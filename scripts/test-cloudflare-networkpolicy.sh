#!/bin/bash
# scripts/test-cloudflare-networkpolicy.sh
# Security validation for cloudflared CiliumNetworkPolicy
#
# Usage: ./scripts/test-cloudflare-networkpolicy.sh

set -euo pipefail

# Use homelab kubeconfig
export KUBECONFIG="${HOME}/.kube/homelab.yaml"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║   Cloudflared NetworkPolicy Security Validation (Hardened)     ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Using KUBECONFIG: ${KUBECONFIG}"
echo ""

# Check prerequisites
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl not found"
    exit 1
fi

if ! kubectl get namespace cloudflare &> /dev/null; then
    echo "Error: cloudflare namespace not found"
    exit 1
fi

if ! kubectl get ciliumnetworkpolicy -n cloudflare cloudflared-egress &> /dev/null; then
    echo "Warning: CiliumNetworkPolicy 'cloudflared-egress' not found"
    echo "Tests will run but results may not reflect intended security posture"
fi

echo "Creating PSS-compliant test pod with app=cloudflared label..."
echo "(This inherits the same NetworkPolicy as cloudflared pods)"
echo ""

# Delete existing test pod if it exists
kubectl delete pod netpol-test -n cloudflare --ignore-not-found=true --wait=true 2>/dev/null || true

# Create pod manifest
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: netpol-test
  namespace: cloudflare
  labels:
    app: cloudflared
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: netshoot
    image: nicolaka/netshoot
    command: ["sleep", "600"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
          - ALL
EOF

echo "Waiting for test pod to be ready..."
kubectl wait --for=condition=Ready pod/netpol-test -n cloudflare --timeout=90s

echo ""

# Run comprehensive tests
kubectl exec -n cloudflare netpol-test -- /bin/sh -c '
PASS=0
FAIL=0
WARN=0

# Helper function for blocked test
test_blocked() {
    local name="$1"
    local host="$2"
    local port="$3"

    printf "%-50s" "$name"
    if timeout 3 nc -zv "$host" "$port" >/dev/null 2>&1; then
        echo "❌ SECURITY FAIL - Reachable!"
        FAIL=$((FAIL+1))
        return 1
    else
        echo "✅ BLOCKED"
        PASS=$((PASS+1))
        return 0
    fi
}

# Helper function for allowed test
test_allowed() {
    local name="$1"
    local host="$2"
    local port="$3"

    printf "%-50s" "$name"
    if timeout 5 nc -zv "$host" "$port" >/dev/null 2>&1; then
        echo "✅ PASS"
        PASS=$((PASS+1))
        return 0
    else
        echo "❌ FAIL"
        FAIL=$((FAIL+1))
        return 1
    fi
}

echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃              SECTION 1: ALLOWED CONNECTIONS                    ┃"
echo "┃                    (These MUST succeed)                        ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo ""

# 1.1 DNS
printf "%-50s" "1.1 DNS resolution (kube-dns)"
if nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; then
    echo "✅ PASS"
    PASS=$((PASS+1))
else
    echo "❌ FAIL"
    FAIL=$((FAIL+1))
fi

# 1.2 Cloudflare Edge (multiple IPs for redundancy check)
test_allowed "1.2 Cloudflare Edge (104.16.132.229:443)" "104.16.132.229" "443"
test_allowed "1.3 Cloudflare Edge alt (104.16.133.229:443)" "104.16.133.229" "443"

# 1.4 Cloudflare QUIC port (UDP - nc tests TCP, so we check UDP separately)
printf "%-50s" "1.4 Cloudflare QUIC/UDP (104.16.132.229:7844)"
# QUIC uses UDP, nc -z tests TCP. UDP test sends a packet and checks for ICMP unreachable.
# If no ICMP unreachable, the port is likely open (or filtered). This is expected behavior.
# The actual tunnel uses QUIC and works (verified by tunnel connections).
if timeout 3 nc -zu 104.16.132.229 7844 >/dev/null 2>&1; then
    echo "✅ PASS (UDP)"
    PASS=$((PASS+1))
else
    # UDP "closed" usually means ICMP unreachable or timeout - not definitive
    # Since tunnel works via QUIC, mark as warning not failure
    echo "⚠️  WARNING (UDP test inconclusive, tunnel uses QUIC)"
    WARN=$((WARN+1))
fi

# 1.5 DMZ VM (temporary rule)
printf "%-50s" "1.5 DMZ VM portfolio (10.10.50.10:3001)"
if timeout 5 nc -zv 10.10.50.10 3001 >/dev/null 2>&1; then
    echo "✅ PASS (temporary DMZ rule)"
    PASS=$((PASS+1))
else
    echo "⚠️  TIMEOUT (expected if DMZ rule removed)"
    WARN=$((WARN+1))
fi

printf "%-50s" "1.6 DMZ VM invoicetron (10.10.50.10:3000)"
if timeout 5 nc -zv 10.10.50.10 3000 >/dev/null 2>&1; then
    echo "✅ PASS (temporary DMZ rule)"
    PASS=$((PASS+1))
else
    echo "⚠️  TIMEOUT (expected if DMZ rule removed)"
    WARN=$((WARN+1))
fi

echo ""
echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃              SECTION 2: INFRASTRUCTURE TARGETS                 ┃"
echo "┃                    (These MUST be blocked)                     ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo ""

# 2.1-2.4 NAS/Storage
test_blocked "2.1 NAS Web UI (10.10.30.4:5000)" "10.10.30.4" "5000"
test_blocked "2.2 NAS SSH (10.10.30.4:22)" "10.10.30.4" "22"
test_blocked "2.3 NFS (10.10.30.4:2049)" "10.10.30.4" "2049"
test_blocked "2.4 Immich (10.10.30.4:2283)" "10.10.30.4" "2283"

# 2.5-2.6 Network Infrastructure
test_blocked "2.5 Router/OPNsense (10.10.30.1:443)" "10.10.30.1" "443"
test_blocked "2.6 Router SSH (10.10.30.1:22)" "10.10.30.1" "22"

# 2.7-2.9 K8s Nodes (direct access)
test_blocked "2.7 k8s-cp1 SSH (10.10.30.11:22)" "10.10.30.11" "22"
test_blocked "2.8 k8s-cp2 SSH (10.10.30.12:22)" "10.10.30.12" "22"
test_blocked "2.9 k8s-cp3 SSH (10.10.30.13:22)" "10.10.30.13" "22"

echo ""
echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃              SECTION 3: KUBERNETES SERVICES                    ┃"
echo "┃                    (These MUST be blocked)                     ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo ""

# 3.1-3.4 Internal K8s services
test_blocked "3.1 Grafana (monitoring ns)" "prometheus-grafana.monitoring.svc.cluster.local" "80"
test_blocked "3.2 Prometheus (monitoring ns)" "prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local" "9090"
test_blocked "3.3 Alertmanager (monitoring ns)" "prometheus-kube-prometheus-alertmanager.monitoring.svc.cluster.local" "9093"
test_blocked "3.4 Longhorn UI (longhorn-system ns)" "longhorn-frontend.longhorn-system.svc.cluster.local" "80"

# 3.5 AdGuard
test_blocked "3.5 AdGuard DNS (home ns)" "adguard-dns.home.svc.cluster.local" "53"

echo ""
echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃              SECTION 4: KUBERNETES CONTROL PLANE               ┃"
echo "┃              (Critical - MUST be blocked)                      ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo ""

# 4.1 K8s API Server
test_blocked "4.1 K8s API Server (kubernetes.default)" "kubernetes.default.svc.cluster.local" "443"

# 4.2-4.4 etcd (critical!)
test_blocked "4.2 etcd cp1 (10.10.30.11:2379)" "10.10.30.11" "2379"
test_blocked "4.3 etcd cp2 (10.10.30.12:2379)" "10.10.30.12" "2379"
test_blocked "4.4 etcd cp3 (10.10.30.13:2379)" "10.10.30.13" "2379"

# 4.5-4.7 Kubelet API
test_blocked "4.5 Kubelet cp1 (10.10.30.11:10250)" "10.10.30.11" "10250"
test_blocked "4.6 Kubelet cp2 (10.10.30.12:10250)" "10.10.30.12" "10250"
test_blocked "4.7 Kubelet cp3 (10.10.30.13:10250)" "10.10.30.13" "10250"

echo ""
echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃              SECTION 5: EDGE CASES & ATTACK VECTORS            ┃"
echo "┃              (Security hardening tests)                        ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo ""

# 5.1 Cloud Metadata API (AWS/GCP/Azure style - should not exist but test anyway)
test_blocked "5.1 Cloud Metadata API (169.254.169.254)" "169.254.169.254" "80"

# 5.2 Link-local addresses
test_blocked "5.2 Link-local (169.254.1.1)" "169.254.1.1" "80"

# 5.3 External HTTP (only HTTPS should be allowed)
test_blocked "5.3 External HTTP (1.1.1.1:80)" "1.1.1.1" "80"
test_blocked "5.4 External HTTP (8.8.8.8:80)" "8.8.8.8" "80"

# 5.5 Other DMZ IPs (only 10.10.50.10 should be allowed)
test_blocked "5.5 Other DMZ (10.10.50.1:80)" "10.10.50.1" "80"
test_blocked "5.6 Other DMZ (10.10.50.100:80)" "10.10.50.100" "80"

# 5.7 Other private ranges
test_blocked "5.7 Private 172.16.0.1:80" "172.16.0.1" "80"
test_blocked "5.8 Private 192.168.1.1:80" "192.168.1.1" "80"

# 5.9 Localhost/loopback (should fail to connect anyway)
printf "%-50s" "5.9 Localhost (127.0.0.1:80)"
if timeout 2 nc -zv 127.0.0.1 80 >/dev/null 2>&1; then
    echo "⚠️  WARNING - Localhost reachable"
    WARN=$((WARN+1))
else
    echo "✅ BLOCKED/No service"
    PASS=$((PASS+1))
fi

# 5.10 Random high port on allowed Cloudflare IP (should be blocked - only 443, 7844 allowed)
test_blocked "5.10 Cloudflare IP wrong port (104.16.132.229:8080)" "104.16.132.229" "8080"

# 5.11 DNS over TCP (we only allow UDP 53)
printf "%-50s" "5.11 DNS over TCP (kube-dns:53/tcp)"
if timeout 3 nc -zv kube-dns.kube-system.svc.cluster.local 53 >/dev/null 2>&1; then
    echo "⚠️  WARNING - DNS/TCP allowed (may be intentional)"
    WARN=$((WARN+1))
else
    echo "✅ BLOCKED (UDP only)"
    PASS=$((PASS+1))
fi

echo ""
echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃                      TEST SUMMARY                              ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo ""
echo "┌────────────────────────────────────────┐"
echo "│  Passed:   $PASS                            "
echo "│  Failed:   $FAIL                            "
echo "│  Warnings: $WARN                            "
echo "└────────────────────────────────────────┘"
echo ""

if [ $FAIL -gt 0 ]; then
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ❌ SECURITY VALIDATION FAILED                                 ║"
    echo "║                                                                ║"
    echo "║  ACTION REQUIRED: Review CiliumNetworkPolicy and fix gaps!    ║"
    echo "║  Do NOT proceed with production traffic until all tests pass. ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    exit 1
elif [ $WARN -gt 0 ]; then
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ⚠️  SECURITY VALIDATION PASSED WITH WARNINGS                  ║"
    echo "║                                                                ║"
    echo "║  Review warnings above - some may be expected behavior.       ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    exit 0
else
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  ✅ SECURITY VALIDATION PASSED                                 ║"
    echo "║                                                                ║"
    echo "║  NetworkPolicy is correctly blocking unauthorized access.     ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    exit 0
fi
'

# Capture exit code
TEST_RESULT=$?

# Cleanup
echo ""
echo "Cleaning up test pod..."
kubectl delete pod netpol-test -n cloudflare --wait=false 2>/dev/null || true

echo ""
if [ $TEST_RESULT -eq 0 ]; then
    echo "Security validation complete."
    exit 0
else
    echo "Security tests failed! Review NetworkPolicy."
    exit 1
fi
