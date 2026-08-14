# .kiro/ - Homelab Kiro Agent Ecosystem

Workspace-local Kiro CLI configuration for this homelab repo. These agents mirror
the Claude Code safety model (same kubeconfigs, same GitOps rules) and are only
available inside this repository.

Full design spec: `docs/plans/2026-08-14-kiro-homelab-agents-design.md`

## Agent family

| Agent | Responsibility | Write surface |
|-------|----------------|---------------|
| `homelab-orchestrator` | Converse, plan, delegate, commit. Default entry point. | git only |
| `homelab-sre` | Investigate alerts and incidents, correlate to root cause, perform safe live remediation. | live cluster only (delete pod/lease/job, rollout restart) |
| `homelab-deploy` | Author declarative changes - manifests, Helm values, structural fixes, new deployments. | repo only (`manifests/`, `helm/`) |

Each agent has exactly one write surface. `homelab-sre` can never commit a bad
manifest. `homelab-deploy` can never touch the live cluster. Only
`homelab-orchestrator` touches git.

## How to use

**Default - cross-domain work, new deployments, incident-to-fix workflow:**
Use `homelab-orchestrator`. It plans, delegates to the specialists, and owns git
operations (commit, push on explicit approval).

**Direct incident work - alert triage, live investigation:**
Switch to `homelab-sre`. One agent, one context, no round-trips. Use this for
"why am I getting these alerts" or "triage the current alert storm".

**Manifest/Helm authoring only:**
Switch to `homelab-deploy` for focused declarative work without cluster access.

## Safety summary

- All agents use full `kubectl --kubeconfig <path>` forms - the bash shell has no
  zsh aliases. See `steering/cluster-access.md`.
- Restricted kubeconfig (`homelab-claude.yaml`) for reads; admin (`homelab.yaml`)
  for logs and remediation only.
- Never bare `kubectl` or `helm` - those hit the work AWS EKS cluster.
- All structural fixes go through Git - ArgoCD is the source of truth.
  See `steering/gitops.md`.
- Live remediation is tiered (AUTO / CONFIRM / NEVER). See `steering/remediation-safety.md`.
- No secrets flow through the model. No secret values in any file here.

## Contents

```
.kiro/
├── README.md                              # this file
├── agents/                                # agent JSON configs
│   ├── homelab-orchestrator.json
│   ├── homelab-sre.json
│   └── homelab-deploy.json
├── hooks/                                 # preToolUse guard hook
│   └── protect-cluster.sh
├── settings/
│   └── cli.json                           # workspace settings
├── steering/                              # workspace steering (replace global)
│   ├── cluster-access.md                  # kubeconfig table, bash forms, WSL DNS fallback
│   ├── gitops.md                          # ArgoCD rules, change flow, manual-sync apps
│   ├── remediation-safety.md              # AUTO/CONFIRM/NEVER tiers, Longhorn PVC safety
│   └── conventions.md                     # namespaces, node names, secrets, commits
└── skills/
    └── homelab-alert-triage/
        └── SKILL.md                       # alert triage procedure (7-step)
```

All files are committed to the repo. No kubeconfigs or secret values are stored
here - agents reference `~/.kube/*` paths on the host.
