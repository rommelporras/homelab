# Validate Configuration

Validate Kubernetes manifests and infrastructure configuration files.

## Instructions

1. **Identify Files to Validate**
   ```bash
   # Find all YAML files
   find . -name "*.yaml" -o -name "*.yml" | head -20

   # Find Kubernetes manifests
   find manifests/ -name "*.yaml" 2>/dev/null
   ```

2. **YAML Syntax Validation**
   ```bash
   # Using yq (if installed)
   yq eval '.' <file.yaml> > /dev/null && echo "Valid YAML" || echo "Invalid YAML"

   # Using Python
   python3 -c "import yaml; yaml.safe_load(open('<file.yaml>'))"
   ```

3. **Kubernetes Manifest Validation**
   ```bash
   # Dry-run against cluster (requires cluster access)
   kubectl apply --dry-run=server -f <file.yaml>

   # Client-side validation (no cluster needed)
   kubectl apply --dry-run=client -f <file.yaml>

   # Validate entire directory
   kubectl apply --dry-run=client -f manifests/ --recursive
   ```

4. **Check for Common Issues**

   **Missing Required Fields:**
   ```bash
   # Check for apiVersion
   grep -L "apiVersion:" manifests/*.yaml

   # Check for kind
   grep -L "kind:" manifests/*.yaml

   # Check for metadata
   grep -L "metadata:" manifests/*.yaml
   ```

   **Security Issues:**
   ```bash
   # Find privileged containers
   grep -r "privileged: true" manifests/

   # Find hostNetwork usage
   grep -r "hostNetwork: true" manifests/

   # Find missing resource limits
   grep -L "resources:" manifests/*.yaml
   ```

5. **Validate Specific Resource Types**

   **Deployments:**
   ```bash
   # Check replica count
   grep -A2 "replicas:" manifests/*.yaml

   # Check for readiness probes
   grep -L "readinessProbe:" manifests/*.yaml
   ```

   **Services:**
   ```bash
   # Check port configurations
   grep -A5 "ports:" manifests/*.yaml

   # Verify selector matches
   grep -A3 "selector:" manifests/*.yaml
   ```

   **ConfigMaps/Secrets:**
   ```bash
   # Find hardcoded secrets
   grep -r "password:" manifests/
   grep -r "secret:" manifests/
   ```

6. **Documentation Validation**
   ```bash
   # Check markdown links
   grep -r "\[.*\](.*)" docs/*.md | grep -v http

   # Find TODO items
   grep -r "TODO\|FIXME\|XXX" docs/
   ```

## Validation Report Format

```
Configuration Validation Report
===============================

Files Checked: 12 YAML files, 5 Markdown files

YAML Syntax:
  manifests/deployment.yaml     VALID
  manifests/service.yaml        VALID
  manifests/configmap.yaml      VALID

Kubernetes Validation:
  manifests/deployment.yaml     PASS (dry-run successful)
  manifests/service.yaml        PASS (dry-run successful)

Security Checks:
  Privileged containers:    None found
  Host networking:          None found
  Missing resource limits:  2 files (see below)

Warnings:
  manifests/dev-pod.yaml - No resource limits defined
  manifests/debug-pod.yaml - No resource limits defined

Best Practice Violations:
  None

Status: VALIDATION PASSED (2 warnings)
```

## Pre-Commit Validation

Run before committing changes:

```bash
# Quick validation script
for f in $(git diff --cached --name-only | grep -E '\.(yaml|yml)$'); do
  echo "Validating: $f"
  kubectl apply --dry-run=client -f "$f" 2>&1 || exit 1
done
echo "All manifests valid"
```

## Tools Reference

**Recommended validation tools:**
- `kubectl --dry-run` - Built-in K8s validation
- `kubeval` - Validate against K8s schemas
- `kube-linter` - Security and best practices
- `yamllint` - YAML syntax and style
- `kubeconform` - Fast K8s manifest validation

**Installation:**
```bash
# kubeval
wget https://github.com/instrumenta/kubeval/releases/latest/download/kubeval-linux-amd64.tar.gz
tar xf kubeval-linux-amd64.tar.gz
sudo mv kubeval /usr/local/bin/

# kube-linter
curl -LO https://github.com/stackrox/kube-linter/releases/latest/download/kube-linter-linux
chmod +x kube-linter-linux
sudo mv kube-linter-linux /usr/local/bin/kube-linter

# yamllint
pip install yamllint
```

## Common Validation Errors

**Invalid apiVersion:**
```
error: unable to recognize "file.yaml": no matches for kind "Deployment" in version "apps/v1beta1"
```
Fix: Use current apiVersion (apps/v1)

**Missing required field:**
```
error: error validating "file.yaml": missing required field "spec"
```
Fix: Add the required field

**Invalid label selector:**
```
error: selector does not match template labels
```
Fix: Ensure spec.selector matches spec.template.metadata.labels

**Invalid port:**
```
error: Invalid value: 0: must be between 1 and 65535
```
Fix: Use valid port number
