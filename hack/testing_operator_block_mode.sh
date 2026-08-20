#!/usr/bin/env bash
# testing_operator_block_mode.sh — Verify the controller-driven block-mode path end-to-end.
#
# Companion to hack/testing_block_mode.sh (which exercises the agent in isolation). This drives the
# *operator*: it creates a Block StorageBasedRemediationConfig and asserts the controller builds the
# full block stack — an RWX volumeMode=Block PVC, the superblock --init Job, and the agent DaemonSet
# mounting the raw device at /dev/sbr-block — and that agents detect block mode at runtime.
#
# Assumes the operator is already installed (see hack/install-olm.sh / hack/redeploy-block.sh) and a
# Ceph RBD StorageClass exists.
#
# Usage:
#   ./hack/testing_operator_block_mode.sh <deploy|test|undeploy|all>
# Env: NAMESPACE, STORAGE_CLASS (auto-detected if unset), CONFIG_NAME (default sbr-block).

set -euo pipefail

NAMESPACE="${NAMESPACE:-sbr-operator-system}"
STORAGE_CLASS="${STORAGE_CLASS:-}"
CONFIG_NAME="${CONFIG_NAME:-sbr-block}"
DETECT_ONLY="${DETECT_ONLY:-true}"
DEVICE_PATH="/dev/sbr-block"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*" >&2; }
pass()  { echo -e "${GREEN}[PASS]${NC}  $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

# Derived resource names (must match internal/controller + api/v1alpha1).
PVC_NAME="${CONFIG_NAME}-shared-storage"
INIT_JOB_NAME="${CONFIG_NAME}-sbr-device-init"
DAEMONSET_NAME="sbr-agent-${CONFIG_NAME}"

command -v oc >/dev/null 2>&1 || fail "oc not found in PATH"
oc whoami >/dev/null 2>&1 || fail "not logged into a cluster"

detect_storage_class() {
    [[ -n "$STORAGE_CLASS" ]] && return 0
    STORAGE_CLASS="$(oc get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.provisioner}{"\n"}{end}' 2>/dev/null \
        | awk -F'|' '$2=="rbd.csi.ceph.com" || $2=="openshift-storage.rbd.csi.ceph.com" || $2=="pxd.portworx.com" {print $1; exit}')"
    [[ -n "$STORAGE_CLASS" ]] || fail "no block-capable StorageClass found (rbd.csi.ceph.com, openshift-storage.rbd.csi.ceph.com, pxd.portworx.com); set STORAGE_CLASS explicitly"
}

# wait_for <timeout-sec> <description> <command...> : poll until command succeeds.
wait_for() {
    local timeout="$1" desc="$2"; shift 2
    local deadline=$((SECONDS + timeout))
    info "waiting for: $desc (timeout ${timeout}s)"
    while (( SECONDS < deadline )); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 5
    done
    return 1
}

deploy() {
    detect_storage_class
    local detect_only_line=""
    [[ "$DETECT_ONLY" == "true" ]] && detect_only_line="  detectOnlyMode: Enabled"
    info "Creating Block SBRConfig '$CONFIG_NAME' (SC=$STORAGE_CLASS, detectOnly=${DETECT_ONLY}) in $NAMESPACE"
    oc apply -f - <<EOF
apiVersion: storage-based-remediation.medik8s.io/v1alpha1
kind: StorageBasedRemediationConfig
metadata:
  name: ${CONFIG_NAME}
  namespace: ${NAMESPACE}
spec:
  sharedStorageVolumeMode: Block
  sharedStorageClass: ${STORAGE_CLASS}
  watchdogPath: /dev/watchdog
${detect_only_line}
EOF
    pass "SBRConfig created"
}

test_block_path() {
    info "== Verifying controller-driven block path for '$CONFIG_NAME' =="

    # 1. PVC: block volume mode, RWX, Bound.
    wait_for 120 "PVC ${PVC_NAME} to exist" \
        oc get pvc "$PVC_NAME" -n "$NAMESPACE" || fail "PVC ${PVC_NAME} was not created by the controller"
    local vm am phase
    vm="$(oc get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.volumeMode}')"
    am="$(oc get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.accessModes[*]}')"
    [[ "$vm" == "Block" ]] || fail "PVC volumeMode is '$vm', expected Block"
    [[ "$am" == *"ReadWriteMany"* ]] || fail "PVC accessModes '$am' missing ReadWriteMany"
    pass "PVC ${PVC_NAME} is volumeMode=Block accessModes=[${am}]"
    wait_for 180 "PVC ${PVC_NAME} to be Bound" \
        bash -c "[[ \"\$(oc get pvc $PVC_NAME -n $NAMESPACE -o jsonpath='{.status.phase}')\" == Bound ]]" \
        || fail "PVC ${PVC_NAME} did not reach Bound (phase: $(oc get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}'))"
    pass "PVC ${PVC_NAME} is Bound"

    # 2. Init Job: completed (writes the V1 superblock via sbr-agent --init).
    wait_for 120 "init Job ${INIT_JOB_NAME} to exist" \
        oc get job "$INIT_JOB_NAME" -n "$NAMESPACE" || fail "init Job ${INIT_JOB_NAME} was not created"
    wait_for 240 "init Job ${INIT_JOB_NAME} to complete" \
        bash -c "[[ \"\$(oc get job $INIT_JOB_NAME -n $NAMESPACE -o jsonpath='{.status.succeeded}')\" == 1 ]]" \
        || fail "init Job ${INIT_JOB_NAME} did not complete"
    pass "init Job ${INIT_JOB_NAME} completed (superblock written)"

    # 3. DaemonSet: scheduled and all pods ready.
    wait_for 120 "DaemonSet ${DAEMONSET_NAME} to exist" \
        oc get daemonset "$DAEMONSET_NAME" -n "$NAMESPACE" || fail "DaemonSet ${DAEMONSET_NAME} was not created"
    wait_for 240 "DaemonSet ${DAEMONSET_NAME} to be fully ready" bash -c "
        d=\$(oc get daemonset $DAEMONSET_NAME -n $NAMESPACE -o jsonpath='{.status.desiredNumberScheduled}')
        r=\$(oc get daemonset $DAEMONSET_NAME -n $NAMESPACE -o jsonpath='{.status.numberReady}')
        [[ -n \"\$d\" && \"\$d\" -gt 0 && \"\$d\" == \"\$r\" ]]" \
        || fail "DaemonSet ${DAEMONSET_NAME} not fully ready (desired=$(oc get ds "$DAEMONSET_NAME" -n "$NAMESPACE" -o jsonpath='{.status.desiredNumberScheduled}') ready=$(oc get ds "$DAEMONSET_NAME" -n "$NAMESPACE" -o jsonpath='{.status.numberReady}'))"
    local desired; desired="$(oc get ds "$DAEMONSET_NAME" -n "$NAMESPACE" -o jsonpath='{.status.desiredNumberScheduled}')"
    pass "DaemonSet ${DAEMONSET_NAME} ready on all ${desired} node(s)"

    # 4. Agent pods: running with no restarts (crash loops => O_DIRECT / device issues).
    local restarts
    restarts="$(oc get pods -n "$NAMESPACE" -l app=sbr-agent -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null | sort -rn | head -1)"
    [[ -z "$restarts" || "$restarts" -le 0 ]] || warn "an agent pod has restartCount=${restarts} (investigate crash loops)"
    [[ -z "$restarts" || "$restarts" -le 2 ]] || fail "agent pods are crash-looping (max restartCount=${restarts})"
    pass "agent pods running (max restartCount=${restarts:-0})"

    # 5. Agent logs: block mode detected, mounting the raw device; no filesystem fallback / EINVAL.
    local logs
    logs="$(oc logs -n "$NAMESPACE" -l app=sbr-agent --tail=200 --all-containers 2>/dev/null || true)"
    echo "$logs" | grep -q "Block mode detected" \
        || fail "agent logs do not show 'Block mode detected' (device at ${DEVICE_PATH} may not have a valid superblock)"
    pass "agent logs show 'Block mode detected'"
    if echo "$logs" | grep -qi "Filesystem mode"; then
        fail "agent fell back to Filesystem mode — block device auto-detection failed"
    fi
    if echo "$logs" | grep -qi "invalid argument"; then
        fail "agent logs contain 'invalid argument' (likely O_DIRECT alignment / raw device access issue)"
    fi
    pass "no filesystem fallback and no 'invalid argument' in agent logs"

    echo -e "${GREEN}=== block-mode verification PASSED for '${CONFIG_NAME}' ===${NC}" >&2
}

undeploy() {
    info "Deleting SBRConfig '$CONFIG_NAME' (controller finalizer cleans up PVC/Job/DaemonSet)"
    oc delete storagebasedremediationconfig "$CONFIG_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true --timeout=120s || true
    pass "SBRConfig deleted"
}

case "${1:-}" in
    deploy)   deploy ;;
    test)     test_block_path ;;
    undeploy) undeploy ;;
    all)      deploy; test_block_path ;;
    *) echo "Usage: $0 <deploy|test|undeploy|all>" >&2; exit 1 ;;
esac
