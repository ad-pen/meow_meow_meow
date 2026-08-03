#!/bin/bash

set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="$HOME/all_install.log"
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
# package/download from silently sinking a whole batch.
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
            # DEBIAN_FRONTEND, so without this, debconf prompts (e.g. docker.io's
            # "Remove all Docker data?") appear and fail non-interactive installs.
            print_success "$pkg installed"
        else
            print_warning "$pkg FAILED to install"
            APT_FAILED+=("$pkg")
        fi
    done
}

# Idempotent pip install: skip entirely if the module already imports, so re-runs
# and cross-script duplicates don't re-resolve/re-download. $1=import name, rest=pip specs.
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

# Idempotent download with retries: skip if the destination already exists.
# $1=url  $2=dest path  $3=optional 'sudo' to write privileged paths.
fetch() {
    local url=$1 dest=$2 pre=${3:-}
    if [ -s "$dest" ]; then
        print_success "$(basename "$dest") already present (skip)"
        return 0
    fi
    if $pre curl -fSL --retry 3 --connect-timeout 15 "$url" -o "$dest"; then
        return 0
    fi
    print_warning "download failed: $(basename "$dest")"
    return 1
}

echo -e "${GREEN}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║     PSUT VAPT Team - Full Tool Installation           ║"
echo "║     Installing comprehensive pentesting suite...      ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# NOTE: shell-history growth + command logging moved to command_logging.sh, which
# start.sh runs. Do not re-add inline HISTSIZE/preexec lines here - command_logging.sh
# refuses to run when it detects those stale, un-guarded hooks in ~/.zshrc.

if xfconf-query -c xfwm4 -p /general/use_compositing -s false ; then
    print_success "Shell display settings configured"
else 
    print_warning "Shell display configuration failed"
fi


if [ -d "$HOME/dropzone" ]; then
    print_warning "Dropzone directory exists, maybe you ran this before?"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_error "Installation cancelled by user"
        exit 1
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
    wget aircrack-ng set sqlmap hydra docker.io openjdk-11-jdk john awscli \
    sshuttle ffuf burpsuite python3.13-venv nuclei dirsearch flameshot scrot \
    maim cyberchef enum4linux nikto wfuzz steghide binwalk exiftool \
    netcat-traditional socat proxychains4 masscan metasploit-framework responder \
    crackmapexec zaproxy wireshark tcpdump tmux screen remmina terminator

print_status "Installing docker-compose..."
if command -v docker-compose &>/dev/null; then
    print_success "docker-compose already installed: $(docker-compose --version 2>&1)"
elif sudo curl -fSL --retry 3 --connect-timeout 15 "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose && sudo chmod +x /usr/local/bin/docker-compose; then
    print_success "docker-compose installed: $(docker-compose --version 2>&1)"
else
    print_warning "docker-compose installation failed (non-critical)"
fi

print_status "Adding user to docker group..."
if sudo usermod -aG docker $USER; then
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
fetch https://github.com/carlospolop/PEASS-ng/releases/latest/download/linpeas.sh ~/dropzone/privesc/linpeas.sh
fetch https://raw.githubusercontent.com/PowerShellMafia/PowerSploit/master/Privesc/PowerUp.ps1 ~/dropzone/privesc/PowerUp.ps1
fetch https://github.com/peass-ng/PEASS-ng/releases/download/20241011-2e37ba11/winPEASx64.exe ~/dropzone/privesc/winpeas.exe
fetch https://raw.githubusercontent.com/enjoiz/Privesc/refs/heads/master/privesc.ps1 ~/dropzone/privesc/privesc.ps1
fetch https://github.com/itm4n/PrivescCheck/releases/latest/download/PrivescCheck.ps1 ~/dropzone/privesc/PrivescCheck.ps1
chmod +x ~/dropzone/privesc/linpeas.sh 2>/dev/null
fin_msg 'Privesc Scripts'

print_status "Downloading pspy64..."
if fetch https://github.com/DominicBreuker/pspy/releases/download/v1.2.1/pspy64 ~/dropzone/pspy64; then
    chmod +x ~/dropzone/pspy64
    fin_msg 'pspy64'
fi

print_status "Downloading username-anarchy..."
if fetch https://raw.githubusercontent.com/urbanadventurer/username-anarchy/refs/heads/master/username-anarchy ~/dropzone/username-anarchy; then
    chmod +x ~/dropzone/username-anarchy
fi

print_status "Downloading upshell (TTY upgrade helper)..."
if [ -f /usr/local/bin/upshell ]; then
    print_success "upshell already installed (skip)"
elif fetch https://raw.githubusercontent.com/brightio/penelope/main/extras/manual_tty_upgrade.sh ~/dropzone/upshell; then
    sudo cp ~/dropzone/upshell /usr/local/bin/upshell && sudo chmod +x /usr/local/bin/upshell
    print_success "upshell installed to /usr/local/bin/upshell"
    fin_msg 'upshell'
fi

print_status "Downloading chisel..."
# chisel release assets are a gzipped BINARY (chisel_<ver>_linux_amd64.gz), NOT a
# tarball - the old .tar.gz URL 404'd, so chisel never installed. Gunzip, don't untar.
if command -v chisel &>/dev/null; then
    print_success "chisel already installed: $(chisel --version 2>&1)"
elif wget -q --tries=3 --timeout=30 https://github.com/jpillora/chisel/releases/download/v1.10.1/chisel_1.10.1_linux_amd64.gz -O chisel.gz && \
     gunzip -f chisel.gz && chmod +x chisel && sudo mv chisel /usr/local/bin/chisel; then
    print_success "chisel installed: $(chisel --version 2>&1)"
    fin_msg 'chisel'
else
    print_warning "chisel installation failed"
    rm -f chisel.gz chisel
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
    if sudo git clone https://github.com/00xBAD/kali-wordlists.git /usr/share/wordlists/kali-wordlists; then
        print_success "Kali wordlists cloned"
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
if [ ! -d "nuclei-templates" ]; then
    if git clone https://github.com/projectdiscovery/nuclei-templates.git; then
        templates_count=$(find nuclei-templates -name "*.yaml" | wc -l)
        print_success "Nuclei templates cloned ($templates_count templates)"
        fin_msg 'Nuclei Templates'
    else
        print_warning "Nuclei templates clone failed"
    fi
else
    print_success "Nuclei templates already exist"
fi


print_status "Cloning SSTImap"
cd ~/dropzone
if [ ! -d "SSTImap" ]; then
    if git clone https://github.com/vladko312/SSTImap.git; then
        print_success "SSTImap cloned"
    else
        print_warning "SSTImap clone failed"
    fi
else
    print_success "SSTImap already exists"
fi


print_status "Installing additional useful Go tools..."
export GOPATH=$HOME/go
export PATH=$PATH:$GOPATH/bin

# go install COMPILES from source each time - skip if the binary already exists so
# re-runs don't recompile (the single biggest time sink on a re-run).
go_install() {   # $1=binary name  $2=module path
    if command -v "$1" &>/dev/null || [ -x "$GOPATH/bin/$1" ]; then
        print_success "$1 already installed (skip)"
    elif go install "$2" 2>/dev/null; then
        print_success "$1 installed"
    else
        print_warning "$1 install failed"
    fi
}
go_install httprobe    github.com/tomnomnom/httprobe@latest
go_install waybackurls github.com/tomnomnom/waybackurls@latest
go_install subfinder   github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
go_install httpx       github.com/projectdiscovery/httpx/cmd/httpx@latest

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

check_tool() {
    local tool=$1
    local test_cmd=${2:-"$tool --version"}

    if command -v $tool &> /dev/null; then
        if eval "$test_cmd" &> /dev/null; then
            print_success "$tool verified"
            ((PASS++))
        else
            print_warning "$tool installed but may not be functional"
            ((WARN++))
        fi
    else
        print_error "$tool NOT installed"
        ((FAIL++))
    fi
}

check_file() {
    local file=$1
    local desc=$2

    if [ -f "$file" ]; then
        print_success "$desc verified"
        ((PASS++))
    else
        print_error "$desc NOT found"
        ((FAIL++))
    fi
}

print_status "Checking core scanning tools..."
check_tool "nmap"
check_tool "masscan" "command -v masscan"
check_tool "gobuster"
check_tool "ffuf" "ffuf -V"
check_tool "feroxbuster"

print_status "Checking web tools..."
check_tool "sqlmap"
check_tool "nikto"
check_tool "nuclei"
check_tool "whatweb"

print_status "Checking network tools..."
check_tool "chisel"
check_tool "socat" "socat -V"
check_tool "proxychains4" "command -v proxychains4"

print_status "Checking password tools..."
check_tool "hydra" "command -v hydra"
check_tool "john" "command -v john"
check_tool "hashcat"

print_status "Checking screenshot tools..."
check_tool "flameshot"
check_tool "scrot" "scrot --version"

print_status "Checking privilege escalation scripts..."
check_file "$HOME/dropzone/privesc/linpeas.sh" "linpeas.sh"
check_file "$HOME/dropzone/privesc/winpeas.exe" "winpeas.exe"
check_file "$HOME/dropzone/pspy64" "pspy64"

print_status "Checking wordlists..."
check_file "/usr/share/wordlists/rockyou.txt" "rockyou.txt"

print_status "Checking Python packages..."
python3 -c "import requests" 2>/dev/null && print_success "requests verified" && ((PASS++)) || (print_error "requests NOT working" && ((FAIL++)))
python3 -c "import pwn" 2>/dev/null && print_success "pwntools verified" && ((PASS++)) || (print_error "pwntools NOT working" && ((FAIL++)))

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
