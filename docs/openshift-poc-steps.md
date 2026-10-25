# OpenShift POC — Exact Steps

The minimal path to mount a GCP Secret Manager secret in an OpenShift pod.
Reuses the existing POC project (`udc-cloud-architect-poc`) and secret
(`godev-demo`). Full design rationale: [`openshift-landing-zone-runbook.md`](openshift-landing-zone-runbook.md).

**Prerequisites:** cluster-admin on a disposable/dev OpenShift cluster; nodes
can reach `sts.googleapis.com` and `secretmanager.googleapis.com` on 443;
`gcloud` + `oc` on your workstation.

**Variables used throughout:**

```bash
export PROJECT_ID=udc-cloud-architect-poc
export PROJECT_NUMBER=148538518928
export BUCKET=ocp-poc-oidc-${PROJECT_ID}          # must be globally unique
export ISSUER="https://storage.googleapis.com/${BUCKET}"
export POOL=ocp-poc-pool
export WIF_PROVIDER=ocp-poc-cluster
```

---

## Part 1 — ON OPENSHIFT: export the cluster's signing keys (read-only)

```bash
oc get --raw /openid/v1/jwks > keys.json
```

## Part 2 — ON GCP: trust the cluster

```bash
# 2.1 Public bucket hosting the cluster's OIDC discovery docs
gsutil mb -p $PROJECT_ID gs://${BUCKET}
cat > openid-configuration <<EOF
{
  "issuer": "${ISSUER}",
  "jwks_uri": "${ISSUER}/keys.json",
  "response_types_supported": ["id_token"],
  "subject_types_supported": ["public"],
  "id_token_signing_alg_values_supported": ["RS256"]
}
EOF
gsutil cp openid-configuration gs://${BUCKET}/.well-known/openid-configuration
gsutil cp keys.json gs://${BUCKET}/keys.json
gsutil iam ch allUsers:objectViewer gs://${BUCKET}

# 2.2 Workload identity pool + provider for this cluster
gcloud iam workload-identity-pools create $POOL \
  --project $PROJECT_ID --location global
gcloud iam workload-identity-pools providers create-oidc $WIF_PROVIDER \
  --project $PROJECT_ID --location global \
  --workload-identity-pool $POOL \
  --issuer-uri "${ISSUER}" \
  --allowed-audiences "https://secretmanager.ocp-poc" \
  --attribute-mapping "google.subject=assertion.sub"

# 2.3 Grant the provider's future identity access to the ONE secret
gcloud secrets add-iam-policy-binding godev-demo --project $PROJECT_ID \
  --role roles/secretmanager.secretAccessor \
  --member "principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/subject/system:serviceaccount:secrets-store:csi-provider-gcp"
```

## Part 3 — ON OPENSHIFT: everything else

### 3.1 Point the cluster at the new issuer  ⚠️ disruptive — disposable cluster only

```bash
oc patch authentication cluster --type=merge \
  -p "{\"spec\":{\"serviceAccountIssuer\":\"${ISSUER}\"}}"
# wait until PROGRESSING=False again (several minutes):
oc get co kube-apiserver -w
```

### 3.2 Install the Secrets Store CSI Driver operator

Easiest: **web console → OperatorHub → "Secrets Store CSI driver" → Install**
(all defaults). Then enable the driver:

```bash
oc apply -f - <<'EOF'
apiVersion: operator.openshift.io/v1
kind: ClusterCSIDriver
metadata:
  name: secrets-store.csi.k8s.io
spec:
  managementState: Managed
EOF
oc get pods -n openshift-cluster-csi-drivers   # driver DaemonSet pods Running
```

### 3.3 Deploy the GCP provider (keyless, via the WIF config)

```bash
oc new-project secrets-store
oc apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: csi-provider-gcp
  namespace: secrets-store
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: gcp-wif-credentials
  namespace: secrets-store
data:
  config: |
    {
      "type": "external_account",
      "audience": "//iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${WIF_PROVIDER}",
      "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
      "token_url": "https://sts.googleapis.com/v1/token",
      "credential_source": { "file": "/var/run/secrets/tokens/gcp-ksa/token" }
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: csi-provider-gcp
  namespace: secrets-store
spec:
  selector: { matchLabels: { app: csi-provider-gcp } }
  template:
    metadata: { labels: { app: csi-provider-gcp } }
    spec:
      serviceAccountName: csi-provider-gcp
      containers:
        - name: provider
          # pick the latest release: github.com/GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp/releases
          image: us-docker.pkg.dev/secretmanager-csi/secrets-store-csi-driver-provider-gcp/plugin:v1.8.0
          args: ["-provider_volume=/provider"]
          env:
            - name: GOOGLE_APPLICATION_CREDENTIALS
              value: /var/run/secrets/tokens/gcp-ksa/google-application-credentials.json
          volumeMounts:
            - { name: providervol, mountPath: /provider }
            - { name: gcp-ksa, mountPath: /var/run/secrets/tokens/gcp-ksa, readOnly: true }
          securityContext: { privileged: true }
      volumes:
        - name: providervol
          hostPath: { path: /var/run/secrets-store-csi-providers }   # where the RH driver looks for provider sockets
        - name: gcp-ksa
          projected:
            sources:
              - serviceAccountToken:
                  audience: "https://secretmanager.ocp-poc"     # = --allowed-audiences in 2.2
                  expirationSeconds: 3600
                  path: token
              - configMap:
                  name: gcp-wif-credentials
                  items: [{ key: config, path: google-application-credentials.json }]
EOF

# provider needs hostPath + privileged:
oc adm policy add-scc-to-user privileged -z csi-provider-gcp -n secrets-store
oc -n secrets-store get pods    # Running on every node
```

### 3.4 Deploy the test app (godev manifests, two strings changed)

```bash
oc new-project godev
oc apply -f - <<EOF
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: godev-secrets
  namespace: godev
spec:
  provider: gcp                                    # GKE POC had: gke
  parameters:
    secrets: |
      - resourceName: "projects/${PROJECT_ID}/secrets/godev-demo/versions/latest"
        path: "godev-demo"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: godev
  namespace: godev
spec:
  replicas: 1
  selector: { matchLabels: { app: godev } }
  template:
    metadata: { labels: { app: godev } }
    spec:
      containers:
        - name: godev
          image: us-central1-docker.pkg.dev/${PROJECT_ID}/godev/godev:644bffb
          ports: [{ containerPort: 8080 }]
          env:
            - { name: APP_ENV, value: openshift-poc }
            - { name: SECRET_FILE, value: /var/secrets/godev-demo }
          volumeMounts:
            - { name: gcp-secrets, mountPath: /var/secrets, readOnly: true }
      volumes:
        - name: gcp-secrets
          csi:
            driver: secrets-store.csi.k8s.io        # GKE POC had: secrets-store-gke.csi.k8s.io
            readOnly: true
            volumeAttributes: { secretProviderClass: godev-secrets }
EOF
```

**Image pull:** the godev image lives in Artifact Registry. For the POC either
make the repo public (`gcloud artifacts repositories add-iam-policy-binding
godev --location us-central1 --member allUsers --role
roles/artifactregistry.reader`) or create a pull secret; or swap in any public
image and just `cat` the file (3.5).

## Part 4 — Verify

```bash
oc -n godev get pods                                   # 1/1 Running
oc -n godev get secrets                                # nothing app-related → not in etcd
oc -n godev port-forward deploy/godev 8080:8080        # page shows "Loaded" + masked value
# rotation (OSS driver re-fetches without restart if rotation is enabled):
printf '%s' 'ocp-rotated' | gcloud secrets versions add godev-demo --data-file=- --project $PROJECT_ID
```

**If the pod is stuck `ContainerCreating`:** `oc -n godev describe pod` —
`PermissionDenied` → the IAM principal in 2.3 doesn't match the token `sub`;
`connection refused`/socket errors → provider DaemonSet or SCC (3.3);
`invalid_grant`/issuer errors → bucket contents or the audience mismatch
(2.2 vs 3.3).

## Cleanup (GCP side)

```bash
gcloud iam workload-identity-pools delete $POOL --location global --project $PROJECT_ID
gsutil rm -r gs://${BUCKET}
gcloud secrets remove-iam-policy-binding godev-demo --project $PROJECT_ID \
  --role roles/secretmanager.secretAccessor --member "principal://...(same as 2.3)"
```
