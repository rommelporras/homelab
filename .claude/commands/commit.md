# Smart Conventional Commit

Analyze the current git changes and create a well-structured conventional commit.

## Usage

```
/commit              → Auto-analyze and auto-generate commit message
```

No arguments needed. The command analyzes git diff and generates the appropriate message.

## Instructions

1. **Check Git Status**
   - Run `git status` to see modified files
   - Run `git diff` to see actual changes (or `git diff --cached` if staged)

2. **Detect Commit Type**
   Analyze the changes and determine the appropriate type:
   - `feat:` - New feature or functionality
   - `fix:` - Bug fix or correction
   - `docs:` - Documentation changes
   - `style:` - Formatting, whitespace (no logic change)
   - `refactor:` - Code restructuring without behavior change
   - `perf:` - Performance improvements
   - `test:` - Adding or updating tests
   - `chore:` - Build process, dependencies, tooling
   - `infra:` - Infrastructure changes (K8s manifests, configs)

3. **Analyze and Group Changes**
   - Identify what categories of files changed (docs, configs, code, etc.)
   - Group related changes together
   - Understand the PURPOSE of changes, not just what files changed

4. **Write Commit Message**
   Format (NO AI attribution):
   ```
   <type>: <short summary (50 chars max)>

   <One sentence context - what is this change about?>

   <Category 1>:
   - Specific change 1
   - Specific change 2

   <Category 2>:
   - Specific change 1
   - Specific change 2
   ```

   **Structure rules:**
   - Title: 50 chars max, imperative mood ("Add" not "Added")
   - Context: One sentence explaining the purpose
   - Categories: Group changes logically (Documentation, Configuration, etc.)
   - Bullets: Specific items under each category

5. **Execute Commit**
   ```bash
   git add .
   git commit -m "$(cat <<'EOF'
   [commit message here]
   EOF
   )"
   ```

6. **Show Status**
   Run `git status` and `git log --oneline -1` to confirm

## Examples

**Simple (few changes):**
```
fix: correct storage prerequisites in setup guide

Changed completed checkboxes to uncompleted state.
Cluster must be running before storage setup.
```

**Medium (single category):**
```
docs: update kubeadm bootstrap guide for Ubuntu 24.04

Align guide with official Kubernetes v1.35 documentation.

Changes:
- Add cgroup v2 verification steps
- Add snap package removal for Ubuntu
- Update containerd config for SystemdCgroup
- Add required ports reference table
```

**Complex (multiple categories):**
```
docs: project setup and planning documentation

Preparation for 3-node HA Kubernetes cluster on Lenovo M80q nodes.

Documentation:
- kubeadm bootstrap guide for Ubuntu 24.04
- Architecture decisions and network planning
- CKA learning materials and K8s v1.35 notes
- Storage setup with Longhorn

Claude Code configuration:
- Custom commands (commit, release, validate)
- kubernetes-expert agent and kubeadm-patterns skill
- Security hooks for sensitive file protection
```

**Infrastructure:**
```
infra: add Cilium CNI manifests for network policies

Replace kube-proxy with Cilium eBPF datapath.

Manifests:
- Cilium DaemonSet with hubble enabled
- Network policies for namespace isolation

Configuration:
- Enable native routing mode
- Configure IPAM for pod CIDR
```

## Quality Checklist

Before committing, verify:
- [ ] Title is under 50 characters
- [ ] Title uses imperative mood (Add, Fix, Update)
- [ ] Context sentence explains the "why"
- [ ] Changes are grouped by category (if multiple types)
- [ ] Each bullet is specific and meaningful
- [ ] NO AI attribution anywhere

## Important Notes

- NEVER commit if there are no changes
- Stage all changes with `git add .`
- Use present tense ("Add" not "Added")
- Group changes by category for multi-file commits
- Simple commits don't need categories - just context + bullets
- NO AI attribution (no "Generated with Claude" or "Co-Authored-By")
