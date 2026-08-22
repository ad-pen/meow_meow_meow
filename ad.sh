#!/bin/bash

set -u

LOG_FILE="$HOME/ad_install.log"
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
# $HOME/dropzone, so it reported NOT FOUND for tools that had installed fine.
# This never failed in rehearsal because the practice VM's user IS 'kali'.
mkdir -p "$HOME/dropzone" || { print_error "Cannot create $HOME/dropzone"; exit 1; }
cd "$HOME/dropzone" || { print_error "Cannot cd to $HOME/dropzone"; exit 1; }
print_success "Dropzone ready at $HOME/dropzone"

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
    enum4linux impacket-scripts bloodhound.py docker.io bloodhound neo4j \
    certipy-ad evil-winrm responder netexec \
    build-essential python3-dev libffi-dev

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
fin_msg 'Database guidance'



print_status "Cloning Ghostpack compiled binaries..."
if clone_pinned Ghostpack-CompiledBinaries \
        https://github.com/r3motecontrol/Ghostpack-CompiledBinaries \
        "$HOME/dropzone/Ghostpack-CompiledBinaries"; then
    bin_count=$(find "$HOME/dropzone/Ghostpack-CompiledBinaries" -name "*.exe" | wc -l)
    print_success "Ghostpack: $bin_count executables"
    fin_msg 'Ghostpack Compiled Binaries'
fi

print_status "Installing SharpEfsPotato (requires mono for building)..."
if ! command -v mono &> /dev/null; then
    print_status "Installing mono for C# compilation..."
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y mono-complete mono-devel
fi

if [ ! -d "$HOME/dropzone/SharpEfsPotato" ]; then
    if clone_pinned SharpEfsPotato https://github.com/bugch3ck/SharpEfsPotato \
            "$HOME/dropzone/SharpEfsPotato"; then
        cd "$HOME/dropzone/SharpEfsPotato" || print_warning "cd SharpEfsPotato failed - skipping build"
        # '[ -f "*.csproj" ]' was a QUOTED glob: test never expands it, so it looked for
        # a file literally named '*.csproj' and could never match. Dead branch.
        if [ -f "SharpEfsPotato.sln" ] || compgen -G "*.csproj" >/dev/null 2>&1; then
            print_status "Building SharpEfsPotato with mono..."
            if msbuild SharpEfsPotato.sln 2>/dev/null || xbuild SharpEfsPotato.sln 2>/dev/null; then
                print_success "SharpEfsPotato built successfully"
            else
                print_warning "SharpEfsPotato build failed, check $HOME/dropzone/SharpEfsPotato for manual build"
            fi
        fi
        cd "$HOME/dropzone" || exit 1
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
clone_pinned PKINITtools https://github.com/dirkjanm/PKINITtools "$HOME/dropzone/PKINITtools"
pip_ensure minikerberos minikerberos   # usually already present from all.sh; skipped if so
fin_msg 'PKINITtools'

print_status "Installing bloodyAD..."
clone_pinned bloodyAD https://github.com/CravateRouge/bloodyAD.git "$HOME/dropzone/bloodyAD"
if [ -d "$HOME/dropzone/bloodyAD" ]; then
    cd "$HOME/dropzone/bloodyAD" || exit 1
    if pip install -r requirements.txt --break-system-packages; then
        print_success "bloodyAD dependencies installed"
    else
        print_warning "bloodyAD dependencies installation failed"
    fi
    cd "$HOME/dropzone" || exit 1
    fin_msg 'bloodyAD'
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

verify_repo "$HOME/dropzone/Ghostpack-CompiledBinaries" "Ghostpack binaries"
# Rubeus is the one file we can count on being in that repo - prove it is a real
# PE and not an HTML error page or an LFS pointer stub.
if [ -f "$HOME/dropzone/Ghostpack-CompiledBinaries/Rubeus.exe" ]; then
    if head -c 2 "$HOME/dropzone/Ghostpack-CompiledBinaries/Rubeus.exe" | grep -qa "^MZ"; then
        print_success "Rubeus.exe verified (valid PE)"; AD_PASS=$((AD_PASS+1))
    else
        print_error "Rubeus.exe is not a PE file - bad clone"; AD_FAIL=$((AD_FAIL+1))
    fi
fi
verify_repo "$HOME/dropzone/SharpEfsPotato" "SharpEfsPotato"
verify_repo "$HOME/dropzone/bloodyAD" "bloodyAD"
# Running PKINITtools with -h imports minikerberos, so this proves the tool AND
# its dependency in one go - the thing a file-existence check cannot tell you.
verify_cmd "PKINITtools" "python3 $HOME/dropzone/PKINITtools/gettgtpkinit.py -h" "usage|error"

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
echo -e "${YELLOW}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║   IMPORTANT: LOG OUT AND BACK IN (or reboot) NOW       ║${NC}"
echo -e "${YELLOW}╚═══════════════════════════════════════════════════════╝${NC}"
print_warning "A fresh login activates command logging, the uniform terminal look,"
print_warning "docker group access, and PATH for ~/go/bin and ~/.local/bin (nxc, impacket)."

echo ""
print_success "Good Luck!"
