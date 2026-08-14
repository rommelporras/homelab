#!/usr/bin/env bash
# PreToolUse hook -- blocks the write tool if content contains known secret patterns.
# Catches secrets hardcoded into files (e.g. manifests, scripts, config values).
#
# Supports field names used by Kiro's write/fs_write tool:
#   tool_input.content     -- full file write (create)
#   tool_input.file_text   -- alternate full-write field name
#   tool_input.new_str     -- strReplace new content
#   parameters.*           -- fallback for alternate schema shapes
#
# Exit 2 = block the tool call (message shown to the agent).
# Exit 0 = allow.

set -euo pipefail

INPUT=$(cat)

# Extract the file path for error messages (best-effort; may be empty).
FILE=$(echo "${INPUT}" | jq -r '
  .tool_input.path //
  .tool_input.file_path //
  .parameters.path //
  .parameters.file_path //
  ""
')

# Extract content from whichever field the tool populated.
CONTENT=$(echo "${INPUT}" | jq -r '
  .tool_input.content //
  .tool_input.file_text //
  .tool_input.new_str //
  .parameters.content //
  .parameters.file_text //
  .parameters.new_str //
  ""
')

if [[ -z "${CONTENT}" ]]; then
  exit 0
fi

BLOCKED=0

# check NAME PATTERN -- prints a message and sets BLOCKED=1 if the pattern matches.
# Uses grep -qP (PCRE) for the patterns that require lookaheads; safe for all patterns here.
check() {
  local name="${1}"
  local pattern="${2}"
  if printf '%s' "${CONTENT}" | grep -qP -- "${pattern}"; then
    echo "BLOCKED: Detected potential ${name} in content being written to '${FILE:-file}'." >&2
    BLOCKED=1
  fi
}

# PEM private key headers (RSA, EC, OpenSSH, and bare PRIVATE KEY)
check "private key" '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'

# AWS access key IDs (20-char AKIA prefix format)
check "AWS access key" 'AKIA[0-9A-Z]{16}'

# GitHub tokens: personal access (classic: ghp_, fine-grained: github_pat is newer,
# but task spec targets gh[pousr]_ prefixes)
check "GitHub token" 'gh[pousr]_[A-Za-z0-9]{36,}'

# GitLab personal access tokens
check "GitLab token" 'glpat-[A-Za-z0-9_-]{20}'

# Anthropic API keys
check "Anthropic API key" 'sk-ant-'

# OpenAI project keys
check "OpenAI API key" 'sk-proj-'

if [[ "${BLOCKED}" -eq 1 ]]; then
  echo "Use environment variables or a secret manager (e.g. 1Password op:// references) instead." >&2
  exit 2
fi

exit 0
