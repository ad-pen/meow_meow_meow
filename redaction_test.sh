#!/bin/bash
# redaction_test.sh - prove the engagement logs do not leak credentials.
#
# WHY THIS EXISTS
# The evidence layer has TWO redactors: the shell one in command_logging.sh and
# the Burp one in burp_logger.py. They enforce the same policy against different
# input, in different languages, and nothing cross-checked them - so they drifted.
# On 2026-10-05 a test battery found:
#   * seven installed tools whose `-p <password>` was logged IN CLEAR, because the
#     shell redactor gates that flag behind a tool allowlist they were missing
#     from (certipy and certipy-ad among them, i.e. all ADCS and Certighost work);
#   * `mysql -u root -ptoor` - the attached form with no separator;
#   * `kerbrute passwordspray ... 'Welcome123!'` - a positional password, in the
#     signature invocation of the password-spray tool;
#   * `aws configure set aws_secret_access_key ...` - a bare positional secret;
#   * `user=admin&pass=hunter2` in a POST body, because burp_logger.py's key list
#     had `password` and `passwd` but not a bare `pass`.
# Each of those would have gone into a file we hand the client. Per the KB,
# leaking client data was the single most common penalty of the CPTC 11 season.
#
# A redactor nobody tests is the same failure as a sha256 nobody computed: it
# looks like protection while protecting nothing.
#
# WHAT IT DOES
# Extracts the real redactor from command_logging.sh (not a copy - the actual
# heredoc that gets written into ~/.zshrc and ~/.bashrc), imports the real
# functions from burp_logger.py, runs both against the battery below, and fails
# if any known secret survives or any identity is destroyed.
#
# RUN IT: after any change to either redactor, and as part of a rehearsal.
#   bash redaction_test.sh          # quiet unless something fails
#   bash redaction_test.sh -v       # show every case and its redacted form
#
# Exit 0 = clean. Exit 1 = a leak, an over-redaction, or a broken extraction.

set -u

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); [ "$VERBOSE" -eq 1 ] && echo -e "  ${GREEN}ok${NC}   $1"; return 0; }
bad()  { FAIL=$((FAIL+1)); echo -e "  ${RED}FAIL${NC} $1"; return 0; }

# ---------------------------------------------------------------------------
# Extract the shell redactor from the heredoc that command_logging.sh emits.
# ---------------------------------------------------------------------------
awk "/cat <<'REDACTOR_EOF'/{f=1;next} /^REDACTOR_EOF\$/{f=0} f" \
    "$SCRIPT_DIR/command_logging.sh" > "$TMP/redactor.sh"

if [ ! -s "$TMP/redactor.sh" ]; then
    echo -e "${RED}[-]${NC} Could not extract the redactor from command_logging.sh."
    echo "    The REDACTOR_EOF heredoc markers moved - fix this script's awk."
    exit 1
fi
if ! bash -n "$TMP/redactor.sh" 2>/dev/null; then
    echo -e "${RED}[-]${NC} The extracted redactor is not valid shell."
    exit 1
fi

# ---------------------------------------------------------------------------
# THE BATTERY.  <secret-that-must-not-survive> <TAB> <command>
# Keep every entry a REAL invocation of a tool these scripts install. Add a case
# whenever a tool is added to the build.
# ---------------------------------------------------------------------------
cat > "$TMP/cases.tsv" <<'CASES'
Summer2026!	nxc smb 10.0.0.5 -u administrator -p 'Summer2026!'
Summer2026!	netexec smb 10.0.0.5 -u svc -p 'Summer2026!' --shares
31d6cfe0d16ae931b73c59d7e0c089c0	netexec smb 10.0.0.5 -u svc -H aad3b435b51404eeaad3b435b51404ee:31d6cfe0d16ae931b73c59d7e0c089c0
BrouhahaTung2023!	impacket-secretsdump corp.com/jeffadmin:'BrouhahaTung2023!'@192.168.50.70
P@ssw0rd	evil-winrm -i 10.0.0.5 -u admin -p 'P@ssw0rd'
lDaP_1n_th3_cle4r!	ldapsearch -x -H ldap://10.0.0.5 -D 'CORP\svc' -w 'lDaP_1n_th3_cle4r!' -b "DC=corp,DC=com"
lDaP_1n_th3_cle4r!	certipy find -u svc_ldap@corp.com -p 'lDaP_1n_th3_cle4r!' -dc-ip 10.0.0.5
Secret1!	certipy-ad auth -u admin -p 'Secret1!' -dc-ip 10.0.0.5
CloudPass1!	az login -u admin@corp.com -p 'CloudPass1!'
AzurePass1	roadrecon auth -u admin@corp.com -p 'AzurePass1'
Guest123	enum4linux -u guest -p 'Guest123' 10.0.0.5
UXLCI5iETU	python3 targetedKerberoast.py -d corp.com -u emily -p 'UXLCI5iETU'
Spring2026!	pywhisker -d corp.com -u lowpriv -p 'Spring2026!' --target victim
Thestrokes23	bloodhound-python -d corp.com -u fsmith -p Thestrokes23 -ns 10.0.0.5 -c all
Thestrokes23	bloodhound-ce-python -d corp.com -u fsmith -p Thestrokes23 -ns 10.0.0.5
Welcome123!	kerbrute passwordspray -d corp.com users.txt 'Welcome123!'
toor	mysql -u root -ptoor -h 10.0.0.5
hunter2	curl -u admin:hunter2 https://target/api
eyJhbGciOiJIUzI1NiJ9.abcdef	curl -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abcdef' https://target/api
abc123deadbeef	curl -H 'Cookie: PHPSESSID=abc123deadbeef' https://target/
Winter2026	sshpass -p 'Winter2026' ssh user@10.0.0.5
35CE465C01BC1577DE3410452165E5244779C17B64E6D89459C1EC3C8DAA362B	python3 getST.py corp.com/FAKE01 -impersonate administrator -aesKey 35CE465C01BC1577DE3410452165E5244779C17B64E6D89459C1EC3C8DAA362B
wJalrXUtnFEMIK7MDENGbPxRfiCY	aws configure set aws_secret_access_key wJalrXUtnFEMIK7MDENGbPxRfiCY
ghp_AbCdEf123456	git clone https://user:ghp_AbCdEf123456@github.com/org/repo
Nexus123	sudo impacket-GetUserSPNs -request -dc-ip 10.0.0.5 corp.com/pete:Nexus123
Pass123	proxychains4 nxc smb 10.0.0.5 -u admin -p 'Pass123'
CASES

# Commands that must come through UNTOUCHED. Over-redaction is a real defect: it
# destroys the attribution and reproduction detail the log exists to provide.
cat > "$TMP/keep.tsv" <<'KEEP'
445	nmap -p 445,139 -sV 10.0.0.0/24
389	ldapsearch -x -H ldap://10.0.0.5 -p 389 -b "DC=corp,DC=com"
1000:1000	docker run -u 1000:1000 alpine
rockyou.txt	hydra -l admin -P /usr/share/wordlists/rockyou.txt ssh://10.0.0.5
administrator	nxc smb 10.0.0.5 -u administrator -p 'Summer2026!'
svc_ldap@corp.com	certipy find -u svc_ldap@corp.com -p 'lDaP_1n_th3_cle4r!' -dc-ip 10.0.0.5
10.0.0.5	nxc smb 10.0.0.5 -u administrator -p 'Summer2026!'
corp.com	bloodhound-python -d corp.com -u fsmith -p Thestrokes23 -ns 10.0.0.5 -c all
users.txt	kerbrute passwordspray -d corp.com users.txt 'Welcome123!'
KEEP

# ---------------------------------------------------------------------------
# 1. Shell redactor - secrets must not survive
# ---------------------------------------------------------------------------
echo -e "${BLUE}[*]${NC} Shell redactor (command_logging.sh) - secrets must be removed"
cat > "$TMP/run_leak.sh" <<'RUNNER'
source "$1"
while IFS=$'\t' read -r secret cmd; do
    [ -z "${cmd:-}" ] && continue
    printf '%s\t%s\t%s\n' "$secret" "$cmd" "$(_cptc_redact "$cmd")"
done < "$2"
RUNNER
while IFS=$'\t' read -r secret cmd out; do
    [ -z "${out:-}" ] && continue
    if printf '%s' "$out" | grep -qF -- "$secret"; then
        bad "LEAKED '$secret'"
        echo "       cmd: $cmd"
        echo "       log: $out"
    else
        ok "$cmd"
        [ "$VERBOSE" -eq 1 ] && echo "         -> $out"
    fi
done < <(bash "$TMP/run_leak.sh" "$TMP/redactor.sh" "$TMP/cases.tsv")

# ---------------------------------------------------------------------------
# 2. Shell redactor - identities and non-secrets must be preserved
# ---------------------------------------------------------------------------
echo -e "${BLUE}[*]${NC} Shell redactor - identities and paths must be preserved"
while IFS=$'\t' read -r keep cmd out; do
    [ -z "${out:-}" ] && continue
    if printf '%s' "$out" | grep -qF -- "$keep"; then
        ok "kept '$keep'"
    else
        bad "OVER-REDACTED: lost '$keep'"
        echo "       cmd: $cmd"
        echo "       log: $out"
    fi
done < <(bash "$TMP/run_leak.sh" "$TMP/redactor.sh" "$TMP/keep.tsv")

# ---------------------------------------------------------------------------
# 3. Burp redactor - same policy, different input shape
# ---------------------------------------------------------------------------
echo -e "${BLUE}[*]${NC} Burp redactor (burp_logger.py) - URLs and bodies"
if ! command -v python3 >/dev/null 2>&1; then
    echo -e "  ${YELLOW}skip${NC} python3 not available"
else
    python3 - "$SCRIPT_DIR/burp_logger.py" <<'PY' > "$TMP/burp.out" 2>"$TMP/burp.err"
import re, sys

# Import the real redaction code out of the extension without importing Burp's
# Java classes (which only exist inside Jython). Everything from the "Redaction"
# banner up to the IBurpExtender class is pure-Python and self-contained.
src = open(sys.argv[1]).read()
# Anchor on _FULL_KEYS, not on the "# Redaction" banner: that string also appears
# in the file's header comment, so anchoring there swept in `from burp import ...`
# and the import failed outside Jython. _FULL_KEYS is the first line of the actual
# redaction code and everything from there to BurpExtender is pure Python.
start = src.index("_FULL_KEYS")
end = src.index("class BurpExtender")
ns = {"re": re}
exec(compile(src[start:end], "burp_logger_redaction", "exec"), ns)
ru, rb = ns["_redact_url"], ns["_redact_body"]

URL_CASES = [
    ("hunter2",        "https://t/api?password=hunter2&user=admin"),
    ("S3cret",         "https://admin:S3cret@t/panel"),
    ("31d6cfe0d16ae931b73c59d7e0c089c0",
                       "https://t/api?ntlm=aad3b435b51404eeaad3b435b51404ee:31d6cfe0d16ae931b73c59d7e0c089c0"),
    ("hunter2",        "https://t/login?pass=hunter2"),
    ("hunter2",        "https://t/login?pw=hunter2"),
]
BODY_CASES = [
    ("hunter2",        '{"username":"admin","password":"hunter2"}'),
    ("hunter2",        'user=admin&pass=hunter2'),
    ("hunter2",        'user=admin&pwd=hunter2'),
    ("hunter2",        'login=admin&credential=hunter2'),
    ("Summer2026!",    'username=admin&password=Summer2026!'),
    ("payload.sig",    '{"access_token":"eyJhbGciOiJIUzI1NiJ9.payload.sig"}'),
    ("topsecret",      'secret=topsecret&apikey=ABCDEF123456'),
]
KEEP_CASES = [
    ("admin",   "https://t/api?password=hunter2&user=admin",  ru),
    ("1001",    "https://t/order?id=1001",                    ru),
    ("admin",   '{"username":"admin","password":"hunter2"}',  rb),
    ("12345",   '{"amount":100,"account":"12345"}',           rb),
]

for secret, case in URL_CASES:
    print("LEAK\t%s\t%s\t%s" % ("yes" if secret in ru(case) else "no", case, ru(case)))
for secret, case in BODY_CASES:
    print("LEAK\t%s\t%s\t%s" % ("yes" if secret in rb(case) else "no", case, rb(case)))
for keep, case, fn in KEEP_CASES:
    print("KEEP\t%s\t%s\t%s" % ("yes" if keep in fn(case) else "no", case, fn(case)))
PY
    if [ -s "$TMP/burp.err" ] && [ ! -s "$TMP/burp.out" ]; then
        bad "could not import burp_logger.py's redaction code"
        sed 's/^/       /' "$TMP/burp.err"
    else
        while IFS=$'\t' read -r kind verdict case out; do
            case "$kind:$verdict" in
                LEAK:yes) bad "LEAKED in: $case"; echo "       -> $out" ;;
                LEAK:no)  ok "$case"; [ "$VERBOSE" -eq 1 ] && echo "         -> $out" ;;
                KEEP:yes) ok "kept identity in: $case" ;;
                KEEP:no)  bad "OVER-REDACTED: $case"; echo "       -> $out" ;;
            esac
        done < "$TMP/burp.out"
    fi
fi

# ---------------------------------------------------------------------------
echo
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo -e "Redaction test:  ${GREEN}${PASS} passed${NC}   ${RED}${FAIL} failed${NC}"
echo -e "${GREEN}═══════════════════════════════════════${NC}"
if [ "$FAIL" -gt 0 ]; then
    echo -e "${RED}[-]${NC} A failure here means a credential reaches a file we hand the client,"
    echo -e "${RED}   ${NC} or that the log lost the identity it exists to record. Fix before the freeze."
    exit 1
fi
echo -e "${GREEN}[+]${NC} Both redactors enforce the policy: secrets removed, identities kept."
