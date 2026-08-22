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
        elif sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"; then
            # 'sudo env DEBIAN_FRONTEND=...' is REQUIRED: sudo strips the exported
            # DEBIAN_FRONTEND, so without this, debconf prompts (docker.io's
            # "Remove all Docker data?", neo4j's preconfigure) appear and fail the
            # non-interactive install.
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
PIN_VER[winpeas]="20241011-2e37ba11"; PIN_SHA[winpeas]="TBD"

PIN_URL[pspy64]="https://github.com/DominicBreuker/pspy/releases/download/v1.2.1/pspy64"
PIN_VER[pspy64]="v1.2.1";             PIN_SHA[pspy64]="TBD"

PIN_URL[chisel]="https://github.com/jpillora/chisel/releases/download/v1.10.1/chisel_1.10.1_linux_amd64.gz"
PIN_VER[chisel]="v1.10.1";            PIN_SHA[chisel]="TBD"

PIN_URL[kerbrute]="https://github.com/ropnop/kerbrute/releases/download/v1.0.3/kerbrute_linux_amd64"
PIN_VER[kerbrute]="v1.0.3";           PIN_SHA[kerbrute]="TBD"

PIN_URL[windapsearch]="https://github.com/ropnop/go-windapsearch/releases/download/v0.3.0/windapsearch-linux-amd64"
PIN_VER[windapsearch]="v0.3.0";       PIN_SHA[windapsearch]="TBD"

# --- NOT pinned: these track a moving target. Pin them at the next rehearsal. ---
PIN_URL[linpeas]="https://github.com/carlospolop/PEASS-ng/releases/latest/download/linpeas.sh"
PIN_VER[linpeas]="latest";            PIN_SHA[linpeas]="TBD"

PIN_URL[powerup]="https://raw.githubusercontent.com/PowerShellMafia/PowerSploit/master/Privesc/PowerUp.ps1"
PIN_VER[powerup]="master";            PIN_SHA[powerup]="TBD"

PIN_URL[privesc_ps1]="https://raw.githubusercontent.com/enjoiz/Privesc/refs/heads/master/privesc.ps1"
PIN_VER[privesc_ps1]="master";        PIN_SHA[privesc_ps1]="TBD"

PIN_URL[privesccheck]="https://github.com/itm4n/PrivescCheck/releases/latest/download/PrivescCheck.ps1"
PIN_VER[privesccheck]="latest";       PIN_SHA[privesccheck]="TBD"

PIN_URL[username_anarchy]="https://raw.githubusercontent.com/urbanadventurer/username-anarchy/refs/heads/master/username-anarchy"
PIN_VER[username_anarchy]="master";   PIN_SHA[username_anarchy]="TBD"

PIN_URL[upshell]="https://raw.githubusercontent.com/brightio/penelope/main/extras/manual_tty_upgrade.sh"
PIN_VER[upshell]="main";              PIN_SHA[upshell]="TBD"

# Where each box records what it ACTUALLY got. Diff this file between two
# operators' boxes: any difference is a build that will not reproduce.
PINS_LOCK="${PINS_LOCK:-$HOME/pins.lock}"

record_pin() {   # <name> <version-or-commit> <sha256-or-->
    printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" "$2" "$3" >> "$PINS_LOCK"
}

# fetch_pinned <pin-name> <dest> [sudo]
# Idempotent (skips if dest exists), retries, verifies sha256 when the manifest
# has one, records what actually landed, and flags anything unpinned.
fetch_pinned() {
    local name=$1 dest=$2 pre=${3:-} url=${PIN_URL[$1]:-} want=${PIN_SHA[$1]:-TBD} ver=${PIN_VER[$1]:-?} got
    if [ -z "$url" ]; then
        print_error "fetch_pinned: no manifest entry for '$name'"
        return 1
    fi
    if [ -s "$dest" ]; then
        print_success "$(basename "$dest") already present (skip)"
        return 0
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
    record_pin "$name" "$ver" "${got:--}"
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
    record_pin "$name" "${tag:-HEAD}" "$commit"
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
        record_pin "$bin" "@$ver" "$out"
    else
        print_warning "$bin install failed"
    fi
    return 0
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
    else
        print_success "Every downloaded artifact was version-pinned and hash-verified."
    fi
    [ -f "$PINS_LOCK" ] && print_status "What this box actually got: $PINS_LOCK"
    return 0
}
