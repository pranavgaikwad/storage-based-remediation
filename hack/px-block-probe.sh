#!/usr/bin/env bash
# px-block-probe.sh — Rigorously test whether a Portworx RWX raw-block volume
# supports the semantics SBR block mode needs: concurrent multi-writer with
# cross-node read coherency.
#
# Improvements over the old test-portworx-block.sh:
#   * Fixes the O_DIRECT alignment bug: builds a page-aligned buffer in a file
#     (dd from a real file gives full aligned blocks) instead of piping `echo`
#     into `dd oflag=direct`, which issues short/misaligned O_DIRECT writes.
#   * Each node owns a distinct slot; every iteration each node WRITES its own
#     slot and READS BACK its own slot AND the peer's slot -> proves cross-node
#     coherency, not just single-node round-trips.
#   * Runs both O_DIRECT and buffered (fsync) writes so we can tell a device
#     hang apart from an alignment/EINVAL failure.
#   * Reports pxctl attachment (single vs multi-attach) for the volume.
#   * Collision-free slots: the deploy side enumerates worker nodes, sorts them,
#     and injects the list; each pod's slot is its index in that list (no md5
#     hash collisions, and peers occupy a dense 0..N-1 range the scan can find).
#   * D-state hang detection: writes run as a background PID whose /proc state is
#     polled. A non-coordinator O_DIRECT write hangs in uninterruptible D-state,
#     which `timeout` cannot abort (SIGTERM/SIGKILL are ignored in D); we detect
#     and report it explicitly instead of the loop silently wedging.
#
# Usage:
#   ./hack/px-block-probe.sh                               # deploy PVC+DaemonSet, stream logs
#   ./hack/px-block-probe.sh --storage-class my-sc         # pin a custom StorageClass
#   ./hack/px-block-probe.sh --attach                      # just report pxctl attachment state
#   ./hack/px-block-probe.sh --cleanup
#
# Env: NAMESPACE, STORAGE_CLASS (default px-csi-replicated), PXNS.
set -euo pipefail

NAMESPACE="${NAMESPACE:-px-block-test}"
STORAGE_CLASS="${STORAGE_CLASS:-px-csi-replicated}"
PXNS="${PXNS:-portworx}"
ACTION="deploy"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --storage-class|--storage-class=*)
      if [[ "$1" == *=* ]]; then STORAGE_CLASS="${1#*=}"; else shift; STORAGE_CLASS="$1"; fi; shift ;;
    --cleanup) ACTION="cleanup"; shift ;;
    --attach)  ACTION="attach"; shift ;;
    -h|--help)
      echo "Usage: $0 [--storage-class <sc>] [--attach] [--cleanup]" >&2; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

pxpod() { oc get pods -n "$PXNS" -l name=portworx -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }

report_attach() {
  local pv; pv=$(oc get pvc px-block-probe-pvc -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}' 2>/dev/null)
  [[ -z "$pv" ]] && { echo "no PVC bound yet"; return; }
  echo "=== pxctl volume inspect $pv ==="
  oc exec -n "$PXNS" "$(pxpod)" -- /opt/pwx/bin/pxctl volume inspect "$pv" 2>&1 \
    | grep -iE "shared|state|attached|device path|io_profile" || true
}

if [[ "$ACTION" == "cleanup" ]]; then
  oc delete namespace "$NAMESPACE" --ignore-not-found --timeout=90s
  exit 0
fi
if [[ "$ACTION" == "attach" ]]; then
  report_attach
  exit 0
fi

oc get namespace "$NAMESPACE" >/dev/null 2>&1 || oc create namespace "$NAMESPACE"
oc adm policy add-scc-to-user privileged -z default -n "$NAMESPACE" >/dev/null

oc apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: px-block-probe-pvc
spec:
  accessModes: [ReadWriteMany]
  volumeMode: Block
  resources:
    requests:
      storage: 1Gi
  storageClassName: ${STORAGE_CLASS}
EOF

#echo "Waiting for PVC to bind ..."
#for _ in $(seq 1 24); do
#  [[ "$(oc get pvc px-block-probe-pvc -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Bound" ]] && break
#  sleep 5
#done
#[[ "$(oc get pvc px-block-probe-pvc -n "$NAMESPACE" -o jsonpath='{.status.phase}')" == "Bound" ]] || { echo "PVC did not bind"; exit 1; }

# Enumerate worker nodes (sorted) so each pod derives a stable, collision-free
# slot = its index in this list. This also bounds the peer-scan range.
NODE_LIST=$(oc get nodes -l node-role.kubernetes.io/worker= \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort | paste -sd, -)
[[ -z "$NODE_LIST" ]] && { echo "no worker nodes found"; exit 1; }
echo "worker nodes -> slots: $NODE_LIST"
oc create configmap px-block-probe-nodes -n "$NAMESPACE" \
  --from-literal=NODE_LIST="$NODE_LIST" \
  --dry-run=client -o yaml | oc apply -n "$NAMESPACE" -f -

oc apply -n "$NAMESPACE" -f - <<'DSEOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: px-block-probe
spec:
  selector:
    matchLabels: {app: px-block-probe}
  template:
    metadata:
      labels: {app: px-block-probe}
    spec:
      nodeSelector: {node-role.kubernetes.io/worker: ""}
      tolerations: [{operator: Exists}]
      terminationGracePeriodSeconds: 3
      containers:
        - name: probe
          image: registry.access.redhat.com/ubi9/ubi:latest
          command: ["/bin/bash","-c"]
          args:
            - |
              set -uo pipefail
              DEV=/dev/probe-block
              NODE=${NODE_NAME}
              BS=4096
              WRITE_LIMIT=15   # seconds before a write is declared hung
              # Collision-free slot = index of this node in the injected sorted
              # node list. Peers occupy a dense 0..NUM-1 range.
              IFS=',' read -ra NODES <<< "${NODE_LIST}"
              SLOT=-1
              for i in "${!NODES[@]}"; do
                [[ "${NODES[$i]}" == "$NODE" ]] && { SLOT=$i; break; }
              done
              NUM=${#NODES[@]}
              if [[ "$SLOT" -lt 0 ]]; then
                echo "[$NODE] FATAL: node not in NODE_LIST='${NODE_LIST}'"; sleep 3600; exit 1
              fi
              echo "[$NODE] START slot=$SLOT/$((NUM-1)) dev=$DEV (scan peers 0..$((NUM-1)))"
              ls -la $DEV; stat $DEV 2>&1 || true

              # Build a page-aligned 4096-byte buffer in a FILE (fixes O_DIRECT
              # alignment: dd reading a regular file emits full aligned blocks).
              mkbuf() { # $1=text -> /tmp/buf (4096 bytes, newline-terminated)
                printf '%-4095s\n' "$1" | head -c $BS > /tmp/buf
              }

              # writeslot runs dd as a background PID and polls /proc/<pid>/stat.
              # Returns: 0=ok, 2=hang/timeout (already reported), other=dd error.
              # A non-coordinator O_DIRECT write parks in state 'D' (uninterruptible)
              # and is unkillable, so `timeout` cannot recover it — we detect and
              # report the D-state rather than let the loop wedge silently.
              writeslot() { # $1=slot $2=text $3=direct|buffered
                mkbuf "$2"
                local flag; [[ "$3" == "direct" ]] && flag="oflag=direct" || flag="conv=fsync"
                dd if=/tmp/buf of=$DEV bs=$BS count=1 seek=$1 $flag conv=notrunc 2>/tmp/dderr &
                local pid=$! waited=0 st
                while :; do
                  st=$(cut -d' ' -f3 /proc/$pid/stat 2>/dev/null) || st=""
                  [[ -z "$st" || "$st" == Z* ]] && break   # finished (gone/zombie)
                  if (( waited >= WRITE_LIMIT )); then
                    if [[ "$st" == D* ]]; then
                      echo "[$NODE] WRITE HANG slot=$1 mode=$3 iter=$iter state=D (uninterruptible; unkillable — no durable write from this node)"
                    else
                      echo "[$NODE] WRITE TIMEOUT slot=$1 mode=$3 iter=$iter state=$st"
                    fi
                    kill -9 "$pid" 2>/dev/null || true   # best-effort; ignored in D
                    return 2
                  fi
                  sleep 1; waited=$((waited+1))
                done
                wait "$pid"; return $?
              }
              readslot() { # $1=slot -> stdout trimmed
                timeout 10 dd if=$DEV bs=$BS count=1 skip=$1 iflag=direct 2>/dev/null | tr -d '\0' | head -c 120
              }

              iter=0
              while true; do
                iter=$((iter+1)); ts=$(date +%s)
                for mode in direct buffered; do
                  MSG="NODE=$NODE iter=$iter mode=$mode ts=$ts"
                  writeslot "$SLOT" "$MSG" "$mode"; rc=$?
                  case $rc in
                    0) echo "[$NODE] WRITE OK   slot=$SLOT mode=$mode iter=$iter" ;;
                    2) : ;;  # hang/timeout already reported
                    *) echo "[$NODE] WRITE FAIL slot=$SLOT mode=$mode iter=$iter rc=$rc err=$(tr -d '\n' </tmp/dderr)" ;;
                  esac
                done
                # read back own slot
                own=$(readslot "$SLOT")
                echo "[$NODE] READ  own  slot=$SLOT -> '${own}'"
                # scan peer slots (dense 0..NUM-1), report cross-node visibility
                for ((s=0; s<NUM; s++)); do
                  [[ "$s" == "$SLOT" ]] && continue
                  v=$(readslot "$s")
                  if echo "$v" | grep -q "NODE=" && ! echo "$v" | grep -q "NODE=$NODE"; then
                    echo "[$NODE] READ  PEER slot=$s -> '${v}'   <== cross-node visible"
                  fi
                done
                sleep 8
              done
          env:
            - name: NODE_NAME
              valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
            - name: NODE_LIST
              valueFrom: {configMapKeyRef: {name: px-block-probe-nodes, key: NODE_LIST}}
          volumeDevices:
            - {name: block-vol, devicePath: /dev/probe-block}
          securityContext: {privileged: true}
      volumes:
        - name: block-vol
          persistentVolumeClaim: {claimName: px-block-probe-pvc}
DSEOF

echo "Waiting for pods ..."
for _ in $(seq 1 24); do
  oc get pods -n "$NAMESPACE" -l app=px-block-probe --no-headers 2>/dev/null | grep -q Running && break
  sleep 5
done
oc get pods -n "$NAMESPACE" -l app=px-block-probe -o wide
echo; report_attach
echo; echo "=== logs (Ctrl-C to stop; cleanup: $0 --cleanup) ==="
oc logs -n "$NAMESPACE" -l app=px-block-probe --prefix -f --max-log-requests 6 2>/dev/null
