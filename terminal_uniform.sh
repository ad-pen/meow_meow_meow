#!/bin/bash
# Terminal uniform for CPTC engagements.
# Makes every teammate's qterminal look identical so report screenshots match:
#   - opaque solid-black background  (no wallpaper bleed-through in screenshots)
#   - GreenOnBlack text              (Kali's stock scheme, ships by default)
#   - FiraCode 10                    (Kali's default font, pinned so it can't drift)
#
# Surgical: only the appearance keys below are touched; every other qterminal
# preference is left alone. Idempotent - safe to re-run.
#
# Usage:  bash terminal_uniform.sh
#
# IMPORTANT: qterminal rewrites its config file when it exits, so an open
# qterminal will overwrite these edits on close. Run this with qterminal FULLY
# closed (from a TTY / SSH), or just log out and back in afterwards so new
# windows pick up the change. The script warns if qterminal is running.

INI="$HOME/.config/qterminal.org/qterminal.ini"

# --- the uniform (key=value pairs applied under [General]) ---
UNIFORM=(
    "colorScheme=GreenOnBlack"
    "TerminalTransparency=0"
    "TerminalBackgroundMode=0"   # 0 = solid colour, not a background image
    "fontFamily=FiraCode"
    "fontSize=10"
)

# --- set (or insert) a key under the [General] section of an INI file ---
set_ini_key() {
    local f=$1 k=$2 v=$3
    if grep -q "^${k}=" "$f"; then
        sed -i "s|^${k}=.*|${k}=${v}|" "$f"
    elif grep -q '^\[General\]' "$f"; then
        sed -i "/^\[General\]/a ${k}=${v}" "$f"
    else
        printf '[General]\n%s=%s\n' "$k" "$v" >> "$f"
    fi
}

# --- make sure the config exists ---
mkdir -p "$(dirname "$INI")"
if [ ! -f "$INI" ]; then
    printf '[General]\n' > "$INI"
    echo "[*] No qterminal.ini yet - created a fresh one."
fi

# --- back up once, then apply ---
cp -n "$INI" "$INI.cptcbak" && echo "[+] Backed up current config -> $INI.cptcbak"
for kv in "${UNIFORM[@]}"; do
    set_ini_key "$INI" "${kv%%=*}" "${kv#*=}"
done
echo "[+] Applied uniform to $INI:"
printf '      %s\n' "${UNIFORM[@]}"

# --- warn if qterminal is open (its on-exit save would clobber us) ---
if pgrep -x qterminal >/dev/null 2>&1; then
    echo
    echo "[!] qterminal is currently running. It rewrites this file on exit, which"
    echo "    would UNDO these changes. To make them stick, do ONE of:"
    echo "      - log out and back in, then open qterminal, or"
    echo "      - close every qterminal window, re-run this script from a TTY/SSH,"
    echo "        then open a fresh qterminal."
else
    echo "[*] Open a new qterminal to see the uniform applied."
fi
