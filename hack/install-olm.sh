#!/usr/bin/env bash
# install-olm.sh — Install the SBR operator via OLM using ONLY in-cluster-built images.
#
# Why not `operator-sdk run bundle`? It pulls the bundle image *off-cluster* (from this laptop),
# which cannot reach the internal registry service, and routing it through the registry's external
# route fails in-cluster on x509 (nodes distrust the ingress cert) and needs a short-lived token.
# Instead we build a file-based catalog (FBC) whose bundle/operator/agent references all use the
# *internal* service pullspec, so every runtime pull is in-cluster (service CA, auto-auth, no token).
#
# Prerequisites (see docs/block-mode-testing-runbook.md):
#   - Operator + agent images already built in-cluster: `hack/build-in-cluster.sh`
#     (istags sbr-operator:latest and sbr-agent:latest present in NAMESPACE).
#   - Local tools: oc (logged in, cluster-admin), plus repo-local bin/{operator-sdk,opm,kustomize,yq}
#     (auto-downloaded by `make operator-sdk opm kustomize yq` if missing).
#
# The only off-cluster step is `opm render` of the bundle, done via the registry route with a
# freshly-minted ServiceAccount token; the rendered image refs are rewritten back to the internal
# service before the catalog is built.
#
# Usage:
#   ./hack/install-olm.sh [--namespace NS]
# Env equivalents: NAMESPACE.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

NAMESPACE="${NAMESPACE:-sbr-operator-system}"
OPERATOR_NAME="storage-based-remediation"
VERSION="0.0.1"
CHANNEL="stable"
INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"
OPM="${REPO_ROOT}/bin/opm"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*" >&2; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*" >&2; }
fatal() { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace|--namespace=*)
            if [[ "$1" == *=* ]]; then NAMESPACE="${1#*=}"; else shift; NAMESPACE="$1"; fi; shift ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) fatal "Unknown argument: $1" ;;
    esac
done

command -v oc >/dev/null 2>&1 || fatal "oc not found in PATH"
oc whoami >/dev/null 2>&1 || fatal "not logged into a cluster (oc login ...)"

# Ensure repo-local OLM tooling exists (idempotent; downloads only what's missing).
if [[ ! -x "${OPM}" ]] || [[ ! -x "${REPO_ROOT}/bin/operator-sdk" ]]; then
    info "Fetching OLM tooling (operator-sdk, opm, kustomize, yq) ..."
    make operator-sdk opm kustomize yq >/dev/null 2>&1 || fatal "failed to fetch OLM tooling"
fi

# --- read the in-cluster image digests (pin by digest for guaranteed freshness) ---
istag_digest() {
    oc get istag "$1:latest" -n "$NAMESPACE" -o jsonpath='{.image.dockerImageReference}' 2>/dev/null
}
OP_DIGEST="$(istag_digest sbr-operator)"
AGENT_DIGEST="$(istag_digest sbr-agent)"
[[ -n "$OP_DIGEST" ]]    || fatal "istag sbr-operator:latest not found in $NAMESPACE — run hack/build-in-cluster.sh first"
[[ -n "$AGENT_DIGEST" ]] || fatal "istag sbr-agent:latest not found in $NAMESPACE — run hack/build-in-cluster.sh first"
info "Operator image: $OP_DIGEST"
info "Agent image:    $AGENT_DIGEST"

# --- 1. generate the OLM bundle manifests with both digests baked in ---
info "Generating OLM bundle manifests ..."
make bundle IMG="$OP_DIGEST" AGENT_IMG="$AGENT_DIGEST" >/dev/null 2>&1 || fatal "make bundle failed"

# --- 2. build the bundle image in-cluster ---
info "Building bundle image in-cluster ..."
oc apply -n "$NAMESPACE" -f - >/dev/null <<'EOF'
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata: { name: sbr-bundle }
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata: { name: sbr-bundle }
spec:
  source: { type: Binary }
  strategy:
    type: Docker
    dockerStrategy: { dockerfilePath: bundle.Dockerfile }
  output:
    to: { kind: ImageStreamTag, name: sbr-bundle:latest }
EOF
oc start-build sbr-bundle -n "$NAMESPACE" --from-dir=. --follow --wait >/dev/null 2>&1 \
    || fatal "bundle image build failed"
BUNDLE_DIGEST_REF="$(istag_digest sbr-bundle)"
BUNDLE_SHA="${BUNDLE_DIGEST_REF#*@}"
INTERNAL_BUNDLE="${INTERNAL_REGISTRY}/${NAMESPACE}/sbr-bundle@${BUNDLE_SHA}"
ok "Bundle image: $INTERNAL_BUNDLE"

# --- 3. render the bundle off-cluster via the registry route, rewrite refs to internal ---
info "Ensuring registry default route + local pull auth (for opm render) ..."
oc patch configs.imageregistry.operator.openshift.io/cluster --type merge \
    -p '{"spec":{"defaultRoute":true}}' >/dev/null 2>&1 || true
ROUTE=""
for _ in $(seq 1 12); do
    ROUTE="$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    [[ -n "$ROUTE" ]] && break; sleep 5
done
[[ -n "$ROUTE" ]] || fatal "registry default route did not become available"

# opm needs a containers policy.json and docker auth for the route.
mkdir -p "${HOME}/.config/containers"
[[ -f "${HOME}/.config/containers/policy.json" ]] || \
    echo '{"default":[{"type":"insecureAcceptAnything"}]}' > "${HOME}/.config/containers/policy.json"
TOKEN="$(oc create token default -n "$NAMESPACE" --duration=1h 2>/dev/null)"
[[ -n "$TOKEN" ]] || fatal "could not mint a ServiceAccount token for registry auth"
oc policy add-role-to-user system:image-puller \
    "system:serviceaccount:${NAMESPACE}:default" -n "$NAMESPACE" >/dev/null 2>&1 || true
AUTH_B64="$(printf 'default:%s' "$TOKEN" | base64 | tr -d '\n')"
mkdir -p "${HOME}/.docker"
ROUTE="$ROUTE" AUTH="$AUTH_B64" python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.docker/config.json")
cfg = {}
if os.path.exists(p):
    try: cfg = json.load(open(p))
    except Exception: cfg = {}
cfg.setdefault("auths", {})[os.environ["ROUTE"]] = {"auth": os.environ["AUTH"]}
json.dump(cfg, open(p, "w"), indent=2)
PY

info "Rendering bundle (opm render via route) and rewriting refs to internal ..."
ROUTE_BUNDLE="${ROUTE}/${NAMESPACE}/sbr-bundle@${BUNDLE_SHA}"
RENDERED="$(mktemp)"
"${OPM}" render "$ROUTE_BUNDLE" --skip-tls-verify -o yaml > "$RENDERED" 2>/dev/null \
    || fatal "opm render failed"
# Route host -> internal service host for every sbr-* reference in the rendered config.
sed -i.bak "s#${ROUTE}/${NAMESPACE}/#${INTERNAL_REGISTRY}/${NAMESPACE}/#g" "$RENDERED" && rm -f "${RENDERED}.bak"

# --- 4. assemble + validate the file-based catalog ---
info "Assembling file-based catalog ..."
rm -rf catalog catalog.Dockerfile && mkdir -p catalog
cat > catalog/index.yaml <<EOF
---
schema: olm.package
name: ${OPERATOR_NAME}
defaultChannel: ${CHANNEL}
---
schema: olm.channel
package: ${OPERATOR_NAME}
name: ${CHANNEL}
entries:
  - name: ${OPERATOR_NAME}.v${VERSION}
---
EOF
cat "$RENDERED" >> catalog/index.yaml
rm -f "$RENDERED"
"${OPM}" validate catalog || fatal "opm validate failed"
"${OPM}" generate dockerfile catalog >/dev/null

# --- 5. build the catalog image in-cluster ---
info "Building catalog image in-cluster ..."
oc apply -n "$NAMESPACE" -f - >/dev/null <<'EOF'
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata: { name: sbr-catalog }
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata: { name: sbr-catalog }
spec:
  source: { type: Binary }
  strategy:
    type: Docker
    dockerStrategy: { dockerfilePath: catalog.Dockerfile }
  output:
    to: { kind: ImageStreamTag, name: sbr-catalog:latest }
EOF
oc start-build sbr-catalog -n "$NAMESPACE" --from-dir=. --follow --wait >/dev/null 2>&1 \
    || fatal "catalog image build failed"
CATALOG_DIGEST_REF="$(istag_digest sbr-catalog)"
CATALOG_SHA="${CATALOG_DIGEST_REF#*@}"
INTERNAL_CATALOG="${INTERNAL_REGISTRY}/${NAMESPACE}/sbr-catalog@${CATALOG_SHA}"
ok "Catalog image: $INTERNAL_CATALOG"

# --- 6. (re)create the OLM objects ---
# Same-version rebuilds won't re-roll the CSV, so drop the Subscription+CSV first to force the
# freshly-built images to take effect (a no-op on a clean cluster).
info "Recreating OLM Subscription/CatalogSource ..."
oc delete subscription "$OPERATOR_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
oc delete csv "${OPERATOR_NAME}.v${VERSION}" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true

oc apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: sbr-catalog
  namespace: ${NAMESPACE}
spec:
  sourceType: grpc
  image: ${INTERNAL_CATALOG}
  displayName: SBR Dev Catalog (in-cluster)
  publisher: dev
  updateStrategy:
    registryPoll: { interval: 10m }
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: sbr-operator-group
  namespace: ${NAMESPACE}
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${OPERATOR_NAME}
  namespace: ${NAMESPACE}
spec:
  channel: ${CHANNEL}
  name: ${OPERATOR_NAME}
  source: sbr-catalog
  sourceNamespace: ${NAMESPACE}
  installPlanApproval: Automatic
EOF

# --- wait for the CSV to reach Succeeded ---
info "Waiting for CSV ${OPERATOR_NAME}.v${VERSION} to succeed ..."
PHASE=""
for _ in $(seq 1 40); do
    PHASE="$(oc get csv "${OPERATOR_NAME}.v${VERSION}" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$PHASE" == "Succeeded" ]] && break
    [[ "$PHASE" == "Failed" ]] && fatal "CSV failed: $(oc get csv "${OPERATOR_NAME}.v${VERSION}" -n "$NAMESPACE" -o jsonpath='{.status.message}')"
    sleep 15
done
[[ "$PHASE" == "Succeeded" ]] || fatal "CSV did not reach Succeeded (last phase: ${PHASE:-none})"

oc rollout status deploy/sbr-operator-controller-manager -n "$NAMESPACE" --timeout=120s >/dev/null 2>&1 || true
ok "SBR operator installed via OLM (CSV Succeeded)"
oc get pods -n "$NAMESPACE" -l control-plane=controller-manager >&2 || true
