#!/usr/bin/env bash
# Create the /dev/watchdog device node on every Kind node for SBR e2e.
#
# The shared dev environment (tools/dev/setup.sh, run by `make dev-setup`) already
# loads softdog with soft_noboot=1 on every worker. It does NOT create the
# /dev/watchdog device node though: Kind nodes have no udev, so loading the module
# alone leaves the node absent. SNR does not need it (it never opens a real
# watchdog in Kind), but SBR agent preflight/readiness require /dev/watchdog
# (cmd/sbr-agent/preflight.go; the e2e suite sets WatchdogPath=/dev/watchdog and
# does not enable detect-only mode). In filesystem mode the agent DaemonSet
# bind-mounts host /dev, so the node's /dev/watchdog appears in the agent pod.
set -euo pipefail

CLUSTER_NAME="${MEDIK8S_CLUSTER_NAME:-medik8s-ci}"
CONTAINER_TOOL="${CONTAINER_TOOL:-docker}"

echo "=== Ensuring /dev/watchdog on each Kind node ==="
for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
  "${CONTAINER_TOOL}" exec "${node}" sh -c '
    grep -q softdog /proc/modules 2>/dev/null || modprobe softdog soft_noboot=1
    [ -c /dev/watchdog ] || mknod /dev/watchdog c 10 130
    ls -l /dev/watchdog'
done
echo "=== Watchdog setup complete ==="
