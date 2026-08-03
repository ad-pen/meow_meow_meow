#!/bin/bash

set -e
set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="$HOME/start_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Resolve our own location so we can call sibling scripts regardless of cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

handle_error() {
    print_error "Error occurred in start.sh at line $1"
    print_error "Check log file: $LOG_FILE"
    exit 1
}

trap 'handle_error $LINENO' ERR

echo -e "${GREEN}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║     PSUT VAPT Team - Initial Setup Script             ║"
echo "║     Starting basic tool installation...               ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# The logging/terminal scripts edit the invoking user's dotfiles (~/.zshrc,
# ~/.bashrc, ~/.config/qterminal). If run under sudo, $HOME is /root and those
# land on the wrong account. Run start.sh as the normal user; it sudos as needed.
if [ "$(id -u)" -eq 0 ]; then
    print_warning "Running as root: per-user logging/terminal config would apply to /root, not your user."
    print_warning "Recommended: run this as your normal user (it will prompt for sudo itself)."
    read -p "Continue as root anyway? (y/N): " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] || { print_error "Aborted. Re-run as the normal user."; exit 1; }
fi

print_status "Checking sudo privileges..."
if ! sudo -v; then
    print_error "sudo access denied. Please run this script with sudo privileges."
    exit 1
fi
print_success "Sudo privileges confirmed"

while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

print_status "Updating package lists..."
if sudo apt update; then
    print_success "Package lists updated"
else
    print_error "Failed to update package lists"
    exit 1
fi

print_status "Installing basic packages (python3, pip, nmap)..."
if sudo apt install -y \
    python3 \
    python3-pip \
    python3-venv \
    nmap \
    git \
    curl \
    wget; then
    print_success "Basic packages installed"
else
    print_error "Failed to install basic packages"
    exit 1
fi

print_status "Verifying basic tool installations..."
for tool in python3 pip3 nmap git curl wget; do
    if command -v $tool &> /dev/null; then
        version=$($tool --version 2>&1 | head -n1)
        print_success "$tool is installed: $version"
    else
        print_error "$tool installation failed!"
        exit 1
    fi
done

print_status "Upgrading pip and setuptools..."
if python3 -m pip install --upgrade pip setuptools --break-system-packages; then
    print_success "pip and setuptools upgraded"
else
    print_warning "Failed to upgrade pip/setuptools (non-critical)"
fi

print_status "Installing Python packages (argparse, requests, pwntools, bs4)..."
if pip install argparse requests pwntools bs4 --break-system-packages; then
    print_success "Python packages installed"
else
    print_warning "Some Python packages may have failed (non-critical)"
fi

print_status "Verifying Python package installations..."
python3 -c "import requests; import bs4; import pwn" 2>/dev/null && \
    print_success "Python packages verified" || \
    print_warning "Some Python packages may not be fully functional"


print_status "Configuring SSH service..."
if sudo systemctl enable ssh && sudo systemctl start ssh; then
    print_success "SSH service enabled and started"
    ssh_status=$(sudo systemctl is-active ssh)
    print_status "SSH Status: $ssh_status"
else
    print_warning "Failed to configure SSH (non-critical)"
fi

print_status "Checking for desktop environment..."
if ! dpkg -l | grep -q kali-desktop-xfce; then
    print_status "Installing XFCE desktop and xRDP (this may take a while)..."
    if sudo apt install -y kali-desktop-xfce xorg xrdp; then
        sudo systemctl enable xrdp --now
        sudo systemctl start xrdp
        print_success "Desktop environment installed and xRDP configured"
    else
        print_warning "Desktop environment installation failed (non-critical)"
    fi
else
    print_success "Desktop environment already installed"
fi

print_status "Configuring engagement command logging (zsh + bash)..."
if bash "$SCRIPT_DIR/command_logging.sh"; then
    print_success "Command logging configured (readable log: ~/.zsh_history_readable)"
else
    print_warning "Command logging setup reported an issue (non-critical) - see output above"
    print_warning "If it flagged old logging lines, remove them from ~/.zshrc and re-run command_logging.sh"
fi

print_status "Applying uniform terminal appearance..."
if bash "$SCRIPT_DIR/terminal_uniform.sh"; then
    print_success "Terminal uniform applied (open a fresh qterminal to see it)"
else
    print_warning "Terminal uniform setup reported an issue (non-critical) - see output above"
fi

print_status "Configuring Burp Suite HTTP logging..."
if bash "$SCRIPT_DIR/burp_logging.sh"; then
    print_success "Burp logging configured (readable log: ~/.burp_history_readable)"
else
    print_warning "Burp logging setup reported an issue (non-critical) - see output above"
fi

echo -e "\n${GREEN}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║     Initial Setup Complete!                           ║"
echo "║     Log file: $LOG_FILE                               ║"
echo "║     Good Luck!!       ~ ziadstr                       ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# --- NEXT STEPS ------------------------------------------------------------
# Everything the operator still has to do by hand: activation of things this
# script *installed* but did not *start*, plus commands that only make sense
# at engagement time (jVision sync, scans).
echo
echo -e "${YELLOW}==============================================================${NC}"
echo -e "${YELLOW}                       NEXT STEPS${NC}"
echo -e "${YELLOW}==============================================================${NC}"

echo
echo -e "${BLUE}[1] Activate command logging${NC} (adds preexec hook to your shell)"
echo "    source ~/.zshrc     # or: source ~/.bashrc, or open a fresh shell"
echo "    New commands land in ~/.zsh_history_readable with timestamps + exit codes."

echo
echo -e "${BLUE}[2] See the uniform terminal look${NC}"
echo "    Open a NEW qterminal or xfce4-terminal window."
echo "    Windows opened before terminal_uniform.sh ran still show the old look."

echo
echo -e "${BLUE}[3] Verify Burp Suite auto-loads the CPTC Engagement Logger${NC}"
echo "    Start Burp -> Extensions tab should show 'CPTC Engagement Logger'."
echo "    Verify it works: hit Repeater once, then:"
echo "        tail -f ~/.burp_history_readable"
echo "    If it did NOT auto-load, see the manual instructions printed by"
echo "    burp_logging.sh above."

echo
echo -e "${BLUE}[4] Install the full tool suite${NC} (heavy; run once per box)"
echo "    bash \"$SCRIPT_DIR/all.sh\""

echo
echo -e "${BLUE}[5] AD-side tools${NC} (run before AD work)"
echo "    bash \"$SCRIPT_DIR/ad.sh\""

echo
echo -e "${BLUE}[6] AT ENGAGEMENT START -- push your logs to jVision${NC}"
echo "    bash \"$SCRIPT_DIR/jvis_logsync.sh\" start -i <jvision-ip> -u <jvis-user>"
echo "    Control commands:"
echo "        bash \"$SCRIPT_DIR/jvis_logsync.sh\" status"
echo "        bash \"$SCRIPT_DIR/jvis_logsync.sh\" log       # tail daemon log"
echo "        bash \"$SCRIPT_DIR/jvis_logsync.sh\" stop"
echo "    (Prompts for your jVision password; JVIS_PASS env var also works.)"

echo
echo -e "${BLUE}[7] Run scans via the jVision client${NC} (from the jVision repo)"
echo "    sudo python3 jvisionclient.py -i <jvision-ip> -p 7777 -s <target-subnet>"
echo "        -n         only run the heavy scan (skip the fast pass)"
echo "        -u         also run UDP top-50 (SNMP/DNS/NetBIOS etc.)"
echo "    OT/ICS ports are excluded automatically -- do NOT override."

echo
echo -e "${YELLOW}==============================================================${NC}"
echo -e "${GREEN}Setup log: $LOG_FILE${NC}"
echo


