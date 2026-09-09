# E2E Storage Disruption Testing

## Overview

The SBR operator e2e tests include comprehensive storage disruption testing to validate that nodes properly self-fence when they lose access to shared storage. The testing framework now supports multiple storage backends with specialized disruption methods.

## Running the Tests

### Prerequisites

The e2e suite (`test/e2e/`) assumes the operator is already deployed and does not deploy it for you (`make test-e2e` runs `ginkgo` directly against `test/e2e`). Before running it:

1. A Kubernetes/OpenShift cluster is reachable via `KUBECONFIG` (or `~/.kube/config`).
2. CRDs are installed: `make install`.
3. The operator is deployed and its `sbr-operator-controller-manager` Deployment is `Running` in the `sbr-operator-system` namespace (via OLM/bundle, or `make deploy`; see the [README Installation section](../README.md#installation) for the recommended path).
4. At least one RWX-capable StorageClass exists in the cluster (CephFS/ODF, AWS EFS, or another provisioner listed under [Supported Storage Backends](#supported-storage-backends)).

### Basic usage

```bash
make test-e2e
```

This runs the full suite. No extra setup is required beyond the prerequisites above.

### Running only filesystem-mode or only block-mode specs (`--label-filter`)

Every `It()` is labeled `fs` and/or `block` (`testIncompatibleStorageClass` is independent of both and carries both labels; every other core test is filesystem-mode-only and asserts an RWX filesystem StorageClass must exist, so it **fails** rather than skips if run on a block-only cluster). Use Ginkgo's `--label-filter` to select which set to run:

```bash
# Only fs-labeled specs: all core tests + the filesystem-mode write-check scenario (10 specs)
make test-e2e TEST_ARGS="--label-filter=fs"

# Only block-labeled specs: testIncompatibleStorageClass + both block-mode scenarios (3 specs)
make test-e2e TEST_ARGS="--label-filter=block"
```

## Storage Backend Detection

The e2e tests automatically detect the storage backend in use and apply appropriate disruption methods:

### Supported Storage Backends

1. **Ceph Storage** (`cephfs.csi.ceph.com`, `openshift-storage.cephfs.csi.ceph.com`)
   - Uses Ceph-specific port blocking (6789, 6800-7300)
   - Targets Ceph Monitor, OSD, and MDS traffic
   - Discovers and blocks specific Ceph service IPs

2. **AWS EFS** (`efs.csi.aws.com`)
   - Uses NFS port blocking (2049)
   - Blocks AWS EFS service IP ranges (169.254.0.0/16)
   - Compatible with AWS-specific infrastructure

3. **NFS** (`nfs.csi.k8s.io`, various NFS provisioners)
   - Uses standard NFS port blocking (2049)
   - Generic NFS traffic disruption

4. **Other Storage** (fallback)
   - Uses AWS/NFS-style disruption as default

## Storage Disruption Methods

### Ceph Storage Disruption

For Ceph-based storage, the disruption pod:

```bash
# Blocks Ceph Monitor traffic
iptables -I OUTPUT -p tcp --dport 6789 -j DROP
iptables -I INPUT -p tcp --sport 6789 -j DROP

# Blocks Ceph OSD traffic 
iptables -I OUTPUT -p tcp --dport 6800:7300 -j DROP
iptables -I INPUT -p tcp --sport 6800:7300 -j DROP

# Discovers and blocks specific Ceph service IPs
kubectl get svc -n openshift-storage -l app=rook-ceph-mon -o jsonpath='{.items[*].spec.clusterIP}'
```

**Ceph-Specific Features:**

- Targets Ceph Monitor communication (port 6789)
- Blocks OSD data traffic (ports 6800-7300)
- Discovers actual Ceph service IPs dynamically
- Validates disruption with Ceph-specific connectivity tests

### AWS/EFS Storage Disruption

For AWS EFS storage, the disruption pod:

```bash
# Blocks NFS traffic
iptables -I OUTPUT -p tcp --dport 2049 -j DROP
iptables -I INPUT -p tcp --sport 2049 -j DROP

# Blocks AWS EFS service ranges
iptables -I OUTPUT -d 169.254.0.0/16 -j DROP
```

**AWS-Specific Features:**

- Targets NFS v4 protocol used by EFS
- Blocks AWS EFS mount target IP ranges
- Compatible with AWS network architecture

## Test Implementation

### Detection Implementation

```go
type StorageBackendType string

const (
    StorageBackendAWS   StorageBackendType = "aws"
    StorageBackendCeph  StorageBackendType = "ceph"
    StorageBackendNFS   StorageBackendType = "nfs"
    StorageBackendOther StorageBackendType = "other"
)

func detectStorageBackend() (StorageBackendType, string, error) {
    // Analyzes available StorageClasses
    // Returns detected backend type and StorageClass name
}
```

### Disruption Flow

1. **Detection**: Analyze cluster StorageClasses to identify backend
2. **Selection**: Choose appropriate disruption method based on backend
3. **Execution**: Deploy storage-specific disruption pod
4. **Validation**: Verify disruption rules are active and effective
5. **Monitoring**: Wait for node self-fencing behavior
6. **Cleanup**: Remove disruption and restore storage access

### Validation

Each storage backend includes specific validation:

**Ceph Validation:**

- Verifies iptables rules for ports 6789, 6800-7300
- Tests connectivity to Ceph Monitor ports (should fail)
- Counts expected number of blocking rules (minimum 4)

**AWS Validation:**

- Verifies iptables rules for port 2049 and IP ranges
- Tests connectivity to EFS mount targets (should fail)
- Validates AWS-specific network blocking

## Pod Specifications

### Ceph Disruption Pod

```yaml
spec:
  hostNetwork: true
  hostPID: true
  containers:
  - name: disruptor
    image: registry.redhat.io/ubi9/ubi:latest
    securityContext:
      privileged: true
      capabilities:
        add: [SYS_ADMIN, NET_ADMIN]
```

### AWS Disruption Pod

```yaml
spec:
  hostNetwork: true
  hostPID: true
  containers:
  - name: disruptor
    image: registry.redhat.io/ubi9/ubi:latest
    securityContext:
      privileged: true
      capabilities:
        add: [SYS_ADMIN]
```

## Storage volume mode scenarios

Three additional scenarios validate the storage write-check / fencing-gate behavior described in [`docs/design/storage-validation.md`](design/storage-validation.md):

| Scenario | Label | Backend | What it proves |
| --- | --- | --- | --- |
| `should confirm the storage write check passes on filesystem mode` | `fs` | ODF/CephFS (or any RWX filesystem StorageClass) | Once agents pass the real write check, the `StorageWriteable` condition becomes `True`. |
| `should confirm the block-mode storage write check passes on Ceph RBD` | `block` | Ceph RBD | Ceph RBD supports RWX block via multi-attach, so every node's write check passes, agents deploy successfully, and `StorageWriteable` becomes `True`. |
| `should withhold fencing when the block-mode storage write check fails on Portworx` | `block` | Portworx | Only the first-attaching node can write to a Portworx block volume; every other node's write check fails, `StorageWriteable` never becomes `True`, and fencing is correctly withheld rather than falsely triggered. |

Each scenario independently checks the cluster for its own required storage and `Skip`s itself if not found. Which of these run (alongside the core tests) is controlled by Ginkgo's `--label-filter`, described under [Running only filesystem-mode or only block-mode specs](#running-only-filesystem-mode-or-only-block-mode-specs---label-filter) above.

The Portworx scenario does not use any pre-existing Portworx StorageClass directly. It only checks that Portworx is installed (by finding any StorageClass with provisioner `pxd.portworx.com`), then creates and cleans up its own dedicated StorageClass for the test:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: px-test-sc
parameters:
  io_profile: db_remote
  repl: "3"
provisioner: pxd.portworx.com
reclaimPolicy: Delete
volumeBindingMode: Immediate
```

The Ceph RBD scenario, by contrast, reuses whichever existing Ceph RBD StorageClass (provisioner `rbd.csi.ceph.com` or `openshift-storage.rbd.csi.ceph.com`) it finds — no dedicated StorageClass is created for it.

## Cleanup and Recovery

### Comprehensive Cleanup

The cleanup process removes all types of storage disruption rules:

```bash
# AWS/EFS cleanup
iptables -D OUTPUT -p tcp --dport 2049 -j DROP
iptables -D OUTPUT -d 169.254.0.0/16 -j DROP

# Ceph cleanup
iptables -D OUTPUT -p tcp --dport 6789 -j DROP
iptables -D OUTPUT -p tcp --dport 6800:7300 -j DROP

# Service-specific IP cleanup
kubectl get svc -n openshift-storage -l app=rook-ceph-mon
```

### Recovery Verification

After cleanup, the test verifies:

- All iptables rules are removed
- Storage connectivity is restored
- Nodes regain access to shared storage
- SBR agents resume normal operation

## Error Handling

### Detection Failures

- Falls back to AWS/NFS-style disruption for unknown backends
- Logs warnings but continues with test execution
- Provides comprehensive cleanup regardless of backend type

### Validation Failures

- Automatic cleanup of disruption pods
- Detailed logging of iptables rule status
- Graceful test failure with diagnostic information

### Cleanup Failures

- Multiple cleanup attempts with different methods
- Warning logs for partial cleanup failures
- Manual intervention guidance in failure messages

## Best Practices

### Test Environment Requirements

- Privileged pod execution capability
- Network policy compatibility with iptables rules
- Sufficient permissions for StorageClass inspection
- Access to storage backend namespaces (e.g., openshift-storage)

### Security Considerations

- Uses least privilege required for each storage type
- Temporary disruption with automatic cleanup
- Host network access limited to disruption duration
- iptables rules are specific and targeted

### Performance Impact

- Minimal resource usage (128Mi memory, 100m CPU)
- Short-duration disruption (maximum 10 minutes)
- Efficient rule application and removal
- Low overhead storage backend detection

## Troubleshooting

### Common Issues

1. **Permission Denied Errors**
   - Ensure cluster supports privileged pods
   - Verify RBAC permissions for test execution
   - Check node-level security policies

2. **iptables Rule Conflicts**
   - Review existing firewall rules
   - Ensure no conflicting network policies
   - Verify iptables backend compatibility

3. **Storage Backend Mis-detection**
   - Check StorageClass provisioner names
   - Verify storage backend is properly configured
   - Review detection logic for new provisioner types

4. **Cleanup Failures**
   - Check pod deletion permissions
   - Verify network connectivity during cleanup
   - Review node-level iptables rule persistence

### Debug Information

Enable detailed logging:

```bash
# View disruption pod logs
kubectl logs -l app=sbr-e2e-ceph-storage-disruptor

# Check validation results
kubectl logs -l app=sbr-e2e-ceph-storage-validator

# Verify iptables rules
kubectl exec <disruption-pod> -- iptables -L OUTPUT -n -v
```

## Future Enhancements

### Planned Storage Backends

- GlusterFS support with gluster-specific disruption
- iSCSI storage with SCSI-level disruption
- Cloud-specific block storage improvements

### Enhanced Validation

- Real storage I/O testing during disruption
- Performance impact measurement
- Network latency simulation

### Advanced Features

- Multiple simultaneous storage backend testing
- Graduated disruption severity levels
- Storage backend failover testing
