#!/usr/bin/env bash
# Milestone 3 (Argo CD seed + App-of-Apps) verification.
# Confirms Terraform's seed landed, the root Application adopted its children,
# and the SOPS tooling is actually present inside repo-server.
#
# Usage:  scripts/verify-m3.sh
set -uo pipefail

# Resolve repo layout from this script's location (scripts/ -> repo root).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export KUBECONFIG="${REPO_ROOT}/kubeconfig"

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=1; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
FAILED=0

# ---------------------------------------------------------------------------
hdr "1. Cluster reachable"
if kubectl get nodes >/dev/null 2>&1; then
  kubectl get nodes -o wide | sed 's/^/    /'
  pass "kubectl get nodes"
else
  fail "kubectl get nodes (is the apiserver up / kubeconfig fresh?)"
  echo; echo "Cannot continue without the cluster."; exit 1
fi

# ---------------------------------------------------------------------------
hdr "2. Argo CD components running"
for d in argocd-server argocd-repo-server argocd-redis argocd-applicationset-controller; do
  if kubectl -n argocd rollout status "deploy/${d}" --timeout=10s >/dev/null 2>&1; then
    pass "${d} available"
  else
    fail "${d} not available"
  fi
done
if kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=10s >/dev/null 2>&1; then
  pass "argocd-application-controller available"
else
  fail "argocd-application-controller not available"
fi

# dex and notifications are switched off in values; make sure they stayed off.
for d in argocd-dex-server argocd-notifications-controller; do
  if kubectl -n argocd get deploy "${d}" >/dev/null 2>&1; then
    warn "${d} exists but should be disabled"
  else
    pass "${d} absent (disabled by values)"
  fi
done

# ---------------------------------------------------------------------------
hdr "3. CRDs installed"
for crd in applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io; do
  if kubectl get crd "${crd}" >/dev/null 2>&1; then
    pass "${crd}"
  else
    fail "${crd} missing"
  fi
done

# ---------------------------------------------------------------------------
hdr "4. Root Application and its children"
if kubectl -n argocd get application root >/dev/null 2>&1; then
  pass "root Application exists"
  kubectl -n argocd get applications \
    -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
    2>/dev/null | sed 's/^/    /'
else
  fail "root Application missing (did helm_release.argocd_root_app apply?)"
fi

for app in argocd cilium; do
  sync=$(kubectl -n argocd get application "${app}" -o jsonpath='{.status.sync.status}' 2>/dev/null)
  health=$(kubectl -n argocd get application "${app}" -o jsonpath='{.status.health.status}' 2>/dev/null)
  if [ "${sync}" = "Synced" ] && [ "${health}" = "Healthy" ]; then
    pass "${app}: Synced/Healthy"
  else
    fail "${app}: sync=${sync:-<none>} health=${health:-<none>}"
  fi
done

# ---------------------------------------------------------------------------
hdr "5. SOPS tooling inside repo-server"
POD=$(kubectl -n argocd get pod -l app.kubernetes.io/name=argocd-repo-server \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "${POD}" ]; then
  fail "no repo-server pod found"
else
  if kubectl -n argocd exec "${POD}" -c argocd-repo-server -- sops --version >/dev/null 2>&1; then
    pass "sops binary on PATH ($(kubectl -n argocd exec "${POD}" -c argocd-repo-server -- sops --version 2>/dev/null | head -1))"
  else
    fail "sops binary not runnable in repo-server"
  fi

  if kubectl -n argocd exec "${POD}" -c argocd-repo-server -- \
       test -r /home/argocd/.config/sops/age/keys.txt >/dev/null 2>&1; then
    pass "age key readable at SOPS_AGE_KEY_FILE"
  else
    fail "age key not readable (check the argocd-sops-age-key Secret)"
  fi
fi

# ---------------------------------------------------------------------------
hdr "6. Cilium handover"
# Argo CD should own Cilium now; Terraform should have been told to let go.
if (cd "${REPO_ROOT}/terraform" && terraform state list 2>/dev/null | grep -qx 'helm_release.cilium'); then
  warn "helm_release.cilium still in Terraform state — run: terraform state rm helm_release.cilium"
else
  pass "helm_release.cilium no longer in Terraform state"
fi

if kubectl -n kube-system get daemonset cilium >/dev/null 2>&1; then
  desired=$(kubectl -n kube-system get daemonset cilium -o jsonpath='{.status.desiredNumberScheduled}')
  ready=$(kubectl -n kube-system get daemonset cilium -o jsonpath='{.status.numberReady}')
  if [ "${desired}" = "${ready}" ] && [ -n "${ready}" ]; then
    pass "cilium DaemonSet ${ready}/${desired} ready (adoption did not disrupt the CNI)"
  else
    fail "cilium DaemonSet ${ready:-0}/${desired:-?} ready"
  fi
else
  fail "cilium DaemonSet missing"
fi

# ---------------------------------------------------------------------------
echo
if [ "${FAILED}" -eq 0 ]; then
  printf '\033[32mM3 verification passed.\033[0m\n'
  echo
  echo "Argo CD UI:  kubectl -n argocd port-forward svc/argocd-server 8080:80"
  echo "Admin pass:  kubectl -n argocd get secret argocd-initial-admin-secret \\"
  echo "               -o jsonpath='{.data.password}' | base64 -d; echo"
else
  printf '\033[31mM3 verification failed.\033[0m\n'
  exit 1
fi
