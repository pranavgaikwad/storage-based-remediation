#!/usr/bin/env bash
# Set up an in-cluster RWX filesystem StorageClass for SBR e2e in Kind.
#
# SBR's e2e suite (test/e2e) requires a ReadWriteMany filesystem StorageClass:
# findRWXFilesystemStorageClass() accepts the nfs.csi.k8s.io provisioner. On a
# real cluster this is ODF/CephFS; in Kind we stand up csi-driver-nfs backed by
# an in-cluster NFS server and expose it as the "nfs-csi" StorageClass.
#
# NOTE: block-mode tests (Portworx / Ceph RBD) are NOT covered here and are
# excluded from the Kind run via the ginkgo label filter (!block).
set -euo pipefail

CSI_DRIVER_NFS_VERSION="${CSI_DRIVER_NFS_VERSION:-v4.11.0}"
NFS_NAMESPACE="${NFS_NAMESPACE:-nfs-server}"
STORAGE_CLASS_NAME="${STORAGE_CLASS_NAME:-nfs-csi}"
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
          image: registry.k8s.io/sig-storage/nfs-provisioner:v4.0.8
          args:
            - "-provisioner=nfs.csi.k8s.io"
          securityContext:
            capabilities:
              add: ["DAC_READ_SEARCH", "SYS_RESOURCE"]
            privileged: true
          ports:
            - name: nfs
              containerPort: 2049
            - name: nfs-udp
              containerPort: 2049
              protocol: UDP
            - name: nlockmgr
              containerPort: 32803
            - name: nlockmgr-udp
              containerPort: 32803
              protocol: UDP
            - name: mountd
              containerPort: 20048
            - name: mountd-udp
              containerPort: 20048
              protocol: UDP
            - name: rquotad
              containerPort: 875
            - name: rquotad-udp
              containerPort: 875
              protocol: UDP
            - name: rpcbind
              containerPort: 111
            - name: rpcbind-udp
              containerPort: 111
              protocol: UDP
            - name: statd
              containerPort: 662
            - name: statd-udp
              containerPort: 662
              protocol: UDP
          volumeMounts:
            - name: export-volume
              mountPath: /export
      volumes:
        - name: export-volume
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
    - name: nfs
      port: 2049
    - name: nfs-udp
      port: 2049
      protocol: UDP
    - name: nlockmgr
      port: 32803
    - name: nlockmgr-udp
      port: 32803
      protocol: UDP
    - name: mountd
      port: 20048
    - name: mountd-udp
      port: 20048
      protocol: UDP
    - name: rquotad
      port: 875
    - name: rquotad-udp
      port: 875
      protocol: UDP
    - name: rpcbind
      port: 111
    - name: rpcbind-udp
      port: 111
      protocol: UDP
    - name: statd
      port: 662
    - name: statd-udp
      port: 662
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
