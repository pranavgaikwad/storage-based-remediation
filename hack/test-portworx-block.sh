#!/usr/bin/env bash
# test-portworx-block.sh — Diagnose Portworx RWX block volume read/write behaviour
# across all worker nodes via a DaemonSet. Each pod writes a node-unique pattern,
# reads it back, and logs pass/fail verbosely. Useful for diagnosing asymmetric
# write failures (e.g. only non-primary Portworx nodes fail).
#
# Usage:
#   ./hack/test-portworx-block.sh [--storage-class <sc>] [--cleanup]
# Env: STORAGE_CLASS (default: portworx-replica-two), NAMESPACE (default: px-block-test)

set -euo pipefail

NAMESPACE="${NAMESPACE:-px-block-test}"
STORAGE_CLASS="${STORAGE_CLASS:-portworx-replica-two}"
ACTION="deploy"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --storage-class|--storage-class=*)
            if [[ "$1" == *=* ]]; then STORAGE_CLASS="${1#*=}"; else shift; STORAGE_CLASS="$1"; fi; shift ;;
        --cleanup) ACTION="cleanup"; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ "$ACTION" == "cleanup" ]]; then
    echo "Cleaning up namespace $NAMESPACE ..."
    oc delete namespace "$NAMESPACE" --ignore-not-found --timeout=60s
    echo "Done."
    exit 0
fi

oc get namespace "$NAMESPACE" >/dev/null 2>&1 || oc create namespace "$NAMESPACE"

echo "Granting privileged SCC to default service account ..."
oc adm policy add-scc-to-user privileged -z default -n "$NAMESPACE"

echo "Creating RWX Block PVC (SC=$STORAGE_CLASS) ..."
oc apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: px-block-test-pvc
spec:
  accessModes: [ReadWriteMany]
  volumeMode: Block
  resources:
    requests:
      storage: 10Mi
  storageClassName: ${STORAGE_CLASS}
EOF

echo "Waiting for PVC to bind ..."
for _ in $(seq 1 24); do
    phase=$(oc get pvc px-block-test-pvc -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ "$phase" == "Bound" ]] && { echo "PVC Bound"; break; }
    sleep 5
done
[[ "$(oc get pvc px-block-test-pvc -n "$NAMESPACE" -o jsonpath='{.status.phase}')" == "Bound" ]] \
    || { echo "PVC did not bind"; exit 1; }

echo "Deploying DaemonSet ..."
oc apply -n "$NAMESPACE" -f - <<'DSEOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: px-block-test
spec:
  selector:
    matchLabels:
      app: px-block-test
  template:
    metadata:
      labels:
        app: px-block-test
    spec:
      nodeSelector:
        node-role.kubernetes.io/worker: ""
      tolerations:
        - operator: Exists
      terminationGracePeriodSeconds: 5
      containers:
        - name: tester
          image: registry.access.redhat.com/ubi9/ubi:latest
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -euo pipefail
              DEV=/dev/test-block
              NODE=${NODE_NAME}
              SLOT=$((RANDOM % 100))   # random 4096-aligned slot offset (slot * 4096)
              OFFSET=$(( (SLOT + 1) * 4096 ))
              PATTERN="NODE=${NODE} SLOT=${SLOT} ts=$(date +%s)"
              echo "[$(date -u +%T)] START node=$NODE device=$DEV offset=$OFFSET"

              # --- device info ---
              echo "[$(date -u +%T)] INFO: device info:"
              ls -la $DEV || echo "WARN: cannot stat $DEV"
              stat $DEV 2>&1 || true

              iter=0
              while true; do
                iter=$((iter+1))
                PATTERN="NODE=${NODE} iter=${iter} ts=$(date +%s)"
                PADDED=$(printf "%-4095s" "$PATTERN" | head -c 4095)$'\n'  # 4096 bytes

                # --- WRITE ---
                echo "[$(date -u +%T)] WRITE iter=$iter offset=$OFFSET pattern='$PATTERN'"
                if echo -n "$PADDED" | timeout 15 dd of=$DEV bs=4096 count=1 seek=$(( OFFSET / 4096 )) oflag=direct conv=notrunc 2>&1; then
                    echo "[$(date -u +%T)] WRITE OK iter=$iter"
                else
                    rc=$?
                    echo "[$(date -u +%T)] WRITE FAIL iter=$iter rc=$rc offset=$OFFSET"
                fi

                # --- READ BACK ---
                echo "[$(date -u +%T)] READ  iter=$iter offset=$OFFSET"
                if READ=$(timeout 5 dd if=$DEV bs=4096 count=1 skip=$(( OFFSET / 4096 )) iflag=direct 2>/dev/null); then
                    TRIMMED=$(echo "$READ" | tr -d '\0' | head -c 80)
                    if echo "$TRIMMED" | grep -q "NODE=${NODE}"; then
                        echo "[$(date -u +%T)] READ  OK   iter=$iter read='$TRIMMED'"
                    else
                        echo "[$(date -u +%T)] READ  MISMATCH iter=$iter read='$TRIMMED' expected contains NODE=${NODE}"
                    fi
                else
                    rc=$?
                    echo "[$(date -u +%T)] READ  FAIL iter=$iter rc=$rc"
                fi

                sleep 10
              done
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          volumeDevices:
            - name: block-vol
              devicePath: /dev/test-block
          securityContext:
            privileged: true
      volumes:
        - name: block-vol
          persistentVolumeClaim:
            claimName: px-block-test-pvc
DSEOF

echo ""
echo "Waiting for pods to be Running (up to 120s) ..."
for _ in $(seq 1 24); do
    running=$(oc get pods -n "$NAMESPACE" -l app=px-block-test --no-headers 2>/dev/null | grep -c "Running" || true)
    total=$(oc get pods -n "$NAMESPACE" -l app=px-block-test --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo "  pods Running: ${running}/${total}"
    [[ "$running" -gt 0 ]] && break
    sleep 5
done
oc get pods -n "$NAMESPACE" -l app=px-block-test -o wide

echo ""
echo "=== Streaming logs (Ctrl-C to stop) ==="
echo "    To clean up: $0 --cleanup"
echo ""
oc logs -n "$NAMESPACE" -l app=px-block-test --prefix -f 2>/dev/null \
    || oc logs -n "$NAMESPACE" -l app=px-block-test --prefix 2>/dev/null
