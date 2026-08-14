---
paths:
  - "manifests/**"
---

# Manifest Authoring Standards

Apply these rules to every file written or reviewed under `manifests/**`.

- **`namespace:` in every metadata block** - prevents accidental deployment to `default`.
  Phase 5.1 incident: a CronJob deployed to the wrong namespace due to a missing field.
- **Pod-level securityContext** must include `seccompProfile.type: RuntimeDefault`.
- **Container-level securityContext** must include:
  - `allowPrivilegeEscalation: false`
  - `capabilities.drop: [ALL]`
  - `runAsNonRoot: true` (omit only when the workload requires root; document why in a comment)
- **`resources.limits`** (cpu and memory) required on every container - no unbounded workloads.
- **`automountServiceAccountToken: false`** unless the pod calls the Kubernetes API.
- **Before flagging a missing securityContext field as a bug**, check
  `docs/context/Security.md` for documented exceptions.
