#!/usr/bin/env bash
# Milestone 4 — EBS CSI driver verification.
# Confirms the driver is deployed and healthy, the nodes can reach IMDSv2, and
# runs an end-to-end volume lifecycle: PVC -> EBS volume (via IRSA) -> attach ->
# write -> delete -> volume gone from AWS. Creating the volume is the first AWS
# call the controller makes, so this is also the real test of the M2 IRSA setup.
#
# Usage:  scripts/verify-m4-ebs.sh
# Needs:  kubectl, aws (logged in), a running cluster. Leaves nothing behind.
set -uo pipefail

# Resolve repo layout from this script's location (scripts/ -> repo root).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export KUBECONFIG="${REPO_ROOT}/kubeconfig"
REGION="${AWS_REGION:-eu-central-1}"

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=1; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
FAILED=0

NS=default
NAME=verify-m4-ebs
VOL=""

cleanup() {
  kubectl -n "${NS}" delete pod "${NAME}" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl -n "${NS}" delete pvc "${NAME}" --ignore-not-found --wait=true >/dev/null 2>&1
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
hdr "1. Cluster reachable"
if kubectl get nodes >/dev/null 2>&1; then
  pass "kubectl get nodes"
else
  fail "kubectl get nodes (is the apiserver up / kubeconfig fresh?)"
  echo; echo "Cannot continue without the cluster."; exit 1
fi

hdr "1b. AWS CLI usable"
# Every AWS check below trusts the CLI's exit code, so prove the CLI runs and
# is logged in first — otherwise its errors surface later as nonsense values.
if aws_id=$(aws sts get-caller-identity --query Account --output text 2>&1); then
  pass "aws CLI works (account ${aws_id}, $(command -v aws))"
else
  fail "aws CLI not usable: ${aws_id} ($(command -v aws))"
  echo; echo "Fix the aws CLI (PATH / aws sso login) and re-run."; exit 1
fi

# ---------------------------------------------------------------------------
hdr "2. IMDS reachable from pods (instance metadata options)"
# The node plugin reads its instance ID from IMDSv2. Cilium's tunnel routing
# adds hops, so the default hop limit of 2 drops the token response and the
# node pods crash-loop. See metadata_options in terraform/01-compute.tf.
if ! imds=$(aws ec2 describe-instances --region "${REGION}" \
  --filters "Name=tag:Name,Values=dev-platform-*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,MetadataOptions.HttpTokens,MetadataOptions.HttpPutResponseHopLimit]' \
  --output text 2>&1) || [ -z "${imds}" ]; then
  fail "could not read instance metadata options: ${imds:-no running dev-platform instances}"
else
  while read -r name tokens hops; do
    if [ "${tokens}" = "required" ] && [ "${hops}" -ge 3 ]; then
      pass "${name}: IMDSv2 required, hop limit ${hops}"
    else
      fail "${name}: http_tokens=${tokens} hop_limit=${hops} (want required / >=3)"
    fi
  done <<< "${imds}"
fi

# ---------------------------------------------------------------------------
hdr "3. Driver deployed and healthy"
sync=$(kubectl -n argocd get application ebs-csi -o jsonpath='{.status.sync.status}' 2>/dev/null)
health=$(kubectl -n argocd get application ebs-csi -o jsonpath='{.status.health.status}' 2>/dev/null)
if [ "${sync}" = "Synced" ] && [ "${health}" = "Healthy" ]; then
  pass "ebs-csi Application: Synced/Healthy"
else
  fail "ebs-csi Application: sync=${sync:-<none>} health=${health:-<none>}"
fi

if kubectl -n kube-system rollout status deploy/ebs-csi-controller --timeout=10s >/dev/null 2>&1; then
  pass "ebs-csi-controller available"
else
  fail "ebs-csi-controller not available"
fi

desired=$(kubectl -n kube-system get daemonset ebs-csi-node -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
ready=$(kubectl -n kube-system get daemonset ebs-csi-node -o jsonpath='{.status.numberReady}' 2>/dev/null)
if [ -n "${ready}" ] && [ "${desired}" = "${ready}" ]; then
  pass "ebs-csi-node DaemonSet ${ready}/${desired} ready"
else
  fail "ebs-csi-node DaemonSet ${ready:-0}/${desired:-?} ready (IMDS hop limit? see section 2)"
fi

# ---------------------------------------------------------------------------
hdr "4. Default StorageClass"
default_sc=$(kubectl get storageclass \
  -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}' 2>/dev/null)
case "${default_sc}" in
  "ebs-sc ") pass "ebs-sc is the only default StorageClass" ;;
  "")        fail "no default StorageClass" ;;
  *)         fail "unexpected default StorageClass(es): ${default_sc}" ;;
esac

# ---------------------------------------------------------------------------
hdr "5. End-to-end volume lifecycle"
cleanup  # leftovers from an interrupted run
START=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# PVC without storageClassName, so the default class is exercised too.
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${NAME}
  namespace: ${NS}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
EOF

sleep 5
phase=$(kubectl -n "${NS}" get pvc "${NAME}" -o jsonpath='{.status.phase}' 2>/dev/null)
if [ "${phase}" = "Pending" ]; then
  pass "PVC Pending before any pod exists (WaitForFirstConsumer)"
else
  fail "PVC is ${phase:-<missing>} before any pod exists (want Pending)"
fi

kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${NAME}
  namespace: ${NS}
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: writer
      image: busybox:1.37
      command: [sh, -c, 'echo verify-m4-ebs > /data/probe && cat /data/probe && sleep 3600']
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${NAME}
EOF

if kubectl -n "${NS}" wait --for=condition=Ready "pod/${NAME}" --timeout=180s >/dev/null 2>&1; then
  pass "pod Ready with the volume mounted"
else
  fail "pod not Ready within 180s"
  kubectl -n "${NS}" describe pvc "${NAME}" 2>/dev/null | sed -n '/Events:/,$p' | sed 's/^/    /'
fi

phase=$(kubectl -n "${NS}" get pvc "${NAME}" -o jsonpath='{.status.phase}' 2>/dev/null)
sc=$(kubectl -n "${NS}" get pvc "${NAME}" -o jsonpath='{.spec.storageClassName}' 2>/dev/null)
if [ "${phase}" = "Bound" ] && [ "${sc}" = "ebs-sc" ]; then
  pass "PVC Bound via ebs-sc"
else
  fail "PVC phase=${phase:-<none>} storageClass=${sc:-<none>}"
fi

if [ "$(kubectl -n "${NS}" logs "${NAME}" 2>/dev/null)" = "verify-m4-ebs" ]; then
  pass "pod wrote and read back a file on the volume"
else
  fail "pod could not write/read the volume"
fi

pv=$(kubectl -n "${NS}" get pvc "${NAME}" -o jsonpath='{.spec.volumeName}' 2>/dev/null)
[ -n "${pv}" ] && VOL=$(kubectl get pv "${pv}" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null)
if [ -n "${VOL}" ]; then
  # type encrypted state cluster-tag, e.g. "gp3 True in-use true"
  if ! attrs=$(aws ec2 describe-volumes --region "${REGION}" --volume-ids "${VOL}" \
    --query 'Volumes[0].[VolumeType,Encrypted,State,Tags[?Key==`ebs.csi.aws.com/cluster`]|[0].Value]' \
    --output text 2>&1); then
    fail "describe-volumes ${VOL}: ${attrs}"
    attrs=""
  fi
  read -r vtype venc vstate vtag <<< "${attrs}"
  [ "${vtype}" = "gp3" ]    && pass "${VOL}: gp3"      || fail "${VOL}: type=${vtype:-?} (want gp3)"
  [ "${venc}" = "True" ]    && pass "${VOL}: encrypted" || fail "${VOL}: not encrypted"
  [ "${vstate}" = "in-use" ] && pass "${VOL}: attached (in-use)" || fail "${VOL}: state=${vstate:-?}"
  # AmazonEBSCSIDriverPolicyV2 only lets the driver touch volumes with this tag.
  [ "${vtag}" = "true" ]    && pass "${VOL}: tagged ebs.csi.aws.com/cluster=true" \
                             || fail "${VOL}: missing ebs.csi.aws.com/cluster tag (V2 policy will deny it)"
else
  fail "no EBS volume behind the PVC"
fi

# Delete path: reclaimPolicy Delete must remove the volume from AWS.
cleanup
if [ -n "${VOL}" ]; then
  gone=0
  out=""
  for _ in $(seq 1 36); do
    out=$(aws ec2 describe-volumes --region "${REGION}" --volume-ids "${VOL}" \
            --query 'Volumes[0].State' --output text 2>&1)
    case "${out}" in *InvalidVolume.NotFound*) gone=1; break ;; esac
    sleep 5
  done
  if [ "${gone}" -eq 1 ]; then
    pass "${VOL} deleted from AWS after PVC deletion"
  else
    fail "${VOL} not confirmed deleted after 3 min (last answer: ${out}) — check it by hand"
  fi
fi

# ---------------------------------------------------------------------------
hdr "6. IRSA errors in the controller"
logs=$(kubectl -n kube-system logs deploy/ebs-csi-controller -c ebs-plugin --since-time="${START}" 2>/dev/null)
case "${logs}" in
  *AccessDenied*|*InvalidIdentityToken*|*WebIdentityErr*|*"no EC2 IMDS role found"*)
    fail "credential errors in ebs-plugin logs since ${START}"
    printf '%s\n' "${logs}" | grep -E 'AccessDenied|InvalidIdentityToken|WebIdentityErr|IMDS role' | tail -5 | sed 's/^/    /' ;;
  *)
    pass "no credential errors in ebs-plugin logs during the test" ;;
esac

# ---------------------------------------------------------------------------
echo
if [ "${FAILED}" -eq 0 ]; then
  printf '\033[32mM4 EBS CSI verification passed.\033[0m\n'
else
  printf '\033[31mM4 EBS CSI verification failed.\033[0m\n'
  exit 1
fi
