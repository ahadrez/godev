#!/usr/bin/env bash
#
# Verifies the godev deployment end to end:
#   Config Sync status -> deployment rollout -> LoadBalancer IP -> HTTP check
# Usage: [PROJECT_ID=...] [REGION=...] [CLUSTER_NAME=...] ./scripts/verify.sh
#
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-us-central1}"
CLUSTER_NAME="${CLUSTER_NAME:-godev-autopilot}"
NAMESPACE=godev

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

gcloud container clusters get-credentials "$CLUSTER_NAME" --region "$REGION" --project "$PROJECT_ID" >/dev/null

log "Config Sync status (fleet)"
gcloud beta container fleet config-management status --project "$PROJECT_ID" || true

log "Waiting for Config Sync to create the deployment (up to 5 min)"
for i in $(seq 1 30); do
  kubectl get deployment godev -n "$NAMESPACE" >/dev/null 2>&1 && break
  sleep 10
done
kubectl get deployment godev -n "$NAMESPACE" >/dev/null 2>&1 || {
  echo "Deployment never appeared - check Config Sync:"
  kubectl get rootsync -n config-management-system -o yaml 2>/dev/null | grep -A5 'errors:' || true
  exit 1
}

log "Waiting for rollout"
kubectl rollout status deployment/godev -n "$NAMESPACE" --timeout=5m

log "Current state"
kubectl get pods,svc,configmap -n "$NAMESPACE"
echo
# ConfigMap name carries a kustomize content-hash suffix; resolve it via the deployment's reference
CM_NAME=$(kubectl get deployment godev -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].envFrom[0].configMapRef.name}')
echo "APP_ENV in ConfigMap ($CM_NAME): $(kubectl get configmap "$CM_NAME" -n "$NAMESPACE" -o jsonpath='{.data.APP_ENV}')"
echo "Image: $(kubectl get deployment godev -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}')"

log "Waiting for LoadBalancer external IP (up to 5 min)"
EXTERNAL_IP=""
for i in $(seq 1 30); do
  EXTERNAL_IP=$(kubectl get svc godev -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [ -n "$EXTERNAL_IP" ] && break
  sleep 10
done
[ -n "$EXTERNAL_IP" ] || { echo "No external IP yet; re-run verify.sh in a few minutes"; exit 1; }

log "HTTP check: http://${EXTERNAL_IP}/"
BODY=$(curl -sf --max-time 15 "http://${EXTERNAL_IP}/")
echo "$BODY" | grep -o '<h1>[^<]*</h1>' || true
echo "$BODY" | grep -o 'env-label[^>]*>[^<]*' || true
echo
echo "SUCCESS: app is live at http://${EXTERNAL_IP}/"
