# Update-NetScalerHAPair-v2.ps1

Rolling upgrade of a **NetScaler (VPX) HA pair** from a single PowerShell script, with live progress, step-by-step messages, automatic error diagnosis, auto-fix for common failures, and a per-run log file.

The secondary node is upgraded first, then an HA failover is forced, then the old primary is upgraded. Traffic stays on a healthy node throughout.

---

## Features

- Weighted overall progress percentage plus per-step messages
- Pre-checks before any change (HA health, sync, free disk space, version / downgrade check)
- Full backup (`save ns config` + `create system backup -level full`) on both nodes
- SCP upload of the build with **SHA256 verification** (skips upload if the correct file is already staged)
- Live installer output (`installns -y` runs in the background, log tailed every 10 s)
- Waits for reboot, new version, and HA `UP` on each node
- Forced HA failover with confirmation that the upgraded node is Primary
- Post-upgrade verification: version, HA state, sync, exactly one Primary
- Optional fail-back to the original primary and optional cleanup of build files
- **Idempotent**: nodes already on the target build are detected and skipped, so a failed run can be re-run with the same command
- Error knowledge base: each failure shows the likely reason and numbered suggested actions, and some are auto-fixed and retried
- Timestamped log file per run

---

## Requirements

| Item | Requirement |
|---|---|
| PowerShell | 5.1 or 7+ |
| Module | [Posh-SSH](https://www.powershellgallery.com/packages/Posh-SSH) |
| Network | TCP **22** (SSH/SCP) and **443** (NITRO) to both NSIPs; use TCP 80 with `-UseHttp` |
| Account | NetScaler superuser (e.g. `nsroot`) with shell access |
| Build file | NetScaler build file named like `build-14.1-73.58_nc_64.tgz` |
| Disk | At least `-MinFreeMB` free on `/var` of each node (default 5000 MB) |

Install the module:

```powershell
Install-Module Posh-SSH -Scope CurrentUser
```

> The build file name is parsed to determine the target release and build number, so **do not rename it**. It must match `build-<release>-<build>_nc[_64].tgz`.

---

## Usage

### 1. Pre-checks only (no changes)

```powershell
.\Update-NetScalerHAPair-v2.ps1 -Node1 10.128.201.10 -Node2 10.128.201.11 `
    -BuildFile C:\Patches\build-14.1-73.58_nc_64.tgz `
    -Credential (Get-Credential nsroot) -PreCheckOnly
```

### 2. Full upgrade with fail-back and cleanup

```powershell
.\Update-NetScalerHAPair-v2.ps1 -Node1 10.128.201.10 -Node2 10.128.201.11 `
    -BuildFile C:\Patches\build-14.1-73.58_nc_64.tgz `
    -Credential (Get-Credential nsroot) `
    -ChangeTicket CHG12345 -FailBack -CleanupBuild
```

Node1 and Node2 can be given in either order. The script detects which one is Primary.

---

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-Node1` | Yes | | NSIP of the first HA node |
| `-Node2` | Yes | | NSIP of the second HA node |
| `-BuildFile` | Yes | | Local path to the `build-*_nc_64.tgz` file |
| `-Credential` | Yes | | NetScaler superuser credential |
| `-ChangeTicket` | No | `NA` | Change ticket ID, used in progress text and the log file name |
| `-RemoteDir` | No | `/var/nsinstall` | Staging directory on the nodes |
| `-MinFreeMB` | No | `5000` | Minimum free space required on `/var` |
| `-RebootTimeoutMin` | No | `25` | Max minutes to wait for a node to return after reboot |
| `-MaxRetries` | No | `2` | Max auto-fix retries per step |
| `-FailBack` | No | off | Return the original Primary/Secondary roles at the end |
| `-CleanupBuild` | No | off | Delete build and extracted files from the nodes at the end |
| `-UseHttp` | No | off | Use HTTP instead of HTTPS for NITRO |
| `-PreCheckOnly` | No | off | Run only the pre-checks and exit |
| `-NoAutoFix` | No | off | Disable all auto-fix actions (diagnosis is still shown) |

---

## Workflow

| Step | ID | What it does | Weight |
|---|---|---|---|
| Pre-checks | `PRE` | Posh-SSH present, read HA state via NITRO, detect roles, require HA `UP` and no sync failure, check target vs installed build (blocks downgrade), check free space | 8 |
| Backup | `BACKUP` | `save ns config` and full system backup on both nodes (stored in `/var/ns_sys_backup`) | 7 |
| Upload | `UPLOAD` | SCP build to `RemoteDir`, verify SHA256 on each node needing the patch | 20 |
| Install secondary | `INST_A` | Extract and run `installns -y`, tail the installer log, wait for reboot, new version and HA `UP` | 22 |
| Failover | `FAILOVER` | `force HA failover -f`, wait up to 180 s for the upgraded node to become Primary | 5 |
| Install old primary | `INST_B` | Same as `INST_A` on the old primary | 22 |
| Verify | `VERIFY` | Both nodes on target build, HA `UP`, sync not failed (waits up to 5 min for sync in progress), exactly one Primary | 6 |
| Fail back | `FAILBACK` | Optional (`-FailBack`): return original roles | 4 |
| Cleanup | `CLEANUP` | Optional (`-CleanupBuild`): remove build files, extracted files and installer log | 2 |

Steps are skipped automatically when not needed (for example, a node already on the target build).

---

## Error handling and auto-fix

On failure the script prints the step, node, error, **likely reason**, and **numbered suggested actions**. If an auto-fix exists, it runs and the step is retried up to `-MaxRetries` times.

| Problem detected | Auto-fix |
|---|---|
| Low disk space | Removes old `build-*` files and `ns-*` extracted dirs in `/var/nsinstall` |
| SHA256 mismatch / corrupt tgz | Deletes the bad remote copy so it is re-uploaded |
| HA sync failed | Runs `force HA sync` on the node in Secondary role |
| Transient connection error | Waits 30 s and retries |
| Installer finished but node does not reboot | Issues `reboot -w` after 4 min |

Diagnosis only (no auto-fix): authentication failures, TLS/certificate errors, SSH key-exchange mismatch, missing Posh-SSH, split-brain / no Primary, HA not healthy, failover not completing, reboot timeout, downgrade attempt, and `installns` rejections (unsupported upgrade path, wrong build type, licence).

Anything unrecognised is reported as "Unclassified error" with pointers to the log and `/var/log/ns.log`.

---

## Output

- **Console**: colour-coded progress bar, step messages, diagnosis blocks, and a final summary table (step, status, time, note) with the version, role, HA state and sync state of each node.
- **Log file**: written next to the script as `NSPatch_<ChangeTicket>_<yyyyMMdd_HHmmss>.log`.
- **On the nodes**: installer output in `/var/tmp/ns_patch_install.log` (removed by `-CleanupBuild`); backups in `/var/ns_sys_backup` (named `pre_patch_<ticket>_<yyyyMMdd_HHmm>`).
- **Exit code**: `0` on success, `1` on failure.

---

## Recovery

- **Roll-forward**: fix the cause and re-run the same command. Completed nodes and steps are detected and skipped. A mixed-version HA pair is supported during an upgrade.
- **Roll-back**: restore the pre-patch backup from `/var/ns_sys_backup`, or boot the previous kernel from the boot menu via the hypervisor console.

---

## Notes and limitations

- Downgrades are **not supported** and are blocked in pre-checks.
- A change of release (for example 13.1 to 14.1) only produces a warning. Verify the supported upgrade path in the release notes first.
- The script refuses to run if both nodes report Primary, no node is Primary, or either node's HA status is not `UP`.
- On PowerShell 5.1 the script trusts all certificates for NITRO calls (self-signed NSIP certs). On PowerShell 7 it uses `-SkipCertificateCheck`.
- NITRO credentials are sent as `X-NITRO-USER` / `X-NITRO-PASS` headers. Prefer HTTPS (the default) unless policy requires otherwise.
- SSH host keys are auto-accepted (`-AcceptKey`).
- Run `-PreCheckOnly` first, and take a hypervisor snapshot where possible before a production change.
