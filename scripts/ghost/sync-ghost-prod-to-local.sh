#!/bin/bash
set -euo pipefail

# Sync Ghost production database to local docker-compose environment
# Usage: ./scripts/sync-ghost-prod-to-local.sh [theme-repo-path]
#
# What this does:
#   1. Dumps prod MySQL database
#   2. Copies SQL dump to theme repo backup/ directory
#   3. Prints instructions for local restore
#
# CKA topic: kubectl exec, Service DNS pattern <svc>.<ns>.svc.cluster.local

export KUBECONFIG="$HOME/.kube/homelab.yaml"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

THEME_PATH="${1:-$HOME/personal/eventually-consistent}"
PROD_NS="ghost-prod"
BACKUP_DIR="/tmp/ghost-backup-$(date +%Y%m%d-%H%M%S)"

echo -e "${GREEN}=== Ghost Prod → Local Sync ===${NC}"
mkdir -p "${BACKUP_DIR}"
mkdir -p "${THEME_PATH}/backup"

# 1. Get prod MySQL password
echo -e "${YELLOW}[1/2] Getting prod MySQL password...${NC}"
PROD_MYSQL_PASS=$(kubectl get secret -n ${PROD_NS} ghost-mysql -o jsonpath='{.data.user-password}' | base64 -d)

# 2. Dump production database
echo -e "${YELLOW}[2/2] Dumping production database...${NC}"
kubectl exec -n ${PROD_NS} ghost-mysql-0 -- \
  mysqldump -u ghost -p"${PROD_MYSQL_PASS}" ghost > "${BACKUP_DIR}/ghost.sql"

# Copy to theme repo
cp "${BACKUP_DIR}/ghost.sql" "${THEME_PATH}/backup/"
echo -e "${GREEN}Database dumped: $(wc -c < "${BACKUP_DIR}/ghost.sql") bytes${NC}"

echo -e "\n${GREEN}=== Database dumped to ${THEME_PATH}/backup/ghost.sql ===${NC}"
echo ""
echo "To restore locally:"
echo "  cd ${THEME_PATH}"
echo "  docker compose -f docker-compose.dev.yml up -d mysql"
echo "  docker compose -f docker-compose.dev.yml exec mysql mysql -u ghost -pghost ghost < backup/ghost.sql"
echo "  # Update URL for local (note: backticks around 'key' - it's a MySQL reserved word):"
echo "  docker compose -f docker-compose.dev.yml exec mysql mysql -u ghost -pghost -e \"UPDATE settings SET value='http://localhost:2368' WHERE \\\`key\\\`='url';\" ghost"
echo "  docker compose -f docker-compose.dev.yml up -d ghost"
