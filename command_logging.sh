#!/bin/bash
# Command logging setup for CPTC engagements.
# Produces a timestamped, human-readable log of every interactive command at
# ~/.zsh_history_readable  ->  hand this over if the client asks for activity logs.
# Both zsh and bash interactive shells write to the same log.
#
# Each line: <time> (exit <code>) <command>
#   2026-07-07 22:05:01 (exit 0) nmap -sV 10.0.0.5
#
# POLICY: every SECRET is redacted; every USERNAME is kept in full.
#
# Redacted -> [REDACTED]:
#   passwords, NTLM/LM hashes, Kerberos keys and tickets, and web secrets
#   (Authorization/Cookie/X-API-Key headers, --cookie/--token/--api-token, HTTP
#   basic auth, password=/token= in POST bodies and JSON) for known tools
#   (netexec/nxc, impacket, evil-winrm, smbclient, ldapsearch, hydra, sshpass,
#   curl -u, certipy, Rubeus-style /ticket:, user:pass@host, ...).
#
# NOT redacted: usernames, domains, hostnames and IPs. Keeping them is
# deliberate - the log's job is to let the client answer "which account touched
# this host at time T", and a masked username makes it useless for exactly the
# incident-response question it exists to answer. The secret is what must never
# be in the file; the identity is the point of the file.
#
# The command still RUNS unmodified; only the LOGGED text is scrubbed.
# This is best-effort pattern matching - see the redactor's notes.
#
# Usage:  bash command_logging.sh      (idempotent - safe to re-run)
# Then:   source ~/.zshrc  (or ~/.bashrc, or open a new shell)


# ---------------------------------------------------------------------------
# WHOSE HOME IS IT?  - duplicated from lib.sh ON PURPOSE
# ---------------------------------------------------------------------------
# This script is standalone: start.sh, all.sh and smol-all.sh all invoke it, and
# it must work without sourcing anything. Keep in step with cptc_user_home() in
# lib.sh.
#
# It writes into the OPERATOR's home. Under sudo, $HOME is /root, so everything
# below would configure root's account and the real user would get none of it -
# while the verification afterwards looked in the real home and reported it
# missing. The home is therefore derived from this script's own path: an operator
# clones the repo into their own home, so the path names them.
_cptc_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cptc_user_home() {
    local dir u home
    dir="$_cptc_script_dir"
    if [[ $dir =~ ^/home/([^/]+)(/|$) ]]; then
        u="${BASH_REMATCH[1]}"
        home=$(getent passwd "$u" 2>/dev/null | cut -d: -f6)
        if [ -n "$home" ] && [ -d "$home" ]; then printf '%s\n' "$home"; return 0; fi
        if [ -d "/home/$u" ]; then printf '%s\n' "/home/$u"; return 0; fi
    fi
    if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
        home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
        if [ -n "$home" ] && [ -d "$home" ]; then printf '%s\n' "$home"; return 0; fi
    fi
    printf '%s\n' "$HOME"
}
USER_HOME="${USER_HOME:-$(cptc_user_home)}"
CPTC_USER="$(stat -c %U "$USER_HOME" 2>/dev/null || id -un)"
own_user() {
    [ "$(id -u)" -eq 0 ] || return 0
    [ -n "${CPTC_USER:-}" ] || return 0
    chown -R "$CPTC_USER:" "$@" 2>/dev/null
    return 0
}

ZSHRC="$USER_HOME/.zshrc"
BASHRC="$USER_HOME/.bashrc"
MARKER="cptc engagement logging"

# --- warn about stale one-liners from an earlier version of this script ---
# (the old version appended an un-guarded preexec() + HISTFILESIZE line;
#  HISTFILESIZE is a bash var and does nothing in zsh, so history still rolled off)
if grep -q "zsh_history_readable" "$ZSHRC" 2>/dev/null && ! grep -q "$MARKER" "$ZSHRC" 2>/dev/null; then
    echo "[!] Found logging lines from an older version of this script in $ZSHRC."
    echo "    Remove the old 'preexec()' and 'HISTSIZE/HISTFILESIZE' lines to avoid"
    echo "    stacking duplicate hooks, then re-run this script."
    exit 1
fi

# --- the credential redactor, defined ONCE ---------------------------------
# This block is IDENTICAL for zsh and bash - only the hook wiring around it
# differs - and it used to be pasted into both rc blocks verbatim: ~120 lines,
# twice, in one file. That is exactly how a new redaction rule gets added to the
# zsh copy only, while the bash copy keeps writing that credential into the SAME
# log file, with nothing anywhere to warn you. Emitted from here into both.
_emit_redactor() {
cat <<'REDACTOR_EOF'
# Credential redaction: scrub passwords/hashes/keys from the LOGGED text only
# (the command still RUNS unmodified).
# USERNAMES ARE KEPT IN FULL - they are not masked at all. That is deliberate and
# is the whole point of the log: the client needs to answer "which account touched
# this host at time T", and a masked username defeats the only question the file
# exists to answer. See command_logging.sh's header, and the note at the bottom of
# this block. (This comment used to claim usernames were partially masked, which
# had not been true for some time.)
_cptc_tool() {                              # first real tool, skipping wrappers
    local cmd=$1 first rest
    while [ -n "$cmd" ]; do
        read -r first rest <<< "$cmd"
        case ${first##*/} in
            sudo|doas|proxychains|proxychains4|python|python2|python3|ruby|perl|env|time|stdbuf|nohup|*=*)
                cmd=$rest ;;
            *) printf '%s' "${first##*/}"; return ;;
        esac
    done
}
_cptc_redact() {
    local cmd=$1 tool prog
    tool=$(_cptc_tool "$cmd")
    # a flag value may be bare, '\x27quoted\x27' or "quoted" (\x27 = a single quote)
    local V="(\x27[^\x27]*\x27|\"[^\"]*\"|[^[:space:]]+)"
    # always-on: unambiguous secret patterns, any tool
    prog="
      s/((--password|--passwd|-password|--pw|-hashes|--hashes|--pw-nt-hash|-nthash|-lmhash|-aesKey|--aesKey)([[:space:]]+|=))$V/\\1[REDACTED]/g
      s/(sshpass[[:space:]]+-p[[:space:]]*)$V/\\1[REDACTED]/g
      s/([[:alnum:]._\$-]+:)(\x27[^\x27]*\x27|\"[^\"]*\")@([[:alnum:].:-]+)/\\1[REDACTED]@\\3/g
      s/([[:alnum:]._\$-]+:)[^[:space:]\x27\"\/]+(@[[:alnum:].:-]+)/\\1[REDACTED]\\2/g
      s/(-U[[:space:]]*[^%[:space:]]+%)[^[:space:]]+/\\1[REDACTED]/g
      s/((--api-token|--auth-token|--bearer|--api-key|--apikey|--token|--http-token)([[:space:]]+|=))$V/\\1[REDACTED]/g
      s/(--http-auth[[:space:]=]+[^:[:space:]]+:)[^[:space:]]+/\\1[REDACTED]/g
      s/(authorization:[[:space:]]*)[^\x27\"]*/\\1[REDACTED]/gI
      s/(cookie:[[:space:]]*)[^\x27\"]*/\\1[REDACTED]/gI
      s/((--cookie|--cookies)[[:space:]=]+)$V/\\1[REDACTED]/g
      s/(password|passwd|passphrase|pwd|pass|token|secret|api_key|apikey)=[^&\x27\"[:space:]]+/\\1=[REDACTED]/gI
      s/(x-[a-z-]*(key|token):[[:space:]]*)[^\x27\"]*/\\1[REDACTED]/gI
      s/(\"(password|passwd|passphrase|pwd|token|secret|api_key|apikey)\"[[:space:]]*:[[:space:]]*)\"[^\"]*\"/\\1\"[REDACTED]\"/gI
      s/((--ticket|-ticket|--tgt|--tgs|--krbcred|--pfx-pass|-pfx-pass|--cert-pass)([[:space:]]+|=))$V/\\1[REDACTED]/g
      s#(/(ticket|krbcred):)[^[:space:]]+#\\1[REDACTED]#g
      s/(doI|YII)[A-Za-z0-9+\/=_-]{60,}/[REDACTED-TICKET]/g
      s/((aws_secret_access_key|aws_session_token|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN)[[:space:]]+)[^[:space:]]+/\\1[REDACTED]/g
    "
    # The aws rule above is always-on and matches a BARE POSITIONAL secret:
    #   aws configure set aws_secret_access_key wJalrXUtnFEMIK7MDENGbPxRfiCY
    # There is no flag to gate on, but the key names are unambiguous enough that
    # this is safe for any tool. aws_access_key_id is deliberately NOT redacted -
    # it identifies the principal, which is the half of the pair the log exists to
    # record (same reasoning as usernames, below).
    # tool-gated: short flags are ambiguous, so key off the detected tool.
    # -p = password (NOT nmap -p port)
    #
    # ⚠️ THIS LIST IS A DENY-BY-DEFAULT GATE: a tool missing from it logs the
    # password IN CLEAR. Adding a tool to the build means checking it here.
    # The seven names after 'bloodyad' were added 2026-10-05 after testing the
    # redactor against real invocations: every one of them is installed by these
    # scripts, takes -p <password>, and was leaking. certipy was the worst of them
    # (ADCS work and every Certighost step), followed by az/roadrecon on the cloud
    # side. Before adding a tool, confirm its -p is NOT a port (that is why nmap,
    # smbmap -P and ldapsearch -p are deliberately absent).
    case " netexec nxc crackmapexec cme evil-winrm evil-winrm.rb hydra medusa smbmap bloodhound.py bloodhound-python bloodyAD bloodyad certipy certipy-ad certipy.py az roadrecon enum4linux enum4linux-ng enum4linux.pl targetedKerberoast targetedKerberoast.py pywhisker pywhisker.py bloodhound-ce-python mssqlclient.py mysql psql " in
      *" $tool "*) prog="$prog
        s/((-p)([[:space:]]+|=))$V/\\1[REDACTED]/g
        s/((^|[[:space:]])-p)[^[:space:]=-][^[:space:]]*/\\1[REDACTED]/g" ;;
    esac
    # The SECOND rule above catches the ATTACHED form with no space and no '=' -
    # 'mysql -u root -ptoor' - which the first rule cannot see because it requires
    # a separator. It is anchored to start-or-whitespace followed by a SINGLE dash
    # so it cannot chew into '--password' (where the -p is preceded by '-', not
    # whitespace), and the value's first character excludes '-' so '-p -x' is left
    # alone. Without the anchor it rewrote '--password x' to '--p[REDACTED] x',
    # mangling the flag while leaving the secret.

    # -P = basic-auth password (gobuster). NOT hydra/medusa -P, which is a password
    # LIST FILE: the path is not a secret, and redacting it deletes the one detail
    # the report's reproduction steps need ("which wordlist?"). hydra's single
    # password is -p, which the gate above already covers.
    case " gobuster " in
      *" $tool "*) prog="$prog
        s/((-P)([[:space:]]+|=))$V/\\1[REDACTED]/g" ;;
    esac
    # kerbrute's password-spray password is POSITIONAL and last:
    #   kerbrute passwordspray [flags] <userfile> <password>
    # There is no flag to key off, so this is gated on the tool AND the subcommand,
    # and it replaces the final token. A token starting with '-' is skipped so
    # 'kerbrute passwordspray -h' is not mangled.
    case " kerbrute " in
      *" $tool "*) prog="$prog
        s/(passwordspray.*[[:space:]])[^-[:space:]][^[:space:]]*[[:space:]]*\$/\\1[REDACTED]/" ;;
    esac
    # -w = LDAP bind password (ldapsearch); ldapsearch -p is a PORT, left alone
    case " ldapsearch " in
      *" $tool "*) prog="$prog
        s/((-w)([[:space:]]+|=))$V/\\1[REDACTED]/g" ;;
    esac
    # -H = NTLM hash (nxc/cme/evil-winrm); NOT smbmap/ldapsearch -H (=host)
    case " netexec nxc crackmapexec cme evil-winrm evil-winrm.rb " in
      *" $tool "*) prog="$prog
        s/((-H)([[:space:]]+|=))$V/\\1[REDACTED]/g" ;;
    esac
    # -u user:pass (curl/wget); gated so docker -u 1000:1000 is left alone
    case " curl wget " in
      *" $tool "*) prog="$prog
        s/((-[[:alpha:]]*u|--user)[[:space:]=]+[^:[:space:]]+:)[^[:space:]]+/\\1[REDACTED]/g" ;;
    esac
    # gated: impacket "domain/user:password" with no @host
    case $tool in
      *.py|impacket-*) prog="$prog"'
        s#(/[[:alnum:]._$-]+:)[^[:space:]@]+#\1[REDACTED]#g
      ' ;;
    esac

    # NO USERNAME MASKING. Usernames, domains and hosts are kept verbatim - see
    # the policy note in this script's header. Every rule above targets only the
    # secret half of a pair, so "-u administrator -p hunter2" logs the account
    # in full and the password not at all.
    printf '%s\n' "$cmd" | sed -E "$prog"
}
REDACTOR_EOF
}

# --- install the logging block (guarded so re-running is a no-op) ---
if ! grep -q "$MARKER" "$ZSHRC" 2>/dev/null; then
{
cat <<'EOF'

# >>> cptc engagement logging >>>
# Grow history so nothing rolls off mid-engagement. In zsh the on-disk cap is
# SAVEHIST (NOT HISTFILESIZE, which is bash-only); EXTENDED_HISTORY timestamps
# the native ~/.zsh_history and INC_APPEND_HISTORY flushes each command as it
# runs, so a crash or lost box still leaves a record.
export HISTSIZE=100000
export SAVEHIST=100000
setopt EXTENDED_HISTORY INC_APPEND_HISTORY

# Human-readable log with time and exit status for the client.
_cptc_log=~/.zsh_history_readable
typeset -g _cptc_cmd _cptc_ts

EOF
_emit_redactor
cat <<'EOF'

_cptc_preexec() {
    _cptc_cmd=$1
    _cptc_ts=$(date '+%Y-%m-%d %H:%M:%S')   # time the command was launched
}
_cptc_precmd() {
    local ret=$?                            # must be captured first
    [[ -n $_cptc_cmd ]] || return           # skip empty prompts / startup
    local safe=$(_cptc_redact "$_cptc_cmd") # scrub secrets before writing
    printf '%s (exit %d) %s\n' \
        "$_cptc_ts" "$ret" "$safe" >> "$_cptc_log"
    _cptc_cmd=
}
# add-zsh-hook APPENDS to the preexec/precmd hook arrays instead of replacing a
# distro's existing preexec()/precmd() (Kali/Debian define a precmd that sets the
# terminal title) -- so our logging coexists with the stock prompt.
autoload -Uz add-zsh-hook
add-zsh-hook preexec _cptc_preexec
add-zsh-hook precmd _cptc_precmd
# <<< cptc engagement logging <<<
EOF
} >> "$ZSHRC"
    echo "[+] Logging block added to $ZSHRC"
else
    echo "[=] Logging block already present in $ZSHRC (nothing to do)"
fi

# --- install the same logging into bash (guarded so re-running is a no-op) ---
if ! grep -q "$MARKER" "$BASHRC" 2>/dev/null; then
{
cat <<'EOF'

# >>> cptc engagement logging >>>
# Grow history so nothing rolls off mid-engagement, and flush each command as it
# runs (histappend + PROMPT_COMMAND) so a crash still leaves a record.
export HISTSIZE=100000
export HISTFILESIZE=100000
export HISTTIMEFORMAT='%Y-%m-%d %H:%M:%S '
shopt -s histappend

# Human-readable log with time and exit status for the client.
# Reads bash's own history to get the exact line typed (full pipelines/&&),
# de-duped by history number. Time logged is when the command RETURNED.
_cptc_log=~/.zsh_history_readable
_cptc_last_hist=-1
_cptc_primed=          # bash loads ~/.bash_history AFTER .bashrc, so we can't
                       # seed at source time; seed on the first prompt instead

EOF
_emit_redactor
cat <<'EOF'
_cptc_precmd() {
    local ret=$? line num cmd
    line=$(HISTTIMEFORMAT= history 1)              # "  512  nmap -sV 10.0.0.5"
    num=${line%%[^ 0-9]*}; num=${num//[!0-9]/}     # leading history number
    if [[ -z $_cptc_primed ]]; then                # first prompt of the shell:
        _cptc_primed=1; _cptc_last_hist=${num:--1} # adopt pre-existing history,
        return                                     # don't log the prior session
    fi
    [[ -z $num || $num == "$_cptc_last_hist" ]] && return   # nothing new typed
    _cptc_last_hist=$num
    cmd=${line#*"$num"}; cmd=${cmd#"${cmd%%[![:space:]]*}"}  # strip num + ltrim
    cmd=$(_cptc_redact "$cmd")                               # scrub secrets before writing
    printf '%s (exit %d) %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$ret" "$cmd" >> "$_cptc_log"
}
# Keep our logger armed even if something reassigns PROMPT_COMMAND. Kali's stock
# .bashrc sets PROMPT_COMMAND="PROMPT_COMMAND=echo" (a newline-before-prompt hack)
# that drops any prepended hook after the first prompt. This DEBUG trap re-adds us
# before each interactive command if we've been knocked out -- cheap, distro-agnostic,
# and it only fires at the interactive prompt (functions/subshells don't inherit it).
_cptc_arm() {
    case "${PROMPT_COMMAND[*]}" in
        *_cptc_precmd*) ;;                                    # still armed
        *) PROMPT_COMMAND="_cptc_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
    esac
}
trap '_cptc_arm' DEBUG
_cptc_arm      # initial install (prepend so $? is captured before other hooks)
# <<< cptc engagement logging <<<
EOF
} >> "$BASHRC"
    echo "[+] Logging block added to $BASHRC"
else
    echo "[=] Logging block already present in $BASHRC (nothing to do)"
fi

# --- make sure the log file exists and is only readable by you ---
touch "$USER_HOME/.zsh_history_readable"
chmod 600 "$USER_HOME/.zsh_history_readable"
# If we got here as root (sudo run), hand the files back - otherwise the shell
# hooks cannot append to their own log and nothing is recorded.
own_user "$USER_HOME/.zsh_history_readable" "$ZSHRC" "$BASHRC"

echo "[+] Readable log: $USER_HOME/.zsh_history_readable (zsh + bash both write here)"
echo "[*] Run 'source $USER_HOME/.zshrc' (or ~/.bashrc, or open a new shell) to activate."
