#!/usr/bin/env bash
#
# UDC Secret Manager POC — step 2: OpenShift side.
# Applies the manifests, creates the WIF ConfigMap from the credentials.json
# written by step 1, waits for rollouts, prints the app URL.
#
# Needs: oc (logged in to the LZ cluster). Run ./1-gcp-setup.sh first.
# Idempotent — safe to re-run.
#
set -euo pipefail

NAMESPACE="${NAMESPACE:-ucod-hadrezak-sandbox}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# ---------- 0. Pre-flight ----------
log "Pre-flight checks"
[ -f "${SCRIPT_DIR}/credentials.json" ] || { echo "credentials.json missing — run ./1-gcp-setup.sh first"; exit 1; }
oc get namespace "$NAMESPACE" >/dev/null || { echo "namespace ${NAMESPACE} not found / no access"; exit 1; }
oc get csidriver secrets-store.csi.k8s.io >/dev/null 2>&1 || {
  echo "CSIDriver secrets-store.csi.k8s.io not found."
  echo "The Red Hat Secrets Store CSI Driver operator must be installed and its"
  echo "ClusterCSIDriver set to Managed — ask the platform team."; exit 1; }
oc get crd secretproviderclasses.secrets-store.csi.x-k8s.io >/dev/null 2>&1 || {
  echo "SecretProviderClass CRD not found — operator not fully installed."; exit 1; }
echo "OK: driver installed, namespace reachable, credentials.json present"

# ---------- 1. Cluster-scoped RBAC + SCC (needs cluster-admin) ----------
log "Applying cluster-scoped RBAC + SCC grant (manifests/00-rbac-scc.yaml)"
if ! oc apply -f "${SCRIPT_DIR}/manifests/00-rbac-scc.yaml"; then
  echo ""
  echo "FORBIDDEN? You lack cluster-admin. Send manifests/00-rbac-scc.yaml to the"
  echo "platform team, have them apply it, then re-run this script."
  exit 1
fi

# ---------- 2. Keyless WIF ConfigMap (from step 1's output) ----------
log "Creating/updating ConfigMap csi-wif from credentials.json"
oc -n "$NAMESPACE" create configmap csi-wif \
  --from-file=credentials.json="${SCRIPT_DIR}/credentials.json" \
  --dry-run=client -o yaml | oc apply -f -

# ---------- 3. Secret Manager CSI provider ----------
log "Deploying the Google Secret Manager provider (manifests/10-provider.yaml)"
oc apply -f "${SCRIPT_DIR}/manifests/10-provider.yaml"
oc -n "$NAMESPACE" rollout status daemonset/csi-secrets-store-provider-gcp --timeout=180s

# ---------- 4. Application ----------
log "Deploying goapp-sm (manifests/20-app.yaml)"
oc apply -f "${SCRIPT_DIR}/manifests/20-app.yaml"
oc -n "$NAMESPACE" rollout status deployment/goapp-sm --timeout=180s

# ---------- 5. Result ----------
log "Done — verify:"
echo "  App URL:   https://$(oc -n "$NAMESPACE" get route goapp-sm -o jsonpath='{.spec.host}')"
echo "             (page should show 'Loaded' + the masked secret value)"
echo "  Etcd check: oc -n ${NAMESPACE} get secret csi-poc-password   # NotFound = good"
