#!/usr/bin/env bash
# install-portworx-rosa.sh — Install Portworx Enterprise on an existing ROSA cluster.
#
# Scope (idempotent; a Y/n gate precedes each mutating step):
#   1. AWS IAM user + policy + access key
#   2. aws-creds secret in the Portworx namespace
#   3. Open Portworx ports on the worker security group(s)
#   4. Enable user-workload monitoring
#   5. Install the Portworx operator via OLM (auto-discover, skip-if-installed)
#   6. Apply the PX-Central StorageCluster spec + enable console plugin
#   7. Verify cluster / pods / pool / provision status
#
# The StorageCluster spec must be generated at central.portworx.com (Platform=AWS,
# Distribution=ROSA) and saved to $SPEC_FILE. It MUST contain the aws-creds env
# block (this script validates it and prints the block to add if missing).
#
# Usage:
#   ./hack/install-portworx-rosa.sh [--spec-file PATH] [--namespace NS]
#                                   [--region R] [--yes] [--dry-run]
#                                   [--rotate-keys]
set -euo pipefail

# ---- helpers ---------------------------------------------------------------
c_blue=$'\033[1;34m'; c_yellow=$'\033[1;33m'; c_red=$'\033[1;31m'; c_off=$'\033[0m'
banner() { echo; echo "${c_blue}==> $*${c_off}"; }
warn()   { echo "${c_yellow}WARN: $*${c_off}" >&2; }
die()    { echo "${c_red}ERROR: $*${c_off}" >&2; exit 1; }

GUID="${GUID:-}"
if [ -z "$GUID" ]; then
  die "GUID must be set. This will be used as a prefix for IAM resources"
fi

PX_NAMESPACE="${PX_NAMESPACE:-portworx}"
SPEC_FILE="${SPEC_FILE:-hack/portworx-spec.yaml}"
IAM_USER_NAME="${GUID}-portworx-px"
IAM_POLICY_NAME="${GUID}-portworx-px-policy"
SECRET_NAME="${GUID}-px-aws-creds"
AWS_REGION="${AWS_REGION:-}"
ASSUME_YES=false
DRY_RUN=false
ROTATE_KEYS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec-file) shift; SPEC_FILE="$1"; shift ;;
    --namespace) shift; PX_NAMESPACE="$1"; shift ;;
    --region)    shift; AWS_REGION="$1"; shift ;;
    --yes|-y)    ASSUME_YES=true; shift ;;
    --dry-run)   DRY_RUN=true; shift ;;
    --rotate-keys) ROTATE_KEYS=true; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# confirm "<description>" — Y/n gate. Returns 0 to proceed, 1 to skip.
confirm() {
  $ASSUME_YES && { echo "  [auto-yes] $1"; return 0; }
  $DRY_RUN    && { echo "  [dry-run] would: $1"; return 1; }
  local ans
  read -r -p "  Proceed: $1 ? [Y/n] " ans
  [[ -z "$ans" || "$ans" =~ ^[Yy] ]]
}

# run <cmd...> — execute unless dry-run.
run() {
  if $DRY_RUN; then echo "  [dry-run] $*"; return 0; fi
  "$@"
}

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH"; }

# ---- preflight -------------------------------------------------------------
banner "Preflight"
need oc; need aws; need jq
oc whoami >/dev/null 2>&1 || die "not logged into a cluster (oc whoami failed)"
aws sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials not configured"

INFRA_ID="$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')"
[[ -z "$AWS_REGION" ]] && \
  AWS_REGION="$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}')"
[[ -z "$AWS_REGION" ]] && die "could not determine AWS region; pass --region"

echo "  cluster user : $(oc whoami)"
echo "  context      : $(oc config current-context)"
echo "  infra id     : $INFRA_ID"
echo "  aws region   : $AWS_REGION"
echo "  aws identity : $(aws sts get-caller-identity --query Arn --output text)"
echo "  namespace    : $PX_NAMESPACE"
echo "  spec file    : $SPEC_FILE"
confirm "continue against THIS cluster/account" || die "aborted by user"

export AWS_REGION

# ---- Step 1: IAM policy + user + access key --------------------------------
banner "Step 1: AWS IAM user, policy, access key"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${IAM_POLICY_NAME}"

read -r -d '' PX_POLICY_DOC <<'JSON' || true
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "", "Effect": "Allow", "Resource": ["*"],
    "Action": [
      "ec2:AttachVolume","ec2:ModifyVolume","ec2:DetachVolume","ec2:CreateTags",
      "ec2:CreateVolume","ec2:DeleteTags","ec2:DeleteVolume","ec2:DescribeTags",
      "ec2:DescribeVolumeAttribute","ec2:DescribeVolumesModifications",
      "ec2:DescribeVolumeStatus","ec2:DescribeVolumes","ec2:DescribeInstances",
      "autoscaling:DescribeAutoScalingGroups"
    ]
  }]
}
JSON

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  echo "  policy $IAM_POLICY_NAME already exists — skipping create"
else
  if confirm "create IAM policy $IAM_POLICY_NAME"; then
    run aws iam create-policy --policy-name "$IAM_POLICY_NAME" \
      --policy-document "$PX_POLICY_DOC" >/dev/null
  fi
fi

if aws iam get-user --user-name "$IAM_USER_NAME" >/dev/null 2>&1; then
  echo "  user $IAM_USER_NAME already exists — skipping create"
else
  if confirm "create IAM user $IAM_USER_NAME"; then
    run aws iam create-user --user-name "$IAM_USER_NAME" >/dev/null
  fi
fi

if confirm "attach policy to user (idempotent)"; then
  run aws iam attach-user-policy --user-name "$IAM_USER_NAME" --policy-arn "$POLICY_ARN"
fi

# Access key: create only if the aws-creds secret is missing, unless --rotate-keys.
NEW_KEY=""; NEW_SECRET=""
SECRET_EXISTS=false
oc get secret "$SECRET_NAME" -n "$PX_NAMESPACE" >/dev/null 2>&1 && SECRET_EXISTS=true

if $SECRET_EXISTS && ! $ROTATE_KEYS; then
  echo "  secret $SECRET_NAME already exists — reusing (pass --rotate-keys to replace)"
else
  if confirm "create a new IAM access key for $IAM_USER_NAME"; then
    if $DRY_RUN; then
      echo "  [dry-run] aws iam create-access-key --user-name $IAM_USER_NAME"
    else
      KEY_JSON="$(aws iam create-access-key --user-name "$IAM_USER_NAME")"
      NEW_KEY="$(echo "$KEY_JSON"    | jq -r '.AccessKey.AccessKeyId')"
      NEW_SECRET="$(echo "$KEY_JSON" | jq -r '.AccessKey.SecretAccessKey')"
      echo "  created access key $NEW_KEY (secret shown only once)"
    fi
  fi
fi

# ---- Step 2: namespace + aws-creds secret ---------------------------------
banner "Step 2: namespace + $SECRET_NAME secret"
if ! oc get namespace "$PX_NAMESPACE" >/dev/null 2>&1; then
  confirm "create namespace $PX_NAMESPACE" && run oc create namespace "$PX_NAMESPACE"
fi

if [[ -n "$NEW_KEY" && -n "$NEW_SECRET" ]]; then
  if confirm "write $SECRET_NAME secret in $PX_NAMESPACE"; then
    # apply (create-or-replace) keeps this idempotent
    run bash -c "oc create secret generic '$SECRET_NAME' -n '$PX_NAMESPACE' \
      --from-literal=aws-key='$NEW_KEY' --from-literal=aws-secret='$NEW_SECRET' \
      --dry-run=client -o yaml | oc apply -f -"
  fi
elif $SECRET_EXISTS; then
  echo "  reusing existing $SECRET_NAME secret"
else
  warn "no new key created and no existing secret — Portworx will fail to provision drives"
fi

# ---- Step 3: worker security-group ports ----------------------------------
banner "Step 3: open Portworx ports on worker security group(s)"
mapfile -t WORKER_INSTANCE_IDS < <(
  oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}' \
    | sed -n 's#.*/\(i-[0-9a-f]*\)$#\1#p' | sort -u)
[[ ${#WORKER_INSTANCE_IDS[@]} -eq 0 ]] && die "no worker instance IDs found"

mapfile -t WORKER_SGS < <(
  aws ec2 describe-instances --instance-ids "${WORKER_INSTANCE_IDS[@]}" \
    --query 'Reservations[].Instances[].SecurityGroups[].GroupId' --output text | tr '\t' '\n' | sort -u)
[[ ${#WORKER_SGS[@]} -eq 0 ]] && die "no worker security groups found"
echo "  worker SGs: ${WORKER_SGS[*]}"

# ip-permissions: TCP 17001-17022, 20048, 111, 2049; UDP 17002 — source = same SG.
authorize_sg() {
  local sg="$1"
  local perms
  perms="$(jq -n --arg sg "$sg" '[
    {IpProtocol:"tcp",FromPort:17001,ToPort:17022,UserIdGroupPairs:[{GroupId:$sg}]},
    {IpProtocol:"tcp",FromPort:20048,ToPort:20048,UserIdGroupPairs:[{GroupId:$sg}]},
    {IpProtocol:"tcp",FromPort:111,  ToPort:111,  UserIdGroupPairs:[{GroupId:$sg}]},
    {IpProtocol:"tcp",FromPort:2049, ToPort:2049, UserIdGroupPairs:[{GroupId:$sg}]},
    {IpProtocol:"udp",FromPort:17002,ToPort:17002,UserIdGroupPairs:[{GroupId:$sg}]}
  ]')"
  if $DRY_RUN; then echo "  [dry-run] authorize ingress on $sg"; return 0; fi
  # Swallow the duplicate-rule error to stay idempotent.
  aws ec2 authorize-security-group-ingress --group-id "$sg" \
    --ip-permissions "$perms" >/dev/null 2>/tmp/sgerr || {
      grep -q 'InvalidPermission.Duplicate' /tmp/sgerr \
        && echo "  $sg: rules already present" \
        || { cat /tmp/sgerr >&2; die "failed to authorize $sg"; }
    }
}
for sg in "${WORKER_SGS[@]}"; do
  if confirm "open Portworx ports on $sg"; then authorize_sg "$sg"; fi
done

# ---- Step 4: user-workload monitoring -------------------------------------
banner "Step 4: enable user-workload monitoring"
# Merge-safe: patch only enableUserWorkload into config.yaml if not already true.
if oc -n openshift-monitoring get cm cluster-monitoring-config >/dev/null 2>&1 \
   && oc -n openshift-monitoring get cm cluster-monitoring-config -o jsonpath='{.data.config\.yaml}' \
        | grep -q 'enableUserWorkload:[[:space:]]*true'; then
  echo "  user-workload monitoring already enabled"
elif confirm "enable user-workload monitoring (creates/updates cluster-monitoring-config)"; then
  if oc -n openshift-monitoring get cm cluster-monitoring-config >/dev/null 2>&1; then
    warn "cluster-monitoring-config exists; verify it isn't overwriting other keys"
  fi
  run oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
fi

# ---- Step 5: install Portworx operator via OLM (auto-discover) -------------
banner "Step 5: install Portworx operator via OLM"
# Skip if a Portworx CSV already reached Succeeded (e.g. installed via console).
EXISTING_CSV="$(oc -n "$PX_NAMESPACE" get csv -o name 2>/dev/null | grep -i portworx | head -1)"
if [[ -n "$EXISTING_CSV" ]] \
   && [[ "$(oc -n "$PX_NAMESPACE" get "$EXISTING_CSV" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Succeeded" ]]; then
  echo "  operator already installed (${EXISTING_CSV#*/}) — skipping"
else
  # Discover package coordinates from the packagemanifest (survives channel renames).
  PX_PKG="$(oc get packagemanifests -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
            | grep -i portworx | grep -iv essential | head -1)"
  [[ -z "$PX_PKG" ]] && die "no Portworx packagemanifest found — is the certified-operators catalog enabled?"
  PX_CHANNEL="$(oc get packagemanifest "$PX_PKG" -o jsonpath='{.status.defaultChannel}')"
  PX_SOURCE="$(oc get packagemanifest "$PX_PKG" -o jsonpath='{.status.catalogSource}')"
  PX_SOURCE_NS="$(oc get packagemanifest "$PX_PKG" -o jsonpath='{.status.catalogSourceNamespace}')"
  [[ -z "$PX_CHANNEL" || -z "$PX_SOURCE" || -z "$PX_SOURCE_NS" ]] \
    && die "incomplete package coordinates: pkg=$PX_PKG channel=$PX_CHANNEL source=$PX_SOURCE ns=$PX_SOURCE_NS"
  echo "  discovered: package=$PX_PKG channel=$PX_CHANNEL source=$PX_SOURCE/$PX_SOURCE_NS"

  # Namespace may not exist yet if Step 2 was skipped.
  oc get namespace "$PX_NAMESPACE" >/dev/null 2>&1 || \
    { confirm "create namespace $PX_NAMESPACE" && run oc create namespace "$PX_NAMESPACE"; }

  if confirm "install operator '$PX_PKG' (channel=$PX_CHANNEL, source=$PX_SOURCE) via OLM"; then
    run oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: portworx-og
  namespace: $PX_NAMESPACE
spec:
  targetNamespaces: [$PX_NAMESPACE]
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $PX_PKG
  namespace: $PX_NAMESPACE
spec:
  channel: $PX_CHANNEL
  name: $PX_PKG
  source: $PX_SOURCE
  sourceNamespace: $PX_SOURCE_NS
  installPlanApproval: Automatic
EOF
    if ! $DRY_RUN; then
      echo "  waiting for CSV to reach Succeeded (up to 10m)..."
      for _ in $(seq 1 60); do
        csv="$(oc -n "$PX_NAMESPACE" get subscription "$PX_PKG" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
        phase=""
        [[ -n "$csv" ]] && phase="$(oc -n "$PX_NAMESPACE" get csv "$csv" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        echo "    CSV=${csv:-<pending>} phase=${phase:-<none>}"
        [[ "$phase" == "Succeeded" ]] && break
        sleep 10
      done
      [[ "${phase:-}" == "Succeeded" ]] || die "operator CSV did not reach Succeeded"
    fi
  fi
fi

# ---- Step 6: StorageCluster + console plugin ------------------------------
banner "Step 6: apply StorageCluster spec"
[[ -f "$SPEC_FILE" ]] || die "spec file not found: $SPEC_FILE (generate at central.portworx.com)"
if ! grep -q "$SECRET_NAME" "$SPEC_FILE" || ! grep -q 'AWS_ACCESS_KEY_ID' "$SPEC_FILE"; then
  warn "spec $SPEC_FILE does not reference the $SECRET_NAME env block."
  cat <<'EOF' >&2
  Add this to spec.env in your StorageCluster before continuing:
    env:
      - name: AWS_ACCESS_KEY_ID
        valueFrom: {secretKeyRef: {name: aws-creds, key: aws-key}}
      - name: AWS_SECRET_ACCESS_KEY
        valueFrom: {secretKeyRef: {name: aws-creds, key: aws-secret}}
EOF
  die "fix the spec env block, then re-run"
fi
if confirm "oc apply StorageCluster from $SPEC_FILE"; then
  run oc apply -f "$SPEC_FILE"
fi

if oc get console.operator cluster -o jsonpath='{.spec.plugins}' 2>/dev/null | grep -q portworx; then
  echo "  console plugin already enabled"
elif confirm "enable Portworx console plugin"; then
  run oc patch console.operator cluster --type=json \
    -p='[{"op":"add","path":"/spec/plugins/-","value":"portworx"}]'
fi

# ---- Step 7: verification (read-only) --------------------------------------
banner "Step 7: verification"
echo "  waiting for StorageCluster to report Online (up to 10m)..."
if ! $DRY_RUN; then
  for _ in $(seq 1 60); do
    st="$(oc -n "$PX_NAMESPACE" get storagecluster -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
    echo "    storagecluster phase: ${st:-<none>}"
    [[ "$st" == "Online" || "$st" == "Running" ]] && break
    sleep 10
  done
fi
echo "--- storagecluster ---";  run oc -n "$PX_NAMESPACE" get storagecluster
echo "--- storagenodes ---";    run oc -n "$PX_NAMESPACE" get storagenodes 2>/dev/null || true
echo "--- pods ---";            run bash -c "oc get pods -n '$PX_NAMESPACE' -o wide | grep -e portworx -e px || true"

PXPOD="$(oc get pods -n "$PX_NAMESPACE" -l name=portworx -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "$PXPOD" ]] && ! $DRY_RUN; then
  echo "--- pxctl pool show ---"
  oc exec "$PXPOD" -n "$PX_NAMESPACE" -- /opt/pwx/bin/pxctl service pool show 2>/dev/null | grep -i 'Type:' || true
  echo "--- pxctl provision-status ---"
  oc exec "$PXPOD" -n "$PX_NAMESPACE" -- /opt/pwx/bin/pxctl cluster provision-status 2>/dev/null | head -20 || true
fi

banner "Done"
echo "Next: validate RWX raw-block coherency for SBR with:  ./hack/px-block-probe.sh"
