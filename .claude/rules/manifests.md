---
paths:
  - "manifests/**/*.yaml"
---

# Manifest Conventions

- **Always include `namespace:` in metadata** — prevents accidental deployment to `default`. Phase 5.1 incident: invoicetron CronJob deployed to wrong namespace due to missing field.
- **Include `securityContext`** on all new workloads:
  - Pod level: `seccompProfile.type: RuntimeDefault`
  - Container level: `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`
  - Add `runAsNonRoot: true` unless the workload needs root (document why in a comment)
- **Include `resources.limits`** (cpu + memory) on every container.
- **Include `automountServiceAccountToken: false`** unless the pod calls the Kubernetes API.
- **Check `docs/context/Security.md`** for accepted exceptions before flagging missing securityContext as a bug.
