#!/usr/bin/env bash
#
# Secret Manager POC setup for godev:
#   1. Enables the GKE built-in Secret Manager add-on (Secrets Store CSI driver)
#   2. Creates the demo secret 'godev-demo'
#   3. Grants the godev KSA access to THAT secret only, via Workload Identity
#      Federation for GKE - no Google service account, no keys
#
# Idempotent: safe to re-run. Usage:
#   PROJECT_ID=my-project [SECRET_VALUE='s3cret-from-gcp'] ./scripts/setup-secrets.sh
#
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-us-central1}"
CLUSTER_NAME="${CLUSTER_NAME:-godev-autopilot}"
SECRET_NAME="${SECRET_NAME:-godev-demo}"
SECRET_VALUE="${SECRET_VALUE:-hello-from-secret-manager}"
NAMESPACE="godev"
KSA="godev"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

[ -n "$PROJECT_ID" ] || { echo "PROJECT_ID is not set and no gcloud default project found"; exit 1; }
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
log "Project: $PROJECT_ID ($PROJECT_NUMBER) | Cluster: $CLUSTER_NAME | Secret: $SECRET_NAME"

# ---------- 1. Secret Manager add-on (Secrets Store CSI driver, GKE provider) ----------
# Autopilot blocks privileged DaemonSets, so the self-installed driver is not an
# option here; the managed add-on provides the same SecretProviderClass API.
if [ "$(gcloud container clusters describe "$CLUSTER_NAME" --region "$REGION" --project "$PROJECT_ID" \
      --format='value(secretManagerConfig.enabled)')" != "True" ]; then
  log "Enabling Secret Manager add-on on $CLUSTER_NAME (can take a few minutes)"
  gcloud container clusters update "$CLUSTER_NAME" \
    --region "$REGION" --project "$PROJECT_ID" \
    --enable-secret-manager
else
  log "Secret Manager add-on already enabled"
fi

# ---------- 2. Demo secret ----------
if gcloud secrets describe "$SECRET_NAME" --project "$PROJECT_ID" >/dev/null 2>&1; then
  log "Secret '$SECRET_NAME' exists - adding a new version"
else
  log "Creating secret '$SECRET_NAME'"
  gcloud secrets create "$SECRET_NAME" \
    --replication-policy=automatic \
    --project "$PROJECT_ID" \
    --labels=app=godev,managed-by=setup-secrets
fi
printf '%s' "$SECRET_VALUE" | gcloud secrets versions add "$SECRET_NAME" --data-file=- --project "$PROJECT_ID"

# ---------- 3. IAM: least-privilege, keyless ----------
# Workload Identity Federation for GKE lets us grant IAM directly to the KSA
# principal - the same model (a WIF principal) you will use from on-prem
# OpenShift, where the pool is backed by the cluster's OIDC issuer instead.
PRINCIPAL="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/${NAMESPACE}/sa/${KSA}"
log "Granting secretAccessor on '$SECRET_NAME' (only) to $NAMESPACE/$KSA"
gcloud secrets add-iam-policy-binding "$SECRET_NAME" \
  --member "$PRINCIPAL" \
  --role roles/secretmanager.secretAccessor \
  --project "$PROJECT_ID" >/dev/null

log "Done. After Config Sync applies config-sync/, verify with:"
echo "  kubectl -n $NAMESPACE exec deploy/godev -- cat /var/secrets/$SECRET_NAME"
echo "  kubectl -n $NAMESPACE port-forward svc/godev 8080:80   # then open http://localhost:8080"
