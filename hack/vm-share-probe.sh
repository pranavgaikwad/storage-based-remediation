#!/usr/bin/env bash
# vm-share-probe.sh — Reproduce the Portworx RWX-block multi-writer limitation
# one layer up, through the OpenShift Virtualization (KubeVirt/QEMU) stack.
#
# Three Fedora VMs are pinned one-per-node and all attach the SAME RWX raw-block
# PVC as a shared disk (shareable=true). Each guest runs an O_DIRECT write loop
# into its own 4K slot and reads its peers' slots back. Because KubeVirt drives
# block disks with cache=none, a guest O_DIRECT write becomes an O_DIRECT write
# to the host /dev/pxd device — the exact path px-block-probe exercises with dd.
#
# Expectation (matches px-block-probe): the VM on the volume's coordinator/attach
# node writes fine; the VMs on non-coordinator nodes hang in guest I/O (the dd
# never returns, serial log shows a WRITE with no OK) — proving that VMs sharing
# a Portworx RWX-block device cannot all durably write concurrently.
#
# Read each VM's progress from its serial console:
#   oc logs -n vm-share-probe <virt-launcher-pod> -c guest-console-log -f
# or:  virtctl console -n vm-share-probe sbr-vm-0
#
# Usage:
#   ./hack/vm-share-probe.sh                          # deploy PVC + 3 VMs
#   ./hack/vm-share-probe.sh --storage-class my-sc    # override shared-disk SC
#   ./hack/vm-share-probe.sh --attach                 # report pxctl attach node
#   ./hack/vm-share-probe.sh --logs                   # tail all guest consoles
#   ./hack/vm-share-probe.sh --cleanup
set -euo pipefail

NAMESPACE="${NAMESPACE:-vm-share-probe}"
STORAGE_CLASS="${STORAGE_CLASS:-portworx-block-direct}"   # RWX raw-block SC
PXNS="${PXNS:-portworx}"
FEDORA_IMG="${FEDORA_IMG:-quay.io/containerdisks/fedora:latest}"
# One VM per node. Defaults to the three nodes used by px-block-probe
# (28-216 was the coordinator/attach node in prior runs).
NODES=("${NODE_0:-ip-10-0-28-216.ec2.internal}" \
       "${NODE_1:-ip-10-0-3-45.ec2.internal}" \
       "${NODE_2:-ip-10-0-8-24.ec2.internal}")
ACTION="deploy"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --storage-class|--storage-class=*)
      if [[ "$1" == *=* ]]; then STORAGE_CLASS="${1#*=}"; else shift; STORAGE_CLASS="$1"; fi; shift ;;
    --cleanup) ACTION="cleanup"; shift ;;
    --attach)  ACTION="attach"; shift ;;
    --logs)    ACTION="logs"; shift ;;
    -h|--help) echo "Usage: $0 [--storage-class <sc>] [--attach] [--logs] [--cleanup]" >&2; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

pxpod() { oc get pods -n "$PXNS" -l name=portworx -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }

report_attach() {
  local pv; pv=$(oc get pvc sbr-shared-block -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}' 2>/dev/null)
  [[ -z "$pv" ]] && { echo "no PVC bound yet"; return; }
  echo "=== pxctl volume inspect $pv (attach/coordinator node) ==="
  oc exec -n "$PXNS" "$(pxpod)" -- /opt/pwx/bin/pxctl volume inspect "$pv" 2>&1 \
    | grep -iE "shared|state|attached|device path|coordinator|replica sets on nodes" || true
}

tail_logs() {
  echo "=== guest serial consoles (Ctrl-C to stop) ==="
  local pods; pods=$(oc get pods -n "$NAMESPACE" -l kubevirt.io=virt-launcher \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  local args=()
  for p in $pods; do args+=("$p"); done
  # stream each console with a prefix
  for p in "${args[@]}"; do
    ( oc logs -n "$NAMESPACE" "$p" -c guest-console-log -f 2>/dev/null | sed "s/^/[$p] /" ) &
  done
  wait
}

case "$ACTION" in
  cleanup) oc delete namespace "$NAMESPACE" --ignore-not-found --timeout=120s; exit 0 ;;
  attach)  report_attach; exit 0 ;;
  logs)    tail_logs; exit 0 ;;
esac

oc get namespace "$NAMESPACE" >/dev/null 2>&1 || oc create namespace "$NAMESPACE"
oc label namespace "$NAMESPACE" \
  pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null 2>&1 || true

# Shared RWX raw-block PVC — the one device all three VMs write to.
oc apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sbr-shared-block
spec:
  accessModes: [ReadWriteMany]
  volumeMode: Block
  resources:
    requests:
      storage: 1Gi
  storageClassName: ${STORAGE_CLASS}
EOF

NUM=${#NODES[@]}

# cloud-init write/read loop, emitted per-VM with SLOT/NODE/NUM substituted.
# Writes are O_DIRECT (oflag=direct); KubeVirt cache=none forwards them to the
# host pxd device as O_DIRECT. A non-coordinator write parks in uninterruptible
# guest I/O and never returns -> the serial log shows START + WRITE-begin but no
# "WRITE OK". The coordinator VM logs "WRITE OK" every iteration.
gen_userdata() { # $1=slot $2=node
  cat <<CIEOF
#cloud-config
write_files:
  - path: /usr/local/bin/sbr-probe.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      exec > /dev/ttyS0 2>&1
      SLOT=$1; NODE="$2"; NUM=${NUM}; BS=4096
      DEV=""
      for i in \$(seq 1 30); do
        DEV=\$(ls /dev/disk/by-id/*SBRSHARE* 2>/dev/null | head -1)
        [ -n "\$DEV" ] && break; sleep 2
      done
      [ -z "\$DEV" ] && { echo "SBR-PROBE FATAL: shared disk not found"; exit 1; }
      echo "SBR-PROBE START node=\$NODE slot=\$SLOT dev=\$DEV num=\$NUM"
      iter=0
      while true; do
        iter=\$((iter+1)); ts=\$(date +%s)
        printf 'NODE=%s slot=%s iter=%s ts=%s' "\$NODE" "\$SLOT" "\$iter" "\$ts" > /tmp/buf
        truncate -s 4096 /tmp/buf
        echo "SBR-PROBE WRITE begin slot=\$SLOT iter=\$iter (if no OK follows, guest I/O is hung)"
        if timeout -k 2 15 dd if=/tmp/buf of=\$DEV bs=\$BS count=1 seek=\$SLOT oflag=direct conv=notrunc 2>/tmp/err; then
          echo "SBR-PROBE WRITE OK   slot=\$SLOT iter=\$iter took=\$((\$(date +%s)-ts))s"
        else
          echo "SBR-PROBE WRITE FAIL slot=\$SLOT iter=\$iter took=\$((\$(date +%s)-ts))s err=\$(tr -d '\n' </tmp/err)"
        fi
        for s in \$(seq 0 \$((NUM-1))); do
          [ "\$s" = "\$SLOT" ] && continue
          v=\$(timeout 10 dd if=\$DEV bs=\$BS count=1 skip=\$s iflag=direct 2>/dev/null | tr -d '\0' | head -c 80)
          echo "\$v" | grep -q "NODE=" && echo "SBR-PROBE READ PEER slot=\$s -> '\$v'   <== cross-node visible"
        done
        sleep 8
      done
runcmd:
  - [ systemd-run, --unit, sbr-probe, /usr/local/bin/sbr-probe.sh ]
CIEOF
}

for i in "${!NODES[@]}"; do
  NODE="${NODES[$i]}"
  UD=$(gen_userdata "$i" "$NODE" | base64 | tr -d '\n')
  oc apply -n "$NAMESPACE" -f - <<VMEOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: sbr-vm-${i}
spec:
  running: true
  template:
    metadata:
      labels: {app: sbr-vm-probe}
    spec:
      nodeSelector:
        kubernetes.io/hostname: ${NODE}
      terminationGracePeriodSeconds: 0
      domain:
        cpu: {cores: 1}
        resources:
          requests: {memory: 1Gi}
        devices:
          disks:
            - name: rootdisk
              disk: {bus: virtio}
            - name: cloudinit
              disk: {bus: virtio}
            - name: shared
              serial: SBRSHARE
              disk: {bus: virtio}
              shareable: true
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          containerDisk: {image: ${FEDORA_IMG}}
        - name: cloudinit
          cloudInitNoCloud: {userDataBase64: ${UD}}
        - name: shared
          persistentVolumeClaim: {claimName: sbr-shared-block}
VMEOF
done

echo
echo "Deployed. Watch VMs come up:  oc get vmi -n ${NAMESPACE} -w"
echo "Coordinator node:            $0 --attach"
echo "Guest write logs:            $0 --logs"
echo "Cleanup:                     $0 --cleanup"
