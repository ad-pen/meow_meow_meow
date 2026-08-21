#!/bin/bash

set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="$HOME/ad_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

print_status() {
    echo -e "${BLUE}[*]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[+]${NC} $1"
}

print_error() {
    echo -e "${RED}[-]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

fin_msg(){
    echo -e "\n${GREEN}#################################${NC}"
    echo -e "${GREEN}  $1 DONE${NC}"
    echo -e "${GREEN}#################################${NC}\n"
}

# ---------------------------------------------------------------------------
# Resilient / idempotent install helpers: make re-runs fast and stop one bad
# package from silently sinking a whole batch.
# ---------------------------------------------------------------------------
APT_FAILED=()   # apt packages that failed, reported at the end

# Install apt packages ONE AT A TIME so a single failure is logged and skipped
# instead of aborting the whole 'apt install a b c' transaction. Already-present
# packages are detected with dpkg and skipped without hitting the network.
apt_install() {
    local pkg
    for pkg in "$@"; do
        if dpkg -s "$pkg" &>/dev/null; then
            print_success "$pkg already installed"
        elif sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"; then
            # 'sudo env DEBIAN_FRONTEND=...' is REQUIRED: sudo strips the exported
            # DEBIAN_FRONTEND, so without this, debconf prompts (e.g. neo4j/bloodhound
            # preconfigure) appear and abort the non-interactive install.
            print_success "$pkg installed"
        else
            print_warning "$pkg FAILED to install"
            APT_FAILED+=("$pkg")
        fi
    done
}

# Idempotent pip install: skip entirely if the module already imports, so re-runs
# and cross-script duplicates (minikerberos/pypykatz already come from all.sh)
# don't re-resolve/re-download. $1=import name, rest=pip specs.
pip_ensure() {
    local mod=$1; shift
    if python3 -c "import $mod" &>/dev/null; then
        print_success "python: $mod already present (skip)"
    elif pip install "$@" --break-system-packages; then
        print_success "python: $mod installed"
    else
        print_warning "python: $mod FAILED to install"
    fi
}

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
if [ ! -d "Ghostpack-CompiledBinaries" ]; then
    if git clone https://github.com/r3motecontrol/Ghostpack-CompiledBinaries; then
        bin_count=$(find Ghostpack-CompiledBinaries -name "*.exe" | wc -l)
        print_success "Ghostpack binaries cloned ($bin_count executables)"
        fin_msg 'Ghostpack Compiled Binaries'
    else
        print_warning "Ghostpack binaries clone failed"
    fi
else
    print_success "Ghostpack binaries already exist"
fi

print_status "Installing SharpEfsPotato (requires mono for building)..."
if ! command -v mono &> /dev/null; then
    print_status "Installing mono for C# compilation..."
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y mono-complete mono-devel
fi

if [ ! -d "SharpEfsPotato" ]; then
    if git clone https://github.com/bugch3ck/SharpEfsPotato; then
        print_success "SharpEfsPotato cloned"
        cd SharpEfsPotato || print_warning "cd SharpEfsPotato failed - skipping build"
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
if [ ! -d "PKINITtools" ]; then
    if git clone https://github.com/dirkjanm/PKINITtools; then
        print_success "PKINITtools cloned"
    else
        print_warning "PKINITtools clone failed"
    fi
else
    print_success "PKINITtools already exists"
fi
pip_ensure minikerberos minikerberos   # usually already present from all.sh; skipped if so
fin_msg 'PKINITtools'

print_status "Installing bloodyAD..."
if [ ! -d "bloodyAD" ]; then
    if git clone https://github.com/CravateRouge/bloodyAD.git; then
        print_success "bloodyAD cloned"
    else
        print_warning "bloodyAD clone failed"
    fi
else
    print_success "bloodyAD already exists"
fi
if [ -d "bloodyAD" ]; then
    cd bloodyAD || exit 1
    if pip install -r requirements.txt --break-system-packages; then
        print_success "bloodyAD dependencies installed"
    else
        print_warning "bloodyAD dependencies installation failed"
    fi
    cd "$HOME/dropzone" || exit 1
    fin_msg 'bloodyAD'
fi

print_status "Installing Kerbrute..."
if sudo curl -L https://github.com/ropnop/kerbrute/releases/download/v1.0.3/kerbrute_linux_amd64 -o /usr/local/bin/kerbrute && sudo chmod +x /usr/local/bin/kerbrute; then
    kerbrute_version=$(kerbrute version 2>&1 || echo "installed")
    print_success "Kerbrute installed: $kerbrute_version"
    fin_msg 'Kerbrute'
else
    print_warning "Kerbrute installation failed"
fi

print_status "Installing windapsearch..."
if sudo wget -q https://github.com/ropnop/go-windapsearch/releases/download/v0.3.0/windapsearch-linux-amd64 -O /usr/local/bin/windapsearch && sudo chmod +x /usr/local/bin/windapsearch; then
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
verify_tool() {
    local tool=$1
    if command -v "$tool" &> /dev/null; then
        print_success "$tool verified"
        AD_PASS=$((AD_PASS+1))
    else
        print_error "$tool NOT found"
        AD_FAIL=$((AD_FAIL+1))
    fi
}

verify_file() {
    local file=$1
    local desc=$2
    if [ -e "$file" ]; then
        print_success "$desc verified"
        AD_PASS=$((AD_PASS+1))
    else
        print_error "$desc NOT found"
        AD_FAIL=$((AD_FAIL+1))
    fi
}

# $1 = python module name, $2 = human label
verify_pymod() {
    if python3 -c "import $1" &> /dev/null; then
        print_success "$2 verified"
        AD_PASS=$((AD_PASS+1))
    else
        print_error "$2 NOT working"
        AD_FAIL=$((AD_FAIL+1))
    fi
}

verify_tool "bloodhound"
verify_tool "neo4j"
verify_tool "evil-winrm"
verify_tool "responder"
verify_tool "enum4linux"
verify_tool "kerbrute"
verify_tool "windapsearch"
verify_tool "certipy-ad"
verify_tool "netexec"
verify_tool "impacket-secretsdump"
verify_tool "bloodhound-python"

verify_file "$HOME/dropzone/Ghostpack-CompiledBinaries" "Ghostpack binaries"
verify_file "$HOME/dropzone/SharpEfsPotato" "SharpEfsPotato"
verify_file "$HOME/dropzone/PKINITtools" "PKINITtools"
verify_file "$HOME/dropzone/bloodyAD" "bloodyAD"

verify_pymod pypykatz "pypykatz"
verify_pymod impacket "impacket (python module)"

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
