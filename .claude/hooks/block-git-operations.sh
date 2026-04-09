#!/usr/bin/env bash
# PreToolUse hook - blocks direct git/gh commands outside /commit and /ship.
#
# Skills create a lock file before running git/gh commands:
#   /tmp/.claude-skill-commit  (created by /commit skill)
#   /tmp/.claude-skill-ship    (created by /ship skill)
#
# If a lock file exists, git add/commit/tag commands are allowed.
# git push is blocked by BOTH this hook and the global bash-write-protect.sh.
# bash-write-protect.sh blocks it unconditionally (no lock file bypass).
# This hook also blocks it to show a project-specific error message.
#
# Exit 0 = allow, Exit 2 = block.

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // .parameters.command // empty')

# Only check Bash tool
if [[ "$TOOL" != "Bash" || -z "$COMMAND" ]]; then
  exit 0
fi

# Allow lock file creation/cleanup (the skills themselves)
if echo "$COMMAND" | grep -qE '(touch|rm).*\.claude-skill-'; then
  exit 0
fi

# Check if a skill lock file exists (bypasses add/commit/tag)
if [[ -f /tmp/.claude-skill-commit || -f /tmp/.claude-skill-ship ]]; then
  exit 0
fi

# Block git write operations (without lock file).
# Read-only git commands (log, status, diff, tag -l, describe, show, fetch, etc.) are allowed.
if echo "$COMMAND" | grep -qE '\bgit\s+add\b'; then
  echo "BLOCKED: Direct git commands are not allowed." >&2
  echo "   Use /commit to stage and commit changes." >&2
  exit 2
fi
if echo "$COMMAND" | grep -qE '\bgit\s+commit\b'; then
  echo "BLOCKED: Direct git commands are not allowed." >&2
  echo "   Use /commit to stage and commit changes." >&2
  exit 2
fi
if echo "$COMMAND" | grep -qE '(^|[;|&])\s*git\s+push\b'; then
  echo "BLOCKED: Direct git commands are not allowed." >&2
  echo "   Use /ship to push and create a GitHub release." >&2
  exit 2
fi
# Block annotated/signed tag creation (git tag -a, git tag -s) but allow listing (git tag -l, git tag --sort, etc.)
if echo "$COMMAND" | grep -qE '\bgit\s+tag\s+(-[a-zA-Z]*[as][a-zA-Z]*\s|--annotate|--sign)'; then
  echo "BLOCKED: Direct git commands are not allowed." >&2
  echo "   Use /ship to create tags." >&2
  exit 2
fi

# Block gh release create/delete
if echo "$COMMAND" | grep -qE '\bgh\s+release\s+(create|delete)\b'; then
  echo "BLOCKED: Direct gh release commands are not allowed." >&2
  echo "   Use /ship to create releases with proper format and confirmation." >&2
  exit 2
fi

# Block recursive rm (rm -rf, rm -r)
if echo "$COMMAND" | grep -qE '\brm\s+(-[a-zA-Z]*r|-[a-zA-Z]*f[a-zA-Z]*r)\b'; then
  echo "BLOCKED: Recursive rm is not allowed." >&2
  echo "   Delete files individually or ask the user to run this manually." >&2
  exit 2
fi

exit 0
