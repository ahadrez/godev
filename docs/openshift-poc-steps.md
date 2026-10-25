# PoC Runbook — OpenShift + Google Secret Manager via Secrets Store CSI

**Scope:** one non-production on-prem OpenShift cluster, one test secret, one
test application pod. No Kubernetes Secret synchronization; no Google
service-account JSON keys; no changes to the OpenShift OIDC issuer. The
open-source GCP provider authenticates with one shared, keyless WIF identity.
**This gives per-cluster, not per-application, IAM isolation — do not promote
to production unchanged** (production guardrails:
[`openshift-landing-zone-runbook.md`](openshift-landing-zone-runbook.md)).

This runbook is self-contained: every manifest is inline. It has not been
executed against your cluster — expect to adapt SCC/SELinux details (§4).

## Prerequisites

- OpenShift version with a supported Red Hat **Secrets Store CSI Driver
  Operator** in OperatorHub. Cluster-admin access (operator install + SCC grant).
- `gcloud` with permission to enable services, create WIF pools/providers,
  manage Secret Manager and IAM; `oc`, `jq`, `curl`, `sed`.
- Worker-node/provider-pod HTTPS connectivity to `sts.googleapis.com` and
  `secretmanager.googleapis.com` (approved proxy or private Google API
  routing). The IAM Credentials API is **not** needed for direct WIF. Mirror
  the provider and test images internally if external registries are blocked.
- A Bash shell with `gcloud` and `oc` pointed at the intended test project and
  cluster.

## 1. Variables and OIDC information

```bash
export PROJECT_ID='udc-cloud-architect-poc'            # or your test project
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
export POOL='ocp-csi-poc'
export PROVIDER='ocp-lab1'
export PROVIDER_NS='csi-poc-system'
export APP_NS='csi-poc'
export POC_AUDIENCE='https://ocp-csi-poc.example.invalid'

export ISSUER="$(oc get --raw /.well-known/openid-configuration | jq -r '.issuer')"
oc get --raw /openid/v1/jwks > cluster-jwks.json
printf 'Issuer: %s\n' "$ISSUER"
```

If the issuer is not HTTPS or looks unexpected, stop and review the cluster's
token configuration — do **not** patch `serviceAccountIssuer`. Google accepts
an uploaded JWKS for private clusters
([official guide](https://docs.cloud.google.com/iam/docs/workload-identity-federation-with-kubernetes)),
so no public OIDC bucket is needed. Re-upload the JWKS if the cluster's
signing keys rotate (`gcloud iam workload-identity-pools providers update-oidc
... --jwk-json-path cluster-jwks.json`).

## 2. GCP: secret + workload identity federation

```bash
gcloud services enable iam.googleapis.com sts.googleapis.com secretmanager.googleapis.com \
  --project="$PROJECT_ID"

printf '%s' 'POC-DEMO-VALUE-NOT-PRODUCTION' | \
  gcloud secrets create csi-poc-password --project="$PROJECT_ID" \
    --replication-policy=automatic --data-file=-

gcloud iam workload-identity-pools create "$POOL" \
  --project="$PROJECT_ID" --location=global --display-name='OpenShift CSI PoC'

gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" \
  --project="$PROJECT_ID" --location=global --workload-identity-pool="$POOL" \
  --issuer-uri="$ISSUER" \
  --allowed-audiences="$POC_AUDIENCE" \
  --attribute-mapping='google.subject=assertion.sub' \
  --attribute-condition="assertion.sub == 'system:serviceaccount:${PROVIDER_NS}:secrets-store-csi-driver-provider-gcp'" \
  --jwk-json-path=cluster-jwks.json

gcloud secrets add-iam-policy-binding csi-poc-password \
  --project="$PROJECT_ID" \
  --role='roles/secretmanager.secretAccessor' \
  --member="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/subject/system:serviceaccount:${PROVIDER_NS}:secrets-store-csi-driver-provider-gcp"
```

The binding grants access **only to the test secret**, and the attribute
condition means only the provider's exact ServiceAccount can federate at all.
The provider still shares that identity across all workloads it serves — it is
not an application isolation boundary.

## 3. OpenShift: install the Red Hat driver

In OperatorHub install **Secrets Store CSI Driver Operator** (Red Hat) into
its default namespace `openshift-cluster-csi-drivers`, then enable the driver
and wait for it to reconcile:

```bash
oc apply -f - <<'EOF'
apiVersion: operator.openshift.io/v1
kind: ClusterCSIDriver
metadata:
  name: secrets-store.csi.k8s.io
spec:
  managementState: Managed
EOF

oc get csidriver secrets-store.csi.k8s.io
oc get clustercsidriver secrets-store.csi.k8s.io
oc get crd secretproviderclasses.secrets-store.csi.x-k8s.io
```

The CSI driver is Red Hat–managed; the **GCP provider below is separate
open-source software**.

## 4. OpenShift: install the Google provider DaemonSet

```bash
oc get namespace "$PROVIDER_NS" >/dev/null 2>&1 || oc create namespace "$PROVIDER_NS"
oc get namespace "$APP_NS"      >/dev/null 2>&1 || oc create namespace "$APP_NS"

# Upstream manifest, moved out of kube-system
curl -fsSLo provider-upstream.yaml \
  https://raw.githubusercontent.com/GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp/main/deploy/provider-gcp-plugin.yaml
sed "s/namespace: kube-system/namespace: ${PROVIDER_NS}/g" \
  provider-upstream.yaml > provider-poc.yaml
oc apply -f provider-poc.yaml

# Narrower than privileged, but still sensitive (hostPath + any UID).
oc adm policy add-scc-to-user hostmount-anyuid \
  -z secrets-store-csi-driver-provider-gcp -n "$PROVIDER_NS"
```

The upstream plugin uses a hostPath socket and an init container that changes
its ownership. `hostmount-anyuid` may suffice, but SELinux/admission behavior
differs between clusters — if pods are rejected or socket writes are denied,
inspect the actual denial before escalating the SCC, and never add
`privileged` outside this disposable PoC namespace.

### 4b. Configure the provider's keyless credentials

```bash
# Official generator for the external_account config (contains NO secrets)
gcloud iam workload-identity-pools create-cred-config \
  "projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}" \
  --credential-source-file='/var/run/wif/token' \
  --credential-source-type=text \
  --output-file=credentials.json

oc -n "$PROVIDER_NS" create configmap csi-wif \
  --from-file=credentials.json=credentials.json

# Inject the projected token + credential file into the provider DaemonSet
oc -n "$PROVIDER_NS" patch daemonset csi-secrets-store-provider-gcp \
  --type=strategic --patch "$(cat <<EOF
spec:
  template:
    spec:
      containers:
        - name: provider
          env:
            - name: GOOGLE_APPLICATION_CREDENTIALS
              value: /var/run/wif/credentials.json
          volumeMounts:
            - name: wif
              mountPath: /var/run/wif
              readOnly: true
      volumes:
        - name: wif
          projected:
            sources:
              - serviceAccountToken:
                  audience: ${POC_AUDIENCE}
                  expirationSeconds: 3600
                  path: token
              - configMap:
                  name: csi-wif
                  items:
                    - key: credentials.json
                      path: credentials.json
EOF
)"

oc -n "$PROVIDER_NS" rollout status daemonset/csi-secrets-store-provider-gcp --timeout=180s
oc -n "$PROVIDER_NS" get pods -o wide
```

`credentials.json` is a non-secret external-account *configuration*, not a
key: it tells the Google client library to read the projected, auto-rotating
ServiceAccount token at `/var/run/wif/token` and exchange it at STS. The token
audience must equal `--allowed-audiences` from §2.

## 5. SecretProviderClass and test pod

```bash
oc apply -f - <<EOF
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: csi-poc
  namespace: ${APP_NS}
spec:
  provider: gcp
  parameters:
    secrets: |
      - resourceName: "projects/${PROJECT_ID}/secrets/csi-poc-password/versions/latest"
        path: "password"
---
apiVersion: v1
kind: Pod
metadata:
  name: csi-demo
  namespace: ${APP_NS}
spec:
  containers:
    - name: demo
      image: registry.access.redhat.com/ubi9/ubi-minimal
      command: ["sleep", "infinity"]
      volumeMounts:
        - name: secrets
          mountPath: /mnt/secrets
          readOnly: true
  volumes:
    - name: secrets
      csi:
        driver: secrets-store.csi.k8s.io
        readOnly: true
        volumeAttributes:
          secretProviderClass: csi-poc
EOF

oc -n "$APP_NS" get pods -w
```

When the pod is Running:

```bash
# Confirm the mount without printing the secret to terminals or logs
oc -n "$APP_NS" exec csi-demo -- ls -l /mnt/secrets
oc -n "$APP_NS" exec csi-demo -- test -s /mnt/secrets/password && echo 'CSI mount OK'

# Expect NotFound — the value must NOT exist as a Kubernetes Secret
oc -n "$APP_NS" get secret csi-poc-password
```

Do not add `secretObjects:` / Secret sync to the SecretProviderClass — keeping
the value out of etcd is the point.

**Optional:** deploy the `godev` app instead of the bare pod (visual masked
proof) — its Deployment from the GKE POC works verbatim with
`driver: secrets-store.csi.k8s.io`, `provider: gcp`, and
`SECRET_FILE=/mnt/secrets/password`; mirror or make its Artifact Registry
image pullable first.

## 6. Troubleshooting

```bash
oc -n "$APP_NS" describe pod csi-demo
oc -n "$PROVIDER_NS" logs daemonset/csi-secrets-store-provider-gcp --tail=100
oc get events -n "$APP_NS" --sort-by=.lastTimestamp | tail -20
```

- `PermissionDenied` → the IAM principal (§2) vs the token `sub`; the
  attribute condition; stale uploaded JWKS.
- STS `invalid_grant` / issuer errors → issuer mismatch, stale JWKS, or the
  projected token audience ≠ `--allowed-audiences`.
- Connection timeout / TLS → DNS, proxy, CA trust, firewall for STS and
  Secret Manager **from the provider pods**, not just your laptop.
- `FailedMount` / socket unavailable → CSI driver pods, provider DaemonSet
  placement, hostPath SCC / SELinux.
- `ImagePullBackOff` → mirror the provider image (and ubi-minimal) internally
  and point the manifests at the mirror.

## Exit criteria

1. Red Hat CSI driver and GCP provider DaemonSets healthy on the test pod's node.
2. Test pod mounts `/mnt/secrets/password` with nonzero content.
3. No Kubernetes Secret containing the value exists (etcd clean).
4. Authentication used only short-lived federated credentials — no Google
   service-account JSON key anywhere.

## Cleanup

```bash
oc -n "$APP_NS" delete pod csi-demo --ignore-not-found
oc -n "$APP_NS" delete secretproviderclass csi-poc --ignore-not-found
oc adm policy remove-scc-from-user hostmount-anyuid \
  -z secrets-store-csi-driver-provider-gcp -n "$PROVIDER_NS"
oc delete -f provider-poc.yaml --ignore-not-found
oc delete namespace "$APP_NS" "$PROVIDER_NS" --ignore-not-found

gcloud secrets delete csi-poc-password --project="$PROJECT_ID" --quiet
gcloud iam workload-identity-pools providers delete "$PROVIDER" \
  --project="$PROJECT_ID" --location=global --workload-identity-pool="$POOL" --quiet
gcloud iam workload-identity-pools delete "$POOL" \
  --project="$PROJECT_ID" --location=global --quiet
```

Cleanup intentionally does **not** remove the shared Red Hat CSI operator or
`ClusterCSIDriver` — remove those only if nothing else uses them. Deletion is
destructive; re-check the variables first.

## References

- Red Hat OpenShift CSI docs: https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/storage/using-container-storage-interface-csi
- Google self-hosted Kubernetes WIF: https://docs.cloud.google.com/iam/docs/workload-identity-federation-with-kubernetes
- GCP provider authentication modes: https://github.com/GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp/blob/main/docs/authentication.md
- GCP provider upstream manifest: https://github.com/GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp/blob/main/deploy/provider-gcp-plugin.yaml
- Production design + guardrails: [`openshift-landing-zone-runbook.md`](openshift-landing-zone-runbook.md)
- GKE POC this builds on: [`secret-manager-poc.md`](secret-manager-poc.md)
