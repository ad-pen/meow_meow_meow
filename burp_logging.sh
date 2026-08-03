#!/bin/bash
# Burp Suite HTTP logging setup for CPTC engagements.
#
# Installs a Jython Burp extension (burp_logger.py) that appends one line per
# manual-testing request (Repeater/Intruder/Scanner) to ~/.burp_history_readable.
# Companion to command_logging.sh -- covers the "we're in Burp all day but
# nothing shows up in the shell log" gap for the web team.
#
# What this script does:
#   1. Downloads jython-standalone.jar into ~/.BurpSuite/ (if not present).
#   2. Copies burp_logger.py into ~/.BurpSuite/.
#   3. Best-effort patches UserConfigCommunity.json / UserConfigPro.json so
#      Burp auto-loads the extension on start. A timestamped backup is kept.
#   4. On any structural mismatch (unknown Burp version), falls back to
#      printing one-time manual load instructions.
#
# Usage:  bash burp_logging.sh   (idempotent - safe to re-run)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BURP_DIR="$HOME/.BurpSuite"
JYTHON_JAR="$BURP_DIR/jython-standalone.jar"
JYTHON_VER="2.7.3"
JYTHON_URL="https://repo1.maven.org/maven2/org/python/jython-standalone/${JYTHON_VER}/jython-standalone-${JYTHON_VER}.jar"
EXT_SRC="$SCRIPT_DIR/burp_logger.py"
EXT_DST="$BURP_DIR/burp_logger.py"
LOG_FILE="$HOME/.burp_history_readable"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_status()  { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[+]${NC} $1"; }
print_error()   { echo -e "${RED}[-]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }

if [ ! -f "$EXT_SRC" ]; then
    print_error "Extension source not found next to this script: $EXT_SRC"
    exit 1
fi

mkdir -p "$BURP_DIR"

# Warn (don't fail) if Burp is currently running. Burp rewrites its user config
# on exit, so any auto-load patch we make now would be clobbered.
if pgrep -f 'burpsuite.*\.jar\|BurpSuite.*Community\|BurpSuite.*Pro' >/dev/null 2>&1; then
    print_warning "Burp Suite appears to be running."
    print_warning "Close it and re-run this script if the extension doesn't stay loaded."
fi

# --- 1. Jython jar ---------------------------------------------------------
if [ ! -f "$JYTHON_JAR" ]; then
    print_status "Downloading Jython ${JYTHON_VER} standalone jar (~40MB)..."
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$JYTHON_JAR.tmp" "$JYTHON_URL" && mv "$JYTHON_JAR.tmp" "$JYTHON_JAR"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$JYTHON_JAR.tmp" "$JYTHON_URL" && mv "$JYTHON_JAR.tmp" "$JYTHON_JAR"
    else
        print_error "Neither curl nor wget available. Manual download URL:"
        print_error "  $JYTHON_URL"
        exit 1
    fi
    if [ ! -f "$JYTHON_JAR" ]; then
        print_error "Jython download failed."
        exit 1
    fi
    print_success "Jython jar -> $JYTHON_JAR"
else
    print_success "Jython jar already present ($JYTHON_JAR)"
fi

# --- 2. Extension file ----------------------------------------------------
cp "$EXT_SRC" "$EXT_DST"
print_success "Extension -> $EXT_DST"

# --- 3. Log file ----------------------------------------------------------
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
print_success "Log file  -> $LOG_FILE (mode 0600)"

# --- 4. Auto-load config: patch existing, or seed a fresh file ------------
# Burp stores user options in ~/.BurpSuite/. Two schemas exist:
#   Modern (Burp >= 2023.x): UserConfig.json, with the Jython jar path at
#     user_options.extender.python.location_of_jython_standalone_jar_file
#   Legacy (older builds):   UserConfig{Community,Pro}.json, with the path at
#     user_options.extender.jython_settings.jython_jar
# The extension list (user_options.extender.extensions) is the same in both.
# Burp tolerates partial configs -- any missing top-level keys fall back to
# defaults -- so on a fresh Kali (Burp never launched) we can seed a minimal
# UserConfig.json instead of asking the operator to touch Burp's menus.

if ! command -v python3 >/dev/null 2>&1; then
    print_warning "python3 not available; skipping config auto-patch."
    patched_any=0
else
    patched_any=0
    # Prefer the modern file if present; else patch any legacy ones; else
    # seed the modern name from scratch.
    if [ -f "$BURP_DIR/UserConfig.json" ]; then
        targets=("$BURP_DIR/UserConfig.json")
    else
        targets=()
        [ -f "$BURP_DIR/UserConfigCommunity.json" ] && targets+=("$BURP_DIR/UserConfigCommunity.json")
        [ -f "$BURP_DIR/UserConfigPro.json" ] && targets+=("$BURP_DIR/UserConfigPro.json")
        [ ${#targets[@]} -eq 0 ] && targets+=("$BURP_DIR/UserConfig.json")
    fi

    for cfg in "${targets[@]}"; do
        if [ -f "$cfg" ]; then
            backup="$cfg.cptc-bak-$(date +%s)"
            cp "$cfg" "$backup"
            action="Patched"
            note="(backup: $(basename "$backup"))"
        else
            action="Seeded"
            note="(fresh file - Burp had never been launched)"
        fi
        if python3 - "$cfg" "$JYTHON_JAR" "$EXT_DST" <<'PY'
import json, os, sys
cfg_path, jython_jar, ext_path = sys.argv[1], sys.argv[2], sys.argv[3]
modern = os.path.basename(cfg_path) == "UserConfig.json"

if os.path.exists(cfg_path):
    with open(cfg_path) as f:
        cfg = json.load(f)
else:
    cfg = {}

uo = cfg.setdefault("user_options", {})
ex = uo.setdefault("extender", {})

if modern:
    py = ex.setdefault("python", {})
    py["location_of_jython_standalone_jar_file"] = jython_jar
else:
    js = ex.setdefault("jython_settings", {})
    js["jython_jar"] = jython_jar

exts = ex.setdefault("extensions", [])
# de-dup by extension_file so re-running the installer doesn't stack copies
exts = [e for e in exts if e.get("extension_file") != ext_path]
entry = {
    "errors": "ui",
    "extension_file": ext_path,
    "extension_type": "python",
    "loaded": True,
    "name": "CPTC Engagement Logger",
    "output": "ui",
}
if modern:
    entry["auto_reload"] = False
    entry["use_ai"] = False
exts.append(entry)
ex["extensions"] = exts

with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2)
PY
        then
            print_success "$action $(basename "$cfg") $note"
            patched_any=1
        else
            print_warning "Could not write $(basename "$cfg") (unknown structure)."
        fi
    done
fi

echo
if [ "$patched_any" -eq 1 ]; then
    print_success "Burp will auto-load 'CPTC Engagement Logger' on next start."
    print_status  "Verify: Extensions tab shows it loaded; '$LOG_FILE' grows as you use Repeater/Intruder."
else
    print_warning "Auto-config failed. Do this ONCE inside Burp:"
    print_warning "  1. Settings > Extensions > Python environment > Jython jar file:"
    print_warning "     $JYTHON_JAR"
    print_warning "  2. Extensions > Installed > Add > Type=Python, File=$EXT_DST"
    print_warning "  Burp saves the config on exit; future starts will auto-load."
fi

echo
print_success "Done. Burp HTTP log: $LOG_FILE"
