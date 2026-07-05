#!/usr/bin/env bash
# Milestone 2 (IRSA + AWS prerequisites) verification.
# Confirms a from-scratch cluster came up with a working self-hosted OIDC
# provider and all the IRSA plumbing AWS needs.
#
# Usage:  AWS_PROFILE=admin scripts/verify-m2.sh
set -uo pipefail

: "${AWS_PROFILE:=admin}"
export AWS_PROFILE
REGION="eu-central-1"

# Resolve repo layout from this script's location (scripts/ -> repo root).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export KUBECONFIG="${REPO_ROOT}/kubeconfig"

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=1; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
FAILED=0

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_BUCKET="dev-platform-oidc-${ACCOUNT_ID}"
VELERO_BUCKET="dev-platform-velero-${ACCOUNT_ID}"
ISSUER="https://${OIDC_BUCKET}.s3.${REGION}.amazonaws.com"

echo "Account: ${ACCOUNT_ID}   Issuer: ${ISSUER}"

# ---------------------------------------------------------------------------
hdr "1. Cluster reachable"
if kubectl get nodes >/dev/null 2>&1; then
  kubectl get nodes -o wide | sed 's/^/    /'
  pass "kubectl get nodes"
else
  fail "kubectl get nodes (is the apiserver up / kubeconfig fresh?)"
fi

# ---------------------------------------------------------------------------
hdr "2. apiserver advertises the bucket URL as issuer"
API_ISS=$(kubectl get --raw /.well-known/openid-configuration 2>/dev/null \
          | grep -o '"issuer":"[^"]*"' | cut -d'"' -f4)
if [ "$API_ISS" = "$ISSUER" ]; then
  pass "issuer == $ISSUER"
else
  fail "apiserver issuer='$API_ISS' expected '$ISSUER'"
fi

# ---------------------------------------------------------------------------
hdr "3. Discovery doc + JWKS are anonymously readable from S3"
DISC_ISS=$(curl -fsS "${ISSUER}/.well-known/openid-configuration" 2>/dev/null \
           | grep -o '"issuer":"[^"]*"' | cut -d'"' -f4)
if [ "$DISC_ISS" = "$ISSUER" ]; then
  pass "GET ${ISSUER}/.well-known/openid-configuration  (issuer matches)"
else
  fail "anonymous discovery doc unreadable or issuer mismatch (got '$DISC_ISS')"
fi

if curl -fsS "${ISSUER}/openid/v1/jwks" 2>/dev/null | grep -q '"keys"'; then
  pass "GET ${ISSUER}/openid/v1/jwks  (contains keys)"
else
  fail "anonymous JWKS unreadable or empty"
fi

# ---------------------------------------------------------------------------
hdr "4. IAM OIDC provider exists"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_BUCKET}.s3.${REGION}.amazonaws.com"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  pass "$OIDC_ARN"
else
  fail "OIDC provider not found: $OIDC_ARN"
fi

# ---------------------------------------------------------------------------
hdr "5. IRSA roles exist"
for r in dev-platform-ebs-csi dev-platform-aws-lbc dev-platform-velero; do
  if aws iam get-role --role-name "$r" >/dev/null 2>&1; then
    pass "role $r"
  else
    fail "role $r missing"
  fi
done

# ---------------------------------------------------------------------------
hdr "6. Buckets exist + Velero versioning enabled"
for b in "$OIDC_BUCKET" "$VELERO_BUCKET"; do
  if aws s3api head-bucket --bucket "$b" >/dev/null 2>&1; then
    pass "bucket $b"
  else
    fail "bucket $b missing"
  fi
done
VER=$(aws s3api get-bucket-versioning --bucket "$VELERO_BUCKET" --query Status --output text 2>/dev/null)
if [ "$VER" = "Enabled" ]; then
  pass "velero bucket versioning Enabled"
else
  fail "velero bucket versioning='$VER' (expected Enabled)"
fi

# ---------------------------------------------------------------------------
if [ "${FAILED:-0}" -eq 0 ]; then
  printf '\n\033[32mM2 verification: ALL CHECKS PASSED\033[0m\n'
else
  printf '\n\033[31mM2 verification: SOME CHECKS FAILED\033[0m\n'
  exit 1
fi
