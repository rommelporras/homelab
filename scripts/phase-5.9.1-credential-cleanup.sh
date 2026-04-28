#!/usr/bin/env bash
# Phase 5.9.1 credential cleanup — run AFTER /ship v0.39.2.
#
# Run from this WSL2 host (the dev workstation with gh + glab logged in).
#
# Deletes the OLD overlapping credentials that have been replaced by the
# 2026-04-24 rotations. Write-paths verified by portfolio-dev-rsgw5 on the
# same day, so these are safe to delete.
#
# Required tools: gh (logged in to github.com), glab (logged in to
# gitlab.k8s.rommelporras.com).
#
# Each step is idempotent and prints what it deleted. Run end-to-end or
# step-by-step.

set -euo pipefail

GITLAB_HOST="gitlab.k8s.rommelporras.com"

echo "==> 1/3 Delete old GitHub deploy key (id 149092650, name 'argo-ci')"
if gh api repos/rommelporras/homelab/keys/149092650 --silent 2>/dev/null; then
  gh api -X DELETE repos/rommelporras/homelab/keys/149092650
  echo "    deleted"
else
  echo "    already gone"
fi

echo
echo "==> 2/3 Delete old invoicetron project deploy tokens (id 2, id 3)"
for id in 2 3; do
  resp=$(glab api -X DELETE "projects/0xwsh%2Finvoicetron/deploy_tokens/$id" \
    --hostname "$GITLAB_HOST" 2>&1 || true)
  echo "    id=$id -> $resp"
done

echo
echo "==> 3/3 Delete old GitLab group deploy token 'argo-workflows-buildkit'"
echo "    (group-level API requires numeric group id; use the UI for safety)"
echo "    Open: https://${GITLAB_HOST}/groups/0xwsh/-/settings/repository"
echo "    Section: 'Deploy tokens' -> revoke 'argo-workflows-buildkit'"
echo "    KEEP: 'argo-workflows-buildkit-2026-04-24'"

# Local keyfile shred (~/tmp/ae-rotate/argo-events-deploy-key{,.pub}) was
# completed manually a few days after the rotation - intentionally not in
# this script.

echo
echo "==> Done. Verify:"
echo "    gh api repos/rommelporras/homelab/keys | jq '.[].id'  (should NOT contain 149092650)"
echo "    glab api projects/0xwsh%2Finvoicetron/deploy_tokens --hostname $GITLAB_HOST | jq '.[] | select(.revoked==false) | .id'  (should be only 4)"
