# Ansible Automation

Ansible playbooks for Kubernetes cluster bootstrap and disaster recovery.

## Structure

```
ansible/
├── ansible.cfg              # Ansible configuration
├── inventory/
│   └── homelab.yml          # Host inventory (YAML format)
├── group_vars/
│   ├── all.yml              # Variables for all hosts
│   └── control_plane.yml    # Control plane specific variables
├── playbooks/
│   ├── 00-preflight.yml         # Pre-flight checks
│   ├── 01-prerequisites.yml     # System prerequisites
│   ├── 02-kube-vip.yml          # kube-vip setup (first node only)
│   ├── 03-init-cluster.yml      # Cluster initialization
│   ├── 04-cilium.yml            # CNI installation
│   ├── 05-join-cluster.yml      # Join additional nodes
│   ├── 06-storage-prereqs.yml   # Storage prerequisites (Longhorn, NFS)
│   └── 07-remove-taints.yml     # Remove control-plane taints (homelab)
└── README.md                    # This file
```

## Prerequisites

```bash
# Install Ansible (Ubuntu/Debian)
sudo apt update
sudo apt install -y ansible

# Verify version (need ansible-core 2.17+)
ansible --version
```

## Inventory Groups

| Group | Hosts | Purpose |
|-------|-------|---------|
| `control_plane` | cp1, cp2, cp3 | All control plane nodes |
| `control_plane_init` | cp1 | First node (for init operations) |
| `control_plane_join` | cp2, cp3 | Nodes to join cluster |

## Usage

### Test connectivity
```bash
cd ansible
ansible all -m ping
```

### Run specific playbook
```bash
ansible-playbook playbooks/00-preflight.yml
```

### Run all playbooks in order
```bash
# Phase 1-2: Bootstrap cluster
ansible-playbook -i inventory/homelab.yml playbooks/00-preflight.yml
ansible-playbook -i inventory/homelab.yml playbooks/01-prerequisites.yml
ansible-playbook -i inventory/homelab.yml playbooks/02-kube-vip.yml
ansible-playbook -i inventory/homelab.yml playbooks/03-init-cluster.yml
ansible-playbook -i inventory/homelab.yml playbooks/04-cilium.yml
ansible-playbook -i inventory/homelab.yml playbooks/05-join-cluster.yml

# Phase 3: Storage
ansible-playbook -i inventory/homelab.yml playbooks/06-storage-prereqs.yml
ansible-playbook -i inventory/homelab.yml playbooks/07-remove-taints.yml
```

### Limit to specific hosts
```bash
# Run only on cp1
ansible-playbook playbooks/01-prerequisites.yml --limit k8s-cp1

# Run only on join nodes
ansible-playbook playbooks/05-join-cluster.yml --limit control_plane_join
```

### Check mode (dry run)
```bash
ansible-playbook playbooks/01-prerequisites.yml --check
```

## Conventions

This project follows modern Ansible conventions (2025):

- **FQCN** - All modules use fully qualified collection names (`ansible.builtin.apt`)
- **YAML inventory** - Not INI format
- **group_vars** - Variables separated from playbooks
- **Idempotent** - Playbooks can be run multiple times safely

## Disaster Recovery

If the cluster needs to be rebuilt:

```bash
# Reset all nodes first
ansible control_plane -m shell -a "kubeadm reset -f"

# Then run playbooks in order
ansible-playbook playbooks/01-prerequisites.yml
# ... continue with remaining playbooks
```

## Related Documentation

- [v0.2.0-bootstrap.md](../docs/rebuild/v0.2.0-bootstrap.md) - Cluster bootstrap guide
- [Cluster.md](../docs/context/Cluster.md) - Current cluster state
