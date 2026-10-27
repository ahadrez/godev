#!/usr/bin/env bash
#
# UDC Secret Manager POC — step 1: GCP side.
# Creates: test secret, workload identity pool + provider (trusting THIS
# OpenShift cluster's tokens via uploaded JWKS), per-secret IAM binding,
# and the keyless credential file used by step 2.
#
# Needs: gcloud (LZ credentials), oc (logged in to the LZ cluster), jq.
# Idempotent — safe to re-run. `./1-gcp-setup.sh --cleanup` prints teardown.
#
set -euo pipefail

# ---------- Config (edit here if needed) ----------
PROJECT_ID="${PROJECT_ID:-udc-d-30049622-stella-1}"
NAMESPACE="${NAMESPACE:-ucod-hadrezak-sandbox}"
POOL="${POOL:-ocp-csi-poc}"
WIF_PROVIDER="${WIF_PROVIDER:-ocp-lab1}"
AUDIENCE="${AUDIENCE:-https://ocp-csi-poc.example.invalid}"
SECRET_NAME="${SECRET_NAME:-csi-poc-password}"
SECRET_VALUE="${SECRET_VALUE:-POC-DEMO-VALUE-NOT-PRODUCTION}"
PROVIDER_KSA="secrets-store-csi-driver-provider-gcp"   # must match manifests/

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
SUBJECT="system:serviceaccount:${NAMESPACE}:${PROVIDER_KSA}"
MEMBER="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/subject/${SUBJECT}"

if [ "${1:-}" = "--cleanup" ]; then
  cat <<EOF
# GCP cleanup commands (destructive — review first):
gcloud secrets delete ${SECRET_NAME} --project=${PROJECT_ID} --quiet
gcloud iam workload-identity-pools providers delete ${WIF_PROVIDER} \\
  --project=${PROJECT_ID} --location=global --workload-identity-pool=${POOL} --quiet
gcloud iam workload-identity-pools delete ${POOL} --project=${PROJECT_ID} --location=global --quiet
EOF
  exit 0
fi

log "Project: ${PROJECT_ID} (${PROJECT_NUMBER}) | Pool: ${POOL}/${WIF_PROVIDER} | Subject: ${SUBJECT}"

# ---------- 1. Cluster identity (read-only against OpenShift) ----------
log "Exporting the OpenShift cluster's OIDC issuer and public signing keys"
ISSUER=$(oc get --raw /.well-known/openid-configuration | jq -r '.issuer')
oc get --raw /openid/v1/jwks > "${SCRIPT_DIR}/cluster-jwks.json"
echo "Issuer: ${ISSUER}"

# ---------- 2. APIs ----------
log "Enabling required APIs"
gcloud services enable iam.googleapis.com sts.googleapis.com secretmanager.googleapis.com \
  --project="$PROJECT_ID"

# ---------- 3. Test secret ----------
if gcloud secrets describe "$SECRET_NAME" --project="$PROJECT_ID" >/dev/null 2>&1; then
  log "Secret '${SECRET_NAME}' exists — leaving it as is"
else
  log "Creating secret '${SECRET_NAME}'"
  printf '%s' "$SECRET_VALUE" | gcloud secrets create "$SECRET_NAME" \
    --project="$PROJECT_ID" --replication-policy=automatic --data-file=-
fi

# ---------- 4. Workload identity pool + provider (trusts the cluster) ----------
if ! gcloud iam workload-identity-pools describe "$POOL" \
    --project="$PROJECT_ID" --location=global >/dev/null 2>&1; then
  log "Creating workload identity pool '${POOL}'"
  gcloud iam workload-identity-pools create "$POOL" \
    --project="$PROJECT_ID" --location=global --display-name='OpenShift CSI PoC'
fi

if gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER" \
    --project="$PROJECT_ID" --location=global --workload-identity-pool="$POOL" >/dev/null 2>&1; then
  log "Provider '${WIF_PROVIDER}' exists — refreshing its uploaded JWKS"
  gcloud iam workload-identity-pools providers update-oidc "$WIF_PROVIDER" \
    --project="$PROJECT_ID" --location=global --workload-identity-pool="$POOL" \
    --jwk-json-path="${SCRIPT_DIR}/cluster-jwks.json"
else
  log "Creating OIDC provider '${WIF_PROVIDER}' (JWKS uploaded — no public issuer needed)"
  gcloud iam workload-identity-pools providers create-oidc "$WIF_PROVIDER" \
    --project="$PROJECT_ID" --location=global --workload-identity-pool="$POOL" \
    --issuer-uri="$ISSUER" \
    --allowed-audiences="$AUDIENCE" \
    --attribute-mapping='google.subject=assertion.sub' \
    --attribute-condition="assertion.sub == '${SUBJECT}'" \
    --jwk-json-path="${SCRIPT_DIR}/cluster-jwks.json"
fi

# ---------- 5. IAM: this ONE secret only, keyless principal ----------
log "Granting secretAccessor on '${SECRET_NAME}' (only) to the provider's identity"
gcloud secrets add-iam-policy-binding "$SECRET_NAME" \
  --project="$PROJECT_ID" \
  --role='roles/secretmanager.secretAccessor' \
  --member="$MEMBER" >/dev/null

# ---------- 6. Keyless credential file for step 2 (contains NO secrets) ----------
log "Writing credentials.json (external_account config — not a key)"
gcloud iam workload-identity-pools create-cred-config \
  "projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${WIF_PROVIDER}" \
  --credential-source-file=/var/run/wif/token \
  --credential-source-type=text \
  --output-file="${SCRIPT_DIR}/credentials.json"

log "GCP side done. Next:  ./2-openshift-deploy.sh"
