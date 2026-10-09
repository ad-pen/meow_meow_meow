# windows.ps1 - PSUT VAPT Team, Windows box setup for CPTC engagements.
#
# WHAT THIS BOX IS FOR. Read this before adding anything.
# We do not run active testing from Windows. Its two jobs are:
#   1. BloodHound graph viewing - fully local, generates no traffic to the client.
#   2. Occasional dynamic mobile work (Burp as the intercepting proxy).
# Everything offensive runs from Kali. The Windows PAYLOADS (mimikatz, Rubeus,
# PowerView, the potatoes) are NOT installed here - they live in
# ~/dropzone/windows on Kali and get served to compromised targets over HTTP/SMB.
# all.sh builds that set. Do not duplicate it onto this box.
#
# BLOODHOUND IS INTENTIONALLY THE LEGACY 4.3.1 EDITION, NOT CE.
# BloodHound CE is a Docker Compose stack, and its only documented Windows install
# path is Docker Desktop - which is unsupported on every edition of Windows Server.
# The CPTC VDI ships Windows Server, so CE cannot run here at all. Legacy 4.3.1 is
# therefore the only option for an on-box viewer, and that choice propagates:
#   this box (legacy 4.3.1)  <-  bloodhound-python / SharpHound 1.x   [LEGACY format]
#   Kali     (CE 9.x)        <-  bloodhound-ce-python / SharpHound 2.x [CE format]
# The two formats CANNOT be mixed - a legacy collection fails at ingest into CE and
# vice versa. all.sh installs both collectors and keeps them in separate directories
# for exactly this reason. Neo4j is pinned to 4.4.19 because that is the version
# BloodHound 4.3.1's own release notes name, and because Neo4j 5.x has a severe
# ingest performance regression with BloodHound (Kali downgraded 5.2 -> 4.4 over it).
#
# ============================== NEEDS INTERNET ==============================
# Chocolatey and every download below reach the public internet. On an isolated
# engagement network this script does nothing useful. RUN IT DURING PREP, while
# egress still exists - not on engagement morning.
# ============================================================================
#
# Usage (elevated PowerShell):
#   powershell -ep bypass
#   .\windows.ps1
#
# Switches:
#   -SkipDefender    leave Defender and the firewall alone
#   -SkipBloodHound  skip Java + Neo4j + BloodHound (mobile-only box)

[CmdletBinding()]
param(
    [switch]$SkipDefender,
    [switch]$SkipBloodHound
)

$ErrorActionPreference = 'Continue'

# GitHub and the Neo4j CDN refuse the default TLS on an older Server build, which
# makes every download below fail with an unhelpful "could not create SSL/TLS
# secure channel". Force 1.2 before touching the network.
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Write-Status  { param($m) Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok      { param($m) Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red }

$script:Pass = 0
$script:Fail = 0

Write-Host ""
Write-Host "+-------------------------------------------------------+" -ForegroundColor Green
Write-Host "|     PSUT VAPT Team - Windows Box Setup                |" -ForegroundColor Green
Write-Host "+-------------------------------------------------------+" -ForegroundColor Green
Write-Host ""

# --- elevation -------------------------------------------------------------
if (-NOT ([Security.Principal.WindowsPrincipal] `
          [Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warn "This script needs elevated privileges."
    Write-Warn "Re-run it from an Administrator PowerShell."
    exit 1
}
Write-Ok "Running elevated"

$Transcript = Join-Path $env:USERPROFILE "windows_install.log"
try { Start-Transcript -Path $Transcript -Append -ErrorAction Stop | Out-Null }
catch { Write-Warn "Could not start a transcript - continuing without one" }

# ---------------------------------------------------------------------------
# PIN MANIFEST
# ---------------------------------------------------------------------------
# Same contract as lib.sh on the Kali side: every third-party artifact in one
# place, with the version we intend and the sha256 we expect. "TBD" means
# UNVERIFIED - do not guess one, a wrong hash is worse than no hash.
#
# All three hashes were computed on 2026-10-09 from a direct download on a Linux
# box with no antivirus in the path, and each file was validated before it was
# hashed: byte count equal to the server's Content-Length, both zips pass an
# integrity test, and Snaffler.exe begins MZ. They were deliberately NOT taken
# from a pins.lock produced by a Windows run - Get-Pinned could record the hash of
# a quarantined or truncated file, so harvesting hashes from its own output would
# bake the bug in permanently.
#
# This table DUPLICATES lib.sh's idea rather than sharing it, because PowerShell
# cannot source a bash file. Keep them conceptually in step; nothing enforces it.
# Every URL here was confirmed to resolve on 2026-10-05.
$Pins = @{
    bloodhound_legacy = @{
        Url     = 'https://github.com/SpecterOps/BloodHound-Legacy/releases/download/v4.3.1/BloodHound-win32-x64.zip'
        Version = 'v4.3.1'
        Sha256  = '5c560a9be9b74ebc5a006a808c82813eeb5c7d7dcff5d1c34be4fb1fba562535'
        # NOTE: the old repo pointed at BloodHoundAD/BloodHound, which SpecterOps
        # has since renamed/archived to BloodHound-Legacy. The old URL is dead.
    }
    neo4j = @{
        Url     = 'https://dist.neo4j.org/neo4j-community-4.4.19-windows.zip'
        Version = '4.4.19'
        Sha256  = '462126a7ed4578e1d4ca6bbedb8e9ee83c0a11439fbb924eadb54716c8d79f5e'
        # 4.4.19 is NOT arbitrary: BloodHound 4.3.1's release notes pin it, and
        # Neo4j 5.x regresses BloodHound ingest badly. Do not "upgrade" this, and
        # do not install neo4j from Chocolatey - that package tracks 5.x.
    }
    snaffler = @{
        Url     = 'https://github.com/SnaffCon/Snaffler/releases/download/1.0.244/Snaffler.exe'
        Version = '1.0.244'
        Sha256  = '397b22a956545ba9cd5f03f0f61cb16e4760db21be97f979a5cfc059c2f854ca'
    }
}

$PinsLock = Join-Path $env:USERPROFILE "pins.lock"

function Get-Pinned {
    <#  Download a manifest artifact, verify it against the pinned sha256 when the
        manifest has one, and record what actually landed in ~/pins.lock. Diff that
        file between two operators' boxes - any difference is a build that will not
        reproduce. Idempotent: an existing non-empty destination is left alone. #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Destination
    )
    $pin = $Pins[$Name]
    if (-not $pin) { Write-Err "Get-Pinned: no manifest entry for '$Name'"; return $false }

    if ((Test-Path $Destination) -and (Get-Item $Destination).Length -gt 0) {
        Write-Ok "$(Split-Path $Destination -Leaf) already present (skip)"
        return $true
    }

    # TWO ATTEMPTS, and the partial file is DELETED between them. Both halves
    # matter. GitHub and the Neo4j CDN are a 108 MB and a 116 MB fetch here, and
    # on the Kali side a transient mirror fault cost us a package in three of
    # seven end-to-end runs - there is no reason to think Windows is luckier.
    # Deleting the partial is what stops the failure becoming permanent: the skip
    # check above only asks "does a non-empty file exist", so a half-written zip
    # left behind would be reported "already present (skip)" on every future run
    # and the operator would never get a complete one.
    $ok = $false
    foreach ($attempt in 1..2) {
        if ($attempt -gt 1) { Write-Warn "retrying $Name (attempt $attempt of 2)..." }
        else { Write-Status "Downloading $Name ($($pin.Version)) ..." }
        try {
            Invoke-WebRequest -Uri $pin.Url -OutFile $Destination -UseBasicParsing -ErrorAction Stop
            $ok = $true
            break
        } catch {
            Write-Err "download failed: $Name - $($_.Exception.Message)"
            Remove-Item $Destination -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $ok) { return $false }

    # THE FILE CAN BE GONE EVEN THOUGH THE DOWNLOAD "SUCCEEDED". Defender
    # quarantines on write, so Invoke-WebRequest returns cleanly and the file is
    # then removed under us. This was observed on a real run: BloodHound.zip and
    # Snaffler.exe were both quarantined, this function reported SUCCESS, and the
    # caller failed later at Expand-Archive with an unrelated-looking .ctor error.
    # Without this guard the rest of the function compounds it - Get-FileHash on a
    # missing path yields $null, $null.ToLower() errors but does not stop the
    # script ($ErrorActionPreference is Continue), a NULL hash gets written to
    # pins.lock as though it were a real record, and 'return $true' is still
    # reached. One wrong answer became three.
    if (-not (Test-Path $Destination) -or
        (Get-Item $Destination -ErrorAction SilentlyContinue).Length -eq 0) {
        Write-Err "$Name vanished after a successful download - antivirus quarantine?"
        Write-Err "  Expected it at: $Destination"
        Write-Err "  Check the Defender status reported above, then re-run."
        return $false
    }

    # Null-safe even so: if Get-FileHash fails for any other reason we must not
    # fall through and write an empty hash into the manifest.
    $hash = Get-FileHash -Path $Destination -Algorithm SHA256 -ErrorAction SilentlyContinue
    if (-not $hash) {
        Write-Err "$Name could not be hashed - not recording it: $Destination"
        return $false
    }
    $got = $hash.Hash.ToLower()

    if ($pin.Sha256 -eq 'TBD') {
        Write-Warn "$Name fetched UNVERIFIED (version $($pin.Version), sha256 $($got.Substring(0,16))...)"
    } elseif ($got -eq $pin.Sha256.ToLower()) {
        Write-Ok "$Name verified against pinned sha256"
    } else {
        Write-Err "$Name SHA256 MISMATCH"
        Write-Err "  expected $($pin.Sha256)"
        Write-Err "  got      $got"
        Write-Err "  Do NOT use this file until you know why: $Destination"
        return $false
    }
    "{0}`t{1}`t{2}`t{3}" -f (Get-Date -Format s), $Name, $pin.Version, $got |
        Add-Content -Path $PinsLock
    return $true
}

# ---------------------------------------------------------------------------
# Defender + firewall
# ---------------------------------------------------------------------------
# Why this is here: this box stores and handles offensive tooling, and Defender
# quarantines files like SharpHound on write, which silently breaks a collection
# mid-engagement. The firewall rule is so a listener on this box is reachable from
# our own Kali hosts.
#
# This box does not touch the client, so nothing here is a change to the client's
# environment. It IS a change to a machine the organisers provided, so the
# pre-change state is recorded to disk before anything is altered - that file is
# what makes the change reversible and is what to quote on the Artifact &
# Configuration Changes sheet.
if ($SkipDefender) {
    Write-Status "-SkipDefender given - leaving Defender and the firewall alone"
} else {
    Write-Status "Recording pre-change Defender/firewall state..."
    $stateFile = Join-Path $env:USERPROFILE "pre-change-security-state.txt"
    try {
        "=== Get-MpComputerStatus $(Get-Date -Format s) ===" | Set-Content $stateFile
        Get-MpComputerStatus | Out-String | Add-Content $stateFile
        "=== Get-NetFirewallProfile ===" | Add-Content $stateFile
        Get-NetFirewallProfile | Select-Object Name,Enabled | Out-String | Add-Content $stateFile
        Write-Ok "Pre-change state saved to $stateFile"
    } catch {
        Write-Warn "Could not record pre-change state: $($_.Exception.Message)"
    }

    Write-Status "Disabling Defender real-time monitoring and the firewall..."
    try {
        Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
    } catch {
        Write-Warn "Could not disable Defender RTM: $($_.Exception.Message)"
    }

    # READ IT BACK. Set-MpPreference RETURNS SUCCESS AND SILENTLY DOES NOTHING
    # when Tamper Protection is enabled - it is not an error, so -ErrorAction Stop
    # and the catch above never fire. On a real run this printed "[+] Defender
    # real-time monitoring disabled" and then Defender quarantined two downloads
    # anyway. Asking the service what its state actually is costs one cmdlet, and
    # Get-MpComputerStatus is already called a few lines above for the pre-change
    # record. Same rule as the Kali side: prove it worked, do not assume it did.
    $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if (-not $mp) {
        Write-Warn "Could not read Defender status back - treat RTM as UNKNOWN"
    } elseif ($mp.RealTimeProtectionEnabled) {
        Write-Err "Defender real-time monitoring is STILL ON (IsTamperProtected=$($mp.IsTamperProtected))"
        Write-Err "  Tamper Protection cannot be turned off from PowerShell - it is GUI only:"
        Write-Err "  Windows Security > Virus & threat protection > Manage settings > Tamper Protection"
        Write-Err "  DOWNLOADS BELOW WILL BE QUARANTINED. Turn it off and re-run this script."
    } else {
        Write-Ok "Defender real-time monitoring disabled (confirmed by Get-MpComputerStatus)"
    }

    # Separate switches from RTM, and they were still active on the failed run.
    # SubmitSamplesConsent matters most: left at its default, Defender uploads
    # samples of our tooling to Microsoft for analysis. Non-fatal - a box where
    # these do not apply is still usable.
    try { Set-MpPreference -SubmitSamplesConsent NeverSend -ErrorAction Stop
          Write-Ok "Sample submission set to NeverSend" }
    catch { Write-Warn "Could not set SubmitSamplesConsent: $($_.Exception.Message)" }

    try { Set-MpPreference -MAPSReporting Disabled -ErrorAction Stop
          Write-Ok "MAPS cloud reporting disabled" }
    catch { Write-Warn "Could not set MAPSReporting: $($_.Exception.Message)" }

    try { Set-MpPreference -DisableBlockAtFirstSeen $true -ErrorAction Stop
          Write-Ok "Block-at-first-seen disabled" }
    catch { Write-Warn "Could not set DisableBlockAtFirstSeen: $($_.Exception.Message)" }
    try {
        Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False -ErrorAction Stop
        Write-Ok "Firewall disabled on all three profiles"
    } catch {
        Write-Warn "Could not disable the firewall: $($_.Exception.Message)"
    }
    Write-Warn "To restore:  Set-MpPreference -DisableRealtimeMonitoring `$false"
    Write-Warn "             Set-MpPreference -SubmitSamplesConsent AlwaysPrompt -MAPSReporting Advanced"
    Write-Warn "             Set-MpPreference -DisableBlockAtFirstSeen `$false"
    Write-Warn "             Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True"
    Write-Warn "  Pre-change values are in $stateFile - that file is the record for the"
    Write-Warn "  Artifact & Configuration Changes sheet."
}

# ---------------------------------------------------------------------------
# Chocolatey + packages
# ---------------------------------------------------------------------------
if (Get-Command choco -ErrorAction SilentlyContinue) {
    Write-Ok "Chocolatey already installed"
} else {
    Write-Status "Installing Chocolatey..."
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString(
            'https://community.chocolatey.org/install.ps1'))
        Write-Ok "Chocolatey installed"
    } catch {
        Write-Err "Chocolatey install failed: $($_.Exception.Message)"
        Write-Err "Everything below depends on it. Check egress and re-run."
    }
}

# Refresh PATH in-process so choco is callable without reopening the shell.
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path','User')

# burp-suite-free-edition is Burp COMMUNITY. Burp Pro is banned by the rules;
# do not swap this for the pro package.
$ChocoPkgs = @('openssh','burp-suite-free-edition','git','flameshot','greenshot')
if (-not $SkipBloodHound) {
    # Neo4j 4.4 runs on Java 11 or 17. Pin 11 - it is what BloodHound 4.3.1 was
    # tested against, and Chocolatey's 'neo4j-community' is deliberately NOT used
    # here because it tracks 5.x (see the pin manifest note).
    $ChocoPkgs += 'temurin11'
}

if (Get-Command choco -ErrorAction SilentlyContinue) {
    # One package at a time, so a single failure is reported and skipped instead
    # of taking the whole batch with it. Same reasoning as apt_install in lib.sh.
    $failed = @()
    foreach ($pkg in $ChocoPkgs) {
        Write-Status "choco install $pkg"
        choco install $pkg -y --no-progress | Out-Null
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 1641 -or $LASTEXITCODE -eq 3010) {
            Write-Ok "$pkg installed"
        } else {
            Write-Warn "$pkg FAILED (choco exit $LASTEXITCODE)"
            $failed += $pkg
        }
    }
    # REFRESH PATH AGAIN, AFTER the loop. The refresh above runs before anything
    # is installed - it is there so 'choco' itself is callable right after a fresh
    # Chocolatey install - which means every tool installed in this loop is absent
    # from the in-process PATH. On a real run that produced "[+] git installed"
    # followed by "[-] git FAILED" from the verification pass thirty lines later.
    # A false FAIL is worse than no check: it is how people learn to ignore the
    # checker, and then they ignore a true one.
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')

    if ($failed.Count -gt 0) {
        Write-Warn "Chocolatey packages that failed: $($failed -join ', ')"
        Write-Warn "  Retry: choco install $($failed -join ' ') -y"
    }
}

# ---------------------------------------------------------------------------
# Snaffler
# ---------------------------------------------------------------------------
# Share-content hunting. Worth having on a theme-park estate specifically: a flat,
# aging network with an overworked generalist admin is where credentials in share
# files actually live. Single binary, run from Desktop.
$desktop = [Environment]::GetFolderPath('Desktop')

# A OneDrive-redirected Desktop syncs everything written here to Microsoft's
# cloud, which scans it server-side no matter what Defender is told locally. On a
# real run that is where Snaffler.exe went. Worth one check: this is a warning,
# not a blocker, because the provided VDI boxes are domain-joined Server and will
# not hit it - a teammate's own laptop during prep will.
if ($env:OneDrive -and $desktop.StartsWith($env:OneDrive, 'OrdinalIgnoreCase')) {
    Write-Warn "Your Desktop is REDIRECTED INTO ONEDRIVE: $desktop"
    Write-Warn "  Tooling written there syncs to Microsoft and is scanned in the cloud,"
    Write-Warn "  which no local Defender setting can prevent. Expect quarantine."
    Write-Warn "  Pause OneDrive sync, or re-run with -SkipDefender and place tools by hand."
}
Get-Pinned -Name snaffler -Destination (Join-Path $desktop 'Snaffler.exe') | Out-Null

# ---------------------------------------------------------------------------
# BloodHound 4.3.1 (LEGACY) + Neo4j 4.4.19
# ---------------------------------------------------------------------------
if ($SkipBloodHound) {
    Write-Status "-SkipBloodHound given - skipping Java/Neo4j/BloodHound"
} else {
    $Root      = 'C:\BloodHound'
    $Neo4jRoot = Join-Path $Root 'neo4j'
    New-Item -ItemType Directory -Force -Path $Root | Out-Null

    # --- Java ---
    # Neo4j's service wrapper resolves the JVM through JAVA_HOME. temurin11 usually
    # sets it machine-wide, but not always before a reboot, so find it ourselves.
    if (-not $env:JAVA_HOME -or -not (Test-Path (Join-Path $env:JAVA_HOME 'bin\java.exe'))) {
        $jdk = Get-ChildItem 'C:\Program Files\Eclipse Adoptium' -Directory -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -like 'jdk-11*' } |
               Sort-Object Name -Descending | Select-Object -First 1
        if ($jdk) {
            [Environment]::SetEnvironmentVariable('JAVA_HOME', $jdk.FullName, 'Machine')
            $env:JAVA_HOME = $jdk.FullName
            Write-Ok "JAVA_HOME set to $($jdk.FullName)"
        } else {
            Write-Warn "No JDK 11 found under Eclipse Adoptium - Neo4j will not start."
            Write-Warn "  Install it: choco install temurin11 -y   then re-run this script."
        }
    } else {
        Write-Ok "JAVA_HOME already set ($env:JAVA_HOME)"
    }

    # --- Neo4j 4.4.19 ---
    $neoZip = Join-Path $Root 'neo4j.zip'
    if (Test-Path (Join-Path $Neo4jRoot 'bin\neo4j.bat')) {
        Write-Ok "Neo4j already extracted at $Neo4jRoot (skip)"
    } elseif (Get-Pinned -Name neo4j -Destination $neoZip) {
        Write-Status "Extracting Neo4j..."
        try {
            Expand-Archive -Path $neoZip -DestinationPath $Root -Force -ErrorAction Stop
            # The archive unpacks to neo4j-community-<ver>; normalise the path so
            # nothing downstream has to know the version string.
            $inner = Get-ChildItem $Root -Directory |
                     Where-Object { $_.Name -like 'neo4j-community-*' } |
                     Select-Object -First 1
            if ($inner) {
                if (Test-Path $Neo4jRoot) { Remove-Item $Neo4jRoot -Recurse -Force }
                Move-Item $inner.FullName $Neo4jRoot
                Write-Ok "Neo4j extracted -> $Neo4jRoot"
            } else {
                # Not hypothetical: every one of the 201 entries in Neo4j's Windows
                # zip uses a BACKSLASH separator, which the ZIP spec does not allow
                # (BloodHound's archive uses forward slashes like everything else).
                # Windows treats backslash as a separator so Expand-Archive makes
                # real directories, but if that ever stops being true this lookup
                # finds nothing - and it used to say nothing, delete the zip, and
                # let the install-service step fail later for no visible reason.
                Write-Err "Extracted, but no neo4j-community-* directory appeared under $Root"
                Write-Err "  Look at what landed there and move it to $Neo4jRoot by hand."
            }
            Remove-Item $neoZip -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Err "Neo4j extraction failed: $($_.Exception.Message)"
        }
    }

    # --- Neo4j password + service ---
    # set-initial-password only works BEFORE the database first starts, which is
    # why it runs here and not after Start-Service.
    $neoAdmin = Join-Path $Neo4jRoot 'bin\neo4j-admin.bat'
    $neoBat   = Join-Path $Neo4jRoot 'bin\neo4j.bat'
    $credFile = Join-Path $Root 'neo4j-credentials.txt'

    if ((Test-Path $neoAdmin) -and -not (Test-Path $credFile)) {
        # Random, not a team-wide default: this database ends up holding the
        # client's full directory structure.
        Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
        $pw = try { [System.Web.Security.Membership]::GeneratePassword(20,4) }
              catch { -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 20 | ForEach-Object {[char]$_}) }

        Write-Status "Setting the Neo4j initial password..."
        & $neoAdmin set-initial-password $pw 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            "neo4j`t$pw" | Set-Content $credFile
            Write-Ok "Neo4j password set and written to $credFile"
            Write-Warn "BloodHound login -> bolt://localhost:7687   user: neo4j   pass: see $credFile"
        } else {
            Write-Warn "set-initial-password failed (exit $LASTEXITCODE) - the DB may already be initialised"
        }
    } elseif (Test-Path $credFile) {
        Write-Ok "Neo4j credentials already recorded at $credFile (skip)"
    }

    if (Test-Path $neoBat) {
        if (Get-Service -Name neo4j -ErrorAction SilentlyContinue) {
            Write-Ok "Neo4j service already installed"
        } else {
            Write-Status "Installing the Neo4j Windows service..."
            & $neoBat install-service 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Ok "Neo4j service installed" }
            else { Write-Warn "Neo4j install-service failed (exit $LASTEXITCODE) - check JAVA_HOME" }
        }
        try {
            Start-Service neo4j -ErrorAction Stop
            Write-Ok "Neo4j service started"
            # Start-Service returns as soon as the SERVICE is up, but Neo4j takes
            # another 20-40s to open the bolt port. Without this wait the port check
            # in the verification pass below fails on a perfectly good install, and
            # a spurious FAIL is worse than no check - people learn to ignore it.
            Write-Status "Waiting for the bolt port (7687) to open..."
            $deadline = (Get-Date).AddSeconds(90)
            $bolt = $false
            while ((Get-Date) -lt $deadline) {
                if (Get-NetTCPConnection -LocalPort 7687 -State Listen -ErrorAction SilentlyContinue) {
                    Write-Ok "Neo4j is listening on 7687"
                    $bolt = $true
                    break
                }
                Start-Sleep -Seconds 3
            }
            # Say so when the wait runs out. Without this the loop just ends and the
            # only sign is a bare "bolt port FAILED" in the verification block, with
            # nothing saying we waited 90s and gave up.
            if (-not $bolt) {
                Write-Warn "Bolt port 7687 did not open within 90s - BloodHound will not connect"
                Write-Warn "  Check the log: $Neo4jRoot\logs\neo4j.log"
            }
        } catch {
            Write-Warn "Could not start Neo4j: $($_.Exception.Message)"
            Write-Warn "  Try by hand: & '$neoBat' console"
        }
    }

    # --- BloodHound 4.3.1 ---
    $bhZip = Join-Path $Root 'BloodHound.zip'
    if (Test-Path (Join-Path $Root 'BloodHound-win32-x64\BloodHound.exe')) {
        Write-Ok "BloodHound 4.3.1 already extracted (skip)"
    } elseif (Get-Pinned -Name bloodhound_legacy -Destination $bhZip) {
        Write-Status "Extracting BloodHound 4.3.1..."
        try {
            Expand-Archive -Path $bhZip -DestinationPath $Root -Force -ErrorAction Stop
            Write-Ok "BloodHound extracted -> $Root"
            Remove-Item $bhZip -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Err "BloodHound extraction failed: $($_.Exception.Message)"
        }
    }

    $bhExe = Get-ChildItem $Root -Recurse -Filter 'BloodHound.exe' -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if ($bhExe) {
        $lnk = Join-Path $desktop 'BloodHound.lnk'
        try {
            $ws = New-Object -ComObject WScript.Shell
            $sc = $ws.CreateShortcut($lnk)
            $sc.TargetPath = $bhExe.FullName
            $sc.WorkingDirectory = $bhExe.DirectoryName
            $sc.Save()
            Write-Ok "Desktop shortcut created"
        } catch { Write-Warn "Could not create the desktop shortcut" }
    }
}

# ---------------------------------------------------------------------------
# PuTTY scrollback
# ---------------------------------------------------------------------------
# 10k lines instead of the 200-line default. Cheap, and it is the difference
# between having and not having the evidence of a long session.
Write-Status "Raising the PuTTY scrollback limit..."
reg add "HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions\Default%20Settings" `
    /v ScrollbackLines /t REG_DWORD /d 10000 /f | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Ok "PuTTY scrollback set to 10000" }
else { Write-Warn "Could not set the PuTTY scrollback value" }

# ---------------------------------------------------------------------------
# VERIFICATION
# ---------------------------------------------------------------------------
# Same contract as all.sh: prove the thing WORKS, do not just locate it.
Write-Host ""
Write-Status "Verifying..."

function Test-Item {
    param([string]$Desc, [scriptblock]$Check)
    try {
        if (& $Check) { Write-Ok "$Desc verified"; $script:Pass++ }
        else { Write-Err "$Desc FAILED"; $script:Fail++ }
    } catch {
        Write-Err "$Desc FAILED ($($_.Exception.Message))"; $script:Fail++
    }
}

# A download that came back as a captive-portal login page still has a 200 status
# and a plausible size. A real PE starts with "MZ"; that is the cheap tell.
function Test-PE {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    # Read the two magic bytes through .NET rather than Get-Content: the PowerShell
    # way needs -Encoding Byte on 5.1 (what Windows Server ships) and -AsByteStream
    # on 7, so either spelling breaks on the other host. A FileStream works on both.
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $b = New-Object byte[] 2
            if ($fs.Read($b, 0, 2) -ne 2) { return $false }
            return ($b[0] -eq 0x4D -and $b[1] -eq 0x5A)
        } finally { $fs.Dispose() }
    } catch { return $false }
}

Test-Item "Chocolatey"  { [bool](Get-Command choco -ErrorAction SilentlyContinue) }
Test-Item "git"         { [bool](Get-Command git   -ErrorAction SilentlyContinue) }
Test-Item "Burp Community" {
    [bool](Get-ChildItem 'C:\Program Files*\BurpSuiteCommunity*' -ErrorAction SilentlyContinue) -or
    [bool](Get-Command 'BurpSuiteCommunity' -ErrorAction SilentlyContinue)
}
Test-Item "Snaffler.exe (valid PE)" { Test-PE (Join-Path $desktop 'Snaffler.exe') }

if (-not $SkipBloodHound) {
    Test-Item "JDK 11 (java runs)" {
        (& "$env:JAVA_HOME\bin\java.exe" -version 2>&1) -match 'version'
    }
    Test-Item "Neo4j extracted"      { Test-Path 'C:\BloodHound\neo4j\bin\neo4j.bat' }
    Test-Item "Neo4j service exists" { [bool](Get-Service neo4j -ErrorAction SilentlyContinue) }
    Test-Item "Neo4j service running" {
        (Get-Service neo4j -ErrorAction SilentlyContinue).Status -eq 'Running'
    }
    Test-Item "Neo4j bolt port 7687 listening" {
        [bool](Get-NetTCPConnection -LocalPort 7687 -State Listen -ErrorAction SilentlyContinue)
    }
    Test-Item "Neo4j credentials recorded" { Test-Path 'C:\BloodHound\neo4j-credentials.txt' }
    Test-Item "BloodHound.exe (valid PE)" {
        $e = Get-ChildItem 'C:\BloodHound' -Recurse -Filter 'BloodHound.exe' -ErrorAction SilentlyContinue |
             Select-Object -First 1
        $e -and (Test-PE $e.FullName)
    }
}

Write-Host ""
Write-Host "=======================================" -ForegroundColor Green
Write-Host "Verification Summary"                    -ForegroundColor Green
Write-Host "=======================================" -ForegroundColor Green
Write-Host "Passed: $script:Pass" -ForegroundColor Green
Write-Host "Failed: $script:Fail" -ForegroundColor Red
Write-Host ""

if ($script:Fail -eq 0) { Write-Ok "All checks passed." }
else { Write-Warn "$script:Fail check(s) failed - see above and the transcript at $Transcript" }

Write-Host ""
Write-Host "+-------------------------------------------------------+" -ForegroundColor Yellow
Write-Host "|   NEXT STEPS                                          |" -ForegroundColor Yellow
Write-Host "+-------------------------------------------------------+" -ForegroundColor Yellow
Write-Warn "1. Reopen PowerShell so the machine PATH and JAVA_HOME are picked up."
if (-not $SkipBloodHound) {
    Write-Warn "2. Launch BloodHound from the Desktop shortcut."
    Write-Warn "   Login: bolt://localhost:7687  user neo4j  pass in C:\BloodHound\neo4j-credentials.txt"
    Write-Warn "3. FEED IT LEGACY COLLECTIONS ONLY:"
    Write-Warn '     kali$   bloodhound-python ...                  (apt bloodhound.py)'
    Write-Warn '     target> SharpHound.exe   from ~/dropzone/windows/legacy/'
    Write-Warn "   A CE collection (bloodhound-ce-python, SharpHound 2.x, azurehound)"
    Write-Warn "   WILL FAIL TO INGEST here. Those go to BloodHound CE on Kali."
}
Write-Warn "4. Offensive payloads are NOT on this box by design - they live in"
Write-Warn "   ~/dropzone/windows on Kali and are served from there. See all.sh."
if (-not $SkipDefender) {
    Write-Warn "5. Defender RTM and the firewall are OFF. Pre-change state is in"
    Write-Warn "   $env:USERPROFILE\pre-change-security-state.txt - log this on the"
    Write-Warn "   Artifact & Configuration Changes sheet."
}
Write-Host ""
Write-Ok "Setup log: $Transcript"
if (Test-Path $PinsLock) { Write-Status "What this box actually downloaded: $PinsLock" }
Write-Ok "Good Luck!"

try { Stop-Transcript | Out-Null } catch { }
