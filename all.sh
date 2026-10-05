#!/bin/bash

set -u

LOG_FILE="$USER_HOME/all_install.log"
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

# ---------------------------------------------------------------------------
# ROLES
# With no arguments this behaves exactly as it always did - the full suite.
# --ismael ADDS the two heaviest things in the build, which only the mobile/AI
# owner actually needs and which everyone else was previously paying for:
#   * the mobile kit incl. Android Studio   ~1.6 GB download
#   * the nuclei-templates clone            ~731 MB (full history)
# Measured sizes are in TOOLS.md. Deliberately the ONLY role: every other tool
# stays default-on, because splitting further costs more in "which flag do I
# need again?" on engagement morning than it saves in bandwidth.
# ---------------------------------------------------------------------------
WANT_ISMAEL=0
for arg in "$@"; do
    case "$arg" in
        --ismael) WANT_ISMAEL=1 ;;
        -h|--help)
            cat <<'USAGE'
Usage: all.sh [--ismael]

  (no arguments)   Install the full standard suite. Unchanged from before.
  --ismael         ALSO install the mobile kit (jadx, apktool, adb, frida-tools,
                   Android Studio) and clone nuclei-templates.
                   Adds roughly 2.3 GB of downloads. Mobile/AI owner only.
  -h, --help       Show this and exit.
USAGE
            exit 0 ;;
        *)
            echo "[-] Unknown argument: $arg  (try: bash all.sh --help)"
            exit 1 ;;
    esac
done

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
    if [ -f "$USER_HOME/start_install.log" ]; then
        pf_ok "start.sh has been run on this box"
    else
        pf_bad "start.sh has NOT been run on this box (no $USER_HOME/start_install.log)" \
               "bash \"$SCRIPT_DIR/start.sh\""
    fi

    # [1] command logging: installed in the rc files, AND actually loaded.
    # A loaded hook is the only thing that proves it: the log file only grows
    # once a shell has sourced the block, so a non-empty log == activated.
    if grep -q "cptc engagement logging" "$USER_HOME/.zshrc" "$USER_HOME/.bashrc" 2>/dev/null; then
        pf_ok "command logging block installed in $USER_HOME/.zshrc / $USER_HOME/.bashrc"
        if [ -s "$USER_HOME/.zsh_history_readable" ]; then
            pf_ok "command logging is LIVE ($(wc -l < "$USER_HOME/.zsh_history_readable") lines so far)"
        else
            pf_bad "command logging installed but NOTHING logged yet - hook not loaded" \
                   "source $USER_HOME/.zshrc   (or $USER_HOME/.bashrc, or open a fresh shell) then re-run this"
        fi
    else
        pf_bad "command logging NOT configured" \
               "bash \"$SCRIPT_DIR/command_logging.sh\"  then  source $USER_HOME/.zshrc"
    fi

    # [2] uniform terminal - both emulators, so screenshots match across the team
    local uni=0
    grep -q "^colorScheme=CPTC" "$USER_HOME/.config/qterminal.org/qterminal.ini" 2>/dev/null && uni=$((uni+1))
    grep -q "^ColorPalette=" "$USER_HOME/.config/xfce4/terminal/terminalrc" 2>/dev/null && uni=$((uni+1))
    if [ "$uni" -eq 2 ]; then
        pf_ok "uniform terminal applied (qterminal + xfce4-terminal)"
    elif [ "$uni" -eq 1 ]; then
        pf_note "uniform terminal applied to only ONE emulator - screenshots may not match" \
                "bash \"$SCRIPT_DIR/terminal_uniform.sh\""
    else
        pf_bad "uniform terminal NOT applied" "bash \"$SCRIPT_DIR/terminal_uniform.sh\""
    fi

    # [3] Burp: deliberately NOT checked here any more.
    # all.sh now installs Burp itself and then wires in the logging extension, in
    # that order, further down this script. A preflight cannot demand something
    # the same run is about to provide - that check used to fail on every fresh
    # box and taught people to ignore the preflight output.
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
    # NON-INTERACTIVE BY DESIGN. This used to stop and ask "Proceed? [N/y]", which
    # meant a build could not be started and left alone - and on a box with no TTY
    # it refused to run at all. The preflight's value is the DIAGNOSIS, not the
    # gate: it tells you precisely which manual step is missing and how to fix it.
    # So it now reports and continues. Set STRICT_PREFLIGHT=1 to make a failure
    # abort instead, for anyone who wants the old behaviour in a rehearsal.
    if [ "$PREFLIGHT_FAIL" -ne 0 ]; then
        if [ "${STRICT_PREFLIGHT:-0}" = "1" ]; then
            print_error "STRICT_PREFLIGHT=1 and $PREFLIGHT_FAIL check(s) failed - aborting."
            print_error "Fix the items above, then: bash \"$SCRIPT_DIR/all.sh\""
            exit 1
        fi
        print_warning "Continuing anyway (nothing here blocks installing tools)."
        print_warning "FIX THE ITEMS ABOVE AFTERWARDS - they are listed again at the end."
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


if [ -d "$USER_HOME/dropzone" ]; then
    # Re-running is the NORMAL case, not an error: apt_install, pip_ensure,
    # fetch_pinned, clone_pinned and go_install are all idempotent and skip work
    # that is already done - REHEARSAL.md step 11 exists to test exactly that. So
    # this is a note, not a question. It used to prompt "Continue anyway? (y/N)",
    # which made an unattended re-run impossible.
    print_status "Dropzone already exists - this looks like a re-run. Installers are"
    print_status "  idempotent, so completed work is skipped. Continuing."
fi

print_status "Checking sudo privileges..."
if ! sudo -v; then
    print_error "sudo access denied. run script with a sudoer please."
    exit 1
fi
print_success "Sudo privileges confirmed"

while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

print_status "Creating dropzone directory..."
mkdir -p "$USER_HOME/dropzone"
cd "$USER_HOME/dropzone" || { print_error "cannot cd to $USER_HOME/dropzone"; exit 1; }
# Hand it back if we are root (sudo run) - otherwise the operator ends up with a
# dropzone they cannot write to without sudo for the rest of the engagement.
own_user "$USER_HOME/dropzone"
print_success "Dropzone created at $USER_HOME/dropzone"

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
    wget aircrack-ng set hydra docker.io docker-compose openjdk-11-jdk default-jdk john awscli \
    sshuttle ffuf python3-venv nuclei dirsearch flameshot scrot \
    maim cyberchef enum4linux nikto wfuzz steghide binwalk exiftool \
    netcat-traditional socat proxychains4 masscan metasploit-framework responder \
    netexec wireshark tcpdump tmux screen remmina terminator \
    arjun phpggc rlwrap unzip
# REMOVED: burpsuite (the apt package). Burp is now installed from PortSwigger's
#   official "latest community" download instead - see install_burp_latest in lib.sh.
#   Two reasons: the archive package is whatever version Kali froze, and the rules
#   permit Community only (Pro is banned), so being explicit about the edition we
#   fetched is worth more than an apt one-liner. Boxes built before this change
#   still have the apt one: sudo apt purge burpsuite
# ADDED: default-jdk. NOT optional, and openjdk-11-jdk does NOT cover it. Burp's
#   own entry point burp/StartBurp is class-file major 65, i.e. Java 21; measured
#   on 2026.3.3, and an older JVM dies with:
#     UnsupportedClassVersionError: burp/StartBurp has been compiled by a more
#     recent version of the Java Runtime (class file version 65.0) ...
#   openjdk-11-jdk STAYS because ysoserial's gadget chains want an old runtime.
#   The /usr/local/bin/burpsuite wrapper picks a JVM >= 21 rather than trusting
#   whatever 'java' resolves to.
# REMOVED: zaproxy. 211 MB download / 267 MB on disk for a second intercepting
#   proxy we do not use - burpsuite is the one the team actually runs, and Burp is
#   the one wired into the engagement-evidence layer (burp_logging.sh). Boxes built
#   before this change still have it: sudo apt purge zaproxy.
# ADDED: arjun (hidden HTTP parameter discovery), phpggc (PHP deserialisation gadget
#   chains - pulls php-cli), rlwrap (readline wrapper; 'rlwrap nc -lvnp 443' makes a
#   raw reverse shell survivable), unzip (needed to unpack the AzureHound release).
#   All four together are about 1 MB.
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

# ---------------------------------------------------------------------------
# BURP SUITE + ITS LOGGING EXTENSION  - in that order, and both live HERE
# ---------------------------------------------------------------------------
# These two moved out of start.sh on purpose. start.sh used to install the Burp
# LOGGING EXTENSION while Burp itself came from all.sh's apt list much later, so
# on a fresh box burp_logging.sh ran against a machine with no Burp on it: it
# could stage the jython jar and the extension, but it had no UserConfig*.json to
# patch (Burp writes that on first run), so the auto-load registration silently
# did not happen. The operator then started Burp for the first time, got no
# extension, and nothing in the logs explained why.
#
# ORDER MATTERS AND IS NOW ENFORCED BY SEQUENCE: install Burp, let the config
# exist, then wire the extension in.
print_status "Installing Burp Suite Community (latest, from PortSwigger)..."
if install_burp_latest; then
    BURP_OK=1
else
    BURP_OK=0
    print_warning "Burp install failed - the logging extension will be staged anyway"
    print_warning "  so it is in place once Burp is available."
fi

print_status "Configuring Burp Suite HTTP logging..."
if bash "$SCRIPT_DIR/burp_logging.sh"; then
    print_success "Burp logging configured (readable log: $USER_HOME/.burp_history_readable)"
else
    print_warning "Burp logging setup reported an issue - see output above"
fi
own_user "$USER_HOME/.BurpSuite" 2>/dev/null
fin_msg 'Burp Suite + engagement logging'

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
mkdir -p $USER_HOME/dropzone/privesc
cd $USER_HOME/dropzone

print_status "Downloading privilege escalation scripts..."
# URLs, versions and expected hashes now live in lib.sh's pin manifest, so the
# same artifact cannot be fetched from two different URLs by two scripts.
fetch_pinned linpeas          $USER_HOME/dropzone/privesc/linpeas.sh
fetch_pinned powerup          $USER_HOME/dropzone/privesc/PowerUp.ps1
fetch_pinned winpeas          $USER_HOME/dropzone/privesc/winpeas.exe
fetch_pinned privesc_ps1      $USER_HOME/dropzone/privesc/privesc.ps1
fetch_pinned privesccheck     $USER_HOME/dropzone/privesc/PrivescCheck.ps1
chmod +x $USER_HOME/dropzone/privesc/linpeas.sh 2>/dev/null
fin_msg 'Privesc Scripts'

print_status "Downloading pspy64..."
if fetch_pinned pspy64 $USER_HOME/dropzone/pspy64; then
    chmod +x $USER_HOME/dropzone/pspy64
    fin_msg 'pspy64'
fi

print_status "Downloading username-anarchy..."
if fetch_pinned username_anarchy $USER_HOME/dropzone/username-anarchy; then
    chmod +x $USER_HOME/dropzone/username-anarchy
fi

print_status "Downloading upshell (TTY upgrade helper)..."
if [ -f /usr/local/bin/upshell ]; then
    print_success "upshell already installed (skip)"
elif fetch_pinned upshell $USER_HOME/dropzone/upshell; then
    sudo cp $USER_HOME/dropzone/upshell /usr/local/bin/upshell && sudo chmod +x /usr/local/bin/upshell
    print_success "upshell installed to /usr/local/bin/upshell"
    fin_msg 'upshell'
fi

print_status "Downloading chisel..."
# chisel release assets are a gzipped BINARY (chisel_<ver>_linux_amd64.gz), NOT a
# tarball - the old .tar.gz URL 404'd, so chisel never installed. Gunzip, don't untar.
if command -v chisel &>/dev/null; then
    print_success "chisel already installed: $(chisel --version 2>&1)"
elif fetch_pinned chisel $USER_HOME/dropzone/chisel.gz && \
     gunzip -f $USER_HOME/dropzone/chisel.gz && chmod +x $USER_HOME/dropzone/chisel && \
     sudo mv $USER_HOME/dropzone/chisel /usr/local/bin/chisel; then
    print_success "chisel installed: $(chisel --version 2>&1)"
    fin_msg 'chisel'
else
    print_warning "chisel installation failed"
    rm -f $USER_HOME/dropzone/chisel.gz $USER_HOME/dropzone/chisel
fi


print_status "Installing AWS/Cloud Python packages..."
pip_ensure pacu pacu
pip_ensure ScoutSuite scoutsuite
pip_ensure principalmapper principalmapper
pip_ensure minikerberos minikerberos
pip_ensure pypykatz pypykatz
fin_msg 'Cloud Security Tools'

# --- Azure / Entra ID ------------------------------------------------------
# Everything above this point is AWS-ONLY (awscli, pacu, ScoutSuite, pmapper).
# That is a real hole: CPTC's own infrastructure is an Entra/M365 tenant, the
# deliverables live in M365, and the CPTC 12 client was identified THROUGH its
# Azure tenant. If the in-scope cloud turns out to be Azure we previously had
# nothing at all.
#
# azure-cli is in Kali's own repo (2.90.0-1), so no Microsoft apt repo, no GPG
# key dance, and no lsb_release workaround. It is ~175 MB with dependencies -
# the single heaviest default-on addition, and roughly what removing zaproxy
# gave back.
print_status "Installing Azure / Entra ID tooling..."
apt_install azure-cli
pip_ensure roadtools roadrecon          # ROADtools - Entra ID recon (roadrecon)

# AzureHound feeds the SAME BloodHound CE instance ad.sh installs, so Azure and
# on-prem AD paths end up in one graph.
if command -v azurehound &>/dev/null; then
    print_success "azurehound already installed: $(azurehound --version 2>&1 | head -n1)"
elif fetch_pinned azurehound $USER_HOME/dropzone/azurehound.zip; then
    # Do not assume where inside the zip the binary sits - locate it. An upstream
    # layout change would otherwise fail as a confusing "unpack failed".
    if unzip -o -q $USER_HOME/dropzone/azurehound.zip -d $USER_HOME/dropzone/azurehound.d && \
       AH_BIN=$(find $USER_HOME/dropzone/azurehound.d -type f -name azurehound | head -n1) && \
       [ -n "$AH_BIN" ] && \
       sudo install -m 0755 "$AH_BIN" /usr/local/bin/azurehound; then
        print_success "azurehound installed: $(azurehound --version 2>&1 | head -n1)"
        rm -rf $USER_HOME/dropzone/azurehound.zip $USER_HOME/dropzone/azurehound.d
        fin_msg 'AzureHound'
    else
        print_warning "azurehound unpack failed - is 'unzip' installed?"
    fi
fi
fin_msg 'Azure / Entra ID Tools'

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
   sudo env DEBIAN_FRONTEND=noninteractive apt-get install -qq -y \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        sublime-text; then
    subl_version=$(subl --version 2>&1)
    print_success "Sublime Text installed: $subl_version"
    fin_msg 'Sublime Text'
else
    print_warning "Sublime Text installation failed (non-critical)"
fi

# nuclei-templates is a FULL-HISTORY clone of a 731 MB repository - by a wide
# margin the biggest git operation in this script. clone_pinned only passes
# --depth 1 when it is given a tag, and this call has none.
if [ "$WANT_ISMAEL" -eq 1 ]; then
    print_status "Cloning nuclei templates (--ismael; ~731 MB)..."
    cd $USER_HOME/dropzone
    if clone_pinned nuclei-templates https://github.com/projectdiscovery/nuclei-templates.git \
            "$USER_HOME/dropzone/nuclei-templates"; then
        templates_count=$(find "$USER_HOME/dropzone/nuclei-templates" -name "*.yaml" | wc -l)
        print_success "Nuclei templates: $templates_count templates"
        fin_msg 'Nuclei Templates'
    fi
else
    print_status "Skipping the nuclei-templates clone (~731 MB) - run with --ismael to get it."
    print_warning "  nuclei itself IS installed. On first use it tries to download its own"
    print_warning "  template set to ~/.local/nuclei-templates, which needs internet egress."
    print_warning "  If the engagement network is isolated, that fetch will fail and nuclei"
    print_warning "  will have no templates. Either run --ismael on one box and copy the"
    print_warning "  directory across, or run 'nuclei -update-templates' while you still"
    print_warning "  have egress."
fi


print_status "Cloning jwt_tool (JWT tampering/cracking)..."
cd $USER_HOME/dropzone
clone_pinned jwt_tool https://github.com/ticarpi/jwt_tool.git "$USER_HOME/dropzone/jwt_tool"
if [ -d "$USER_HOME/dropzone/jwt_tool" ]; then
    chmod +x "$USER_HOME/dropzone/jwt_tool/jwt_tool.py" 2>/dev/null
    # requirements.txt is the source of truth for deps; if upstream ever moves it,
    # fall back to the ones the README names. requests is already in from start.sh.
    if [ -f "$USER_HOME/dropzone/jwt_tool/requirements.txt" ]; then
        if pip install -r "$USER_HOME/dropzone/jwt_tool/requirements.txt" --break-system-packages; then
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

print_status "Downloading ysoserial (Java deserialisation gadget chains)..."
# Not in Kali's repos - verified against the live index, unlike phpggc which is.
# It is a fat jar, so it needs a JRE; openjdk-11-jdk is in the apt list above and
# the verification block below proves 'java -version' actually runs.
if fetch_pinned ysoserial $USER_HOME/dropzone/ysoserial-all.jar; then
    print_status "Run it with: java -jar ~/dropzone/ysoserial-all.jar <gadget> '<cmd>'"
    print_status "  List gadgets: java -jar ~/dropzone/ysoserial-all.jar"
    fin_msg 'ysoserial'
fi

print_status "Installing additional useful Go tools..."
export GOPATH=$USER_HOME/go
export PATH=$PATH:$GOPATH/bin

# go_install lives in lib.sh. The module path no longer carries the @version -
# it is the third argument, so these can be pinned without editing the path.
go_install httprobe    github.com/tomnomnom/httprobe
go_install waybackurls github.com/tomnomnom/waybackurls
go_install subfinder   github.com/projectdiscovery/subfinder/v2/cmd/subfinder
go_install httpx       github.com/projectdiscovery/httpx/cmd/httpx

# ---------------------------------------------------------------------------
# OT / ICS
# ---------------------------------------------------------------------------
# READ THE DOCTRINE BEFORE YOU RUN ANY OF THIS. See the KB, and osint/themepark-playbook.md.
#
# "Rides" at CPTC 11 (maritime) were web dashboards and raw TCP listeners - there
# was not one industrial protocol in the whole environment. These three tools are
# here for the case where CPTC 12 does ship real Modbus/OPC-UA, not because we
# expect it.
#
# THE RULE: prove reachability READ-ONLY, then STOP and escalate in character.
# modbuster can write coils and holding registers and opcattack can forge
# signatures. Do not use those paths against anything ride-, safety- or
# life-safety-shaped. Disrupting the environment is an explicit point loss and a
# DQ risk, and "we could have stopped a ride mid-cycle and chose to report it
# instead" is a stronger report line than a screenshot of having done it.
print_status "Installing OT/ICS tooling (read-only doctrine - see comments)..."
cd $USER_HOME/dropzone

pip_ensure asyncua asyncua        # OPC-UA client library; also opcattack's dependency

# icspacket is the broad-coverage one: DNP3 (IEEE 1815), MMS (ISO 9506) + IEC 61850,
# IEC 60870-5-104, EtherNet/IP (CIP), BACnet/IP, plus Modbus and OPC-UA which it
# layers on pymodbus and asyncua respectively. Ships prebuilt Linux wheels for
# Python 3.10-3.14, so it should not need a compiler on Kali's 3.13.
# It is a LIBRARY, not a CLI - you write a few lines of Python against it. That is
# the right shape for the read-only doctrine above: a scripted read is easier to
# keep harmless, and easier to put in the report, than an interactive attack tool.
pip_ensure icspacket icspacket

if clone_pinned opcattack https://github.com/bvcyber/opcattack "$USER_HOME/dropzone/opcattack"; then
    if [ -f "$USER_HOME/dropzone/opcattack/requirements.txt" ]; then
        pip install -r "$USER_HOME/dropzone/opcattack/requirements.txt" --break-system-packages \
            && print_success "opcattack dependencies installed" \
            || print_warning "opcattack dependencies failed - it may not run"
    fi
    chmod +x "$USER_HOME/dropzone/opcattack/opcattack.py" 2>/dev/null
    print_status "Run it with: python3 ~/dropzone/opcattack/opcattack.py --help"
    fin_msg 'opcattack'
fi

if command -v modbuster &>/dev/null; then
    print_success "modbuster already installed"
elif clone_pinned modbuster https://github.com/TacticalGator/modbuster "$USER_HOME/dropzone/modbuster"; then
    # Upstream ships a pyproject and recommends pipx; fall back to pip so a box
    # without pipx still ends up with the tool.
    if command -v pipx &>/dev/null && pipx install "$USER_HOME/dropzone/modbuster" 2>/dev/null; then
        print_success "modbuster installed via pipx"
        fin_msg 'modbuster'
    elif pip install "$USER_HOME/dropzone/modbuster" --break-system-packages; then
        print_success "modbuster installed via pip"
        fin_msg 'modbuster'
    else
        print_warning "modbuster install failed - run it from $USER_HOME/dropzone/modbuster instead"
    fi
fi
fin_msg 'OT/ICS Tools'

# ---------------------------------------------------------------------------
# MOBILE  (--ismael only)
# ---------------------------------------------------------------------------
# Per the KB this is a TIME-BOXED HEDGE, not a discipline: there is no evidence
# mobile has ever been in scope, and the useful flow is ~90 minutes of
# apktool -> jadx -> grep -> hand the endpoint list to the web team.
if [ "$WANT_ISMAEL" -eq 1 ]; then
    print_status "Installing mobile tooling (--ismael)..."
    # jadx pulls default-jre and is ~69 MB; the other three are under 1 MB together.
    apt_install jadx adb apktool openssl
    pip_ensure frida frida-tools

    # Android Studio: 1.5 GB download, ~4 GB installed - the single largest item in
    # this repo. Its EMULATOR needs nested virtualisation, which a VDI almost
    # certainly does not expose, so treat this as an APK/layout inspector rather
    # than assuming you can run an app on it.
    if [ -d /opt/android-studio ]; then
        print_success "Android Studio already installed at /opt/android-studio (skip)"
    else
        print_warning "Android Studio is a 1.5 GB download and ~4 GB on disk. Fetching..."
        if fetch_pinned android_studio $USER_HOME/dropzone/android-studio.tar.gz; then
            if sudo tar -xzf $USER_HOME/dropzone/android-studio.tar.gz -C /opt; then
                sudo ln -sf /opt/android-studio/bin/studio.sh /usr/local/bin/android-studio
                print_success "Android Studio installed -> run: android-studio"
                # Reclaim the 1.5 GB immediately; /opt/android-studio is the skip test.
                rm -f $USER_HOME/dropzone/android-studio.tar.gz
                fin_msg 'Android Studio'
            else
                print_warning "Android Studio extraction failed - is there enough disk?"
            fi
        fi
    fi
    fin_msg 'Mobile Tools'
else
    print_status "Skipping the mobile kit - run with --ismael for jadx/apktool/adb/frida + Android Studio."
fi

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
# Burp: no longer an apt package, so 'dpkg -s' is the wrong question. These four
# checks each catch a different real failure:
#  1. the jar exists AND is a jar (a captive portal returns HTML with a 200);
#  2. 'burpsuite --version' RUNS - which is the only thing that proves the JVM is
#     new enough. Burp needs Java 21 and Kali also ships openjdk-11; on 17 it dies
#     with "UnsupportedClassVersionError ... class file version 65.0", so this is
#     the check that would have caught shipping only openjdk-11-jdk;
#  3. a JVM of at least 21 is actually present for the wrapper to find;
#  4. the version file, so the summary records WHICH Burp this box has.
check_payload "$BURP_DIR/burpsuite.jar" "Burp jar" '^PK' 100000000
check_cmd  "burpsuite runs (JVM >= 21)" \
           "timeout 180 burpsuite --version 2>&1 | head -5" "burp|version"
check_cmd  "a JVM >= 21 is installed" \
           "for j in \$(ls -d /usr/lib/jvm/*/bin/java 2>/dev/null | sort -rV); do v=\$(\$j -version 2>&1 | sed -n 's/.*version \"\\([0-9][0-9]*\\).*/\\1/p' | head -1); [ -n \"\$v\" ] && [ \"\$v\" -ge 21 ] 2>/dev/null && echo \"found \$v\" && break; done" \
           "found"
check_file "$BURP_DIR/VERSION" "Burp version record ($(cat "$BURP_DIR/VERSION" 2>/dev/null || echo 'unknown'))"
check_tool "java"       "java -version"         "version"
check_cmd  "jwt_tool"   "python3 $USER_HOME/dropzone/jwt_tool/jwt_tool.py --help" "jwt|usage"
check_tool "arjun"      "arjun --help"          "arjun|usage"
check_tool "phpggc"     "phpggc -l"             "gadget|chain|[0-9]"
# A fat jar is only proven by running it: 'java -jar <jar>' with no arguments
# prints the gadget list, which also re-proves the JRE.
check_cmd  "ysoserial"  "java -jar $USER_HOME/dropzone/ysoserial-all.jar 2>&1 | head -40" "gadget|usage|payload"

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
check_script  "$USER_HOME/dropzone/privesc/linpeas.sh" "linpeas.sh"
check_payload "$USER_HOME/dropzone/privesc/winpeas.exe"      "winpeas.exe"      "^MZ"                 100000
check_payload "$USER_HOME/dropzone/pspy64"                   "pspy64"           "ELF"                 1000000
check_payload "$USER_HOME/dropzone/privesc/PowerUp.ps1"      "PowerUp.ps1"      "function|param"      10000
check_payload "$USER_HOME/dropzone/privesc/PrivescCheck.ps1" "PrivescCheck.ps1" "function|param"      10000
check_payload "$USER_HOME/dropzone/privesc/privesc.ps1"      "privesc.ps1"      "function|param|write" 5000
check_payload "$USER_HOME/dropzone/username-anarchy"         "username-anarchy" "ruby|#!"              5000
check_script  "/usr/local/bin/upshell" "upshell"

print_status "Checking cloned repos..."
if [ "$WANT_ISMAEL" -eq 1 ]; then
    check_file "$USER_HOME/dropzone/nuclei-templates" "nuclei-templates"
fi

print_status "Checking wordlists..."
check_payload "/usr/share/wordlists/rockyou.txt" "rockyou.txt" "." 50000000
check_file    "/usr/share/seclists" "SecLists"

print_status "Checking cloud tooling..."
check_tool "aws"        "aws --version"         "aws-cli"
check_tool "az"         "az version"            "azure-cli|[0-9]+\\.[0-9]"
check_tool "azurehound" "azurehound --version"  "azurehound|v?[0-9]+\\.[0-9]"
check_tool "roadrecon"  "roadrecon --help"      "roadrecon|usage"
check_pymod roadtools "ROADtools (roadlib)"

print_status "Checking OT/ICS tooling..."
check_pymod asyncua "asyncua (OPC-UA)"
check_pymod icspacket "icspacket (DNP3/MMS/IEC-104/CIP/BACnet)"
check_cmd  "opcattack" "python3 $USER_HOME/dropzone/opcattack/opcattack.py --help" "usage|opcattack|error"
check_tool "modbuster" "modbuster --help"       "modbus|usage"

if [ "$WANT_ISMAEL" -eq 1 ]; then
    print_status "Checking mobile tooling (--ismael)..."
    check_tool "jadx"    "jadx --version"    "[0-9]+\\.[0-9]"
    check_tool "apktool" "apktool --version" "[0-9]+\\.[0-9]"
    check_tool "adb"     "adb version"       "android debug bridge|[0-9]+\\.[0-9]"
    check_tool "frida"   "frida --version"   "[0-9]+\\.[0-9]"
    check_file "/opt/android-studio" "Android Studio"
fi

print_status "Checking shell helpers..."
check_tool "rlwrap" "rlwrap --version" "rlwrap"

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

# Last chance to hand back anything created while running as root.
own_user "$USER_HOME/dropzone" "$USER_HOME/go" "$PINS_LOCK" 2>/dev/null

pin_summary

echo ""
echo -e "${YELLOW}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║   NEXT STEP                                           ║${NC}"
echo -e "${YELLOW}╚═══════════════════════════════════════════════════════╝${NC}"
print_status "AD team: run ./ad.sh next - it will remind you to log out when done."
if [ "$WANT_ISMAEL" -eq 0 ]; then
    print_status "Mobile/AI owner: this run SKIPPED the mobile kit and nuclei-templates."
    print_status "  Get them with: bash all.sh --ismael   (adds ~2.3 GB of downloads)"
fi
print_status "Everyone else: LOG OUT AND BACK IN (or reboot) now to activate:"
print_warning "  - command logging      (new shells load the ~/.zshrc / ~/.bashrc hooks)"
print_warning "  - uniform terminal look (applies to new terminal windows)"
print_warning "  - docker group access   (run docker without sudo)"
print_warning "  - PATH for ~/go/bin and ~/.local/bin (go & pipx tools)"
echo ""

print_success "Good Luck!"
