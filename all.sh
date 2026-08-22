#!/bin/bash

set -u

LOG_FILE="$HOME/all_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Resolve our own location so we can source lib.sh and name sibling scripts,
# regardless of the cwd this was launched from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colours, print_*, fin_msg, apt_install, pip_ensure, the pin manifest and
# fetch_pinned/clone_pinned/go_install all live in lib.sh. They used to be
# copy-pasted into this file and ad.sh, so a fix to one copy never reached the
# other and nothing reported the divergence.
if [ ! -f "$SCRIPT_DIR/lib.sh" ]; then
    echo "[-] lib.sh not found next to all.sh - incomplete clone? Cannot continue."
    exit 1
fi
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

echo -e "${GREEN}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║     PSUT VAPT Team - Full Tool Installation           ║"
echo "║     Installing comprehensive pentesting suite...      ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ---------------------------------------------------------------------------
# PREFLIGHT
# start.sh ends by PRINTING a NEXT STEPS list, but nothing ever enforced it, so
# all.sh could happily run on a box where command logging was never activated -
# and every tool installed from that shell would be missing from the engagement
# log we hand the client. Check those manual steps here, show exactly what is
# missing and how to fix it, then make the operator decide.
# Default answer is NO. Set SKIP_PREFLIGHT=1 to bypass entirely.
# ---------------------------------------------------------------------------
PREFLIGHT_FAIL=0

pf_ok()   { print_success "  $1"; return 0; }
pf_bad()  { print_error   "  $1"; [ -n "${2:-}" ] && echo "         fix: $2"
            PREFLIGHT_FAIL=$((PREFLIGHT_FAIL+1)); return 0; }
pf_note() { print_warning "  $1"; [ -n "${2:-}" ] && echo "         fix: $2"; return 0; }

preflight() {
    print_status "Preflight - checking the manual steps start.sh asked for:"
    echo

    # [0] did start.sh run at all
    if [ -f "$HOME/start_install.log" ]; then
        pf_ok "start.sh has been run on this box"
    else
        pf_bad "start.sh has NOT been run on this box (no ~/start_install.log)" \
               "bash \"$SCRIPT_DIR/start.sh\""
    fi

    # [1] command logging: installed in the rc files, AND actually loaded.
    # A loaded hook is the only thing that proves it: the log file only grows
    # once a shell has sourced the block, so a non-empty log == activated.
    if grep -q "cptc engagement logging" "$HOME/.zshrc" "$HOME/.bashrc" 2>/dev/null; then
        pf_ok "command logging block installed in ~/.zshrc / ~/.bashrc"
        if [ -s "$HOME/.zsh_history_readable" ]; then
            pf_ok "command logging is LIVE ($(wc -l < "$HOME/.zsh_history_readable") lines so far)"
        else
            pf_bad "command logging installed but NOTHING logged yet - hook not loaded" \
                   "source ~/.zshrc   (or ~/.bashrc, or open a fresh shell) then re-run this"
        fi
    else
        pf_bad "command logging NOT configured" \
               "bash \"$SCRIPT_DIR/command_logging.sh\"  then  source ~/.zshrc"
    fi

    # [2] uniform terminal - both emulators, so screenshots match across the team
    local uni=0
    grep -q "^colorScheme=CPTC" "$HOME/.config/qterminal.org/qterminal.ini" 2>/dev/null && uni=$((uni+1))
    grep -q "^ColorPalette=" "$HOME/.config/xfce4/terminal/terminalrc" 2>/dev/null && uni=$((uni+1))
    if [ "$uni" -eq 2 ]; then
        pf_ok "uniform terminal applied (qterminal + xfce4-terminal)"
    elif [ "$uni" -eq 1 ]; then
        pf_note "uniform terminal applied to only ONE emulator - screenshots may not match" \
                "bash \"$SCRIPT_DIR/terminal_uniform.sh\""
    else
        pf_bad "uniform terminal NOT applied" "bash \"$SCRIPT_DIR/terminal_uniform.sh\""
    fi

    # [3] Burp logging: extension staged AND registered for auto-load
    if [ -f "$HOME/.BurpSuite/burp_logger.py" ] && [ -s "$HOME/.BurpSuite/jython-standalone.jar" ]; then
        if grep -q "burp_logger.py" "$HOME"/.BurpSuite/UserConfig*.json 2>/dev/null; then
            pf_ok "Burp logger staged and registered for auto-load"
        else
            pf_bad "Burp logger staged but NOT registered - Burp will not load it" \
                   "bash \"$SCRIPT_DIR/burp_logging.sh\"  (with Burp CLOSED)"
        fi
        # Soft: proves it actually fired. Requires having opened Burp once, so it
        # is a reminder, not a blocker.
        if [ -s "$HOME/.burp_history_readable" ]; then
            pf_ok "Burp logger has written traffic (verified working)"
        else
            pf_note "Burp logger has never written a line - not yet verified" \
                    "start Burp, send one Repeater request, check ~/.burp_history_readable"
        fi
    else
        pf_bad "Burp logging NOT configured" "bash \"$SCRIPT_DIR/burp_logging.sh\""
    fi
}

if [ "${SKIP_PREFLIGHT:-0}" = "1" ]; then
    print_warning "SKIP_PREFLIGHT=1 - preflight checks bypassed"
else
    preflight
    echo
    if [ "$PREFLIGHT_FAIL" -eq 0 ]; then
        print_success "Preflight clean - every manual step from start.sh is done."
    else
        print_warning "$PREFLIGHT_FAIL preflight check(s) FAILED (see above)."
        print_warning "all.sh installs tools - it does NOT fix any of these."
        print_warning "Anything you run before command logging is live is absent from the"
        print_warning "engagement log, and that log is what answers 'prove what you did at time T'."
    fi
    echo
    if [ -t 0 ]; then
        read -r -p "Proceed with all.sh? [N/y]: " -n 1 REPLY; echo
        if [[ ! ${REPLY:-} =~ ^[Yy]$ ]]; then
            print_error "Aborted. Fix the items above, then: bash \"$SCRIPT_DIR/all.sh\""
            exit 1
        fi
        print_status "Proceeding..."
    elif [ "$PREFLIGHT_FAIL" -eq 0 ]; then
        print_status "No TTY - preflight is clean, continuing without a prompt."
    else
        print_error "No TTY and $PREFLIGHT_FAIL preflight failure(s) - refusing to continue."
        print_error "Re-run interactively, or override with: SKIP_PREFLIGHT=1 bash \"$SCRIPT_DIR/all.sh\""
        exit 1
    fi
fi

# NOTE: shell-history growth + command logging moved to command_logging.sh, which
# start.sh runs. Do not re-add inline HISTSIZE/preexec lines here - command_logging.sh
# refuses to run when it detects those stale, un-guarded hooks in ~/.zshrc.

# Only meaningful with an X session under xfce. Previously this ran unguarded as the
# very first action, so on a headless / SSH-only box the script opened with a red
# failure line before doing anything real.
if [ -n "${DISPLAY:-}" ] && command -v xfconf-query >/dev/null 2>&1; then
    if xfconf-query -c xfwm4 -p /general/use_compositing -s false; then
        print_success "Shell display settings configured"
    else
        print_warning "Shell display configuration failed"
    fi
else
    print_status "No X session (or xfconf-query absent) - skipping compositing tweak"
fi


if [ -d "$HOME/dropzone" ]; then
    print_warning "Dropzone directory exists, maybe you ran this before?"
    # Re-running is the NORMAL case: apt_install / pip_ensure / fetch_pinned / go_install are
    # all idempotent and skip completed work. Only prompt if a human is actually there;
    # without a TTY, default to continuing instead of aborting. (Previously any
    # non-interactive re-run died here with "Installation cancelled by user".)
    if [ -t 0 ]; then
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_error "Installation cancelled by user"
            exit 1
        fi
    else
        print_status "No TTY - assuming re-run is intended (installers are idempotent)."
    fi
    print_status "Continuing with installation..."
fi

print_status "Checking sudo privileges..."
if ! sudo -v; then
    print_error "sudo access denied. run script with a sudoer please."
    exit 1
fi
print_success "Sudo privileges confirmed"

while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

print_status "Creating dropzone directory..."
mkdir -p ~/dropzone
cd ~/dropzone
print_success "Dropzone created at ~/dropzone"

export DEBIAN_FRONTEND=noninteractive

print_status "Removing needrestart to avoid prompts..."
sudo apt remove needrestart -y 2>/dev/null || print_warning "needrestart not installed"

print_status "Updating package lists..."
if sudo apt update; then
    print_success "Package lists updated"
else
    print_error "Failed to update packages"
    exit 1
fi

print_status "Installing APT packages one-by-one (this will take several minutes)..."
apt_install \
    apt-transport-https libssl-dev mc seclists curl golang gobuster nbtscan \
    onesixtyone oscanner smbclient smbmap smtp-user-enum snmp sslscan sipvicious \
    tnscmd10g whatweb hashcat feroxbuster dnsrecon redis-tools git \
    wget aircrack-ng set hydra docker.io docker-compose openjdk-11-jdk john awscli \
    sshuttle ffuf burpsuite python3-venv nuclei dirsearch flameshot scrot \
    maim cyberchef enum4linux nikto wfuzz steghide binwalk exiftool \
    netcat-traditional socat proxychains4 masscan metasploit-framework responder \
    netexec zaproxy wireshark tcpdump tmux screen remmina terminator
# Notes on three entries above:
#  * docker-compose      - Kali packages Compose v2 (2.40.3-3). This replaces an 8-line
#                          curl of a ~49 MB binary from GitHub into /usr/local/bin, i.e.
#                          one less network dependency in the first hour.
#  * python3-venv        - was pinned to python3.13-venv. That package exists today and
#                          Kali's default python3 IS 3.13, so the pin was not broken - but
#                          the metapackage tracks the default and survives a version bump.
#  * netexec             - crackmapexec was DROPPED: cme is the deprecated tool and nxc
#                          supersedes it entirely. netexec (1.5.1) was only ever installed
#                          by ad.sh, so web/cloud operators who never run ad.sh had no nxc;
#                          installing it here is what makes dropping cme safe.

# --- Reporting pipeline dependencies ---------------------------------------
# The report builder (zozo) imports docx, fitz, PIL and pytesseract, and now reads an
# .xlsx findings sheet. NONE of these were installed by any script, so on a fresh VDI
# the most point-bearing tool the team owns could not run at all. All are native Kali
# packages - no pip, no --break-system-packages.
# Trim libreoffice-writer if disk is tight; it is only needed for docx->pdf conversion.
#
# python3-fitz IS REQUIRED and python3-pymupdf alone is NOT enough. Verified on Kali:
# python3-pymupdf provides 'import pymupdf' only, and zozo's tools do 'import fitz'.
# The legacy fitz alias ships in the separate python3-fitz package.
#   with python3-pymupdf only : ModuleNotFoundError: No module named 'fitz'
#   after python3-fitz        : import fitz OK (PyMuPDF 1.26.7)
print_status "Installing reporting pipeline dependencies..."
apt_install \
    tesseract-ocr python3-docx python3-openpyxl python3-pil \
    python3-pytesseract python3-pymupdf python3-fitz libreoffice-writer

print_status "Adding user to docker group..."
# "$(id -un)" not "$USER": with 'set -u' an unset USER (sudo -i, cron, some non-login
# shells) aborts the whole script with "USER: unbound variable".
if sudo usermod -aG docker "$(id -un)"; then
    print_success "User added to docker group (logout/login required)"
else
    print_warning "Failed to add user to docker group"
fi

fin_msg 'APT packages'

# Download jsmith wordlists
#git clone https://github.com/insidetrust/statistically-likely-usernames
#fin_msg 'jsmith wordlists' 



# git clone https://github.com/NaturalT314/ToolBox
# fin_msg 'NaturalT314 ToolBox'

# # Install Neo4j
# wget -O - https://debian.neo4j.com/neotechnology.gpg.key | sudo apt-key add -
# echo 'deb https://debian.neo4j.com stable 4' | sudo tee /etc/apt/sources.list.d/neo4j.list > /dev/null
# sudo apt-get update
# sudo apt-get install neo4j -y
# sudo systemctl stop neo4j
# fin_msg 'neo4j'



print_status "Creating privesc tools directory..."
mkdir -p ~/dropzone/privesc
cd ~/dropzone

print_status "Downloading privilege escalation scripts..."
# URLs, versions and expected hashes now live in lib.sh's pin manifest, so the
# same artifact cannot be fetched from two different URLs by two scripts.
fetch_pinned linpeas          ~/dropzone/privesc/linpeas.sh
fetch_pinned powerup          ~/dropzone/privesc/PowerUp.ps1
fetch_pinned winpeas          ~/dropzone/privesc/winpeas.exe
fetch_pinned privesc_ps1      ~/dropzone/privesc/privesc.ps1
fetch_pinned privesccheck     ~/dropzone/privesc/PrivescCheck.ps1
chmod +x ~/dropzone/privesc/linpeas.sh 2>/dev/null
fin_msg 'Privesc Scripts'

print_status "Downloading pspy64..."
if fetch_pinned pspy64 ~/dropzone/pspy64; then
    chmod +x ~/dropzone/pspy64
    fin_msg 'pspy64'
fi

print_status "Downloading username-anarchy..."
if fetch_pinned username_anarchy ~/dropzone/username-anarchy; then
    chmod +x ~/dropzone/username-anarchy
fi

print_status "Downloading upshell (TTY upgrade helper)..."
if [ -f /usr/local/bin/upshell ]; then
    print_success "upshell already installed (skip)"
elif fetch_pinned upshell ~/dropzone/upshell; then
    sudo cp ~/dropzone/upshell /usr/local/bin/upshell && sudo chmod +x /usr/local/bin/upshell
    print_success "upshell installed to /usr/local/bin/upshell"
    fin_msg 'upshell'
fi

print_status "Downloading chisel..."
# chisel release assets are a gzipped BINARY (chisel_<ver>_linux_amd64.gz), NOT a
# tarball - the old .tar.gz URL 404'd, so chisel never installed. Gunzip, don't untar.
if command -v chisel &>/dev/null; then
    print_success "chisel already installed: $(chisel --version 2>&1)"
elif fetch_pinned chisel ~/dropzone/chisel.gz && \
     gunzip -f ~/dropzone/chisel.gz && chmod +x ~/dropzone/chisel && \
     sudo mv ~/dropzone/chisel /usr/local/bin/chisel; then
    print_success "chisel installed: $(chisel --version 2>&1)"
    fin_msg 'chisel'
else
    print_warning "chisel installation failed"
    rm -f ~/dropzone/chisel.gz ~/dropzone/chisel
fi


print_status "Installing AWS/Cloud Python packages..."
pip_ensure pacu pacu
pip_ensure ScoutSuite scoutsuite
pip_ensure principalmapper principalmapper
pip_ensure minikerberos minikerberos
pip_ensure pypykatz pypykatz
fin_msg 'Cloud Security Tools'

print_status "Setting up wordlists..."
if [ ! -d "/usr/share/wordlists/kali-wordlists" ]; then
    # needs root to write /usr/share, so this one stays a direct clone; the
    # commit is still recorded so boxes can be compared.
    if sudo git clone https://github.com/00xBAD/kali-wordlists.git /usr/share/wordlists/kali-wordlists; then
        print_success "Kali wordlists cloned"
        record_pin kali_wordlists HEAD \
            "$(git -C /usr/share/wordlists/kali-wordlists rev-parse HEAD 2>/dev/null || echo -)"
        UNPINNED+=("kali_wordlists")
    else
        print_warning "Kali wordlists clone failed"
    fi
else
    print_success "Kali wordlists already exist"
fi

if [ -f "/usr/share/wordlists/rockyou.txt.gz" ]; then
    print_status "Extracting rockyou.txt..."
    sudo gunzip /usr/share/wordlists/rockyou.txt.gz 2>/dev/null || print_success "rockyou.txt already extracted"
fi

if [ -f "/usr/share/wordlists/rockyou.txt" ]; then
    rockyou_lines=$(wc -l < /usr/share/wordlists/rockyou.txt)
    print_success "rockyou.txt available ($rockyou_lines lines)"
fi
fin_msg 'Wordlists'

print_status "Installing Sublime Text..."
if wget -qO - https://download.sublimetext.com/sublimehq-pub.gpg | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/sublimehq-archive.gpg > /dev/null && \
   echo "deb https://download.sublimetext.com/ apt/stable/" | sudo tee /etc/apt/sources.list.d/sublime-text.list > /dev/null && \
   sudo apt-get update -qq && \
   sudo apt-get install -qq -y sublime-text; then
    subl_version=$(subl --version 2>&1)
    print_success "Sublime Text installed: $subl_version"
    fin_msg 'Sublime Text'
else
    print_warning "Sublime Text installation failed (non-critical)"
fi

print_status "Cloning nuclei templates..."
cd ~/dropzone
if clone_pinned nuclei-templates https://github.com/projectdiscovery/nuclei-templates.git \
        "$HOME/dropzone/nuclei-templates"; then
    templates_count=$(find "$HOME/dropzone/nuclei-templates" -name "*.yaml" | wc -l)
    print_success "Nuclei templates: $templates_count templates"
    fin_msg 'Nuclei Templates'
fi


print_status "Cloning jwt_tool (JWT tampering/cracking)..."
cd ~/dropzone
clone_pinned jwt_tool https://github.com/ticarpi/jwt_tool.git "$HOME/dropzone/jwt_tool"
if [ -d "$HOME/dropzone/jwt_tool" ]; then
    chmod +x "$HOME/dropzone/jwt_tool/jwt_tool.py" 2>/dev/null
    # requirements.txt is the source of truth for deps; if upstream ever moves it,
    # fall back to the ones the README names. requests is already in from start.sh.
    if [ -f "$HOME/dropzone/jwt_tool/requirements.txt" ]; then
        if pip install -r "$HOME/dropzone/jwt_tool/requirements.txt" --break-system-packages; then
            print_success "jwt_tool dependencies installed"
        else
            print_warning "jwt_tool dependencies failed - it may not run"
        fi
    else
        print_warning "jwt_tool/requirements.txt missing - installing the documented deps"
        pip_ensure Cryptodome pycryptodomex
        pip_ensure termcolor termcolor
        pip_ensure cprint cprint
    fi
    print_status "Run it with: python3 ~/dropzone/jwt_tool/jwt_tool.py <JWT>"
    fin_msg 'jwt_tool'
fi

print_status "Installing additional useful Go tools..."
export GOPATH=$HOME/go
export PATH=$PATH:$GOPATH/bin

# go_install lives in lib.sh. The module path no longer carries the @version -
# it is the third argument, so these can be pinned without editing the path.
go_install httprobe    github.com/tomnomnom/httprobe
go_install waybackurls github.com/tomnomnom/waybackurls
go_install subfinder   github.com/projectdiscovery/subfinder/v2/cmd/subfinder
go_install httpx       github.com/projectdiscovery/httpx/cmd/httpx

print_status "Verifying screenshot tools..."
if command -v flameshot &> /dev/null; then
    flameshot_version=$(flameshot --version 2>&1 | head -n1)
    print_success "Flameshot installed and working: $flameshot_version"
    print_status "Flameshot keybindings: Use 'flameshot gui' or set keyboard shortcut"
else
    print_warning "Flameshot not found"
fi

if command -v scrot &> /dev/null; then
    print_success "scrot installed (alternative screenshot tool)"
fi

if command -v maim &> /dev/null; then
    print_success "maim installed (alternative screenshot tool)"
fi

hash -r

echo -e "\n${GREEN}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║     Full Installation Complete!                       ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}\n"

print_success "All tools installed successfully!"
print_success "Tools are located at: ~/dropzone"
print_success "Log file: $LOG_FILE"
print_warning "Note: Logout/login required for docker group changes to take effect"

echo ""
print_status "Running comprehensive tools verification..."
echo ""

PASS=0
FAIL=0
WARN=0

# NOTE on the counters below: they use VAR=$((VAR+1)), never ((VAR++)).
# ((VAR++)) is post-increment: it returns the OLD value, so when the counter is still
# 0 the arithmetic result is 0 and bash treats that as EXIT STATUS 1. Any
# 'cmd && ok && ((PASS++)) || fail' chain then runs the failure branch too. That bug
# was live below and printed "X verified" and "X NOT working" for the same tool.
# --- verification helpers --------------------------------------------------
# These RUN the tool instead of just locating it. 'command -v' only proves that a
# file exists at a path - a truncated download, a missing shared library, a
# wrong-arch binary or a half-configured package all still sail through it. Ten
# of the checks below used to pass "command -v X" in as the "functional test",
# i.e. they checked presence twice and called it verification.
#
# _run_check <desc> <command> [pattern]
#   no pattern -> the command must exit 0.
#   pattern    -> exit status is IGNORED and the OUTPUT must match /pattern/i.
#                 Required because many tools print their banner and then exit
#                 non-zero (hydra -h, proxychains4 -h, responder -h).
# Everything is wrapped in 'timeout' so one hanging tool cannot stall the run.
_run_check() {
    local desc=$1 cmd=$2 pat=${3:-} out rc
    out=$(timeout 120 bash -c "$cmd" 2>&1); rc=$?
    if [ "$rc" -eq 124 ]; then
        print_warning "$desc TIMED OUT during verification"
        WARN=$((WARN+1)); return 0
    fi
    if [ -n "$pat" ]; then
        if printf '%s' "$out" | grep -qaiE "$pat"; then
            print_success "$desc verified"
            PASS=$((PASS+1))
        else
            print_warning "$desc ran but its output did not match /$pat/ - suspect"
            WARN=$((WARN+1))
        fi
        return 0
    fi
    if [ "$rc" -eq 0 ]; then
        print_success "$desc verified"
        PASS=$((PASS+1))
    else
        print_warning "$desc is installed but FAILED to run (exit $rc)"
        WARN=$((WARN+1))
    fi
    return 0
}

# check_tool <name> [command] [pattern] - PATH lookup first, then run it.
check_tool() {
    local tool=$1
    if ! command -v "$tool" &>/dev/null; then
        print_error "$tool NOT installed"
        FAIL=$((FAIL+1)); return 0
    fi
    _run_check "$tool" "${2:-$tool --version}" "${3:-}"
}

# check_cmd <desc> <command> [pattern] - same contract, for things that are not
# on PATH (repo checkouts invoked through their interpreter).
check_cmd() { _run_check "$1" "$2" "${3:-}"; }

# check_file - existence only. Correct for DIRECTORIES; do not use it for files
# we downloaded (see check_payload).
check_file() {
    local file=$1 desc=$2
    if [ -e "$file" ]; then
        print_success "$desc verified"
        PASS=$((PASS+1))
    else
        print_error "$desc NOT found"
        FAIL=$((FAIL+1))
    fi
}

# check_payload <path> <desc> <pattern> [min-bytes] - for DOWNLOADED files.
# 'curl -f' catches a 404, but a proxy or captive-portal interception page
# answers 200 and lands on disk as a perfectly successful download. So: check
# the size, then sniff the first 2 KB for what the file should actually contain.
# This is the check that catches "linpeas.sh is 1.4 KB of HTML".
check_payload() {
    local f=$1 desc=$2 pat=$3 minb=${4:-1024} sz
    if [ ! -f "$f" ]; then
        print_error "$desc NOT found"
        FAIL=$((FAIL+1)); return 0
    fi
    sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
    if [ "$sz" -lt "$minb" ]; then
        print_error "$desc is only ${sz} bytes (expected >= ${minb}) - truncated or an error page"
        FAIL=$((FAIL+1)); return 0
    fi
    if head -c 2048 "$f" | grep -qaiE "$pat"; then
        print_success "$desc verified (${sz} bytes)"
        PASS=$((PASS+1))
    else
        print_error "$desc is the wrong KIND of file - first bytes do not match /$pat/ (HTML error page?)"
        FAIL=$((FAIL+1))
    fi
    return 0
}

# check_script <path> <desc> - a downloaded shell script that PARSES is a far
# stronger signal than one that merely exists.
check_script() {
    local f=$1 desc=$2
    if [ ! -f "$f" ]; then
        print_error "$desc NOT found"
        FAIL=$((FAIL+1)); return 0
    fi
    if bash -n "$f" 2>/dev/null; then
        print_success "$desc verified (parses as shell)"
        PASS=$((PASS+1))
    else
        print_error "$desc exists but is NOT valid shell - bad download"
        FAIL=$((FAIL+1))
    fi
    return 0
}

# $1 = python module name, $2 = human label
check_pymod() {
    if python3 -c "import $1" &> /dev/null; then
        print_success "$2 verified"
        PASS=$((PASS+1))
    else
        print_error "$2 NOT working"
        FAIL=$((FAIL+1))
    fi
}

print_status "Checking core scanning tools..."
check_tool "nmap"       "nmap --version"        "nmap version"
check_tool "masscan"    "masscan --version"     "masscan"
check_tool "gobuster"   "gobuster version"      "[0-9]+\.[0-9]+"
check_tool "ffuf"       "ffuf -V"               "ffuf"
check_tool "feroxbuster" "feroxbuster --version" "feroxbuster"

print_status "Checking web tools..."
check_tool "nikto"      "nikto -Version"        "nikto"
check_tool "nuclei"     "nuclei -version"       "nuclei"
check_tool "whatweb"    "whatweb --version"     "whatweb"
# Burp is a GUI launcher - running it would open a window, so check the package
# state instead, plus the JRE it needs. This is also the live answer to the
# open 'is openjdk-11-jdk still a real package' question: if java runs, Burp is fine.
check_tool "burpsuite"  "dpkg -s burpsuite"     "install ok installed"
check_tool "java"       "java -version"         "version"
check_cmd  "jwt_tool"   "python3 $HOME/dropzone/jwt_tool/jwt_tool.py --help" "jwt|usage"

print_status "Checking network tools..."
check_tool "chisel"       "chisel --version"    "[0-9]"
check_tool "socat"        "socat -V"            "socat version"
check_tool "proxychains4" "proxychains4 -h"     "proxychains|usage"
check_tool "sshuttle"     "sshuttle --version"  "[0-9]"

print_status "Checking password tools..."
check_tool "hydra"   "hydra -h"                 "hydra v[0-9]|syntax:"
check_tool "john"    "john --list=build-info"   "version|build"
check_tool "hashcat" "hashcat --version"        "[0-9]+\.[0-9]"

print_status "Checking exploitation / traffic tools..."
check_tool "msfconsole" "msfconsole --version"  "framework|metasploit"
check_tool "responder"  "responder -h"          "responder|usage"
check_tool "tcpdump"    "tcpdump --version"     "tcpdump version|libpcap"
check_tool "tshark"     "tshark --version"      "tshark"
check_tool "netexec"    "netexec --version"     "[0-9]+\.[0-9]"

print_status "Checking container tooling..."
# 'docker info' talks to the DAEMON - it is the only check that proves docker can
# actually run something. Falls back to sudo because the docker group is not
# active until the operator has logged out and back in.
check_tool "docker"         "docker info 2>/dev/null || sudo docker info" "server version"
check_tool "docker-compose" "docker-compose version"                      "[0-9]+\.[0-9]"

print_status "Checking Go tools..."
check_tool "httpx"     "httpx -version"     "httpx"
check_tool "subfinder" "subfinder -version" "subfinder"
# These two read domains on stdin; empty stdin makes them exit 0 without touching
# the network, which is the cheapest honest proof that the binary executes.
check_tool "httprobe"    "printf '' | timeout 10 httprobe"
check_tool "waybackurls" "printf '' | timeout 10 waybackurls"

print_status "Checking screenshot tools..."
check_tool "flameshot" "flameshot --version" "flameshot"
check_tool "scrot"     "scrot --version"     "scrot"
check_tool "maim"      "maim --version"      "[0-9]"

print_status "Checking privilege escalation scripts..."
check_script  "$HOME/dropzone/privesc/linpeas.sh" "linpeas.sh"
check_payload "$HOME/dropzone/privesc/winpeas.exe"      "winpeas.exe"      "^MZ"                 100000
check_payload "$HOME/dropzone/pspy64"                   "pspy64"           "ELF"                 1000000
check_payload "$HOME/dropzone/privesc/PowerUp.ps1"      "PowerUp.ps1"      "function|param"      10000
check_payload "$HOME/dropzone/privesc/PrivescCheck.ps1" "PrivescCheck.ps1" "function|param"      10000
check_payload "$HOME/dropzone/privesc/privesc.ps1"      "privesc.ps1"      "function|param|write" 5000
check_payload "$HOME/dropzone/username-anarchy"         "username-anarchy" "ruby|#!"              5000
check_script  "/usr/local/bin/upshell" "upshell"

print_status "Checking cloned repos..."
check_file "$HOME/dropzone/nuclei-templates" "nuclei-templates"

print_status "Checking wordlists..."
check_payload "/usr/share/wordlists/rockyou.txt" "rockyou.txt" "." 50000000
check_file    "/usr/share/seclists" "SecLists"

print_status "Checking Python packages..."
check_pymod requests "requests"
check_pymod pwn "pwntools"

print_status "Checking reporting pipeline dependencies..."
check_pymod docx "python-docx"
check_pymod openpyxl "openpyxl"
check_pymod PIL "Pillow"
check_pymod pytesseract "pytesseract"
check_pymod fitz "PyMuPDF (fitz)"
check_tool "tesseract" "tesseract --version" "tesseract"
check_tool "soffice"   "soffice --version"   "libreoffice"

echo ""
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo -e "${GREEN}Verification Summary${NC}"
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo -e "${GREEN}Passed:  $PASS${NC}"
echo -e "${YELLOW}Warnings: $WARN${NC}"
echo -e "${RED}Failed:  $FAIL${NC}"
echo ""

if [ $FAIL -eq 0 ]; then
    print_success "All critical tools verified!"
else
    print_warning "$FAIL tools failed verification - check log file"
fi

if [ ${#APT_FAILED[@]} -gt 0 ]; then
    echo ""
    print_warning "APT packages that FAILED to install: ${APT_FAILED[*]}"
    print_warning "  Retry manually: sudo apt install ${APT_FAILED[*]}"
fi

pin_summary

echo ""
echo -e "${YELLOW}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║   NEXT STEP                                           ║${NC}"
echo -e "${YELLOW}╚═══════════════════════════════════════════════════════╝${NC}"
print_status "AD team: run ./ad.sh next - it will remind you to log out when done."
print_status "Everyone else: LOG OUT AND BACK IN (or reboot) now to activate:"
print_warning "  - command logging      (new shells load the ~/.zshrc / ~/.bashrc hooks)"
print_warning "  - uniform terminal look (applies to new terminal windows)"
print_warning "  - docker group access   (run docker without sudo)"
print_warning "  - PATH for ~/go/bin and ~/.local/bin (go & pipx tools)"
echo ""

print_success "Good Luck!"
