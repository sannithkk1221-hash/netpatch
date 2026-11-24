#Requires -Version 5.1
<#
.SYNOPSIS
  Rolling upgrade of a NetScaler VPX HA pair with live progress %, step messages,
  automatic error diagnosis, auto-fix and failure suggestions.

.DESCRIPTION
  Flow (secondary first, then failover, then old primary):
    PRE      Pre-checks  : module, creds, HA health, sync, disk space, version/downgrade check
    BACKUP   save ns config + create system backup on both nodes
    UPLOAD   Copy build to /var/nsinstall (SCP) + SHA256 verify
    INST_A   Upgrade SECONDARY (tar + installns -y), live installer output, wait for reboot
    FAILOVER force HA failover, confirm upgraded node is Primary
    INST_B   Upgrade old primary, wait for reboot
    VERIFY   Version + HA state + sync check on both nodes
    FAILBACK (optional) return original roles
    CLEANUP  (optional) delete build files from /var/nsinstall

  Auto-fix examples : low disk space (removes OLD builds in /var/nsinstall), SHA mismatch /
                      corrupt tgz (re-upload), HA sync failed (force HA sync), transient
                      connection errors (wait + retry), node not rebooting after installns (reboot).
  Everything else is diagnosed with a probable reason and numbered suggestions.

.REQUIREMENTS
  PowerShell 5.1+ or 7+, module Posh-SSH  (Install-Module Posh-SSH -Scope CurrentUser)
  Reachability to both NSIPs on TCP 22 and 443 (or 80 with -UseHttp)

.EXAMPLE
  # Checks only (no change)
  .\Update-NetScalerHAPair-v2.ps1 -Node1 10.128.201.10 -Node2 10.128.201.11 `
     -BuildFile C:\Patches\build-14.1-73.58_nc_64.tgz -Credential (Get-Credential nsroot) -PreCheckOnly

.EXAMPLE
  # Full run, fail back to original primary at the end
  .\Update-NetScalerHAPair-v2.ps1 -Node1 10.128.201.10 -Node2 10.128.201.11 `
     -BuildFile C:\Patches\build-14.1-73.58_nc_64.tgz -Credential (Get-Credential nsroot) `
     -ChangeTicket CHG12345 -FailBack -CleanupBuild
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Node1,
    [Parameter(Mandatory)][string]$Node2,
    [Parameter(Mandatory)][ValidateScript({ Test-Path $_ -PathType Leaf })][string]$BuildFile,
    [Parameter(Mandatory)][pscredential]$Credential,
    [string]$ChangeTicket   = 'NA',
    [string]$RemoteDir      = '/var/nsinstall',
    [int]$MinFreeMB         = 5000,
    [int]$RebootTimeoutMin  = 25,
    [int]$MaxRetries        = 2,
    [switch]$FailBack,
    [switch]$CleanupBuild,
    [switch]$UseHttp,
    [switch]$PreCheckOnly,
    [switch]$NoAutoFix
)

$ErrorActionPreference = 'Stop'
$scheme  = if ($UseHttp) { 'http' } else { 'https' }
$LogFile = Join-Path $PSScriptRoot ("NSPatch_{0}_{1:yyyyMMdd_HHmmss}.log" -f ($ChangeTicket -replace '[^\w-]','_'), (Get-Date))

# ---- TLS / self-signed cert handling for NITRO ----
if ($PSVersionTable.PSVersion.Major -lt 7) {
    if (-not ('TrustAllCertsPolicy' -as [type])) {
        Add-Type @"
using System.Net; using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
  public bool CheckValidationResult(ServicePoint s, X509Certificate c, WebRequest r, int p) { return true; } }
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    [System.Net.ServicePointManager]::SecurityProtocol  = [System.Net.SecurityProtocolType]::Tls12
}

# =====================================================================
#  STATE
# =====================================================================
$script:Steps = @(
    @{ Id='PRE';      Name='Pre-checks';                       Weight=8  }
    @{ Id='BACKUP';   Name='Save config + system backup';      Weight=7  }
    @{ Id='UPLOAD';   Name='Stage build in /var/nsinstall';    Weight=20 }
    @{ Id='INST_A';   Name='Upgrade SECONDARY node';           Weight=22 }
    @{ Id='FAILOVER'; Name='HA failover';                      Weight=5  }
    @{ Id='INST_B';   Name='Upgrade old PRIMARY node';         Weight=22 }
    @{ Id='VERIFY';   Name='Post-upgrade verification';        Weight=6  }
)
if ($FailBack)     { $script:Steps += @{ Id='FAILBACK'; Name='Fail back to original primary'; Weight=4 } }
if ($CleanupBuild) { $script:Steps += @{ Id='CLEANUP';  Name='Remove build files from nodes';  Weight=2 } }
if ($PreCheckOnly) { $script:Steps  = @($script:Steps[0]) }

$script:TotalWeight     = ($script:Steps | ForEach-Object { $_.Weight } | Measure-Object -Sum).Sum
$script:CompletedWeight = 0
$script:CurStep         = $script:Steps[0]
$script:CurNode         = $null
$script:LastMsg         = ''
$script:Results         = @()
$script:Clock           = [Diagnostics.Stopwatch]::StartNew()
$script:NodeA = $null     # original SECONDARY (patched first)
$script:NodeB = $null     # original PRIMARY   (patched second)
$script:Need  = @{}       # ip -> $true/$false needs patch
$script:InstallerFinished = @{}
$script:LocalHash = $null

# =====================================================================
#  LOGGING + PROGRESS
# =====================================================================
function Write-Log {
    param([string]$Msg, [ValidateSet('INFO','WARN','ERROR','DEBUG')]$Level = 'INFO')
    Add-Content -Path $LogFile -Value ("{0:u} [{1}] {2}" -f (Get-Date), $Level, $Msg)
    switch ($Level) {
        'WARN'  { Write-Host "  [WARN]  $Msg" -ForegroundColor Yellow }
        'ERROR' { Write-Host "  [ERROR] $Msg" -ForegroundColor Red }
        'INFO'  { Write-Host "  - $Msg" -ForegroundColor DarkGray }
    }
}

function Show-Progress {
    param([string]$Msg, [double]$Fraction = 0, [switch]$NoHost)
    $f   = [math]::Min(1, [math]::Max(0, $Fraction))
    $cw  = $script:CompletedWeight + ($script:CurStep.Weight * $f)
    $pct = [int][math]::Min(100, [math]::Floor($cw / $script:TotalWeight * 100))
    $bar = ('#' * [int]($pct / 5)).PadRight(20, '-')
    Write-Progress -Activity "NetScaler HA patching  [$ChangeTicket]  Target $TargetRelease build $TargetBuild" `
                   -Status ("{0}%  |  {1}" -f $pct, $script:CurStep.Name) `
                   -CurrentOperation $Msg -PercentComplete $pct
    Add-Content -Path $LogFile -Value ("{0:u} [PROGRESS] {1}% {2}" -f (Get-Date), $pct, $Msg)
    if (-not $NoHost -and $Msg -ne $script:LastMsg) {
        Write-Host ("[{0}] {1,3}%  {2}" -f $bar, $pct, $Msg) -ForegroundColor Cyan
        $script:LastMsg = $Msg
    }
}

# =====================================================================
#  ERROR KNOWLEDGE BASE (pattern -> reason, suggestions, optional auto-fix)
# =====================================================================
$script:KB = @(
  @{ Pattern='Low disk space|No space left|not enough space|Disk quota'
     Reason='The node does not have enough free space on /var for the build + extraction.'
     Fix=@('Delete old builds/extracted dirs in /var/nsinstall and old files in /var/core, /var/crash, /var/nslog (after archiving)',
           'Review /var/ns_sys_backup and remove old system backups',
           'If /var is simply too small, extend the VPX disk (hypervisor) and reboot')
     AutoFixDesc='Removing OLD build-*.tgz and ns-* extracted files from /var/nsinstall'
     AutoFix={ Clear-NodeSpace $script:CurNode } }

  @{ Pattern='SHA256 mismatch|checksum|gzip:|not in gzip format|Unexpected EOF|tar:.*(Error|corrupt)|Damaged'
     Reason='The build file on the node is incomplete or corrupt (interrupted upload or bad download).'
     Fix=@('Re-download the build from the NetScaler downloads page and compare the published SHA256',
           'Check for AV/proxy tampering on the machine running the script',
           'Check network stability between this machine and the NSIP')
     AutoFixDesc='Deleting the bad remote copy so it is re-uploaded'
     AutoFix={ Remove-RemoteBuild $script:CurNode } }

  @{ Pattern='HA sync|hasync|synchroni[sz]ation'
     Reason='Configuration synchronisation between the HA nodes is FAILED or stuck.'
     Fix=@('On the secondary run: force HA sync',
           'Check HA heartbeat interfaces and that both nodes use the same NSROOT password / RPC node password',
           'Check "show ha node" and /var/log/ns.log for sync errors')
     AutoFixDesc='Running "force HA sync" on the node currently in Secondary role'
     AutoFix={ Invoke-ForceHaSync } }

  @{ Pattern='timed out|No route to host|unreachable|actively refused|Connection (refused|reset|closed)|Unable to connect|name or service|task was canceled|socket'
     Reason='Network or management-plane connectivity problem to the NSIP (could be a transient blip, firewall, or node busy).'
     Fix=@('Test: Test-NetConnection <nsip> -Port 22 and -Port 443',
           'Check firewall/ACL between this host and the NSIP; check "set ns ip" management access (ssh/gui enabled)',
           'Check the VM is powered on and has CPU/memory (hypervisor console)')
     AutoFixDesc='Waiting 30 seconds and retrying'
     AutoFix={ Start-Sleep -Seconds 30 } }

  @{ Pattern='401|Unauthorized|Permission denied|Authentication fail|Invalid username|password|Access denied|authenticat'
     Reason='Authentication failed (wrong password, locked account, or key/password method disabled).'
     Fix=@('Verify the nsroot (or superuser) password by logging in manually via SSH',
           'Check "show system user" / account lockout and externalauth (LDAP/TACACS) settings',
           'Ensure the account has superuser/ shell access')
     AutoFix=$null }

  @{ Pattern='secure channel|SSL|TLS|certificate|trust relationship'
     Reason='TLS handshake to the NITRO endpoint failed (old TLS, cipher mismatch or cert policy).'
     Fix=@('Re-run with -UseHttp if management HTTP is allowed in your policy',
           'Run PowerShell 7 (supports -SkipCertificateCheck) or enable TLS1.2 on the client',
           'Check the NSIP management SSL profile / ciphers')
     AutoFix=$null }

  @{ Pattern='Key exchange|No suitable|KEX|host key|algorithm'
     Reason='SSH algorithm/key-exchange mismatch between Posh-SSH and the NetScaler.'
     Fix=@('Update Posh-SSH: Update-Module Posh-SSH',
           'Check the NetScaler SSH config ("show ns sshProfile")')
     AutoFix=$null }

  @{ Pattern='Posh-SSH'
     Reason='The Posh-SSH module is not installed.'
     Fix=@('Install-Module Posh-SSH -Scope CurrentUser -Force', 'Behind a proxy: use Save-Module on another machine and copy it over')
     AutoFix=$null }

  @{ Pattern='Split-brain|No Primary|both.*Primary'
     Reason='The HA pair does not have exactly one Primary.'
     Fix=@('Run "show ha node" on both nodes', 'Fix HA first (heartbeat/VLAN/NSIP reachability), then re-run',
           'Do NOT patch until the pair is healthy')
     AutoFix=$null }

  @{ Pattern='HA not healthy|not UP|hastatus|STAY|INIT|COMPLETEFAIL|DISABLED'
     Reason='One of the HA nodes is not in a healthy UP state, so a rolling upgrade is unsafe.'
     Fix=@('Run "show ha node" on both nodes and clear the cause (heartbeat, failed interface, monitored route)',
           'Check "show ha node" for "Node State" and "Reason for failure"',
           'Wait for sync to finish and retry')
     AutoFix=$null }

  @{ Pattern='Failover did not complete'
     Reason='Force failover did not make the upgraded node Primary (INC mode, monitored interface/route, or sync not complete).'
     Fix=@('Run "show ha node" on both nodes to read failure reason',
           'Check for "set ha node -haStatus STAYPRIMARY/STAYSECONDARY" and clear it',
           'Check HA monitored interfaces/routes on the upgraded node',
           'Retry manually: force HA failover -f')
     AutoFix=$null }

  @{ Pattern='Timeout waiting'
     Reason='The node did not come back (or HA did not reach UP) within the timeout.'
     Fix=@('Open the hypervisor console: look for a boot loop, fsck prompt or "Press any key" menu',
           'Larger configs/ SSL certs can need >15 min first boot; raise -RebootTimeoutMin',
           'If the node is up but old version: installer did not apply - check /var/tmp/ns_patch_install.log and /var/nsinstall',
           'Fallback: boot previous kernel from the boot menu or restore the pre-patch backup in /var/ns_sys_backup')
     AutoFix=$null }

  @{ Pattern='older than|downgrade'
     Reason='The selected build is older than what is installed.'
     Fix=@('Pick a newer build file', 'Downgrades must follow the Citrix downgrade guide - not handled by this script')
     AutoFix=$null }

  @{ Pattern='Installer reported|installns|upgrade path|not supported|Invalid build|license|Installation (failed|aborted)'
     Reason='installns rejected or failed the installation (unsupported upgrade path, wrong build type, licence/platform issue).'
     Fix=@('Read the installer output in the log file (and /var/tmp/ns_patch_install.log on the node)',
           'Verify the supported upgrade path for current version -> target in the release notes',
           'Make sure you downloaded the VPX/NS build (build-*_nc_64.tgz), not a hypervisor image',
           'Check licence/ subscription advisory requirements for the target build')
     AutoFix=$null }
)

function Find-Diagnosis { param([string]$Text)
    foreach ($k in $script:KB) { if ($Text -match $k.Pattern) { return $k } }
    return @{ Reason='Unclassified error.'; AutoFix=$null
             Fix=@("Check the log file: $LogFile", 'Check /var/log/ns.log on the node', 'Re-run with -Verbose; open a Citrix/NetScaler support case with the log') }
}

function Show-Diagnosis { param($Kb, [string]$Err, [string]$Step, [int]$Attempt)
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor Red
    Write-Host (" FAILED  step: {0}   node: {1}   attempt: {2}" -f $Step, $script:CurNode, $Attempt) -ForegroundColor Red
    Write-Host (" Error : {0}" -f $Err) -ForegroundColor Red
    Write-Host (" Likely reason : {0}" -f $Kb.Reason) -ForegroundColor Yellow
    Write-Host ' Suggested actions:' -ForegroundColor Yellow
    $n = 1; foreach ($f in $Kb.Fix) { Write-Host ("   {0}. {1}" -f $n, $f) -ForegroundColor Yellow; $n++ }
    Write-Host ('=' * 78) -ForegroundColor Red
    Write-Log "FAILED [$Step] node=$($script:CurNode) attempt=$Attempt : $Err | Reason: $($Kb.Reason)" 'DEBUG'
}

# =====================================================================
#  STEP ENGINE (progress + retry + auto-fix)
# =====================================================================
function Invoke-Step {
    param([string]$Id, [scriptblock]$Action, [bool]$Skip = $false, [string]$SkipReason = '')
    $step = $script:Steps | Where-Object { $_.Id -eq $Id }
    if (-not $step) { return }
    $script:CurStep = $step
    $sw = [Diagnostics.Stopwatch]::StartNew()

    if ($Skip) {
        Show-Progress "Skipping '$($step.Name)': $SkipReason" 1
        $script:CompletedWeight += $step.Weight
        $script:Results += [pscustomobject]@{ Step=$step.Name; Status='SKIPPED'; Time='00:00'; Note=$SkipReason }
        return
    }

    $attempt = 0; $note = ''
    while ($true) {
        $attempt++
        try {
            Show-Progress "Starting: $($step.Name)" 0
            & $Action
            break
        } catch {
            $err = $_.Exception.Message
            $kb  = Find-Diagnosis $err
            Show-Diagnosis $kb $err $step.Name $attempt
            if ($kb.AutoFix -and -not $NoAutoFix -and $attempt -le $MaxRetries) {
                Write-Host (" AUTO-FIX ({0}/{1}): {2}" -f $attempt, $MaxRetries, $kb.AutoFixDesc) -ForegroundColor Green
                try { & $kb.AutoFix; $note += "autofix:$($kb.AutoFixDesc); "; continue }
                catch { Write-Log "Auto-fix itself failed: $($_.Exception.Message)" 'ERROR' }
            }
            $script:Results += [pscustomobject]@{ Step=$step.Name; Status='FAILED'; Time=$sw.Elapsed.ToString('mm\:ss'); Note=$err }
            throw "Aborted at step '$($step.Name)'"
        }
    }
    $script:CompletedWeight += $step.Weight
    Show-Progress "Completed: $($step.Name)" 1
    $script:Results += [pscustomobject]@{ Step=$step.Name; Status='OK'; Time=$sw.Elapsed.ToString('mm\:ss'); Note=$note.Trim() }
}

# =====================================================================
#  NITRO + SSH HELPERS
# =====================================================================
function Invoke-Nitro {
    param([string]$Ip, [string]$Path, [int]$TimeoutSec = 15)
    $c = $Credential.GetNetworkCredential()
    $p = @{ Uri="${scheme}://$Ip/nitro/v1/$Path"; Method='GET'; TimeoutSec=$TimeoutSec
            Headers=@{ 'X-NITRO-USER'=$c.UserName; 'X-NITRO-PASS'=$c.Password } }
    if ($PSVersionTable.PSVersion.Major -ge 7) { $p.SkipCertificateCheck = $true } else { $p.UseBasicParsing = $true }
    Invoke-RestMethod @p
}

function Get-NodeInfo {
    param([string]$Ip)
    $ha   = @((Invoke-Nitro -Ip $Ip -Path 'config/hanode').hanode)
    $ver  = (Invoke-Nitro -Ip $Ip -Path 'config/nsversion').nsversion.version
    $self = $ha | Where-Object { [string]$_.id -eq '0' }
    $peer = $ha | Where-Object { [string]$_.id -ne '0' } | Select-Object -First 1
    [pscustomobject]@{
        Ip=$Ip; Version=$ver
        Role=$self.state; HAStatus=$self.hastatus; Sync=$self.hasync
        PeerRole=$peer.state; PeerStatus=$peer.hastatus; PeerIp=$peer.ipaddress
    }
}

function New-NsSession { param([string]$Ip)
    New-SSHSession -ComputerName $Ip -Credential $Credential -AcceptKey -ConnectionTimeout 30 -ErrorAction Stop
}
function Use-NsSession { param([string]$Ip, [scriptblock]$Block)
    $s = New-NsSession $Ip
    try { & $Block $s } finally { Remove-SSHSession -SSHSession $s -ErrorAction SilentlyContinue | Out-Null }
}
function Invoke-NsCli {
    param($Session, [string]$Cmd, [int]$Timeout = 120, [switch]$Quiet)
    $r   = Invoke-SSHCommand -SSHSession $Session -Command $Cmd -TimeOut $Timeout -ErrorAction Stop
    $out = @($r.Output)
    if (-not $Quiet -and $out.Count) { Write-Log (($out -join ' | ')) 'DEBUG' }
    if ($Cmd -notlike 'shell*' -and ($out -match '^\s*ERROR')) { throw "NetScaler CLI error on $($Session.Host) for '$Cmd': $($out -join ' ')" }
    $r
}
function Invoke-NsShell { param($Session, [string]$Cmd, [int]$Timeout = 120, [switch]$Quiet)
    Invoke-NsCli -Session $Session -Cmd "shell `"$Cmd`"" -Timeout $Timeout -Quiet:$Quiet
}

# ---- auto-fix helpers ----
function Clear-NodeSpace { param([string]$Ip)
    Use-NsSession $Ip { param($s)
        Invoke-NsShell $s ("find $RemoteDir -maxdepth 1 -name 'build-*' ! -name '$buildName' -exec rm -rf {} + ; " +
                           "find $RemoteDir -maxdepth 1 -name 'ns-*' -exec rm -rf {} + ; rm -f /var/tmp/ns_patch_install.log; echo cleaned") 180 | Out-Null
    }
}
function Remove-RemoteBuild { param([string]$Ip)
    Use-NsSession $Ip { param($s) Invoke-NsShell $s "rm -f $RemoteDir/$buildName; echo removed" 60 | Out-Null }
}
function Invoke-ForceHaSync {
    foreach ($ip in $Node1, $Node2) {
        try {
            $i = Get-NodeInfo $ip
            if ($i.Role -eq 'Secondary') {
                Write-Log "force HA sync on $ip"
                Use-NsSession $ip { param($s) Invoke-NsCli $s 'force HA sync' 120 | Out-Null }
                Start-Sleep -Seconds 45
            }
        } catch { Write-Log "force HA sync skipped on ${ip}: $($_.Exception.Message)" 'WARN' }
    }
}

function Get-RemoteHash { param([string]$Ip)
    Use-NsSession $Ip { param($s)
        $o = (Invoke-NsShell $s "(sha256 $RemoteDir/$buildName || sha256sum $RemoteDir/$buildName) 2>/dev/null; echo END" 900 -Quiet).Output -join ' '
        $o.ToLower()
    }
}

function Send-Build {
    param([string]$Ip, [double]$Base = 0, [double]$Span = 1)
    $script:CurNode = $Ip
    Show-Progress "[$Ip] Checking if build is already staged (SHA256)..." ($Base + 0.05 * $Span)
    if ((Get-RemoteHash $Ip) -match $script:LocalHash) {
        Show-Progress "[$Ip] Build already present with matching SHA256 - no upload needed" ($Base + $Span)
        return
    }
    Show-Progress "[$Ip] Uploading $buildName to ${RemoteDir} (SCP, progress bar shown above)..." ($Base + 0.10 * $Span)
    Set-SCPItem -ComputerName $Ip -Credential $Credential -AcceptKey -Path $BuildFile -Destination $RemoteDir -ProgressVisible -ErrorAction Stop
    Show-Progress "[$Ip] Upload finished, verifying SHA256 on node..." ($Base + 0.85 * $Span)
    if ((Get-RemoteHash $Ip) -notmatch $script:LocalHash) { throw "SHA256 mismatch on $Ip after upload" }
    Show-Progress "[$Ip] Upload verified OK" ($Base + $Span)
}

function Wait-NodeBack {
    param([string]$Ip, [string]$Label, [double]$Base = 0.6, [double]$Span = 0.4)
    $start = Get-Date; $deadline = $start.AddMinutes($RebootTimeoutMin); $nudged = $false
    while ((Get-Date) -lt $deadline) {
        $el   = (Get-Date) - $start
        $frac = $Base + $Span * [math]::Min(0.97, $el.TotalSeconds / ($RebootTimeoutMin * 60))
        $stamp = '{0:mm\:ss}' -f $el
        try { $i = Get-NodeInfo $Ip; $up = $true } catch { $up = $false }
        if (-not $up) {
            Show-Progress "[$Label $Ip] Node is rebooting / booting (unreachable)  elapsed $stamp" $frac -NoHost
            if ($script:LastMsg -ne "[$Label $Ip] Node is rebooting...") { Write-Host "[$Label $Ip] node went down - rebooting..." -ForegroundColor Cyan; $script:LastMsg = "[$Label $Ip] Node is rebooting..." }
        }
        elseif ($i.Version -like "*Build $TargetBuild*") {
            if ($i.HAStatus -eq 'UP') {
                Show-Progress "[$Label $Ip] Back online on $($i.Version) | HA $($i.HAStatus) | Role $($i.Role) | Sync $($i.Sync)" 1
                return $i
            }
            Show-Progress "[$Label $Ip] New version running, waiting for HA UP (now '$($i.HAStatus)')  elapsed $stamp" $frac -NoHost
        }
        else {
            Show-Progress "[$Label $Ip] Still on old version, waiting for reboot to begin  elapsed $stamp" $frac -NoHost
            if ($script:InstallerFinished[$Ip] -and -not $nudged -and $el.TotalMinutes -gt 4) {
                $nudged = $true
                Write-Host " AUTO-FIX: installer finished but node did not reboot - issuing 'reboot -w'" -ForegroundColor Green
                try { Use-NsSession $Ip { param($s) Invoke-NsCli $s 'reboot -w' 30 | Out-Null } } catch { }
            }
        }
        Start-Sleep -Seconds 15
    }
    throw "Timeout waiting for $Ip ($Label) to return on build $TargetBuild within $RebootTimeoutMin min"
}

function Install-OnNode {
    param([string]$Ip, [string]$Label)
    $script:CurNode = $Ip
    $info = Get-NodeInfo $Ip
    if ($info.Version -like "*Build $TargetBuild*") {
        Show-Progress "[$Label $Ip] Already on target build - nothing to do" 1; return
    }
    Send-Build -Ip $Ip -Base 0 -Span 0.05          # idempotent re-check (also re-uploads if autofix removed it)
    $log = '/var/tmp/ns_patch_install.log'
    $script:InstallerFinished[$Ip] = $false
    $errRx = '(?i)(installation\s+(failed|aborted)|not enough (disk )?space|no space left|upgrade path|not supported|invalid build|corrupt|gzip:.*(error|not in)|tar:.*(error|unexpected)|cannot )'
    $okRx  = '(?i)(installation has completed|rebooting|reboot)'

    $s = New-NsSession $Ip
    try {
        Show-Progress "[$Label $Ip] Extracting build and launching installns -y in background..." 0.07
        Invoke-NsShell $s "rm -f $log; cd $RemoteDir && nohup sh -c 'tar -zxf $buildName && ./installns -y' > $log 2>&1 < /dev/null &" 60 | Out-Null
        $t0 = Get-Date; $expectSec = 600
        while ($true) {
            Start-Sleep -Seconds 10
            $tail = $null
            try {
                if (-not $s.Session.IsConnected) { throw 'dropped' }
                $tail = (Invoke-NsShell $s "tail -n 6 $log" 30 -Quiet).Output -join "`n"
            } catch { Write-Log "[$Ip] SSH session closed (node is rebooting)"; $script:InstallerFinished[$Ip] = $true; break }
            $last = ($tail -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
            if ($tail -match $errRx) { throw "Installer reported a failure on ${Ip}: $(($tail -split "`n" | Where-Object { $_ -match $errRx } | Select-Object -First 1))" }
            $frac = 0.10 + 0.50 * [math]::Min(0.98, ((Get-Date) - $t0).TotalSeconds / $expectSec)
            if ($last) { Show-Progress "[$Label $Ip] installer: $last" $frac }
            if ($tail -match $okRx) { Write-Log "[$Ip] installer finished, node going down for reboot"; $script:InstallerFinished[$Ip] = $true; break }
            if (((Get-Date) - $t0).TotalMinutes -gt 30) { throw "Installer reported no completion after 30 min on $Ip" }
        }
    } finally { Remove-SSHSession -SSHSession $s -ErrorAction SilentlyContinue | Out-Null }
    Wait-NodeBack -Ip $Ip -Label $Label | Out-Null
}

function Invoke-Failover {
    param([string]$From, [string]$To)
    $script:CurNode = $From
    $cur = Get-NodeInfo $To
    if ($cur.Role -eq 'Primary') { Show-Progress "$To is already Primary - failover not needed" 1; return }
    if ($cur.HAStatus -ne 'UP')  { throw "HA not healthy: $To status is '$($cur.HAStatus)', refusing to failover" }
    Show-Progress "Forcing failover on $From (so $To becomes Primary)..." 0.25
    Use-NsSession $From { param($s) Invoke-NsCli $s 'force HA failover -f' 60 | Out-Null }
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt 180) {
        Start-Sleep -Seconds 8
        try { $n = Get-NodeInfo $To
              Show-Progress "Waiting for $To to take over (role: $($n.Role))..." (0.4 + 0.5 * [math]::Min(1, ((Get-Date) - $t0).TotalSeconds / 180)) -NoHost
              if ($n.Role -eq 'Primary') { Show-Progress "$To is now Primary" 1; return } } catch { }
    }
    throw "Failover did not complete: $To is not Primary after 180s"
}

# =====================================================================
#  MAIN
# =====================================================================
$exit = 0
Write-Host ''
Write-Host "NetScaler HA pair patching  |  ticket $ChangeTicket  |  log: $LogFile" -ForegroundColor White
try {
    $buildName = Split-Path $BuildFile -Leaf
    if ($buildName -notmatch '^build-(?<rel>\d+\.\d+)-(?<bld>\d+\.\d+)_nc(_64)?\.tgz$') {
        throw "Unexpected build file name '$buildName' (expected like build-14.1-73.58_nc_64.tgz)"
    }
    $TargetRelease = $Matches['rel']; $TargetBuild = $Matches['bld']

    # ---------------- PRE ----------------
    Invoke-Step 'PRE' {
        Show-Progress 'Checking Posh-SSH module' 0.05
        if (-not (Get-Module -ListAvailable -Name Posh-SSH)) { throw 'Posh-SSH module is not installed' }
        Import-Module Posh-SSH -ErrorAction Stop

        Show-Progress "Reading HA state from $Node1 and $Node2 (NITRO)" 0.15
        $script:CurNode = $Node1; $i1 = Get-NodeInfo $Node1
        $script:CurNode = $Node2; $i2 = Get-NodeInfo $Node2
        Write-Log "$Node1 : $($i1.Version) | Role $($i1.Role) | HA $($i1.HAStatus) | Sync $($i1.Sync)"
        Write-Log "$Node2 : $($i2.Version) | Role $($i2.Role) | HA $($i2.HAStatus) | Sync $($i2.Sync)"

        if ($i1.Role -eq 'Primary' -and $i2.Role -eq 'Primary') { throw 'Split-brain: both nodes report Primary' }
        if ($i1.Role -ne 'Primary' -and $i2.Role -ne 'Primary') { throw 'No Primary node found in the pair' }
        $script:NodeB = if ($i1.Role -eq 'Primary') { $Node1 } else { $Node2 }   # original primary
        $script:NodeA = if ($script:NodeB -eq $Node1) { $Node2 } else { $Node1 } # original secondary
        Show-Progress "Roles: Primary=$($script:NodeB)  Secondary=$($script:NodeA)" 0.3

        foreach ($i in $i1, $i2) {
            $script:CurNode = $i.Ip
            if ($i.HAStatus -ne 'UP') { throw "HA not healthy: $($i.Ip) hastatus is '$($i.HAStatus)'" }
            if ($i.Sync -match 'FAIL') { throw "HA sync FAILED on $($i.Ip) (hasync=$($i.Sync))" }
        }

        Show-Progress 'Checking target build vs installed build' 0.45
        foreach ($i in $i1, $i2) {
            $script:Need[$i.Ip] = ($i.Version -notlike "*Build $TargetBuild*")
            if ($i.Version -match 'NS(\d+\.\d+): Build (\d+\.\d+)') {
                if ($Matches[1] -eq $TargetRelease -and ([version]$Matches[2] -gt [version]$TargetBuild)) {
                    throw "Target build $TargetBuild is older than installed $($Matches[2]) on $($i.Ip) (downgrade not supported)"
                }
                if ($Matches[1] -ne $TargetRelease) { Write-Log "Release change $($Matches[1]) -> $TargetRelease : verify the supported upgrade path" 'WARN' }
            }
        }
        if (-not ($script:Need.Values -contains $true)) { Write-Log 'Both nodes already on target build.' 'WARN' }

        $n = 0
        foreach ($ip in $Node1, $Node2) {
            $script:CurNode = $ip
            Show-Progress "[$ip] Checking free space on /var..." (0.55 + 0.4 * $n / 2); $n++
            $free = Use-NsSession $ip { param($s)
                $line = ((Invoke-NsShell $s 'df -m /var | tail -1' 30 -Quiet).Output -join ' ').Trim() -split '\s+'
                [int]($line[3] -replace '\D', '')
            }
            Write-Log "[$ip] /var free: $free MB"
            if ($free -lt $MinFreeMB) { throw "Low disk space on ${ip}: $free MB free on /var (need >= $MinFreeMB MB)" }
        }
    }

    if ($PreCheckOnly) { Write-Host "`nPreCheckOnly: all checks passed, no changes were made." -ForegroundColor Green; return }

    # ---------------- BACKUP ----------------
    Invoke-Step 'BACKUP' {
        $name = 'pre_patch_{0}_{1:yyyyMMdd_HHmm}' -f ($ChangeTicket -replace '[^\w-]', '_'), (Get-Date)
        $k = 0
        foreach ($ip in $script:NodeA, $script:NodeB) {
            $script:CurNode = $ip
            Show-Progress "[$ip] Saving running config (save ns config)..." ($k * 0.5 + 0.05)
            Use-NsSession $ip { param($s) Invoke-NsCli $s 'save ns config' 120 | Out-Null }
            Show-Progress "[$ip] Creating full system backup $name (can take a few minutes)..." ($k * 0.5 + 0.20)
            Use-NsSession $ip { param($s) Invoke-NsCli $s "create system backup $name -level full" 900 | Out-Null }
            Show-Progress "[$ip] Backup $name.tgz stored in /var/ns_sys_backup" ($k * 0.5 + 0.50)
            $k++
        }
    }

    # ---------------- UPLOAD ----------------
    $needAny = ($script:Need.Values -contains $true)
    Invoke-Step 'UPLOAD' -Skip (-not $needAny) -SkipReason 'both nodes already on target' {
        Show-Progress 'Computing local SHA256 of build file...' 0.02
        $script:LocalHash = (Get-FileHash -Path $BuildFile -Algorithm SHA256).Hash.ToLower()
        Write-Log "Local SHA256: $($script:LocalHash)"
        $nodes = @($script:NodeA, $script:NodeB) | Where-Object { $script:Need[$_] }
        $k = 0
        foreach ($ip in $nodes) {
            Send-Build -Ip $ip -Base (0.05 + 0.95 * $k / $nodes.Count) -Span (0.95 / $nodes.Count); $k++
        }
    }
    if (-not $script:LocalHash) { $script:LocalHash = (Get-FileHash -Path $BuildFile -Algorithm SHA256).Hash.ToLower() }

    # ---------------- INSTALL SECONDARY ----------------
    Invoke-Step 'INST_A' -Skip (-not $script:Need[$script:NodeA]) -SkipReason 'secondary already on target' {
        Install-OnNode -Ip $script:NodeA -Label 'SECONDARY'
    }

    # ---------------- FAILOVER ----------------
    Invoke-Step 'FAILOVER' -Skip (-not $script:Need[$script:NodeB]) -SkipReason 'primary already on target (no failover needed)' {
        Invoke-Failover -From $script:NodeB -To $script:NodeA
    }

    # ---------------- INSTALL OLD PRIMARY ----------------
    Invoke-Step 'INST_B' -Skip (-not $script:Need[$script:NodeB]) -SkipReason 'old primary already on target' {
        Install-OnNode -Ip $script:NodeB -Label 'OLD-PRIMARY'
    }

    # ---------------- VERIFY ----------------
    Invoke-Step 'VERIFY' {
        $k = 0
        foreach ($ip in $Node1, $Node2) {
            $script:CurNode = $ip
            $t0 = Get-Date
            while ($true) {
                $i = Get-NodeInfo $ip
                Show-Progress "[$ip] $($i.Version) | Role $($i.Role) | HA $($i.HAStatus) | Sync $($i.Sync)" (0.1 + 0.4 * $k)
                if ($i.Version -notlike "*Build $TargetBuild*") { throw "Installer reported success but $ip is on '$($i.Version)'" }
                if ($i.HAStatus -ne 'UP') { throw "HA not healthy: $ip hastatus '$($i.HAStatus)'" }
                if ($i.Sync -match 'FAIL') { throw "HA sync FAILED on $ip (hasync=$($i.Sync))" }
                if ($i.Sync -match 'PROGRESS' -and ((Get-Date) - $t0).TotalMinutes -lt 5) { Start-Sleep 15; continue }
                if ($i.Sync -match 'PROGRESS') { throw "HA sync still IN PROGRESS on $ip after 5 min" }
                break
            }
            $k++
        }
        $r = @(Get-NodeInfo $Node1; Get-NodeInfo $Node2) | ForEach-Object { $_.Role }
        if (($r | Where-Object { $_ -eq 'Primary' }).Count -ne 1) { throw 'Split-brain: pair does not have exactly one Primary after upgrade' }
        Show-Progress 'Both nodes on target build, HA UP, exactly one Primary' 1
    }

    # ---------------- FAILBACK ----------------
    if ($FailBack) {
        Invoke-Step 'FAILBACK' -Skip (-not $needAny) -SkipReason 'nothing was patched' {
            Invoke-Failover -From $script:NodeA -To $script:NodeB
        }
    }

    # ---------------- CLEANUP ----------------
    if ($CleanupBuild) {
        Invoke-Step 'CLEANUP' {
            foreach ($ip in $Node1, $Node2) {
                $script:CurNode = $ip
                Show-Progress "[$ip] Removing $buildName and extracted files from $RemoteDir" 0.5
                Use-NsSession $ip { param($s)
                    Invoke-NsShell $s "rm -rf $RemoteDir/$buildName $RemoteDir/ns-* $RemoteDir/installns /var/tmp/ns_patch_install.log; echo done" 120 | Out-Null }
            }
        }
    }
}
catch {
    $exit = 1
    Write-Log "RUN ABORTED: $($_.Exception.Message)" 'ERROR'
}
finally {
    Write-Progress -Activity 'NetScaler HA patching' -Completed
    Write-Host ''
    Write-Host ('-' * 78)
    Write-Host ' SUMMARY' -ForegroundColor White
    $script:Results | Format-Table Step, Status, Time, Note -AutoSize -Wrap | Out-String | Write-Host
    if ($exit -eq 0 -and -not $PreCheckOnly) {
        foreach ($ip in $Node1, $Node2) {
            try { $f = Get-NodeInfo $ip; Write-Host (" {0,-16} {1} | {2} | HA {3} | Sync {4}" -f $ip, $f.Version, $f.Role, $f.HAStatus, $f.Sync) -ForegroundColor Green } catch { }
        }
    }
    if ($exit -ne 0) {
        Write-Host ' RESULT : FAILED - see diagnosis above. Nodes may be in a mixed-version HA state (supported during upgrade).' -ForegroundColor Red
        Write-Host ' Roll-forward : fix the cause and re-run the same command (completed nodes/steps are detected and skipped).' -ForegroundColor Yellow
        Write-Host ' Roll-back    : restore from /var/ns_sys_backup or boot the previous kernel from the boot menu (hypervisor console).' -ForegroundColor Yellow
    } else {
        Write-Host ' RESULT : SUCCESS' -ForegroundColor Green
    }
    Write-Host (" Elapsed: {0:hh\:mm\:ss}   Log: {1}" -f $script:Clock.Elapsed, $LogFile)
    Write-Host ('-' * 78)
}
exit $exit
