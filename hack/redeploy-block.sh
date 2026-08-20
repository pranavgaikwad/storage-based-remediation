#!/usr/bin/env bash
# redeploy-block.sh — One-command, idempotent redeploy of SBR for block-mode testing.
#
# Safe to re-run on a freshly recreated cluster (the cluster is rebuilt daily). It:
#   1. Preflight — verify cluster-admin access.
#   2. Storage  — find an RWX-block-capable (Ceph RBD) StorageClass.
#   3. Build    — operator + agent images in-cluster (hack/build-in-cluster.sh).
#   4. Install  — operator via OLM from those in-cluster images (hack/install-olm.sh).
#   5. Verify   — controller-driven block path (hack/testing_operator_block_mode.sh), if present.
#   6. Wire     — Block SBRConfig + StorageBasedRemediationTemplate + NodeHealthCheck (fencing trigger).
#
# Every step is check-then-act, so partial state or a clean cluster both converge.
#
# Usage (see --help for the full option list):
#   ./hack/redeploy-block.sh
#   SKIP_BUILD=true ./hack/redeploy-block.sh          # reuse existing in-cluster images
#   BUILD_MODE=binary ./hack/redeploy-block.sh        # build from the local tree instead of git
#   GIT_URI=... GIT_REF=... ./hack/redeploy-block.sh  # build from a specific repo/branch
#   STORAGE_CLASS=ocs-storagecluster-ceph-rbd ./hack/redeploy-block.sh   # pin the RBD SC
#   SKIP_WIRING=true ./hack/redeploy-block.sh         # don't apply SBRConfig/Template/NHC
#   ./hack/redeploy-block.sh --cleanup                # remove everything this script created
#   ./hack/redeploy-block.sh --cleanup --delete-namespace
#
# Env: NAMESPACE, STORAGE_CLASS, SKIP_BUILD, BUILD_MODE (git|binary), GIT_URI, GIT_REF, SKIP_VERIFY,
#      SKIP_WIRING, CONFIG_NAME (default sbr-block), DELETE_NAMESPACE.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

NAMESPACE="${NAMESPACE:-sbr-operator-system}"
STORAGE_CLASS="${STORAGE_CLASS:-}"
SKIP_BUILD="${SKIP_BUILD:-false}"
BUILD_MODE="${BUILD_MODE:-git}"
SKIP_VERIFY="${SKIP_VERIFY:-false}"
SKIP_WIRING="${SKIP_WIRING:-false}"
CONFIG_NAME="${CONFIG_NAME:-sbr-block}"
DELETE_NAMESPACE="${DELETE_NAMESPACE:-false}"
ACTION="deploy"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*" >&2; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
fatal() { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }
step()  { echo -e "\n${CYAN}==>${NC} $*" >&2; }

usage() {
    cat <<EOF
redeploy-block.sh — Idempotent redeploy of SBR for block-mode testing.

Builds the operator + agent images in-cluster, installs the operator via OLM
(from those in-cluster images), verifies the block path, and wires the fencing
trigger (SBRConfig + Template + NodeHealthCheck). Every step is check-then-act,
so a partial state or a clean cluster both converge.

USAGE:
  ./hack/redeploy-block.sh [options]

OPTIONS:
  --cleanup               Remove everything this script creates in the cluster
                          (SBR CRs, OLM objects, build/image artifacts) and exit.
                          Respects NAMESPACE and CONFIG_NAME.
  --delete-namespace      With --cleanup, also delete the namespace itself.
  --skip-build            Reuse existing in-cluster images (istags must exist).
  --skip-verify           Skip the block-mode verification step.
  --skip-wiring           Do not apply SBRConfig / Template / NodeHealthCheck.
  --build-mode <git|binary>
                          git (default): cluster clones GIT_URI@GIT_REF.
                          binary: build from the local working tree.
  --git-uri <url>         Git source URI (implies --build-mode git).
  --git-ref <ref>         Git source ref/branch (implies --build-mode git).
  --namespace <ns>        Target namespace (default: sbr-operator-system).
  --storage-class <sc>    Pin the Ceph RBD StorageClass (default: auto-detect).
  --config-name <name>    Base name for SBRConfig/Template/NHC (default: sbr-block).
  -h, --help              Show this help and exit.

ENVIRONMENT (equivalents to the flags above):
  NAMESPACE, STORAGE_CLASS, SKIP_BUILD, BUILD_MODE (git|binary), GIT_URI,
  GIT_REF, SKIP_VERIFY, SKIP_WIRING, CONFIG_NAME, DELETE_NAMESPACE.

EXAMPLES:
  ./hack/redeploy-block.sh
  SKIP_BUILD=true ./hack/redeploy-block.sh
  ./hack/redeploy-block.sh --build-mode binary
  ./hack/redeploy-block.sh --git-ref my-branch
  ./hack/redeploy-block.sh --cleanup
  ./hack/redeploy-block.sh --cleanup --delete-namespace
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cleanup)          ACTION="cleanup"; shift ;;
        --delete-namespace) DELETE_NAMESPACE="true"; shift ;;
        --skip-build)       SKIP_BUILD="true"; shift ;;
        --skip-verify)      SKIP_VERIFY="true"; shift ;;
        --skip-wiring)      SKIP_WIRING="true"; shift ;;
        --build-mode|--build-mode=*)
            if [[ "$1" == *=* ]]; then BUILD_MODE="${1#*=}"; else shift; BUILD_MODE="$1"; fi; shift ;;
        --git-uri|--git-uri=*)
            if [[ "$1" == *=* ]]; then GIT_URI="${1#*=}"; else shift; GIT_URI="$1"; fi; BUILD_MODE="git"; export GIT_URI; shift ;;
        --git-ref|--git-ref=*)
            if [[ "$1" == *=* ]]; then GIT_REF="${1#*=}"; else shift; GIT_REF="$1"; fi; BUILD_MODE="git"; export GIT_REF; shift ;;
        --namespace|--namespace=*)
            if [[ "$1" == *=* ]]; then NAMESPACE="${1#*=}"; else shift; NAMESPACE="$1"; fi; shift ;;
        --storage-class|--storage-class=*)
            if [[ "$1" == *=* ]]; then STORAGE_CLASS="${1#*=}"; else shift; STORAGE_CLASS="$1"; fi; shift ;;
        --config-name|--config-name=*)
            if [[ "$1" == *=* ]]; then CONFIG_NAME="${1#*=}"; else shift; CONFIG_NAME="$1"; fi; shift ;;
        -h|--help)          usage; exit 0 ;;
        *) fatal "Unknown argument: $1 (try --help)" ;;
    esac
done

command -v oc >/dev/null 2>&1 || fatal "oc not found in PATH"

# cleanup — remove everything the redeploy flow creates in the cluster. Deletion order matters:
# SBR CRs go first (while the operator is still running to honour finalizers), then the OLM objects
# (the CSV owns the controller Deployment), then the in-cluster build/image artifacts.
cleanup() {
    step "Cleanup (namespace: $NAMESPACE, config: $CONFIG_NAME)"
    oc whoami >/dev/null 2>&1 || fatal "not logged into a cluster (oc login ...)"

    local OPERATOR_NAME="storage-based-remediation" VERSION="0.0.1"

    info "Removing NodeHealthCheck / Template / SBRConfig ..."
    oc delete nodehealthcheck "${CONFIG_NAME}-nhc" --ignore-not-found --timeout=60s >/dev/null 2>&1 || true
    oc delete storagebasedremediationtemplate "${CONFIG_NAME}-template" -n "$NAMESPACE" \
        --ignore-not-found --timeout=60s >/dev/null 2>&1 || true
    # SBRConfig may carry a finalizer; give the operator time, then strip it if the delete hangs.
    if oc get storagebasedremediationconfig "$CONFIG_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        oc delete storagebasedremediationconfig "$CONFIG_NAME" -n "$NAMESPACE" \
            --ignore-not-found --timeout=90s >/dev/null 2>&1 || {
            warn "SBRConfig delete timed out — clearing finalizers"
            oc patch storagebasedremediationconfig "$CONFIG_NAME" -n "$NAMESPACE" --type merge \
                -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
        }
    fi
    ok "SBR custom resources removed"

    info "Removing OLM objects (Subscription / CSV / CatalogSource / OperatorGroup) ..."
    oc delete subscription "$OPERATOR_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
    oc delete csv "${OPERATOR_NAME}.v${VERSION}" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
    oc delete catalogsource sbr-catalog -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
    oc delete operatorgroup sbr-operator-group -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
    ok "OLM objects removed"

    info "Removing in-cluster build artifacts (BuildConfigs / ImageStreams / Builds) ..."
    for res in sbr-operator sbr-agent sbr-bundle sbr-catalog; do
        oc delete buildconfig "$res" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
        oc delete imagestream  "$res" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
    done
    oc delete builds --all -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
    ok "Build artifacts removed"

    if [[ "$DELETE_NAMESPACE" == "true" ]]; then
        info "Deleting namespace $NAMESPACE ..."
        oc delete namespace "$NAMESPACE" --ignore-not-found --timeout=120s >/dev/null 2>&1 || true
        ok "Namespace $NAMESPACE deleted"
    else
        info "Namespace $NAMESPACE kept (pass --delete-namespace to remove it)"
    fi

    echo -e "\n${GREEN}=== SBR block-mode cleanup complete ===${NC}" >&2
    warn "Not removed: operator CRDs (left by OLM), the registry defaultRoute, and any
        node iptables rules from inject-partition.sh (those self-heal on reboot/duration)."
}

if [[ "$ACTION" == "cleanup" ]]; then
    cleanup
    exit 0
fi

# --- 1. preflight ---
step "1/6 Preflight"
oc whoami >/dev/null 2>&1 || fatal "not logged into a cluster (oc login ...)"
oc auth can-i create subscriptions.operators.coreos.com -n "$NAMESPACE" >/dev/null 2>&1 \
    || warn "cannot create OLM Subscriptions in $NAMESPACE — cluster-admin is required"
oc get namespace "$NAMESPACE" >/dev/null 2>&1 || oc create namespace "$NAMESPACE" >/dev/null
ok "Logged in as $(oc whoami); namespace $NAMESPACE ready"

# --- 2. storage: find an RWX-block-capable StorageClass (Ceph RBD or Portworx) ---
step "2/6 Storage (Ceph RBD / Portworx)"
find_block_sc() {
    oc get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.provisioner}{"\n"}{end}' 2>/dev/null \
        | awk -F'|' '$2=="rbd.csi.ceph.com" || $2=="openshift-storage.rbd.csi.ceph.com" || $2=="pxd.portworx.com" {print $1; exit}'
}
if [[ -z "$STORAGE_CLASS" ]]; then
    STORAGE_CLASS="$(find_block_sc || true)"
fi
if [[ -z "$STORAGE_CLASS" ]]; then
    fatal "no block-capable StorageClass found (supported provisioners: rbd.csi.ceph.com, openshift-storage.rbd.csi.ceph.com, pxd.portworx.com).
        Install ODF (for Ceph RBD, e.g. ocs-storagecluster-ceph-rbd) or Portworx (e.g. portworx-replica-two), then re-run.
        See docs/block-mode-testing-runbook.md (Prerequisites)."
fi
oc get storageclass "$STORAGE_CLASS" >/dev/null 2>&1 || fatal "StorageClass $STORAGE_CLASS not found"
ok "Using block StorageClass: $STORAGE_CLASS"

# --- 3. build images in-cluster ---
step "3/6 Build images in-cluster"
if [[ "$SKIP_BUILD" == "true" ]]; then
    info "SKIP_BUILD=true — reusing existing in-cluster images"
    oc get istag sbr-operator:latest -n "$NAMESPACE" >/dev/null 2>&1 || fatal "sbr-operator:latest missing; unset SKIP_BUILD"
    oc get istag sbr-agent:latest    -n "$NAMESPACE" >/dev/null 2>&1 || fatal "sbr-agent:latest missing; unset SKIP_BUILD"
else
    BUILD_ARGS=(--namespace "$NAMESPACE")
    [[ "$BUILD_MODE" == "binary" ]] && BUILD_ARGS+=(--binary)
    NAMESPACE="$NAMESPACE" "${SCRIPT_DIR}/build-in-cluster.sh" "${BUILD_ARGS[@]}" >/dev/null \
        || fatal "in-cluster build failed"
fi
ok "Operator + agent images present in $NAMESPACE"

# --- 4. install via OLM ---
step "4/6 Install operator via OLM"
NAMESPACE="$NAMESPACE" "${SCRIPT_DIR}/install-olm.sh" --namespace "$NAMESPACE" >&2 \
    || fatal "OLM install failed"
ok "Operator installed"

# --- 5. verify the controller-driven block path ---
step "5/6 Verify block mode"
if [[ "$SKIP_VERIFY" == "true" ]]; then
    info "SKIP_VERIFY=true — skipping block-mode verification"
elif [[ -x "${SCRIPT_DIR}/testing_operator_block_mode.sh" ]]; then
    NAMESPACE="$NAMESPACE" STORAGE_CLASS="$STORAGE_CLASS" \
        "${SCRIPT_DIR}/testing_operator_block_mode.sh" all >&2 \
        || fatal "block-mode verification failed"
else
    warn "hack/testing_operator_block_mode.sh not found — skipping automated verification"
fi

# --- 6. wire the fencing path: Block SBRConfig + Template + NodeHealthCheck ---
step "6/6 Wire fencing (SBRConfig + Template + NHC)"
if [[ "$SKIP_WIRING" == "true" ]]; then
    info "SKIP_WIRING=true — skipping SBRConfig/Template/NHC"
else
    info "Applying Block SBRConfig '$CONFIG_NAME' ..."
    oc apply -f - >/dev/null <<EOF || fatal "failed to apply SBRConfig"
apiVersion: storage-based-remediation.medik8s.io/v1alpha1
kind: StorageBasedRemediationConfig
metadata:
  name: ${CONFIG_NAME}
  namespace: ${NAMESPACE}
spec:
  sharedStorageVolumeMode: Block
  sharedStorageClass: ${STORAGE_CLASS}
  watchdogPath: /dev/watchdog
EOF
    ok "SBRConfig applied"

    info "Applying StorageBasedRemediationTemplate '${CONFIG_NAME}-template' ..."
    oc apply -f - >/dev/null <<EOF || fatal "failed to apply SBR template"
apiVersion: storage-based-remediation.medik8s.io/v1alpha1
kind: StorageBasedRemediationTemplate
metadata:
  name: ${CONFIG_NAME}-template
  namespace: ${NAMESPACE}
spec:
  template:
    spec: {}
EOF
    ok "Template applied"

    # NHC is a separate operator; only wire it if its CRD is present.
    if oc get crd nodehealthchecks.remediation.medik8s.io >/dev/null 2>&1; then
        info "Applying NodeHealthCheck '${CONFIG_NAME}-nhc' ..."
        # minHealthy MUST be an int (a quoted string fails NHC validation).
        oc apply -f - >/dev/null <<EOF || fatal "failed to apply NodeHealthCheck"
apiVersion: remediation.medik8s.io/v1alpha1
kind: NodeHealthCheck
metadata:
  name: ${CONFIG_NAME}-nhc
spec:
  minHealthy: 1
  selector:
    matchExpressions:
      - key: node-role.kubernetes.io/worker
        operator: Exists
      - key: node-role.kubernetes.io/control-plane
        operator: DoesNotExist
  unhealthyConditions:
    - type: Ready
      status: Unknown
      duration: 60s
    - type: SBRStorageUnhealthy
      status: "True"
      duration: 10s
  remediationTemplate:
    apiVersion: storage-based-remediation.medik8s.io/v1alpha1
    kind: StorageBasedRemediationTemplate
    name: ${CONFIG_NAME}-template
    namespace: ${NAMESPACE}
EOF
        ok "NodeHealthCheck applied"
    else
        warn "NodeHealthCheck CRD not found — install the Node Healthcheck Operator, then re-run
        (or apply an NHC by hand). SBRConfig + Template are in place; agents will still run."
    fi
fi

echo -e "\n${GREEN}=== SBR block-mode redeploy complete ===${NC}" >&2
info "Namespace:      $NAMESPACE"
info "Block SC:       $STORAGE_CLASS"
info "SBRConfig:      $CONFIG_NAME (Block)"
info "Verify agents converged:"
info "    oc get pods -n $NAMESPACE -l sbrconfig=${CONFIG_NAME}"
info "    oc logs <agent-pod> -n $NAMESPACE | grep -E 'nodeCount|healthyPeers'   # want nodeCount:3, healthyPeers:2"
info "Then drive a fence test:  ./hack/inject-partition.sh <victim-node> 420"
