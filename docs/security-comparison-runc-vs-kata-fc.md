# Security Comparison: runc vs Kata-FC (Firecracker microVM)

## OpenClaw on EKS Graviton — Multi-Tenant Isolation Assessment

**Date:** 2026-03-24  
**Cluster:** openclaw-prod (us-east-1)  
**Platform:** Amazon EKS 1.34 on Graviton (ARM64)  
**Karpenter:** v1.9.0  
**Node Types:**
- runc: m6g.xlarge (standard-nodes, eksctl managed)
- kata-fc: c6g.metal (kata-metal, Karpenter provisioned)

---

## 1. Test Environment

| Property | runc Instance | kata-fc Instance |
|----------|--------------|-----------------|
| Namespace | `openclaw-c894b8af` | `openclaw-f2328ce9` |
| RuntimeClass | `runc` (default) | `kata-fc` |
| Node | `ip-172-31-123-183.ec2.internal` (m6g.xlarge) | `ip-172-31-74-47.ec2.internal` (c6g.metal) |
| Node OS | Amazon Linux 2023 | Ubuntu 24.04 LTS |
| Kernel | 6.12.68-92.122.amzn2023 (**host kernel**) | 6.18.12 custom (**guest kernel**) |
| Container Runtime | containerd 2.1.5 + runc | containerd 1.7.28 + kata-fc (Firecracker) |
| Machine Model | Standard Linux | `linux,dummy-virt` (Firecracker microVM) |

---

## 2. Test Results

### Test 1: EC2 Instance Metadata Service (IMDS) — AWS Credential Theft

**Attack:** Attempt to reach `169.254.169.254` to steal Node IAM Role credentials.

| Aspect | runc | kata-fc |
|--------|------|---------|
| `curl 169.254.169.254/latest/meta-data/` | No output (blocked) | No output (blocked) |
| IAM credentials accessible | ❌ No | ❌ No |
| Protection mechanism | `httpPutResponseHopLimit=1` (EC2 metadata config) | Independent VM network stack (IMDS unreachable) |

**Analysis:** Both block IMDS access, but through different mechanisms:
- **runc** relies on EC2 metadata hop limit configuration — a *software policy* that could be misconfigured
- **kata-fc** has inherent VM-level network isolation — the microVM's virtual NIC simply cannot reach the host's metadata endpoint

**Winner:** kata-fc (defense in depth — structural isolation vs configuration)

---

### Test 2: Host Filesystem Reconnaissance

**Attack:** Inspect mount points, storage devices, and host filesystem paths.

| Aspect | runc | kata-fc |
|--------|------|---------|
| Root filesystem | overlayfs (containerd snapshotter) | ext4 on `/dev/vdc` (virtual block device) |
| Host storage visible | `/dev/nvme0n1p1` (XFS) — **host NVMe exposed** | No host devices visible |
| Container runtime paths | `/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/...` visible | kata-containers shared mount paths only |
| `/etc/kubernetes/` | Not found | Not found |
| `/var/lib/kubelet/kubeconfig` | Not found | Not found |
| NFS mounts | `127.0.0.1:/` (NFSv4.1, port 20263) | `127.0.0.1:/` (NFSv4.1, port 20263) |
| Mount info leakage | Exposes containerd internals, pod UUID, NVMe device names | Only shows microVM internal mounts |

**Key Finding (runc):**
```
/dev/nvme0n1p1 on /etc/resolv.conf type xfs (rw,noatime,seclabel,...)
```
This reveals the host's physical storage device type (NVMe) and filesystem (XFS).

**Key Finding (kata-fc):**
```
/dev/vdc on / type ext4 (rw,relatime)
```
Only a virtual block device is visible — no host hardware information leaks.

**Winner:** kata-fc ✅ (complete filesystem isolation)

---

### Test 3: Kernel & Process Inspection

**Attack:** Determine host kernel version, inspect process tree, read kernel logs.

| Aspect | runc | kata-fc |
|--------|------|---------|
| Kernel | `6.12.68-92.122.amzn2023.aarch64` (**host kernel**) | `6.18.12` (**independent guest kernel**) |
| Machine type | Standard Linux | `linux,dummy-virt` (Firecracker) |
| PID 1 | `openclaw` (app process) | `openclaw` (app process) |
| Total visible processes | 10 | 6 |
| Zombie processes | Yes (from exec commands) | Yes (from exec commands) |
| `dmesg` access | ❌ `Operation not permitted` | ❌ `Operation not permitted` |
| cgroup root | `0::/` | `0::/` |
| UID/GID | 1000 (node) | 1000 (node) |

**Critical Difference:**
- **runc** shares the host kernel. A kernel vulnerability (e.g., CVE in cgroup, netfilter, or eBPF) could allow container escape to the **actual host**.
- **kata-fc** runs an independent guest kernel inside the microVM. A kernel vulnerability only compromises the **microVM**, not the host. The Firecracker VMM provides a second security boundary.

**Winner:** kata-fc ✅ (kernel-level isolation)

---

### Test 4: Container Escape Attempts

**Attack:** Test capabilities, mount filesystems, namespace manipulation, chroot escape.

| Aspect | runc | kata-fc |
|--------|------|---------|
| CapInh / CapPrm / CapEff / CapBnd / CapAmb | `0000000000000000` (all zero) | `0000000000000000` (all zero) |
| `capsh` binary | Not found | Not found |
| `mount -t proc` | ❌ `must be superuser` | ❌ `must be superuser` |
| `mount -t cgroup2` | ❌ `must be superuser` | ❌ `must be superuser` |
| `nsenter --target 1` | ❌ `Operation not permitted` | ❌ `Operation not permitted` |
| `chroot /proc/1/root` | ❌ `Operation not permitted` | ❌ `Operation not permitted` |
| `/dev/` devices | null, zero, random, urandom, tty, full, termination-log | null, zero, random, urandom, tty, full |
| Block devices in `/dev/` | None visible | None visible |
| Privileged devices (`/dev/kvm`, `/dev/fuse`) | None | None |

**Analysis:** Both environments have identical application-level security:
- Zero Linux capabilities
- Non-root user (UID 1000)
- Cannot mount, nsenter, chroot, or access dmesg
- Minimal `/dev/` device set

However, the **blast radius** differs fundamentally:
- **runc:** If a kernel 0-day bypasses namespace isolation, attacker reaches the **host node** (and potentially all pods on that node)
- **kata-fc:** If a kernel 0-day is exploited, attacker reaches the **microVM boundary**. They must then escape the Firecracker VMM (separate, minimal attack surface of ~50k LoC) to reach the host

**Winner:** kata-fc ✅ (VM-level blast radius containment)

---

### Test 5: Network Reconnaissance & Lateral Movement

**Attack:** Inspect network config, resolve K8s API, attempt cluster enumeration.

| Aspect | runc | kata-fc |
|--------|------|---------|
| `ip` command | Not found | Available |
| Network interfaces | Unknown (no `ip` cmd) | lo + eth0 |
| Default gateway | Unknown | 169.254.1.1 (via eth0) |
| DNS server | 10.100.0.10 (CoreDNS) | 10.100.0.10 (CoreDNS) |
| DNS search domain | `openclaw-c894b8af.svc.cluster.local` | `openclaw-f2328ce9.svc.cluster.local` |
| K8s API resolve | 10.100.0.1 | 10.100.0.1 |
| Unauthenticated API access | ❌ 401 Unauthorized | ❌ 401 Unauthorized |
| Authenticated namespace list | ❌ 403 Forbidden | ❌ 403 Forbidden |
| ServiceAccount | `system:serviceaccount:openclaw-c894b8af:openclaw-c894b8af` | `system:serviceaccount:openclaw-f2328ce9:openclaw-f2328ce9` |

**Analysis:** Network-level access is similar. Both pods:
- Can reach K8s API (standard in-cluster networking)
- Have ServiceAccount tokens mounted
- Are blocked by RBAC from listing cluster resources (nodes, namespaces)
- Use per-namespace ServiceAccounts with minimal permissions

**Winner:** ≈ Tie (RBAC controls are the primary defense at this layer)

---

## 3. Summary Matrix

| Attack Vector | runc | kata-fc | Advantage |
|---------------|------|---------|-----------|
| AWS IMDS credential theft | Blocked (hop limit) | Blocked (VM isolation) | kata-fc (structural) |
| Host filesystem info leakage | **Partial leak** (NVMe, containerd paths) | **Fully isolated** | kata-fc ✅ |
| Host kernel exposure | **Shared kernel** (6.12.68) | **Independent kernel** (6.18.12) | kata-fc ✅ |
| Kernel 0-day blast radius | Host node compromise | MicroVM only | kata-fc ✅ |
| Linux capabilities | Zero | Zero | Tie |
| Container escape (app-level) | Blocked | Blocked | Tie |
| Container escape (kernel-level) | Namespace boundary only | VMM + namespace | kata-fc ✅ |
| K8s API access | RBAC limited | RBAC limited | Tie |
| Network lateral movement | RBAC limited | RBAC limited | Tie |
| Process isolation | PID namespace | VM-level | kata-fc ✅ |

---

## 4. Architecture Comparison

### runc (Standard Container)
```
┌─────────────────────────────────────────────┐
│              Host Node (m6g.xlarge)          │
│         Kernel: 6.12.68 (shared)            │
│                                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
│  │ Pod A    │  │ Pod B    │  │ Pod C    │  │
│  │ (runc)   │  │ (runc)   │  │ (runc)   │  │
│  │ ns+cgroup│  │ ns+cgroup│  │ ns+cgroup│  │
│  └──────────┘  └──────────┘  └──────────┘  │
│         ▲ Shared kernel attack surface      │
└─────────────────────────────────────────────┘
```
- Isolation: Linux namespaces + cgroups (software)
- Kernel: Shared with host and all other pods
- Escape impact: Full host compromise

### kata-fc (Firecracker microVM)
```
┌───────────────────────────────────────────────────┐
│              Host Node (c6g.metal)                 │
│         Kernel: 6.12.68 (host, not exposed)       │
│                                                   │
│  ┌─────────────────┐  ┌─────────────────┐        │
│  │ Firecracker VMM  │  │ Firecracker VMM  │        │
│  │ (~50k LoC)       │  │ (~50k LoC)       │        │
│  │ ┌─────────────┐ │  │ ┌─────────────┐ │        │
│  │ │ Guest Kernel │ │  │ │ Guest Kernel │ │        │
│  │ │   6.18.12    │ │  │ │   6.18.12    │ │        │
│  │ │ ┌─────────┐ │ │  │ │ ┌─────────┐ │ │        │
│  │ │ │  Pod A  │ │ │  │ │ │  Pod B  │ │ │        │
│  │ │ └─────────┘ │ │  │ │ └─────────┘ │ │        │
│  │ └─────────────┘ │  │ └─────────────┘ │        │
│  └─────────────────┘  └─────────────────┘        │
│         ▲ VMM boundary (hardware virtualization)   │
└───────────────────────────────────────────────────┘
```
- Isolation: Firecracker VMM + KVM hardware virtualization
- Kernel: Each pod has its own guest kernel
- Escape requires: Guest kernel exploit + VMM escape (two independent barriers)

---

## 5. Conclusions

### For Multi-Tenant SaaS (like OpenClaw)

**runc is sufficient when:**
- Tenants are trusted (internal teams, known users)
- Cost optimization is the priority (no bare metal required)
- Application-level isolation (RBAC, network policies) is adequate
- Quick pod startup is critical

**kata-fc is recommended when:**
- Tenants are untrusted (public multi-tenant platform)
- Tenants can execute arbitrary code (like OpenClaw AI agents)
- Compliance requires hardware-level isolation (financial, healthcare, government)
- Defense against kernel 0-day exploits is required
- Complete host information hiding is needed

### Cost-Security Trade-off

| Factor | runc | kata-fc |
|--------|------|---------|
| Node type | m6g.xlarge ($0.154/hr) | c6g.metal ($2.176/hr) |
| Pod startup | ~seconds | ~seconds (after node ready) |
| Node startup | ~2 min | ~5 min (bare metal + bootstrap) |
| Density | High (many pods/node) | Medium (VM overhead per pod) |
| Security boundary | Software (namespace) | Hardware (VMM + KVM) |

### Recommendation

For OpenClaw's workshop scenario where **AI agents execute arbitrary code from untrusted users**, **kata-fc provides meaningful additional security** — particularly the kernel isolation and filesystem information hiding. The cost overhead of c6g.metal is justified for production multi-tenant deployments.

---

*Test conducted on openclaw-prod cluster, 2026-03-24. Both instances running OpenClaw with Claude Sonnet 4.5 model.*
