#!/usr/bin/env bash
#
# One-shot infrastructure deployment for godev:
#   1. Enables required GCP APIs
#   2. Creates an Artifact Registry docker repo
#   3. Creates a GKE Autopilot cluster (fleet-registered)
#   4. Enables Config Management and points Config Sync at this repo's config-sync/ dir
#   5. Grants Cloud Build the IAM it needs, stores the GitHub PAT (if provided),
#      and creates the build trigger on push to main
#   6. Runs an initial build, pins the image tag in the manifests, pushes the commit
#   7. Waits for Config Sync + the rollout, then curls the app
#
# Idempotent: safe to re-run. Usage:
#   PROJECT_ID=my-project [GITHUB_TOKEN=ghp_xxx] [APP_ENV=production] ./scripts/setup-infra.sh
#
set -euo pipefail

# ---------- Config (override via env) ----------
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-us-central1}"
CLUSTER_NAME="${CLUSTER_NAME:-godev-autopilot}"
AR_REPO="${AR_REPO:-godev}"
APP_ENV="${APP_ENV:-production}"
REPO_OWNER="${REPO_OWNER:-ahadrez}"
REPO_NAME="${REPO_NAME:-godev}"
SYNC_REPO="https://github.com/${REPO_OWNER}/${REPO_NAME}"
SYNC_BRANCH="${SYNC_BRANCH:-main}"
POLICY_DIR="${POLICY_DIR:-config-sync}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/godev"
PUSH_CONFIG="${PUSH_CONFIG:-true}"   # set false to skip git commit/push of manifests

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

[ -n "$PROJECT_ID" ] || { echo "PROJECT_ID is not set and no gcloud default project found"; exit 1; }
log "Project: $PROJECT_ID | Region: $REGION | Cluster: $CLUSTER_NAME | APP_ENV: $APP_ENV"

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')

# ---------- 1. APIs ----------
log "Enabling APIs"
gcloud services enable \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  secretmanager.googleapis.com \
  gkehub.googleapis.com \
  anthosconfigmanagement.googleapis.com \
  --project "$PROJECT_ID"

# ---------- 2. Artifact Registry ----------
log "Creating Artifact Registry repo '$AR_REPO' (if missing)"
gcloud artifacts repositories describe "$AR_REPO" --location "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1 || \
  gcloud artifacts repositories create "$AR_REPO" \
    --repository-format=docker --location "$REGION" \
    --description "godev app images" --project "$PROJECT_ID"

# ---------- 3. GKE Autopilot ----------
log "Creating GKE Autopilot cluster '$CLUSTER_NAME' (if missing) - this can take ~10 min"
gcloud container clusters describe "$CLUSTER_NAME" --region "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1 || \
  gcloud container clusters create-auto "$CLUSTER_NAME" \
    --region "$REGION" --project "$PROJECT_ID" \
    --fleet-project "$PROJECT_ID"

gcloud container clusters get-credentials "$CLUSTER_NAME" --region "$REGION" --project "$PROJECT_ID"

# Fleet membership (create-auto --fleet-project registers it; resolve the name)
MEMBERSHIP=$(gcloud container fleet memberships list --project "$PROJECT_ID" \
  --format='value(name)' --filter="name~${CLUSTER_NAME}" | head -1)
[ -n "$MEMBERSHIP" ] || { echo "Cluster is not fleet-registered; aborting"; exit 1; }
log "Fleet membership: $MEMBERSHIP"

# ---------- 4. Config Sync ----------
log "Enabling Config Management and applying Config Sync spec"
gcloud beta container fleet config-management enable --project "$PROJECT_ID"

APPLY_SPEC=$(mktemp)
cat > "$APPLY_SPEC" <<EOF
applySpecVersion: 1
spec:
  configSync:
    enabled: true
    sourceFormat: unstructured
    syncRepo: ${SYNC_REPO}
    syncBranch: ${SYNC_BRANCH}
    secretType: none
    policyDir: ${POLICY_DIR}
EOF
gcloud beta container fleet config-management apply \
  --membership "$MEMBERSHIP" --config "$APPLY_SPEC" --project "$PROJECT_ID"
rm -f "$APPLY_SPEC"

# ---------- 5. Cloud Build: IAM, secret, trigger ----------
log "Granting Cloud Build service accounts AR/logs/secret access"
for SA in "${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" "${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"; do
  for ROLE in roles/artifactregistry.writer roles/logging.logWriter roles/secretmanager.secretAccessor; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member "serviceAccount:${SA}" --role "$ROLE" --condition=None --quiet >/dev/null
  done
done

if [ -n "${GITHUB_TOKEN:-}" ]; then
  log "Storing GitHub PAT in Secret Manager as 'github-token'"
  if gcloud secrets describe github-token --project "$PROJECT_ID" >/dev/null 2>&1; then
    printf '%s' "$GITHUB_TOKEN" | gcloud secrets versions add github-token --data-file=- --project "$PROJECT_ID"
  else
    printf '%s' "$GITHUB_TOKEN" | gcloud secrets create github-token --data-file=- --project "$PROJECT_ID"
  fi
else
  log "GITHUB_TOKEN not provided - CI will push images but won't auto-bump manifests (GitOps step will skip)"
fi

log "Creating Cloud Build trigger (needs the GitHub repo connected to Cloud Build once, via console)"
if ! gcloud builds triggers describe godev-main --project "$PROJECT_ID" --region "$REGION" >/dev/null 2>&1; then
  gcloud builds triggers create github \
    --name godev-main \
    --repo-owner "$REPO_OWNER" --repo-name "$REPO_NAME" \
    --branch-pattern '^main$' \
    --build-config cloudbuild.yaml \
    --ignored-files 'config-sync/**' \
    --region "$REGION" --project "$PROJECT_ID" || \
    echo "WARNING: trigger creation failed - connect the repo at
    https://console.cloud.google.com/cloud-build/triggers/connect?project=${PROJECT_ID}
    then re-run this script. Continuing without the trigger."
fi

# ---------- 6. Initial build + manifest pin ----------
SHORT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD)
log "Running initial build for ${IMAGE}:${SHORT_SHA}"
gcloud builds submit "$REPO_ROOT" \
  --config "$REPO_ROOT/cloudbuild.yaml" \
  --substitutions "SHORT_SHA=${SHORT_SHA},_REGION=${REGION},_AR_REPO=${AR_REPO}" \
  --region "$REGION" --project "$PROJECT_ID"

log "Pinning image tag and APP_ENV in config-sync manifests"
sed -i '' -E "s|newTag: .*|newTag: ${SHORT_SHA}|" "$REPO_ROOT/config-sync/kustomization.yaml" 2>/dev/null || \
  sed -i -E "s|newTag: .*|newTag: ${SHORT_SHA}|" "$REPO_ROOT/config-sync/kustomization.yaml"
sed -i '' -E "s|(APP_ENV: ).*|\1${APP_ENV}|" "$REPO_ROOT/config-sync/configmap.yaml" 2>/dev/null || \
  sed -i -E "s|(APP_ENV: ).*|\1${APP_ENV}|" "$REPO_ROOT/config-sync/configmap.yaml"

if [ "$PUSH_CONFIG" = "true" ] && [ -n "$(git -C "$REPO_ROOT" status --porcelain -- config-sync/)" ]; then
  log "Committing and pushing manifest changes (Config Sync reads from GitHub)"
  git -C "$REPO_ROOT" add config-sync/
  git -C "$REPO_ROOT" commit -m "infra: pin godev image ${SHORT_SHA}, APP_ENV=${APP_ENV}"
  git -C "$REPO_ROOT" push origin "$SYNC_BRANCH"
fi

# ---------- 7. Verify ----------
"$REPO_ROOT/scripts/verify.sh"
