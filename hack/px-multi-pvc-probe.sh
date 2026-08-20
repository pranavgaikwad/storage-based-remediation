#!/usr/bin/env bash
# px-multi-pvc-probe.sh — Test the "per-node PVC + central reader" design.
#
# Instead of ONE shared RWX-block volume that every node writes (which hangs on
# non-coordinator nodes), give each node its OWN RWX-block PVC that only that
# node's writer pod writes (single writer per volume), and run ONE manager pod
# that mounts ALL the PVCs and reads each node's heartbeat.
#
# The question this answers: does Portworx attach each per-node volume to that
# node (writer == coordinator -> O_DIRECT write succeeds), while the manager
# reads them all cross-node? If a writer still hangs, the attach landed on the
# manager's node and even this design fails.
#
# Success  = every writer logs "WRITE OK" (no D-state hang) AND the manager
#            reads a fresh, distinct heartbeat from every per-node volume.
# Failure  = any writer stuck at "WRITE begin" (attach not on writer's node),
#            or the manager reads stale/empty slots.
#
# Usage:
#   ./hack/px-multi-pvc-probe.sh            # deploy PVCs + writers + manager
#   ./hack/px-multi-pvc-probe.sh --attach   # show pxctl attach node per volume
#   ./hack/px-multi-pvc-probe.sh --logs     # tail writers + manager
#   ./hack/px-multi-pvc-probe.sh --cleanup
set -euo pipefail

NAMESPACE="${NAMESPACE:-px-multi-pvc}"
STORAGE_CLASS="${STORAGE_CLASS:-portworx-block-direct}"
PXNS="${PXNS:-portworx}"
IMG="${IMG:-registry.access.redhat.com/ubi9/ubi:latest}"
ACTION="deploy"
case "${1:-}" in
  --cleanup) ACTION="cleanup" ;;
  --attach)  ACTION="attach" ;;
  --logs)    ACTION="logs" ;;
esac

pxpod() { oc get pods -n "$PXNS" -l name=portworx -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }

# Pick 3 worker nodes (sorted, stable).
mapfile -t NODES < <(oc get nodes -l node-role.kubernetes.io/worker= \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort | head -3)
N=${#NODES[@]}

if [[ "$ACTION" == "cleanup" ]]; then
  oc delete namespace "$NAMESPACE" --ignore-not-found --timeout=120s; exit 0
fi
if [[ "$ACTION" == "attach" ]]; then
  for i in "${!NODES[@]}"; do
    pv=$(oc get pvc "pnode-$i" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}' 2>/dev/null)
    [[ -z "$pv" ]] && continue
    echo "=== pnode-$i (writer node ${NODES[$i]}) -> $pv ==="
    oc exec -n "$PXNS" "$(pxpod)" -- /opt/pwx/bin/pxctl volume inspect "$pv" 2>&1 \
      | grep -iE "Shared|Attached|Device Path" || true
  done
  exit 0
fi
if [[ "$ACTION" == "logs" ]]; then
  echo "--- writers ---"; oc logs -n "$NAMESPACE" -l role=writer --prefix --tail=6 2>/dev/null | tr -cd '[:print:]\n'
  echo "--- manager ---"; oc logs -n "$NAMESPACE" -l role=manager --tail=20 2>/dev/null | tr -cd '[:print:]\n'
  exit 0
fi

oc get namespace "$NAMESPACE" >/dev/null 2>&1 || oc create namespace "$NAMESPACE"
oc adm policy add-scc-to-user privileged -z default -n "$NAMESPACE" >/dev/null

# One RWX-block PVC per node.
for i in "${!NODES[@]}"; do
  oc apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: pnode-$i}
spec:
  accessModes: [ReadWriteMany]
  volumeMode: Block
  resources: {requests: {storage: 1Gi}}
  storageClassName: ${STORAGE_CLASS}
EOF
done

# One writer pod per node: pinned to that node, mounts ONLY its own PVC,
# writes a 4K O_DIRECT heartbeat every 5s. Single writer per volume.
for i in "${!NODES[@]}"; do
  oc apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: writer-$i, labels: {role: writer}}
spec:
  nodeSelector: {kubernetes.io/hostname: ${NODES[$i]}}
  terminationGracePeriodSeconds: 2
  containers:
    - name: w
      image: ${IMG}
      securityContext: {privileged: true}
      command: ["/bin/bash","-c"]
      args:
        - |
          set -uo pipefail
          DEV=/dev/wslot; NODE=\$(hostname); BS=4096; iter=0
          echo "[writer-$i on ${NODES[$i]}] START dev=\$DEV"
          while true; do
            iter=\$((iter+1)); ts=\$(date +%s)
            printf 'NODE=%s iter=%s ts=%s' "${NODES[$i]}" "\$iter" "\$ts" > /tmp/buf
            truncate -s 4096 /tmp/buf
            echo "[writer-$i] WRITE begin iter=\$iter (no OK => hung/non-coordinator)"
            if timeout -k 2 15 dd if=/tmp/buf of=\$DEV bs=\$BS count=1 seek=0 oflag=direct conv=notrunc 2>/tmp/e; then
              echo "[writer-$i] WRITE OK iter=\$iter took=\$((\$(date +%s)-ts))s"
            else
              echo "[writer-$i] WRITE FAIL iter=\$iter err=\$(tr -d '\n' </tmp/e)"
            fi
            sleep 5
          done
      volumeDevices: [{name: v, devicePath: /dev/wslot}]
  volumes: [{name: v, persistentVolumeClaim: {claimName: pnode-$i}}]
EOF
done

# Manager pod: mounts ALL per-node PVCs, reads each with O_DIRECT every 6s.
VDEV=""; VOLS=""
for i in "${!NODES[@]}"; do
  VDEV="${VDEV}            - {name: v$i, devicePath: /dev/n$i}\n"
  VOLS="${VOLS}        - {name: v$i, persistentVolumeClaim: {claimName: pnode-$i}}\n"
done
oc apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: manager, labels: {role: manager}}
spec:
  terminationGracePeriodSeconds: 2
  containers:
    - name: m
      image: ${IMG}
      securityContext: {privileged: true}
      command: ["/bin/bash","-c"]
      args:
        - |
          set -uo pipefail
          N=${N}; BS=4096
          echo "[manager on \$(hostname)] reading \$N per-node volumes"
          while true; do
            for i in \$(seq 0 \$((N-1))); do
              v=\$(timeout 10 dd if=/dev/n\$i bs=\$BS count=1 skip=0 iflag=direct 2>/dev/null | tr -d '\0' | head -c 80)
              if echo "\$v" | grep -q "NODE="; then
                echo "[manager] vol n\$i -> '\$v'"
              else
                echo "[manager] vol n\$i -> <empty/stale> (read hung or no heartbeat)"
              fi
            done
            echo "[manager] ---"
            sleep 6
          done
      volumeDevices:
$(echo -e "$VDEV")
  volumes:
$(echo -e "$VOLS")
EOF

echo
echo "Deployed $N per-node PVCs + writers + 1 manager in ns/$NAMESPACE"
echo "Attach node per volume:  $0 --attach"
echo "Logs:                    $0 --logs"
echo "Cleanup:                 $0 --cleanup"
