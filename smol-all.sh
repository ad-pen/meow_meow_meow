#!/bin/bash
# smol-all.sh - the "we lost a box mid-engagement" installer.
#
# WHY THIS EXISTS
# all.sh is a ~30-minute, ~70-package build. That is fine at hour 0. It is the
# wrong tool at hour 3, when a VDI has been rebuilt, the clock is running and an
# operator needs to be back on target NOW. This script installs only what you
# cannot work without, in roughly 3-6 minutes, and - just as importantly -
# re-arms the engagement logging, because a rebuilt box has none of it and
# anything you do before it is back is absent from the log we hand the client.
#
# WHAT IT DELIBERATELY SKIPS (run all.sh later, when things are calm):
#   nuclei-templates, SecLists, rockyou, Go tools, Sublime, the cloud pip stack,
#   the reporting pipeline, the XFCE/xRDP desktop, docker, most privesc payloads.
#
# USAGE
#   bash smol-all.sh                # core + web + AD  (default)
#   bash smol-all.sh --web          # core + web only
#   bash smol-all.sh --ad           # core + AD only
#   bash smol-all.sh --no-burp      # skip Burp (the single heaviest package)
#   bash smol-all.sh --no-log       # skip re-arming the logging layer (rarely right)
#
# It is self-contained ON PURPOSE: no sourcing of lib.sh or any sibling helper.
# If the repo clone on a freshly rebuilt box is partial, this still has to run.
# The cost of that choice: the two URLs below (linpeas, chisel) are duplicated
# from lib.sh's pin manifest. Keep them in step - if you re-pin in lib.sh, re-pin
# here too. This is the one place where duplication buys something worth having.

set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_status()  { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[+]${NC} $1"; }
print_error()   { echo -e "${RED}[-]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$HOME/smol_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

WANT_WEB=1; WANT_AD=1; WANT_BURP=1; WANT_LOG=1; ROLE_SET=0
for arg in "$@"; do
    case $arg in
        --web)     WANT_WEB=1; [ "$ROLE_SET" -eq 0 ] && WANT_AD=0;  ROLE_SET=1 ;;
        --ad)      WANT_AD=1;  [ "$ROLE_SET" -eq 0 ] && WANT_WEB=0; ROLE_SET=1 ;;
        --no-burp) WANT_BURP=0 ;;
        --no-log)  WANT_LOG=0 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) print_error "unknown option: $arg (try --help)"; exit 1 ;;
    esac
done

echo -e "${GREEN}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║   smol-all.sh - emergency rebuild, critical path only  ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"

print_status "Checking sudo privileges..."
if ! sudo -v; then
    print_error "sudo access denied."
    exit 1
fi
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

export DEBIAN_FRONTEND=noninteractive

# --- package sets ----------------------------------------------------------
# CORE is the floor: without these you cannot scan, pivot, catch a shell or keep
# a session alive across a dropped RDP.
CORE_PKGS=(nmap netcat-traditional socat proxychains4 sshuttle tmux curl wget git python3-pip)
# ldap-utils (ldapsearch) is here and NOT in all.sh - a real gap in the main build.
AD_PKGS=(netexec impacket-scripts evil-winrm responder smbclient smbmap enum4linux ldap-utils)
WEB_PKGS=(ffuf feroxbuster gobuster nikto whatweb nuclei)

PKGS=("${CORE_PKGS[@]}")
[ "$WANT_AD"  -eq 1 ] && PKGS+=("${AD_PKGS[@]}")
[ "$WANT_WEB" -eq 1 ] && PKGS+=("${WEB_PKGS[@]}")
[ "$WANT_WEB" -eq 1 ] && [ "$WANT_BURP" -eq 1 ] && PKGS+=(burpsuite)

# Drop anything already installed BEFORE talking to the network - on a partially
# rebuilt box this alone can cut the run to seconds.
TODO=()
for p in "${PKGS[@]}"; do
    dpkg -s "$p" &>/dev/null || TODO+=("$p")
done

if [ ${#TODO[@]} -eq 0 ]; then
    print_success "Every critical package is already installed - nothing to do."
else
    print_status "Updating package lists..."
    sudo apt-get update -qq || print_warning "apt update had problems - continuing anyway"

    print_status "Installing ${#TODO[@]} package(s): ${TODO[*]}"
    # ONE transaction first: it is dramatically faster than all.sh's one-at-a-time
    # loop. Only if that transaction fails do we fall back to per-package installs,
    # so we get all.sh's failure isolation without paying for it up front.
    if sudo apt-get install -y "${TODO[@]}"; then
        print_success "All packages installed in one pass"
    else
        print_warning "Batch install failed - retrying one at a time to isolate the bad package"
        FAILED=()
        for p in "${TODO[@]}"; do
            if sudo apt-get install -y "$p"; then
                print_success "$p installed"
            else
                print_warning "$p FAILED"
                FAILED+=("$p")
            fi
        done
        [ ${#FAILED[@]} -gt 0 ] && print_error "Could not install: ${FAILED[*]}"
    fi
fi

# --- the two downloads worth waiting for -----------------------------------
# Everything else in all.sh's download list can wait; you cannot pivot without a
# tunnel and you cannot triage a Linux foothold without linpeas.
mkdir -p "$HOME/dropzone/privesc"
if [ ! -s "$HOME/dropzone/privesc/linpeas.sh" ]; then
    print_status "Fetching linpeas..."
    if curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 \
        https://github.com/carlospolop/PEASS-ng/releases/latest/download/linpeas.sh \
        -o "$HOME/dropzone/privesc/linpeas.sh"; then
        chmod +x "$HOME/dropzone/privesc/linpeas.sh"
        print_success "linpeas -> ~/dropzone/privesc/linpeas.sh"
    else
        print_warning "linpeas download failed (non-critical)"
    fi
else
    print_success "linpeas already present"
fi

if ! command -v chisel &>/dev/null; then
    print_status "Fetching chisel..."
    if curl -fsSL --retry 2 --connect-timeout 10 --max-time 180 \
        https://github.com/jpillora/chisel/releases/download/v1.10.1/chisel_1.10.1_linux_amd64.gz \
        -o /tmp/chisel.gz && gunzip -f /tmp/chisel.gz && chmod +x /tmp/chisel \
        && sudo mv /tmp/chisel /usr/local/bin/chisel; then
        print_success "chisel -> /usr/local/bin/chisel"
    else
        print_warning "chisel download failed (non-critical)"
        rm -f /tmp/chisel.gz /tmp/chisel
    fi
else
    print_success "chisel already present"
fi

# --- re-arm the engagement evidence layer ----------------------------------
# This is the part people forget on a rebuild, and it is the part that is scored.
# A rebuilt box has no command log, no Burp logger and no terminal uniform.
if [ "$WANT_LOG" -eq 1 ]; then
    echo
    print_status "Re-arming engagement logging..."
    for s in command_logging.sh burp_logging.sh terminal_uniform.sh; do
        if [ -f "$SCRIPT_DIR/$s" ]; then
            if bash "$SCRIPT_DIR/$s"; then
                print_success "$s applied"
            else
                print_warning "$s reported a problem - check the output above"
            fi
        else
            print_warning "$s not found next to this script - logging NOT restored"
        fi
    done
else
    print_warning "--no-log: engagement logging was NOT restored on this box."
fi

# --- quick functional check (run it, do not just locate it) ----------------
echo
print_status "Smoke test..."
PASS=0; MISS=0
smoke() {   # <tool> <command> [pattern]
    local t=$1 cmd=$2 pat=${3:-} out
    command -v "$t" &>/dev/null || { print_error "$t missing"; MISS=$((MISS+1)); return 0; }
    out=$(timeout 60 bash -c "$cmd" 2>&1)
    if [ -z "$pat" ] || printf '%s' "$out" | grep -qaiE "$pat"; then
        print_success "$t works"; PASS=$((PASS+1))
    else
        print_warning "$t present but did not behave as expected"; MISS=$((MISS+1))
    fi
    return 0
}
smoke nmap  "nmap --version"  "nmap version"
smoke socat "socat -V"        "socat version"
smoke tmux  "tmux -V"         "[0-9]"
command -v chisel &>/dev/null && smoke chisel "chisel --version" "[0-9]"
if [ "$WANT_AD" -eq 1 ]; then
    smoke netexec "netexec --version" "[0-9]"
    smoke evil-winrm "evil-winrm -h" "evil-winrm|usage"
    smoke impacket-secretsdump "impacket-secretsdump -h" "impacket|usage"
    smoke ldapsearch "ldapsearch -VV" "ldapsearch|openldap"
fi
if [ "$WANT_WEB" -eq 1 ]; then
    smoke ffuf "ffuf -V" "ffuf"
    smoke feroxbuster "feroxbuster --version" "feroxbuster"
    smoke nuclei "nuclei -version" "nuclei"
    [ "$WANT_BURP" -eq 1 ] && smoke java "java -version" "version"
fi

echo
echo -e "${GREEN}═══════════════════════════════════════${NC}"
printf "%b Back on target in %dm %02ds  |  %d ok, %d missing\n" \
       "${GREEN}[+]${NC}" $((SECONDS/60)) $((SECONDS%60)) "$PASS" "$MISS"
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo
print_warning "NOT installed by this script - run all.sh when the pressure is off:"
echo "    SecLists / rockyou / nuclei-templates / Go tools (httpx, subfinder)"
echo "    hashcat + john / Ghostpack / BloodHound + neo4j / cloud stack (pacu,"
echo "    ScoutSuite) / the reporting pipeline (docx, fitz, tesseract, libreoffice)"
echo
print_status "Full build:  bash \"$SCRIPT_DIR/all.sh\"      AD extras:  bash \"$SCRIPT_DIR/ad.sh\""
print_status "Log: $LOG_FILE"
