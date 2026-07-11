#!/bin/bash
# Command logging setup for CPTC engagements.
# Produces a timestamped, human-readable log of every interactive command at
# ~/.zsh_history_readable  ->  hand this over if the client asks for activity logs.
# Both zsh and bash interactive shells write to the same log.
#
# Each line: <time> [<working dir>] (exit <code>) <command>
#   2026-07-07 22:05:01 [/home/mewo/engagement] (exit 0) nmap -sV 10.0.0.5
#
# Credentials are redacted from the LOG (the command still runs unchanged):
# passwords, NTLM hashes and Kerberos keys become [REDACTED] for known tools
# (netexec/nxc/cme, impacket, evil-winrm, smbclient, ldapsearch, hydra, sshpass,
# curl -u, user:pass@host, ...) plus web secrets (Authorization/Cookie/X-API-Key
# headers, --cookie/--token/--api-token, HTTP basic auth, and password=/token= in
# POST bodies and JSON). Usernames are partially masked - the first 2 chars are
# kept and the rest becomes [REDACTED] (administrator -> ad[REDACTED]); usernames
# of 2 chars or fewer are left as-is. This is best-effort; see the redactor's notes.
#
# Usage:  bash command_logging.sh      (idempotent - safe to re-run)
# Then:   source ~/.zshrc  (or ~/.bashrc, or open a new shell)

ZSHRC=~/.zshrc
BASHRC=~/.bashrc
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

# --- install the logging block (guarded so re-running is a no-op) ---
if ! grep -q "$MARKER" "$ZSHRC" 2>/dev/null; then
cat >> "$ZSHRC" <<'EOF'

# >>> cptc engagement logging >>>
# Grow history so nothing rolls off mid-engagement. In zsh the on-disk cap is
# SAVEHIST (NOT HISTFILESIZE, which is bash-only); EXTENDED_HISTORY timestamps
# the native ~/.zsh_history and INC_APPEND_HISTORY flushes each command as it
# runs, so a crash or lost box still leaves a record.
export HISTSIZE=100000
export SAVEHIST=100000
setopt EXTENDED_HISTORY INC_APPEND_HISTORY

# Human-readable log with time, working dir and exit status for the client.
_cptc_log=~/.zsh_history_readable
typeset -g _cptc_cmd _cptc_cwd _cptc_ts

# Credential redaction: scrub passwords/hashes/keys from the LOGGED text only
# (the command still RUNS unmodified). Usernames are partially masked: the first
# 2 chars are kept, the rest becomes [REDACTED]. See command_logging.sh header.
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
    "
    # tool-gated: short flags are ambiguous, so key off the detected tool.
    # -p = password (NOT nmap -p port)
    case " netexec nxc crackmapexec cme evil-winrm evil-winrm.rb hydra medusa smbmap bloodhound.py bloodhound-python " in
      *" $tool "*) prog="$prog
        s/((-p)([[:space:]]+|=))$V/\\1[REDACTED]/g" ;;
    esac
    # -P = password list (hydra/medusa) / basic-auth pass (gobuster); NOT smbmap -P (=port)
    case " hydra medusa gobuster " in
      *" $tool "*) prog="$prog
        s/((-P)([[:space:]]+|=))$V/\\1[REDACTED]/g" ;;
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

    # --- username partial-masking (runs AFTER the password rules above) -------
    # Usernames were previously kept in full; now we keep only the first 2 chars
    # and mask the rest (administrator -> ad[REDACTED]). Usernames of 2 chars or
    # fewer are left as-is. These rules anchor on the [REDACTED] the password
    # rules just wrote, so the password is redacted no matter how long the user
    # is - a short username can never suppress password redaction.
    # always-on: user:pass@host, --http-auth user:pass, -U user%pass
    prog="$prog"'
      s#([[:alnum:]._$-]{2})[[:alnum:]._$-]+(:\[REDACTED\]@)#\1[REDACTED]\2#g
      s#(--http-auth[[:space:]=]+[^:[:space:]]{2})[^:[:space:]]+(:\[REDACTED\])#\1[REDACTED]\2#g
      s#(-U[[:space:]]*[^%[:space:]]{2})[^%[:space:]]+(%\[REDACTED\])#\1[REDACTED]\2#g
    '
    # tool-gated username masks mirror the password gating above.
    # impacket domain/user:pass with no @host  ->  keep first 2 (domain kept)
    case $tool in
      *.py|impacket-*) prog="$prog"'
        s#(/[[:alnum:]._$-]{2})[[:alnum:]._$-]+(:\[REDACTED\])#\1[REDACTED]\2#g' ;;
    esac
    # username flags -u / --user / --username <user>  ->  keep first 2 chars.
    # Gated to tools where these mean a login (NOT nmap -u, sort -u, docker -u,
    # systemctl --user, ...). The value class stops at ':' so the curl/wget
    # "-u user:pass" form is handled here too (pass already [REDACTED] above).
    case " netexec nxc crackmapexec cme evil-winrm evil-winrm.rb smbmap medusa curl wget " in
      *" $tool "*) prog="$prog"'
        s#((-u|--user|--username)([[:space:]]+|=)[[:alnum:]._$-]{2})[[:alnum:]._$-]+#\1[REDACTED]#g' ;;
    esac
    printf '%s\n' "$cmd" | sed -E "$prog"
}

_cptc_preexec() {
    _cptc_cmd=$1
    _cptc_cwd=$PWD
    _cptc_ts=$(date '+%Y-%m-%d %H:%M:%S')   # time the command was launched
}
_cptc_precmd() {
    local ret=$?                            # must be captured first
    [[ -n $_cptc_cmd ]] || return           # skip empty prompts / startup
    local safe=$(_cptc_redact "$_cptc_cmd") # scrub secrets before writing
    printf '%s [%s] (exit %d) %s\n' \
        "$_cptc_ts" "$_cptc_cwd" "$ret" "$safe" >> "$_cptc_log"
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
    echo "[+] Logging block added to $ZSHRC"
else
    echo "[=] Logging block already present in $ZSHRC (nothing to do)"
fi

# --- install the same logging into bash (guarded so re-running is a no-op) ---
if ! grep -q "$MARKER" "$BASHRC" 2>/dev/null; then
cat >> "$BASHRC" <<'EOF'

# >>> cptc engagement logging >>>
# Grow history so nothing rolls off mid-engagement, and flush each command as it
# runs (histappend + PROMPT_COMMAND) so a crash still leaves a record.
export HISTSIZE=100000
export HISTFILESIZE=100000
export HISTTIMEFORMAT='%Y-%m-%d %H:%M:%S '
shopt -s histappend

# Human-readable log with time, working dir and exit status for the client.
# Reads bash's own history to get the exact line typed (full pipelines/&&),
# de-duped by history number. Time logged is when the command RETURNED.
_cptc_log=~/.zsh_history_readable
_cptc_last_hist=-1
_cptc_primed=          # bash loads ~/.bash_history AFTER .bashrc, so we can't
                       # seed at source time; seed on the first prompt instead

# Credential redaction: scrub passwords/hashes/keys from the LOGGED text only
# (the command still RUNS unmodified). Usernames are partially masked: the first
# 2 chars are kept, the rest becomes [REDACTED]. See command_logging.sh header.
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
    "
    # tool-gated: short flags are ambiguous, so key off the detected tool.
    # -p = password (NOT nmap -p port)
    case " netexec nxc crackmapexec cme evil-winrm evil-winrm.rb hydra medusa smbmap bloodhound.py bloodhound-python " in
      *" $tool "*) prog="$prog
        s/((-p)([[:space:]]+|=))$V/\\1[REDACTED]/g" ;;
    esac
    # -P = password list (hydra/medusa) / basic-auth pass (gobuster); NOT smbmap -P (=port)
    case " hydra medusa gobuster " in
      *" $tool "*) prog="$prog
        s/((-P)([[:space:]]+|=))$V/\\1[REDACTED]/g" ;;
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

    # --- username partial-masking (runs AFTER the password rules above) -------
    # Usernames were previously kept in full; now we keep only the first 2 chars
    # and mask the rest (administrator -> ad[REDACTED]). Usernames of 2 chars or
    # fewer are left as-is. These rules anchor on the [REDACTED] the password
    # rules just wrote, so the password is redacted no matter how long the user
    # is - a short username can never suppress password redaction.
    # always-on: user:pass@host, --http-auth user:pass, -U user%pass
    prog="$prog"'
      s#([[:alnum:]._$-]{2})[[:alnum:]._$-]+(:\[REDACTED\]@)#\1[REDACTED]\2#g
      s#(--http-auth[[:space:]=]+[^:[:space:]]{2})[^:[:space:]]+(:\[REDACTED\])#\1[REDACTED]\2#g
      s#(-U[[:space:]]*[^%[:space:]]{2})[^%[:space:]]+(%\[REDACTED\])#\1[REDACTED]\2#g
    '
    # tool-gated username masks mirror the password gating above.
    # impacket domain/user:pass with no @host  ->  keep first 2 (domain kept)
    case $tool in
      *.py|impacket-*) prog="$prog"'
        s#(/[[:alnum:]._$-]{2})[[:alnum:]._$-]+(:\[REDACTED\])#\1[REDACTED]\2#g' ;;
    esac
    # username flags -u / --user / --username <user>  ->  keep first 2 chars.
    # Gated to tools where these mean a login (NOT nmap -u, sort -u, docker -u,
    # systemctl --user, ...). The value class stops at ':' so the curl/wget
    # "-u user:pass" form is handled here too (pass already [REDACTED] above).
    case " netexec nxc crackmapexec cme evil-winrm evil-winrm.rb smbmap medusa curl wget " in
      *" $tool "*) prog="$prog"'
        s#((-u|--user|--username)([[:space:]]+|=)[[:alnum:]._$-]{2})[[:alnum:]._$-]+#\1[REDACTED]#g' ;;
    esac
    printf '%s\n' "$cmd" | sed -E "$prog"
}
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
    printf '%s [%s] (exit %d) %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$PWD" "$ret" "$cmd" >> "$_cptc_log"
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
    echo "[+] Logging block added to $BASHRC"
else
    echo "[=] Logging block already present in $BASHRC (nothing to do)"
fi

# --- make sure the log file exists and is only readable by you ---
touch ~/.zsh_history_readable
chmod 600 ~/.zsh_history_readable

echo "[+] Readable log: ~/.zsh_history_readable (zsh + bash both write here)"
echo "[*] Run 'source ~/.zshrc' / 'source ~/.bashrc' or open a new shell to activate."
