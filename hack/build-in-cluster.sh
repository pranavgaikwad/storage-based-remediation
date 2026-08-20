#!/usr/bin/env bash
# build-in-cluster.sh — Build the SBR operator and agent images inside the cluster.
#
# Uses OpenShift BuildConfigs so images are compiled on the cluster (native arch, pushed to
# the internal registry) — no local podman, no cross-arch buildx, no external registry.
# Idempotent: BuildConfigs are (re)applied and a fresh build is started each run.
#
# Two source modes:
#   git (default) — the cluster clones a repo + ref. Defaults to the PR #88 fork/branch.
#   binary (--binary) — upload the local working tree (builds exactly what is checked out,
#                       including uncommitted changes).
#
# Usage:
#   ./hack/build-in-cluster.sh [--namespace NS]                        # git, PR #88 default
#   ./hack/build-in-cluster.sh [--namespace NS] --git-uri URL --git-ref REF
#   ./hack/build-in-cluster.sh [--namespace NS] --binary               # local working tree
#
# Env equivalents: NAMESPACE, GIT_URI, GIT_REF.
#
# Outputs ImageStreamTags in NS:
#   sbr-operator:latest  -> image-registry.openshift-image-registry.svc:5000/NS/sbr-operator:latest
#   sbr-agent:latest     -> image-registry.openshift-image-registry.svc:5000/NS/sbr-agent:latest
#
# Prints the two internal pullspecs on the last two lines (stdout) for callers to capture.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NAMESPACE="${NAMESPACE:-sbr-operator-system}"
GIT_URI="${GIT_URI:-https://github.com/mpryc/storage-based-remediation}"
GIT_REF="${GIT_REF:-feature/rwx-block-crd-webhook-phase4}"
SOURCE_MODE="git"
INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*" >&2; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*" >&2; }
fatal() { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace|--namespace=*)
            if [[ "$1" == *=* ]]; then NAMESPACE="${1#*=}"; else shift; NAMESPACE="$1"; fi; shift ;;
        --binary) SOURCE_MODE="binary"; shift ;;
        --git-uri|--git-uri=*)
            if [[ "$1" == *=* ]]; then GIT_URI="${1#*=}"; else shift; GIT_URI="$1"; fi; SOURCE_MODE="git"; shift ;;
        --git-ref|--git-ref=*)
            if [[ "$1" == *=* ]]; then GIT_REF="${1#*=}"; else shift; GIT_REF="$1"; fi; SOURCE_MODE="git"; shift ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) fatal "Unknown argument: $1" ;;
    esac
done

command -v oc >/dev/null 2>&1 || fatal "oc not found in PATH"
oc whoami >/dev/null 2>&1 || fatal "not logged into a cluster (oc login ...)"

if [[ "$SOURCE_MODE" == "git" ]]; then
    info "Source mode:      git ($GIT_URI @ $GIT_REF)"
else
    info "Source mode:      binary (local tree ${REPO_ROOT})"
fi
info "Namespace:        $NAMESPACE"

oc get namespace "$NAMESPACE" >/dev/null 2>&1 || oc create namespace "$NAMESPACE" >/dev/null
ok "Namespace ready"

# Source stanza differs by mode. Binary source is provided per-build by --from-dir; for git the
# uri/ref are baked into the BuildConfig so the cluster clones them.
if [[ "$SOURCE_MODE" == "git" ]]; then
    IFS= read -r -d '' SOURCE_YAML <<EOF || true
    type: Git
    git:
      uri: ${GIT_URI}
      ref: ${GIT_REF}
EOF
else
    IFS= read -r -d '' SOURCE_YAML <<EOF || true
    type: Binary
EOF
fi

# Delete BuildConfigs whose source type differs from what we're about to apply — oc apply can't
# patch across source types (git ↔ binary) because both fields end up set, which is invalid.
info "Applying BuildConfigs and ImageStreams ..."
for bc in sbr-operator sbr-agent; do
    existing_type=$(oc get buildconfig "$bc" -n "$NAMESPACE" -o jsonpath='{.spec.source.type}' 2>/dev/null || true)
    # Normalise: server returns "Git"/"Binary"; SOURCE_MODE is "git"/"binary"
    if [[ -n "$existing_type" && "${existing_type,,}" != "${SOURCE_MODE,,}" ]]; then
        info "Deleting $bc BuildConfig (source type mismatch: ${existing_type} → ${SOURCE_MODE})"
        oc delete buildconfig "$bc" -n "$NAMESPACE" --ignore-not-found >/dev/null
    fi
done
oc apply -n "$NAMESPACE" -f - <<EOF
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: sbr-operator
---
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: sbr-agent
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: sbr-operator
spec:
  source:
${SOURCE_YAML}
  strategy:
    type: Docker
    dockerStrategy:
      dockerfilePath: Dockerfile
  output:
    to:
      kind: ImageStreamTag
      name: sbr-operator:latest
  resources:
    limits:
      memory: 4Gi
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: sbr-agent
spec:
  source:
${SOURCE_YAML}
  strategy:
    type: Docker
    dockerStrategy:
      dockerfilePath: cmd/sbr-agent/Dockerfile
  output:
    to:
      kind: ImageStreamTag
      name: sbr-agent:latest
  resources:
    limits:
      memory: 4Gi
EOF
ok "BuildConfigs applied"

# git:    the cluster clones the configured uri/ref.
# binary: upload the working tree (go source + vendor/ + .git/ for version stamping).
build() {
    local bc="$1"
    if [[ "$SOURCE_MODE" == "git" ]]; then
        info "Starting git build: $bc ($GIT_URI @ $GIT_REF) ..."
        oc start-build "$bc" -n "$NAMESPACE" --follow --wait || fatal "Build $bc failed"
    else
        info "Starting binary build: $bc (uploading ${REPO_ROOT}) ..."
        # --exclude="" overrides oc's default '(^|/)\.git(/|$)' so the .git dir is uploaded;
        # the Dockerfile COPYs it for version stamping.
        oc start-build "$bc" -n "$NAMESPACE" --from-dir="${REPO_ROOT}" --exclude="" --follow --wait \
            || fatal "Build $bc failed"
    fi
    ok "Build $bc complete"
}

build sbr-operator
build sbr-agent

OPERATOR_PULLSPEC="${INTERNAL_REGISTRY}/${NAMESPACE}/sbr-operator:latest"
AGENT_PULLSPEC="${INTERNAL_REGISTRY}/${NAMESPACE}/sbr-agent:latest"
ok "Operator image: ${OPERATOR_PULLSPEC}"
ok "Agent image:    ${AGENT_PULLSPEC}"

# Machine-readable output (last two stdout lines) for callers.
echo "${OPERATOR_PULLSPEC}"
echo "${AGENT_PULLSPEC}"
