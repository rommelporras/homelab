# Deferred Tasks

## Firmware Updates (Low Priority)

**Status**: Deferred - requires physical access (HDMI, keyboard)

### Issue
BIOS and EC firmware updates failed on all nodes due to "Boot Order Lock" enabled in BIOS.
NVMe firmware updated successfully (High urgency - done).

### Affected Nodes
- [x] k8s-cp1 (10.10.60.11) - ALL UPDATES APPLIED
- [ ] k8s-cp2 (10.10.60.12) - Boot Order Lock blocking BIOS/EC
- [ ] k8s-cp3 (10.10.60.13) - Boot Order Lock blocking BIOS/EC

### Updates Pending

| Component | Current | Target | Urgency |
|-----------|---------|--------|---------|
| System BIOS | 1.90 | 1.99 | Low |
| Embedded Controller | 256.20 | 256.24 | Low |

### CVEs Fixed (all Medium/Low severity)
- CVE-2025-20067: Intel CSME timing side-channel
- CVE-2024-38796: EDK2 UEFI heap overflow
- CVE-2025-20064, CVE-2025-22831-22833: Intel firmware disclosure

### Steps to Complete

1. Connect HDMI + keyboard to node
2. Reboot into BIOS: `sudo systemctl reboot --firmware-setup`
3. Navigate to **Security** or **Startup** menu
4. Disable **Boot Order Lock**
5. Save and exit (F10)
6. After Linux boots: `sudo fwupdmgr update`
7. Reboot when prompted
8. Optionally re-enable Boot Order Lock in BIOS

### Why Deferred
- Requires physical access (HDMI, keyboard)
- Machines are rack-mounted, cable switching is hassle
- Low urgency - security patches for edge-case attack vectors
- NVMe (High urgency) already completed

### When to Do
- During scheduled maintenance window
- When physically accessing rack for other reasons
- Before production workloads if security-critical
