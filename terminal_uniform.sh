#!/bin/bash
# Terminal uniform for CPTC engagements.
# Makes every teammate's terminal look identical so report screenshots match, for
# BOTH terminals in play on our boxes:
#   - qterminal        (Kali's default local terminal)
#   - xfce4-terminal   (the terminal in the XFCE/xRDP remote session start.sh sets up)
#
# Applied look (identical on both emulators):
#   - opaque solid-black background  (no wallpaper/transparency bleed in screenshots)
#   - green-on-black text            (matches qterminal's stock GreenOnBlack scheme)
#   - FiraCode 10                    (Kali's default font, pinned so it can't drift)
#
# Surgical: only the appearance keys below are touched; every other preference is
# left alone. Idempotent - safe to re-run. Each config is backed up once (*.cptcbak).
#
# Usage:  bash terminal_uniform.sh
#
# IMPORTANT: qterminal rewrites its ENTIRE config file to its in-memory settings
# every time it exits. So any qterminal that was already open when we applied the
# uniform (e.g. the one you ran this from) will overwrite our edits back to its
# defaults on close - and logging out clobbers it for exactly this reason.
# To make the uniform stick regardless, we set qterminal.ini immutable (chattr +i)
# after writing it, so qterminal's on-exit save silently fails and our config stays.
# This needs root (start.sh already primes sudo); it degrades to a warning otherwise.
# To change qterminal settings later:  sudo chattr -i ~/.config/qterminal.org/qterminal.ini
# xfce4-terminal does NOT rewrite on exit, so it needs no lock - only NEW windows
# pick up the change.

# green-on-black, chosen to approximate qterminal's GreenOnBlack scheme. Both
# emulators use these same two values, so tune here for an exact pixel match.
GREEN_FG="#18b218"
BLACK_BG="#000000"
FONT="FiraCode 10"

QT_INI="$HOME/.config/qterminal.org/qterminal.ini"
XT_INI="$HOME/.config/xfce4/terminal/terminalrc"

# --- set (or insert) key=value under a named [Section] of an INI-style file ---
# Key match is file-global (both configs keep each key in a single section), which
# mirrors the original qterminal-only version.
set_ini_key() {
    local f=$1 section=$2 k=$3 v=$4
    if grep -q "^${k}=" "$f"; then
        sed -i "s|^${k}=.*|${k}=${v}|" "$f"
    elif grep -q "^\[${section}\]" "$f"; then
        sed -i "/^\[${section}\]/a ${k}=${v}" "$f"
    else
        printf '[%s]\n%s=%s\n' "$section" "$k" "$v" >> "$f"
    fi
}

# --- ensure the config exists, back it up once, then apply all key=value pairs ---
apply_uniform() {
    local f=$1 section=$2; shift 2
    mkdir -p "$(dirname "$f")"
    if [ ! -f "$f" ]; then
        printf '[%s]\n' "$section" > "$f"
        echo "[*] No $(basename "$f") yet - created a fresh one."
    fi
    cp -n "$f" "$f.cptcbak" && echo "[+] Backed up current config -> $f.cptcbak"
    local kv
    for kv in "$@"; do
        set_ini_key "$f" "$section" "${kv%%=*}" "${kv#*=}"
    done
    echo "[+] Applied uniform to $f:"
    printf '      %s\n' "$@"
}

# --- qterminal ([General] section, its own key names / value encodings) ---
# Unlock first so a previous run's immutable bit doesn't block our edits (no-op if
# not set / not root).
sudo chattr -i "$QT_INI" 2>/dev/null

apply_uniform "$QT_INI" General \
    "colorScheme=GreenOnBlack" \
    "TerminalTransparency=0" \
    "TerminalBackgroundMode=0" \
    "fontFamily=FiraCode" \
    "fontSize=10"

# Lock it so no open/closing qterminal can overwrite it on exit (see header).
if sudo chattr +i "$QT_INI" 2>/dev/null; then
    echo "[+] Locked $QT_INI (immutable) - qterminal can no longer revert it."
    echo "    To edit qterminal settings later:  sudo chattr -i \"$QT_INI\""
else
    echo "[!] Could NOT lock $QT_INI (need root, or filesystem lacks chattr support)."
    echo "    Without the lock, apply this with ALL qterminal windows closed (from a"
    echo "    TTY/SSH) or an open qterminal will overwrite it again on exit."
fi

echo

# --- xfce4-terminal ([Configuration] section, explicit colours = same look) ---
apply_uniform "$XT_INI" Configuration \
    "FontName=$FONT" \
    "ColorForeground=$GREEN_FG" \
    "ColorBackground=$BLACK_BG" \
    "BackgroundMode=TERMINAL_BACKGROUND_SOLID"

# --- warn about any terminal that's open right now ---
running=()
pgrep -x qterminal      >/dev/null 2>&1 && running+=("qterminal")
pgrep -x xfce4-terminal >/dev/null 2>&1 && running+=("xfce4-terminal")
if [ ${#running[@]} -gt 0 ]; then
    echo
    echo "[!] Currently open: ${running[*]}"
    echo "    These windows still show the OLD look until you close them - just open a"
    echo "    NEW terminal to see the uniform. If qterminal.ini was locked above, those"
    echo "    open windows can no longer revert it on exit."
else
    echo
    echo "[*] Open a new terminal (qterminal or xfce4-terminal) to see the uniform."
fi
