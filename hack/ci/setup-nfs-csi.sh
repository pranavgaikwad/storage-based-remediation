#!/usr/bin/env bash
# Set up an in-cluster RWX filesystem StorageClass for SBR e2e in Kind.
#
# SBR's e2e suite (test/e2e) requires a ReadWriteMany filesystem StorageClass:
# findRWXFilesystemStorageClass() accepts the nfs.csi.k8s.io provisioner. On a
# real cluster this is ODF/CephFS; in Kind we stand up csi-driver-nfs backed by
# an in-cluster NFS server and expose it as the "nfs-csi" StorageClass. This
# mirrors the upstream csi-driver-nfs example (nfs-server-alpine exports its
# SHARED_DIRECTORY as the NFS root "/", which is writable).
#
# NOTE: block-mode tests (Portworx / Ceph RBD) are NOT covered here and are
# excluded from the Kind run via the ginkgo label filter (!block).
#
# NOTE: nfs-server-alpine is a KERNEL NFS server; it needs the host "nfsd" module
# (the workflow loads it with `sudo modprobe nfsd nfs`). NFS client mounts do NOT
# work under Docker Desktop / podman (LinuxKit kernel) locally, so this path is
# only exercisable on the GitHub Actions ubuntu runner, matching the upstream
# csi-driver-nfs example CI.
set -euo pipefail

CSI_DRIVER_NFS_VERSION="${CSI_DRIVER_NFS_VERSION:-v4.11.0}"
NFS_NAMESPACE="${NFS_NAMESPACE:-nfs-server}"
STORAGE_CLASS_NAME="${STORAGE_CLASS_NAME:-nfs-csi}"
NFS_SERVER_IMAGE="${NFS_SERVER_IMAGE:-itsthenetwork/nfs-server-alpine:latest}"
KUBECTL="${KUBECTL:-kubectl}"

echo "=== Installing csi-driver-nfs ${CSI_DRIVER_NFS_VERSION} ==="
curl -skSL "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/${CSI_DRIVER_NFS_VERSION}/deploy/install-driver.sh" \
  | bash -s "${CSI_DRIVER_NFS_VERSION}" --

echo "=== Waiting for csi-driver-nfs to be ready ==="
"${KUBECTL}" -n kube-system rollout status deployment/csi-nfs-controller --timeout=180s
"${KUBECTL}" -n kube-system rollout status daemonset/csi-nfs-node --timeout=180s

echo "=== Deploying in-cluster NFS server ==="
"${KUBECTL}" create namespace "${NFS_NAMESPACE}" --dry-run=client -o yaml | "${KUBECTL}" apply -f -
cat <<EOF | "${KUBECTL}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-server
  namespace: ${NFS_NAMESPACE}
  labels:
    app: nfs-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nfs-server
  template:
    metadata:
      labels:
        app: nfs-server
    spec:
      containers:
        - name: nfs-server
          image: ${NFS_SERVER_IMAGE}
          env:
            - name: SHARED_DIRECTORY
              value: /exports
          ports:
            - name: tcp-2049
              containerPort: 2049
              protocol: TCP
            - name: udp-111
              containerPort: 111
              protocol: UDP
          securityContext:
            privileged: true
          volumeMounts:
            - name: exports
              mountPath: /exports
      volumes:
        - name: exports
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: nfs-server
  namespace: ${NFS_NAMESPACE}
  labels:
    app: nfs-server
spec:
  selector:
    app: nfs-server
  ports:
    - name: tcp-2049
      port: 2049
      protocol: TCP
    - name: udp-111
      port: 111
      protocol: UDP
EOF

echo "=== Waiting for NFS server to be ready ==="
"${KUBECTL}" -n "${NFS_NAMESPACE}" rollout status deployment/nfs-server --timeout=180s

echo "=== Creating StorageClass ${STORAGE_CLASS_NAME} (provisioner nfs.csi.k8s.io) ==="
cat <<EOF | "${KUBECTL}" apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${STORAGE_CLASS_NAME}
provisioner: nfs.csi.k8s.io
parameters:
  # nfs-server-alpine exports SHARED_DIRECTORY as the NFS root "/", which is writable.
  server: nfs-server.${NFS_NAMESPACE}.svc.cluster.local
  share: /
reclaimPolicy: Delete
volumeBindingMode: Immediate
mountOptions:
  - nfsvers=4.1
EOF

echo "=== StorageClasses ==="
"${KUBECTL}" get storageclass
echo "=== NFS CSI storage setup complete ==="
