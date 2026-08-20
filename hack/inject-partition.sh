#!/usr/bin/env bash
# inject-partition.sh <node> [duration_seconds]
#
# Surgically partitions a worker from the kube-apiserver by dropping outbound TCP/6443, driving
# the node to Ready=Unknown while leaving storage (Ceph/RBD) traffic intact — so the node keeps
# writing SBR heartbeats and can still read its fence slot. This exercises the ACTIVE disk-fence
# path: a healthy peer writes a FENCE message to the victim's slot, the victim reads it and reboots.
#
# The rule is applied by a transient systemd unit (systemd-run) on the host, NOT a backgrounded
# process inside `oc debug`. A setsid'd child of the debug pod dies when the pod's cgroup is torn
# down on exit; a systemd transient unit is owned by host PID 1 and survives, so the DROP actually
# engages after `oc debug` returns.
#
# Self-healing on two levels:
#   1. The unit removes the rule after <duration_seconds> (default 300) and exits.
#   2. iptables rules are not persistent, so a fence-reboot clears them and the transient unit
#      (RemainAfterExit=no, --collect) is gone.
#
# The DROP is applied ~3s after the unit starts, so `oc debug` returns cleanly before the node
# loses its API path.
set -euo pipefail

NODE="${1:?usage: inject-partition.sh <node> [duration_seconds]}"
DUR="${2:-300}"
UNIT="sbr-partition"

echo "[inject-partition] partitioning ${NODE} from apiserver (tcp/6443) for ${DUR}s via systemd-run ..."
oc debug node/"${NODE}" --quiet -- chroot /host bash -c "
  systemctl reset-failed ${UNIT} 2>/dev/null || true
  systemd-run --unit=${UNIT} --collect --description='SBR e2e apiserver partition' bash -c '
    sleep 3
    iptables  -I OUTPUT -p tcp --dport 6443 -j DROP
    ip6tables -I OUTPUT -p tcp --dport 6443 -j DROP 2>/dev/null || true
    sleep ${DUR}
    iptables  -D OUTPUT -p tcp --dport 6443 -j DROP 2>/dev/null || true
    ip6tables -D OUTPUT -p tcp --dport 6443 -j DROP 2>/dev/null || true
  '
  echo LAUNCHED
"
echo "[inject-partition] launched; partition engages ~3s after debug pod exit."
