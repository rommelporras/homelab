#!/bin/bash
set -euo pipefail

# Sync Ghost production database and content to dev environment
# Usage: ./scripts/sync-ghost-prod-to-dev.sh
#
# What this does:
#   1. Dumps prod MySQL database
#   2. Copies prod Ghost content (images, themes)
#   3. Scales down dev Ghost
#   4. Imports database to dev MySQL
#   5. Updates site URL in dev database
#   6. Copies content to dev Ghost pod
#   7. Restarts dev Ghost
#
# CKA topic: kubectl exec, kubectl cp, kubectl scale

export KUBECONFIG="$HOME/.kube/homelab.yaml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PROD_NS="ghost-prod"
DEV_NS="ghost-dev"
BACKUP_DIR="/tmp/ghost-backup-$(date +%Y%m%d-%H%M%S)"

echo -e "${GREEN}=== Ghost Prod → Dev Sync ===${NC}"
echo -e "${YELLOW}Backup directory: ${BACKUP_DIR}${NC}"
mkdir -p "${BACKUP_DIR}"

# Confirmation prompt
echo ""
echo -e "${RED}WARNING: This will overwrite the dev database and content!${NC}"
read -p "Continue? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 1
fi

# 1. Get prod MySQL password
echo -e "\n${YELLOW}[1/7] Getting prod MySQL password...${NC}"
PROD_MYSQL_PASS=$(kubectl get secret -n ${PROD_NS} ghost-mysql -o jsonpath='{.data.user-password}' | base64 -d)

# 2. Dump production database
echo -e "${YELLOW}[2/7] Dumping production database...${NC}"
kubectl exec -n ${PROD_NS} ghost-mysql-0 -- \
  mysqldump -u ghost -p"${PROD_MYSQL_PASS}" ghost > "${BACKUP_DIR}/ghost.sql"
echo -e "${GREEN}Database dumped: $(wc -c < "${BACKUP_DIR}/ghost.sql") bytes${NC}"

# 3. Copy production content (images, themes)
echo -e "${YELLOW}[3/7] Copying production content...${NC}"
PROD_POD=$(kubectl get pod -n ${PROD_NS} -l app=ghost -o jsonpath='{.items[0].metadata.name}')
kubectl cp ${PROD_NS}/${PROD_POD}:/var/lib/ghost/content "${BACKUP_DIR}/content"
echo -e "${GREEN}Content copied${NC}"

# 4. Scale down dev Ghost
echo -e "${YELLOW}[4/7] Scaling down dev Ghost...${NC}"
kubectl scale deployment ghost -n ${DEV_NS} --replicas=0
sleep 5

# 5. Import database to dev
echo -e "${YELLOW}[5/7] Importing database to dev...${NC}"
DEV_MYSQL_PASS=$(kubectl get secret -n ${DEV_NS} ghost-mysql -o jsonpath='{.data.user-password}' | base64 -d)
kubectl exec -i -n ${DEV_NS} ghost-mysql-0 -- \
  mysql -u ghost -p"${DEV_MYSQL_PASS}" ghost < "${BACKUP_DIR}/ghost.sql"

# 6. Update URL in dev database
echo -e "${YELLOW}[6/7] Updating site URL in dev database...${NC}"
kubectl exec -n ${DEV_NS} ghost-mysql-0 -- \
  mysql -u ghost -p"${DEV_MYSQL_PASS}" \
  -e "UPDATE ghost.settings SET value='https://blog.dev.k8s.rommelporras.com' WHERE \`key\`='url';" \
  ghost

# 7. Copy content to dev pod (after scaling up)
echo -e "${YELLOW}[7/7] Scaling up dev Ghost and copying content...${NC}"
kubectl scale deployment ghost -n ${DEV_NS} --replicas=1
kubectl wait --for=condition=ready pod -l app=ghost -n ${DEV_NS} --timeout=120s

DEV_POD=$(kubectl get pod -n ${DEV_NS} -l app=ghost -o jsonpath='{.items[0].metadata.name}')
kubectl cp "${BACKUP_DIR}/content" ${DEV_NS}/${DEV_POD}:/var/lib/ghost/content

# Restart dev Ghost to pick up changes
kubectl rollout restart deployment ghost -n ${DEV_NS}

echo -e "\n${GREEN}=== Sync complete! ===${NC}"
echo -e "Backup retained at: ${BACKUP_DIR}"
echo -e "Dev URL: https://blog.dev.k8s.rommelporras.com"
