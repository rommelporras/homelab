# Workstation Setup

Clone-and-go guide for operating this homelab cluster from any machine.

## Prerequisites

**1Password items needed** (all in `Kubernetes` vault):

| Item | Fields You Need | Purpose |
|------|-----------------|---------|
| Kubeconfig | `admin-kubeconfig`, `claude-kubeconfig` | Cluster access |
| Vault Unseal Keys | `unseal-key-1` thru `unseal-key-5`, `root-token` | Break-glass only |

Full 1Password inventory: `docs/context/Secrets.md`

## Step 1 - Install CLI tools

### Aurora DX (immutable Fedora)

```bash
# No apt-get, no chsh. Use brew or rpm-ostree.
brew install kubernetes-cli helm hashicorp/tap/vault 1password-cli jq glab gh
```

### WSL2 (Ubuntu)

```bash
sudo apt update && sudo apt install -y jq socat
# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl
# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
# vault
brew install hashicorp/tap/vault
# 1password-cli, glab, gh
brew install 1password-cli glab gh
```

### Any Linux

```bash
# Minimum required
kubectl helm vault op jq

# Optional (for CI/CD and release management)
glab gh ansible
```

## Step 2 - Clone the repo

```bash
git clone git@github.com:rommelporras/homelab.git ~/personal/homelab
cd ~/personal/homelab
```

## Step 3 - Extract kubeconfigs from 1Password

**Run in a terminal with `op` access** (Aurora desktop, not WSL if op is unavailable there).

```bash
eval $(op signin)
mkdir -p ~/.kube

# Admin kubeconfig (full cluster-admin)
op read "op://Kubernetes/Kubeconfig/admin-kubeconfig" > ~/.kube/homelab.yaml

# Restricted kubeconfig (read-only, no secret access - used by Claude Code)
op read "op://Kubernetes/Kubeconfig/claude-kubeconfig" > ~/.kube/homelab-claude.yaml

chmod 600 ~/.kube/homelab.yaml ~/.kube/homelab-claude.yaml
```

## Step 4 - Set up shell aliases

Add to `~/.zshrc` (or `~/.bashrc`):

```bash
# Homelab kubectl/helm - ALWAYS use these, never plain kubectl/helm
alias kubectl-homelab='kubectl --kubeconfig ~/.kube/homelab-claude.yaml'
alias kubectl-admin='kubectl --kubeconfig ~/.kube/homelab.yaml'
alias helm-homelab='KUBECONFIG=~/.kube/homelab.yaml helm'

# Quick navigation
alias homelab='cd ~/personal/homelab'
```

Reload: `source ~/.zshrc`

**Why aliases?** Plain `kubectl`/`helm` may point to a work cluster (e.g., AWS EKS).
The aliases force the correct kubeconfig every time.

## Step 5 - Set up SSH access

SSH user for all k8s nodes is `wawashi`.

### Option A: 1Password SSH Agent (recommended)

If you use 1Password for SSH keys, configure the SSH agent:

**Aurora DX / native Linux:**

```bash
# Add to ~/.zshrc
export SSH_AUTH_SOCK="$HOME/.1password/agent.sock"
```

**WSL2:**

```bash
# Requires npiperelay.exe from Windows 1Password installation
# Add to ~/.zshrc
export SSH_AUTH_SOCK="$HOME/.1password/agent.sock"
# WSL2 needs the socat relay - see 1Password docs for setup
```

### Option B: Standard SSH key

```bash
ssh-keygen -t ed25519 -C "homelab"
ssh-copy-id wawashi@10.10.30.11
ssh-copy-id wawashi@10.10.30.12
ssh-copy-id wawashi@10.10.30.13
```

### Verify

```bash
ssh wawashi@cp1.k8s.rommelporras.com hostname  # Should print: k8s-cp1
ssh wawashi@cp2.k8s.rommelporras.com hostname  # Should print: k8s-cp2
ssh wawashi@cp3.k8s.rommelporras.com hostname  # Should print: k8s-cp3
```

## Step 6 - Add Helm repos

```bash
helm-homelab repo add longhorn https://charts.longhorn.io
helm-homelab repo add cilium https://helm.cilium.io/
helm-homelab repo add grafana https://grafana.github.io/helm-charts
helm-homelab repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm-homelab repo add gitlab https://charts.gitlab.io
helm-homelab repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm-homelab repo add tailscale https://pkgs.tailscale.com/helmcharts
helm-homelab repo add intel https://intel.github.io/helm-charts/
helm-homelab repo add hashicorp https://helm.releases.hashicorp.com
helm-homelab repo add external-secrets https://charts.external-secrets.io
helm-homelab repo add argo https://argoproj.github.io/argo-helm
helm-homelab repo update
```

## Step 7 - Configure GitLab CLI (optional)

Only needed if you interact with the self-hosted GitLab instance.

```bash
glab auth login --hostname gitlab.k8s.rommelporras.com
```

## Step 8 - Verify everything works

```bash
# Cluster access
kubectl-homelab get nodes
kubectl-admin get nodes
helm-homelab list -A

# SSH to a node
ssh wawashi@10.10.30.11 "uptime"

# DNS resolution (requires being on the LAN or Tailscale)
nslookup grafana.k8s.rommelporras.com 10.10.30.53
```

Expected output for `kubectl-homelab get nodes`:

```
NAME      STATUS   ROLES           AGE   VERSION
k8s-cp1   Ready    control-plane   ...   v1.35.0
k8s-cp2   Ready    control-plane   ...   v1.35.0
k8s-cp3   Ready    control-plane   ...   v1.35.0
```

## Network Access

You must be on the homelab LAN (VLAN 30) or connected via Tailscale to reach the cluster.

| Access Method | Requirement |
|---------------|-------------|
| LAN (home) | Connected to SERVERS VLAN or routed VLAN |
| Remote | Tailscale installed, joined to `capybara-interval.ts.net` |

Tailscale routes `10.10.30.0/24` via the connector pod. All `*.k8s.rommelporras.com`
DNS resolves through AdGuard at `10.10.30.53`.

## Claude Code Setup (optional)

If using Claude Code with this repo, the `.claude/` directory is already committed with:

- **Hooks** that block accidental secret exposure and enforce `/commit`/`/release` workflows
- **Skills** for `/commit`, `/release`, `/audit-docs`, `/audit-security`, `/audit-cluster`
- **Agent memory** for code review context

No additional setup needed - hooks and settings activate automatically when Claude Code
runs in this directory.

## Vault Access (when needed)

Most day-to-day work doesn't require direct Vault access. ESO handles secret delivery
automatically. When you do need it (seeding secrets, debugging):

```bash
# Port-forward to Vault (in a separate terminal)
kubectl --kubeconfig ~/.kube/homelab.yaml port-forward -n vault vault-0 8200:8200

# In another terminal
export VAULT_ADDR=http://localhost:8200
vault status  # Should show Sealed: false
```

For seeding secrets from 1Password into Vault, run in a **safe terminal** (not Claude Code):

```bash
eval $(op signin)
./scripts/vault/seed-vault-from-1password.sh
```

## Ansible (cluster rebuild only)

Only needed if rebuilding the cluster from scratch. Not required for daily operations.

```bash
# Install ansible
brew install ansible  # Aurora
# or: sudo apt install ansible  # Ubuntu

# Run from the ansible/ directory
cd ansible/
ansible all -m ping  # Verify connectivity
# Then follow docs/rebuild/ guides in order
```

## Quick Reference

| What | Command |
|------|---------|
| Check cluster | `kubectl-homelab get nodes` |
| Check all pods | `kubectl-homelab get pods -A \| grep -v Running` |
| Helm releases | `helm-homelab list -A` |
| Pod logs | `kubectl-homelab -n <ns> logs -l app=<name>` |
| Port forward | `kubectl-homelab -n <ns> port-forward svc/<name> <local>:<remote>` |
| SSH to node | `ssh wawashi@cp1.k8s.rommelporras.com` |
| Apply manifests | `kubectl-admin apply -f manifests/<app>/` |
| Helm upgrade | `helm-homelab upgrade <release> <chart> -f helm/<app>/values.yaml -n <ns>` |

## Related

- [Conventions](context/Conventions.md) - Naming patterns, common commands
- [Secrets](context/Secrets.md) - Full 1Password inventory and Vault KV paths
- [Cluster](context/Cluster.md) - Node IPs, hardware, namespaces
- [Networking](context/Networking.md) - VLANs, VIPs, DNS records
- [Rebuild guides](rebuild/) - Full cluster rebuild from scratch
