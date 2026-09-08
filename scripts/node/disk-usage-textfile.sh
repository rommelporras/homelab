#!/usr/bin/env bash
# Write per-directory disk usage as a node-exporter textfile collector metric.
#
# Why this script exists:
#   The 2026-09-08 disk-fill incident showed node_filesystem_avail_bytes (the
#   default node-exporter root-filesystem metric, 60s scrape resolution) is
#   not enough to diagnose a fast drain after the fact - it tells you the
#   total dropped, not which directory drove it. Forensic reconstruction of
#   that incident was inconclusive because there was no historical breakdown
#   by directory, only point-in-time `du` snapshots taken hours later.
#
#   This script closes that gap cheaply: it runs on the host (not in a pod),
#   so it keeps working even if kubelet/containerd are unhealthy - which is
#   exactly the failure mode being watched for. node-exporter's textfile
#   collector is the intended mechanism for exactly this pattern (host-level
#   script writes a Prometheus-format .prom file, node-exporter picks it up
#   on its next scrape automatically - no new exporter, no new container).
#
#   This is intentionally NOT a Kubernetes manifest. It is node-level OS
#   configuration (same category as /etc/multipath.conf or the
#   protectKernelDefaults sysctls - see CLAUDE.md gotchas), installed once
#   per node via systemd timer, not through ArgoCD. It is kept here under
#   version control for review and reproducibility, same as the other
#   scripts/ helpers, but is not GitOps-applied.
#
# What this does:
#   1. Runs `du -sb` on a small fixed set of directories that are the usual
#      suspects for node-local disk growth (containerd, longhorn, journal/log).
#   2. Writes the result as node_directory_size_bytes{directory="..."} gauge
#      lines to a .prom file in node-exporter's textfile collector directory.
#   3. Writes atomically (temp file + mv) so node-exporter never scrapes a
#      half-written file.
#
# Requirements:
#   - Run as root (du needs read access to /var/lib/containerd, /var/lib/longhorn)
#   - node-exporter must be configured with --collector.textfile.directory
#     pointing at TEXTFILE_DIR below (see helm/prometheus/values.yaml)
#
# Installation (once per node, run manually - not automated by any agent):
#   sudo install -m 0755 scripts/node/disk-usage-textfile.sh /usr/local/bin/disk-usage-textfile.sh
#   sudo install -m 0644 scripts/node/disk-usage-textfile.timer /etc/systemd/system/
#   sudo install -m 0644 scripts/node/disk-usage-textfile.service /etc/systemd/system/
#   sudo systemctl daemon-reload
#   sudo systemctl enable --now disk-usage-textfile.timer
#
# Verify:
#   sudo systemctl status disk-usage-textfile.timer
#   cat /var/lib/node_exporter/textfile_collector/disk_usage.prom

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
OUTPUT_FILE="${TEXTFILE_DIR}/disk_usage.prom"
TMP_FILE="${OUTPUT_FILE}.$$.tmp"

# label => path. Keep this list short and specific - the point is to isolate
# the usual suspects, not to replace `du -sh /*` (that belongs in ad-hoc
# investigation, not a metric that scrapes every 2 minutes forever).
declare -A WATCHED_DIRS=(
  ["containerd"]="/var/lib/containerd"
  ["longhorn"]="/var/lib/longhorn"
  ["log"]="/var/log"
)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script must run as root (du needs to read /var/lib/containerd and /var/lib/longhorn)." >&2
    exit 1
  fi

  mkdir -p "${TEXTFILE_DIR}"

  {
    echo "# HELP node_directory_size_bytes Disk usage of a watched directory, in bytes, from a periodic host-level du scan."
    echo "# TYPE node_directory_size_bytes gauge"
    for label in "${!WATCHED_DIRS[@]}"; do
      path="${WATCHED_DIRS[${label}]}"
      if [[ -d "${path}" ]]; then
        size_bytes="$(du -sb "${path}" 2>/dev/null | cut -f1)"
        echo "node_directory_size_bytes{directory=\"${label}\"} ${size_bytes:-0}"
      fi
    done
  } > "${TMP_FILE}"

  # Atomic replace - node-exporter's textfile collector never sees a
  # partially-written file.
  mv "${TMP_FILE}" "${OUTPUT_FILE}"
}

main "$@"
