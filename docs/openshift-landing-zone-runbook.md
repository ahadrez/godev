# OpenShift + GCP Secret Manager — Landing Zone Runbook

**Scope:** implement centralized secrets management for on-prem Red Hat
OpenShift clusters using Google Cloud Secret Manager and the Secrets Store CSI
Driver, integrated into the GCP landing zone. Applications consume secrets as
files from tmpfs; nothing is persisted in OpenShift etcd; no service account
keys exist anywhere.

**Prior art:** the pattern was proven end-to-end on GKE — see
[`secret-manager-poc.md`](secret-manager-poc.md). This runbook covers what is
*different* on-prem, plus the landing-zone integration work.

---

## 1. Target architecture

```mermaid
flowchart LR
    subgraph onprem["On-prem data center"]
        subgraph ocp["OpenShift cluster"]
            OIDC["Cluster OIDC issuer<br/>(bound SA tokens)"]
            PROV["CSI driver + GCP provider<br/>DaemonSets (cluster service)"]
            subgraph app["App namespace"]
                SPC["SecretProviderClass"]
                POD["App pod — tmpfs file mount"]
            end
        end
    end

    subgraph gcp["GCP landing zone"]
        BKT["Cluster JWKS<br/>(uploaded to the provider;<br/>GCS bucket only as fallback)"]
        WIF["Workload Identity Pool<br/>+ OIDC provider (per cluster)"]
        STS["Security Token Service"]
        SM["Secret Manager<br/>(secrets project per env)"]
        LOG["Cloud Audit Logs<br/>(data access)"]
    end

    OIDC -. "public signing keys exported to" .-> BKT
    WIF -- "validates tokens against" --> BKT
    PROV -- "projected SA token" --> STS
    STS -- "trusts" --> WIF
    PROV -- "federated access token" --> SM
    SM --> LOG
    SPC --> PROV
    PROV --> POD
```

**Auth flow:** the provider DaemonSet presents its projected Kubernetes SA
token to GCP STS; STS validates it against the workload identity pool provider
(which validates the signature against the cluster's uploaded JWKS — or fetches it
from the discovery bucket in the Option B fallback);
the returned federated token calls Secret Manager. Keyless end to end.

### ⚠️ The one architectural difference vs the GKE POC

On GKE, IAM sees the **application pod's** ServiceAccount (per-pod identity).
With the self-managed provider off-GKE, the token exchanged is the **provider
DaemonSet's** — so IAM granularity is **per cluster**, not per app.
Consequences and mitigations are in [§6 Guardrails](#6-guardrails--the-per-cluster-identity-gap).
(Keep per-pod ambitions in view: fleet/attached-cluster support and provider
auth modes evolve — re-check
[authentication.md](https://github.com/GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp/blob/main/docs/authentication.md)
at implementation time.)

## 2. Landing-zone prerequisites

| Item | Decision / action |
|---|---|
| **Projects** | A `secrets-<env>` project per environment (dev/test/prod) holding Secret Manager secrets; a shared `identity` project holding the workload identity pools. Keeps IAM administration separable from app projects. |
| **APIs** | `secretmanager.googleapis.com`, `sts.googleapis.com`, `iamcredentials.googleapis.com` (only if impersonating GSAs), `iam.googleapis.com`. |
| **Network egress** | Cluster nodes must reach `sts.googleapis.com` and `secretmanager.googleapis.com` (TCP 443). Over Interconnect/VPN use **Private Google Access**: DNS-map `*.googleapis.com` → `private.googleapis.com` (199.36.153.8/30), or `restricted.googleapis.com` if VPC Service Controls are in scope. A corporate HTTPS proxy also works (the provider honors `HTTPS_PROXY`). |
| **The issuer bucket** | Only needed for the Option B fallback in Phase 1 (public read on two small JSON files containing only public keys; the *cluster* never reads it). Option A uploads the JWKS directly and needs no bucket. |
| **Org policies** | Keep `iam.disableServiceAccountKeyCreation` enforced (this design needs no keys). If `iam.workloadIdentityPoolProviders` (allowed external issuers) is enforced, allowlist the issuer URLs created in Phase 1. |
| **Audit** | Enable Data Access logs for Secret Manager in each `secrets-<env>` project — every secret read becomes an audit entry attributing the cluster identity. |
| **Naming** | Secrets: `<app>-<name>` (e.g. `godev-db-password`). Pools: `ocp-<site>-pool`. Providers: one per cluster, `ocp-<cluster>`. |

## 3. Phase 1 — Give each cluster a GCP-verifiable identity

Two options, per the
[official WIF-with-Kubernetes guide](https://docs.cloud.google.com/iam/docs/workload-identity-federation-with-kubernetes):

**Option A — upload the JWKS to the provider (recommended, zero cluster
changes).** Export the cluster's public signing keys and hand them to the
workload identity provider in Phase 2 via `--jwk-json-path`. The issuer is
never fetched by Google, so it needs no public reachability and the cluster
keeps its existing `serviceAccountIssuer`:

```bash
oc get --raw /openid/v1/jwks > jwks.json
ISSUER=$(oc get --raw /.well-known/openid-configuration | jq -r .issuer)
```

Trade-off: Google validates against the *uploaded* keys, so when the cluster
rotates its SA signing keys you must re-run the export and
`gcloud iam workload-identity-pools providers update-oidc ... --jwk-json-path
jwks.json`. Automate with a CronJob that diffs `/openid/v1/jwks` against the
provider. Also note issuer URIs must be distinguishable per provider — if all
clusters use the default `https://kubernetes.default.svc`, give each cluster
its own pool (this runbook already does one provider per cluster; make it one
pool per cluster if issuers collide).

**Option B — public discovery bucket + issuer change (fallback).** Host
`.well-known/openid-configuration` + the JWKS in a public GCS bucket and patch
`spec.serviceAccountIssuer` to the bucket URL. Google then fetches keys
dynamically (no manual re-upload on rotation). **Maintenance-window change:**
updating `serviceAccountIssuer` invalidates in-flight bound SA tokens, rolls
the kube-apiserver, and workloads using bound tokens need a restart — same
procedure class as OpenShift STS on AWS. Prefer Option A unless the manual
key-rotation step is unacceptable operationally.

## 4. Phase 2 — Workload Identity Pool + provider (per cluster)

```bash
ID_PROJECT=<identity-project>
ID_PROJECT_NUMBER=$(gcloud projects describe $ID_PROJECT --format='value(projectNumber)')
POOL=ocp-onprem-pool
PROVIDER=ocp-cluster1

gcloud iam workload-identity-pools create $POOL \
  --project $ID_PROJECT --location global \
  --display-name "On-prem OpenShift clusters"

gcloud iam workload-identity-pools providers create-oidc $PROVIDER \
  --project $ID_PROJECT --location global \
  --workload-identity-pool $POOL \
  --issuer-uri "${ISSUER}" \
  --jwk-json-path jwks.json \
  --allowed-audiences "https://secretmanager.ocp" \
  --attribute-mapping "google.subject=assertion.sub" \
  --attribute-condition "assertion.sub.startsWith('system:serviceaccount:secrets-store:')"
```

(Drop `--jwk-json-path` if you chose Option B — Google discovers the keys
from the issuer bucket instead.)

Decisions baked in above:

- **One provider per cluster** — lets you revoke a single cluster instantly
  (delete its provider) and keeps audit attribution clean.
- **`--allowed-audiences`** — an arbitrary constant you also set on the
  projected token in Phase 3; prevents token reuse against other relying parties.
- **`--attribute-condition`** — only tokens of ServiceAccounts in the
  `secrets-store` namespace can federate. Even a stolen token from another
  namespace is useless at STS.

The principal you will grant IAM to (note the K8s token `sub` format):

```
principal://iam.googleapis.com/projects/${ID_PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/subject/system:serviceaccount:secrets-store:csi-provider-gcp
```

## 5. Phase 3 — Install the driver and the GCP provider

**5a. Secrets Store CSI Driver** — install the Red Hat **Secrets Store CSI
Driver Operator** from OperatorHub (cluster-wide), then:

```yaml
apiVersion: operator.openshift.io/v1
kind: ClusterCSIDriver
metadata:
  name: secrets-store.csi.k8s.io
spec:
  managementState: Managed
```

**5b. GCP provider DaemonSet** — deploy into a dedicated `secrets-store`
namespace (manifests from the
[provider repo](https://github.com/GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp),
adapted). The pieces that differ from stock:

```yaml
# ServiceAccount whose token is federated (matches the attribute-condition + principal above)
apiVersion: v1
kind: ServiceAccount
metadata:
  name: csi-provider-gcp
  namespace: secrets-store
---
# external_account ADC config — contains NO secrets, only pointers
apiVersion: v1
kind: ConfigMap
metadata:
  name: gcp-wif-credentials
  namespace: secrets-store
data:
  config: |
    {
      "type": "external_account",
      "audience": "//iam.googleapis.com/projects/<ID_PROJECT_NUMBER>/locations/global/workloadIdentityPools/ocp-onprem-pool/providers/ocp-cluster1",
      "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
      "token_url": "https://sts.googleapis.com/v1/token",
      "credential_source": { "file": "/var/run/secrets/tokens/gcp-ksa/token" }
    }
```

In the provider DaemonSet pod spec:

```yaml
serviceAccountName: csi-provider-gcp
containers:
  - name: provider
    env:
      - name: GOOGLE_APPLICATION_CREDENTIALS
        value: /var/run/secrets/tokens/gcp-ksa/google-application-credentials.json
    volumeMounts:
      - { name: gcp-ksa, mountPath: /var/run/secrets/tokens/gcp-ksa, readOnly: true }
volumes:
  - name: gcp-ksa
    projected:
      sources:
        - serviceAccountToken:
            audience: "https://secretmanager.ocp"   # matches --allowed-audiences
            expirationSeconds: 3600
            path: token
        - configMap:
            name: gcp-wif-credentials
            items: [{ key: config, path: google-application-credentials.json }]
```

**OpenShift-specific:** the driver and provider DaemonSets need hostPath access
to the kubelet dir → privileged SCC:

```bash
oc adm policy add-scc-to-user privileged -z csi-provider-gcp -n secrets-store
```

**Rotation:** the OSS driver supports live re-fetch — enable
`--enable-secret-rotation` / `--rotation-poll-interval=2m` (via the operator's
config if exposed, else the driver DaemonSet args). Apps then see rotated
values *without restart* — better than the GKE add-on.

## 6. Guardrails — the per-cluster identity gap

Because Secret Manager sees one identity per cluster, any namespace could
otherwise mount any secret that cluster can read. Close the gap in layers:

1. **IAM (blast-radius ceiling):** grant `roles/secretmanager.secretAccessor`
   to the cluster principal **per secret** in the env's secrets project —
   never project-wide. A cluster can only ever read the union of secrets
   explicitly granted to it:
   ```bash
   gcloud secrets add-iam-policy-binding godev-db-password \
     --project secrets-prod \
     --role roles/secretmanager.secretAccessor \
     --member "principal://iam.googleapis.com/projects/${ID_PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/subject/system:serviceaccount:secrets-store:csi-provider-gcp"
   ```
2. **Admission policy (namespace isolation):** enforce with Gatekeeper/Kyverno
   that a `SecretProviderClass` in namespace `X` may only reference
   `projects/*/secrets/X-*`. Namespace = app ownership boundary, same net
   effect as per-app IAM. Example Kyverno rule: deny if any
   `spec.parameters.secrets[].resourceName` does not match
   `projects/*/secrets/{{request.namespace}}-*`.
3. **RBAC:** app teams get create/update on `SecretProviderClass` only in
   their namespaces (mirror of the `role-secretproviderclass.yaml` pattern
   from the POC, GitOps-delivered).
4. **Audit:** Secret Manager data-access logs + the admission policy's audit
   mode give you both "what was read" and "who tried to cross the line".

> **If per-pod identity becomes a hard requirement:** External Secrets
> Operator supports per-namespace `SecretStore`s each federating its own
> namespace SA — true per-app IAM — at the cost of materializing values as
> Kubernetes Secrets in etcd (encrypt etcd + RBAC if you go there). Trade-off,
> not an upgrade.

## 7. Phase 4 — App onboarding (the easy part)

Per app, exactly the POC pattern with the two strings swapped:

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: godev-secrets
  namespace: godev
spec:
  provider: gcp                      # was: gke
  parameters:
    secrets: |
      - resourceName: "projects/secrets-prod/secrets/godev-db-password/versions/latest"
        path: "db-password"
---
# Deployment volume
volumes:
  - name: gcp-secrets
    csi:
      driver: secrets-store.csi.k8s.io   # was: secrets-store-gke.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: godev-secrets
```

App reads `/var/secrets/db-password` as a file. The `godev` app in this repo
is the reference implementation (file read + masked status page).

## 8. Phase 5 — Validation checklist

- [ ] `oc -n secrets-store get pods` — driver + provider DaemonSets healthy on all nodes
- [ ] Test pod in a test namespace mounts a test secret (file present, correct value)
- [ ] `oc get secrets -A | grep <app>` — nothing materialized in etcd
- [ ] Negative test: SecretProviderClass referencing an *ungran­ted* secret → mount fails with `PermissionDenied`
- [ ] Negative test: SecretProviderClass referencing another namespace's secret prefix → blocked by admission policy
- [ ] Rotation: add a secret version → file updates within the poll interval, no restart
- [ ] Cloud Audit Logs show the access entries attributed to the cluster principal
- [ ] Revocation drill (non-prod): delete the cluster's WIF provider → mounts fail cluster-wide; recreate → recover

## 9. Rollout plan

1. **Dev cluster first** (Phases 1–5). With Phase 1 Option A there is no
   disruptive step; if you chose Option B, rehearse the issuer-change
   maintenance window here — it is the step with real blast radius.
2. Onboard one pilot app (godev-equivalent), run the validation checklist and
   the revocation drill.
3. Write the Kyverno/Gatekeeper policy, test in audit mode, then enforce.
4. Template Phases 2–3 (Terraform in the landing-zone repo: pool, provider,
   JWKS upload, per-secret IAM; Helm/kustomize for the cluster components).
5. Repeat per cluster: each prod cluster gets its own provider (own pool if
   the default issuer URIs collide).
6. Migrate apps incrementally: for each hardcoded/unmanaged secret → create in
   Secret Manager → grant to cluster → SecretProviderClass + volume → delete
   the old Kubernetes Secret → verify etcd clean.

## 10. Reference

- Provider auth modes: [authentication.md](https://github.com/GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp/blob/main/docs/authentication.md)
- WIF credential config for the provider: [fleet-wif-notes.md](https://github.com/GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp/blob/main/docs/fleet-wif-notes.md)
- Red Hat: [Secret Store CSI driver on OpenShift](https://www.redhat.com/en/blog/introducing-the-secret-store-csi-driver-in-openshift)
- GKE POC this builds on: [`secret-manager-poc.md`](secret-manager-poc.md)
