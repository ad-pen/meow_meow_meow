# CPTC Engagement Logger - Burp Suite extension (Jython 2.7)
#
# Companion to command_logging.sh. Appends one line per manual-testing request
# to ~/.burp_history_readable so we have an attribution-grade artifact of what
# actually left the box during the engagement -- if the target's system breaks
# and the client asks "prove what you did at time T", this file is the answer.
#
# Format (single line per request; grep-friendly):
#   <YYYY-MM-DD HH:MM:SS> [<TOOL>] <status> <METHOD> <URL> [CT=<content-type>] [BODY=<body>]
# Session markers on load/unload:
#   <YYYY-MM-DD HH:MM:SS> --- Burp session started ---
#   <YYYY-MM-DD HH:MM:SS> --- Burp session ended ---
#
# Tools logged: Repeater, Intruder, Scanner (Scanner is Pro-only; no-op on
# Community). Proxy is off by default (flip LOG_PROXY_IN_SCOPE to log in-scope
# Proxy traffic too).
#
# Body logging is gated to methods that carry payload data:
#   POST/PUT/PATCH -- always logged (BODY=<empty> if server-side was empty)
#   DELETE          -- logged only if body is non-empty
#   GET/HEAD/OPTIONS/... -- never logged
# Bodies are capped at BODY_MAX bytes and truncated with a marker. Binary bodies
# (null bytes or >30% non-printable) are summarised as <binary N bytes>.
#
# Redaction (applied to URL query string and body content).
# A key is matched with its DECORATION, so `newPassword`, `password_confirmation`
# and `passwordRepeat` are caught as well as `password` -- see the long note at
# the redaction-begin marker for why they were not, until 2026-10-09.
#   FULL redact ([REDACTED]):
#     password/passwd/passphrase/passcode/credential/secret and any decorated
#     form; pw/pwd/pass with a credential-ish suffix; one-time codes (otp, totp,
#     mfa, 2fa, recovery_code, sms_code, pincode); key material gated on a
#     qualifier (api-key, x-api-key, ssh_key, private_key, aes_key, master_key);
#     DB/broker connection strings (connection_string, dsn, database_url) --
#     these embed a username and password; security answers; NTLM/LM hashes and
#     a bare 32hex:32hex pair; Kerberos material on an EXACT root (ticket, tgt,
#     krbcred, ccache) and a bare pin; basic-auth password in a URL
#     (user:PASS@host) and an inline `Basic <b64>`
#   Prefix-keep first 3 chars (auth-granting but useful to identify type):
#     token and any decorated form (access_token, refresh-token, auth_token,
#     id_token), bearer/jwt/authorization/oauth, request signatures (signature,
#     hmac), bare JWTs anywhere in a body (eyJ...), inline `Bearer <tok>`
#   Prefix-keep first 2 chars (identifying, needed for client correlation):
#     session and any decorated form (session_id, sessionId, ASP.NET_SessionId),
#     PHPSESSID, JSESSIONID
#   NO redaction:
#     usernames -- kept as-is, deliberately. The log exists so the client can
#     answer "which account touched this at time T"; a masked username defeats
#     the only question it is there to answer. Secrets must never be in the
#     file, identities are the point of the file.
#
# Hashes and Kerberos tickets are FULLY redacted (they were prefix-kept before):
# an NTLM hash is a credential outright -- pass-the-hash needs nothing else --
# so keeping any of it is keeping the secret.

from __future__ import print_function

from burp import IBurpExtender, IHttpListener, IExtensionStateListener
import os
import re
import time
import threading

LOG_FILE = os.path.expanduser("~/.burp_history_readable")

# Flip to True to also log Proxy traffic (in-scope only).
LOG_PROXY_IN_SCOPE = False

# Per-request body cap in bytes. Bodies longer than this get truncated with a
# marker in the log; full body still lives in Burp's session.
BODY_MAX = 8 * 1024

BODY_METHODS_ALWAYS      = set(["POST", "PUT", "PATCH"])
BODY_METHODS_IF_NONEMPTY = set(["DELETE"])


# --------------------------------------------------------------------------
# Redaction
# --------------------------------------------------------------------------

# >>> redaction-begin (redaction_test.sh extracts the code between these two
# markers and runs it under CPython -- keep everything in here pure Python,
# with no `burp` imports) >>>
#
# KEEP IN STEP WITH command_logging.sh's always-on key=value rules. These two
# redactors are the two halves of one evidence layer, enforcing one policy
# against different input in different languages, so every change here needs the
# matching change there. `redaction_test.sh` exercises BOTH against one shared
# battery, so a divergence fails a test instead of reaching the client.
#
# 2026-10-09 -- THE KEY PATTERNS WERE ANCHORED TOO TIGHTLY AND LEAKED 81 OF 110
# REALISTIC FIELD NAMES. The old shape was `\b(password|...)\s*=\s*(VAL)`, which
# demands the key be EXACTLY one of the listed roots:
#   * the leading \b blocks a word-character PREFIX -- and `_` is a word
#     character, so `new_password=` and `newPassword=` BOTH went in clear;
#   * the `=` required immediately after the root blocks any SUFFIX, so
#     `passwordRepeat=`, `password_confirmation=` and `password2=` did too.
# Every registration and change-password form posts at least one of those, which
# is how a cleartext password reached the file we hand the client. (The shell
# redactor has no left anchor, so prefixes were safe there and suffixes were
# not -- the two halves failed differently on the same input.)
#
# Fixed by allowing decoration on BOTH sides of a root, and by adding the key
# families that were missing outright: OTP/MFA codes, key material, DB
# connection strings, request signatures, security answers, and the
# Authorization/JWT family.

# Decoration permitted AFTER a root: `password`+`Repeat`, `session`+`Id`.
_DEC = r"[A-Za-z0-9_.\[\]-]*"

# Decoration permitted BEFORE a root, for the JSON rules only: `new`+`password`,
# `x-`+`api-key`, `ASP.NET_`+`Session`+`Id`. The form/query rules do NOT match a
# prefix -- they start at the root and leave the prefix outside the match, so
# `new_password=x` -> `new_` + `password=[REDACTED]` writes the field name back
# intact anyway. That is not a style choice but a throughput one: a pattern
# starting with `[A-Za-z0-9_...]*` gives the regex engine no literal to scan
# for, so it attempts a greedy prefix match at all 8192 positions of a maximal
# body. Measured on an 8KB urlencoded body, prefix-matching both sides cost 6x
# (and 11x on a base64 blob) -- call it 70ms per request inside the write lock,
# which an Intruder run would feel. The JSON rules can afford a prefix because
# they are anchored on a literal `"`, which the engine scans for directly, and
# there the prefix is NEEDED: `"newPassword"` puts the decoration between the
# quote and the root. Bounded to 40 chars so a pathological key cannot make the
# engine backtrack across a whole body.
_JPFX = r"[A-Za-z0-9_.-]{0,40}"

# A key must START at a real delimiter (& ? { , " \' or whitespace). Used only by
# the EXACT-root rules, to keep them from firing on a longer key that merely
# ENDS in one of their roots -- `parkTicket=`, `mapPin=`.
_KS = r"(?<![A-Za-z0-9_.\[\]-])"

# Suffixes allowed after a SHORT root (pw/pwd/pass). Deliberately a CLOSED set,
# unlike the strong roots: the client sells theme-park PASSES, so `passType=`,
# `passholder=` and `passenger=` have to survive -- they are ticketing and guest
# evidence, not secrets.
# ⚠️ KNOWN, ACCEPTED OVER-REDACTION: a short root still matches with ANY prefix,
# so `guestPass=7781` and `season_pass=` are redacted. That is the cost of
# catching `userpass=`, `db_pw=` and the next compound nobody thought of, and it
# is the direction that cannot cost points -- the full request is still in Burp's
# own session for the write-up. The shell redactor has always behaved this way.
# To keep pass IDs instead, require a separator or a known qualifier before a
# short root; do it in BOTH redactors or they diverge again.
_WS = r"(?:[0-9]+|[_-]?(?:confirm(?:ation)?|repeat|retype|verify|check|again"
_WS += r"|new|old|hashed|hash))?"

# (root alternation, suffix) pairs, declared once and compiled into both a
# form/query matcher (no prefix) and a JSON matcher (bounded prefix).
_FULL_SPECS = [
    # passwords and friends -- arbitrary suffix. There is no benign field
    # containing the substring `password` whose value we want in the log.
    (r"passphrase|passcode|passwd|password|credentials|credential|secret", _DEC),
    (r"pwd|pw|pass", _WS),
    # one-time codes. Single-use but auth-granting, and a 2FA-bypass finding is
    # written up from the request, not from the code.
    (r"otp|totp|hotp|mfa|2fa|two[_-]?factor"
     r"|one[_-]?time[_-]?(?:code|password|pass)"
     r"|(?:sms|auth|authorization|verification|verify|recovery|backup"
     r"|security|activation)[_-]?code"
     r"|pin[_-]?code", _DEC),
    # key material. `key` alone is far too common to redact, so it is gated on a
    # qualifier: api-key, x-api-key, ssh_key, private_key, aes_key, ...
    (r"(?:master|encryption|private|priv|signing|sign|secret|client|access"
     r"|api|aes|rsa|dsa|ssh|host|consumer|app)[_-]?key", _DEC),
    # DB/broker connection strings -- these EMBED a username and password.
    (r"connection[_-]?string|conn[_-]?str(?:ing)?|dsn"
     r"|(?:database|db|mongo|redis|amqp|postgres|mysql)[_-]?(?:url|uri)", _DEC),
    (r"(?:security|secret)[_-]?(?:question[_-]?)?answer", _DEC),
    # hashes are credentials outright (pass-the-hash needs nothing else). NO
    # suffix on this root: `hashtag=` is a marketing field and the client runs
    # campaign hashtags. `password_hash=`/`pwhash=` are caught by the roots above.
    (r"nt[_-]?hash|lm[_-]?hash|ntlm|hash(?:es|ed)?", ""),
]

# Prefix-keep 3: auth-granting, but the first characters identify the scheme and
# let the client correlate. `token` carries decoration, so this one root covers
# access_token, refresh-token, auth_token, id_token, tokenValue, ...
_TOKEN_SPECS = [
    (r"token", _DEC),
    (r"bearer|jwt|authorization|oauth", _DEC),
    (r"signature|hmac", _DEC),
]

# Prefix-keep 2: identifying, needed for client correlation. `session` with
# decoration covers session_id, sessionId, ASP.NET_SessionId, PHPSESSID, ...
_SESSION_SPECS = [
    (r"session|sessid|phpsessid|jsessionid", _DEC),
]

# FULL redact, EXACT root, no decoration either side. `ticket` is here rather
# than in _FULL_SPECS for a client-specific reason: this season's client sells
# tickets, so `ticketId=`, `ticket_type=` and `parkTicket=` are exactly the IDOR
# evidence the report needs. Only a bare `ticket=` is treated as Kerberos.
_EXACT_FULL_KEYS = r"ticket|krbcred|kirbi|ccache|tgt|tgs|pin"


def _keys(specs, pre=""):
    return "|".join(pre + r"(?:" + root + r")" + sfx for root, sfx in specs)


# key = value  in URL query, form body, JS-object-ish, config-file-ish text.
# Value forms recognized: "double-quoted"  |  'single-quoted'  |  bareword-no-ws.
# Whitespace tolerated around '=' so `password = "hunter2"` matches too.
_VAL = r'(?:"[^"]*"|\'[^\']*\'|[^&\s#]+)'


def _kv(keys, anchor=""):
    return re.compile(r"(?i)" + anchor + r"(" + keys + r")\s*=\s*(" + _VAL + r")")


def _json(keys):
    # JSON:  "key":"value"  (best-effort -- doesn't handle escaped quotes)
    return re.compile(r'(?i)("(?:' + keys + r')"\s*:\s*)"([^"]*)"')


_URL_FULL    = _kv(_keys(_FULL_SPECS))
_URL_TOKEN   = _kv(_keys(_TOKEN_SPECS))
_URL_SESSION = _kv(_keys(_SESSION_SPECS))
_URL_EXACT   = _kv(_EXACT_FULL_KEYS, anchor=_KS)

_JSON_FULL    = _json(_keys(_FULL_SPECS,    pre=_JPFX))
_JSON_TOKEN   = _json(_keys(_TOKEN_SPECS,   pre=_JPFX))
_JSON_SESSION = _json(_keys(_SESSION_SPECS, pre=_JPFX))
_JSON_EXACT   = _json(_EXACT_FULL_KEYS)

# An LM:NT pair with no key name in front of it -- `?h=aad3b4...:31d6cf...`.
# 32 hex : 32 hex is specific enough that a false positive is hard to construct.
_HASH_PAIR = re.compile(r"\b[0-9a-fA-F]{32}:[0-9a-fA-F]{32}\b")

# `Authorization: Bearer <tok>` / `Basic <b64>` appearing INSIDE a logged body
# (proxied requests, SOAP envelopes, a header pasted into a JSON field). Basic
# is redacted whole -- it base64-decodes straight back to user:password.
_INLINE_BEARER = re.compile(r"(?i)\b(bearer\s+)([A-Za-z0-9._~+/=-]{8,})")
_INLINE_BASIC  = re.compile(r"(?i)\b(basic\s+)([A-Za-z0-9+/]{8,}={0,2})")

# Basic-auth user:pass@host embedded in a URL: keep the username, hide the pass
_URL_BASIC = re.compile(r"://([^:/@\s]+):([^@\s]+)@")

# Bare JWT tokens anywhere in a body (base64url header.payload.signature).
# `eyJ` is the base64 encoding of `{"` and is JWT's near-universal prefix.
_BARE_JWT = re.compile(r"\beyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+")


def _keep_prefix(n, val):
    if len(val) <= n:
        return val
    return val[:n] + "[REDACTED]"


def _unquote(v):
    # Strip a matching pair of surrounding single or double quotes.
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
        return v[1:-1]
    return v


def _redact_url(url):
    url = _URL_FULL.sub(   lambda m: m.group(1) + "=[REDACTED]",                               url)
    url = _URL_EXACT.sub(  lambda m: m.group(1) + "=[REDACTED]",                               url)
    url = _URL_TOKEN.sub(  lambda m: m.group(1) + "=" + _keep_prefix(3, _unquote(m.group(2))), url)
    url = _URL_SESSION.sub(lambda m: m.group(1) + "=" + _keep_prefix(2, _unquote(m.group(2))), url)
    # username kept, password dropped
    url = _URL_BASIC.sub(  lambda m: "://" + m.group(1) + ":[REDACTED]@",                      url)
    url = _HASH_PAIR.sub("[REDACTED-HASH]", url)
    return url


def _redact_body(body):
    # form / key=value forms (also fires inside urlencoded and some multipart)
    body = _URL_FULL.sub(   lambda m: m.group(1) + "=[REDACTED]",                               body)
    body = _URL_EXACT.sub(  lambda m: m.group(1) + "=[REDACTED]",                               body)
    body = _URL_TOKEN.sub(  lambda m: m.group(1) + "=" + _keep_prefix(3, _unquote(m.group(2))), body)
    body = _URL_SESSION.sub(lambda m: m.group(1) + "=" + _keep_prefix(2, _unquote(m.group(2))), body)
    # JSON forms
    body = _JSON_FULL.sub(   lambda m: m.group(1) + '"[REDACTED]"',                          body)
    body = _JSON_EXACT.sub(  lambda m: m.group(1) + '"[REDACTED]"',                          body)
    body = _JSON_TOKEN.sub(  lambda m: m.group(1) + '"' + _keep_prefix(3, m.group(2)) + '"', body)
    body = _JSON_SESSION.sub(lambda m: m.group(1) + '"' + _keep_prefix(2, m.group(2)) + '"', body)
    # bare JWTs anywhere (unlabeled Bearer tokens embedded in payloads, etc.)
    body = _BARE_JWT.sub(lambda m: _keep_prefix(3, m.group(0)), body)
    # raw Authorization header values pasted into a body
    body = _INLINE_BEARER.sub(lambda m: m.group(1) + _keep_prefix(3, m.group(2)), body)
    body = _INLINE_BASIC.sub( lambda m: m.group(1) + "[REDACTED]",                body)
    body = _HASH_PAIR.sub("[REDACTED-HASH]", body)
    return body


def _escape_control(s):
    # Newlines/CRs would break the one-line-per-request invariant grep relies on.
    return s.replace(u"\r", u"\\r").replace(u"\n", u"\\n").replace(u"\t", u"\\t")


# <<< redaction-end <<<


# --------------------------------------------------------------------------
# Body handling
# --------------------------------------------------------------------------

def _looks_binary(byte_arr, offset, end):
    # Scan up to first 2KB of the body region. Null byte -> definitely binary.
    # Otherwise, treat as binary if >30% of scanned bytes are non-printable.
    scan_end = min(end, offset + 2048)
    scanned = scan_end - offset
    if scanned <= 0:
        return False
    non_printable = 0
    for i in range(offset, scan_end):
        b = byte_arr[i] & 0xFF                        # java byte -> unsigned int
        if b == 0:
            return True
        if b < 32 and b not in (9, 10, 13):           # allow TAB/LF/CR
            non_printable += 1
        elif b == 127:
            non_printable += 1
    return non_printable * 10 > scanned * 3


def _extract_content_type(headers):
    for h in headers:
        # headers is a Java List<String> of raw header lines
        if h.lower().startswith("content-type:"):
            return h.split(":", 1)[1].strip()
    return None


# --------------------------------------------------------------------------
# Extension
# --------------------------------------------------------------------------

class BurpExtender(IBurpExtender, IHttpListener, IExtensionStateListener):

    def registerExtenderCallbacks(self, callbacks):
        self._callbacks = callbacks
        self._helpers = callbacks.getHelpers()
        self._lock = threading.Lock()

        self._tool_names = {
            callbacks.TOOL_REPEATER: "REPEATER",
            callbacks.TOOL_INTRUDER: "INTRUDER",
            callbacks.TOOL_SCANNER:  "SCANNER",
            callbacks.TOOL_PROXY:    "PROXY",
        }
        self._log_tools = set([
            callbacks.TOOL_REPEATER,
            callbacks.TOOL_INTRUDER,
            callbacks.TOOL_SCANNER,   # no-op on Community
        ])
        self._proxy_tool = callbacks.TOOL_PROXY

        callbacks.setExtensionName("CPTC Engagement Logger")
        callbacks.registerHttpListener(self)
        callbacks.registerExtensionStateListener(self)

        # Ensure log file exists and is owner-only.
        try:
            if not os.path.exists(LOG_FILE):
                open(LOG_FILE, "a").close()
            os.chmod(LOG_FILE, 0o600)
        except Exception as e:
            print("[!] burp_logger: could not prepare " + LOG_FILE + ": " + str(e))

        self._write_line("--- Burp session started ---")

        print("[+] CPTC Engagement Logger loaded")
        print("    log file : " + LOG_FILE)
        proxy_note = ", Proxy (in-scope)" if LOG_PROXY_IN_SCOPE else ""
        print("    tools    : Repeater, Intruder, Scanner" + proxy_note)

    def extensionUnloaded(self):
        try:
            self._write_line("--- Burp session ended ---")
        except Exception:
            pass

    # -- writing ----------------------------------------------------------

    def _write_line(self, payload):
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        line = "%s %s\n" % (ts, payload)
        with self._lock:
            with open(LOG_FILE, "a") as f:
                f.write(line)

    # -- listener ---------------------------------------------------------

    def processHttpMessage(self, toolFlag, messageIsRequest, messageInfo):
        # Log on the response leg so we have a status code in hand.
        if messageIsRequest:
            return

        if toolFlag in self._log_tools:
            need_scope_check = False
        elif toolFlag == self._proxy_tool and LOG_PROXY_IN_SCOPE:
            need_scope_check = True
        else:
            return

        try:
            req = self._helpers.analyzeRequest(messageInfo)
            url_obj = req.getUrl()
            if need_scope_check and not self._callbacks.isInScope(url_obj):
                return

            method = req.getMethod()
            url_str = _redact_url(str(url_obj))
            tool = self._tool_names.get(toolFlag, "UNKNOWN")

            resp = messageInfo.getResponse()
            status = 0 if resp is None else self._helpers.analyzeResponse(resp).getStatusCode()

            ct = _extract_content_type(req.getHeaders())

            # Body extraction (only for methods that carry one)
            body_repr = None
            if method in BODY_METHODS_ALWAYS or method in BODY_METHODS_IF_NONEMPTY:
                full = messageInfo.getRequest()
                offset = req.getBodyOffset()
                body_len = len(full) - offset
                if body_len > 0:
                    if _looks_binary(full, offset, offset + body_len):
                        body_repr = "<binary %d bytes>" % body_len
                    else:
                        clip_end = offset + min(body_len, BODY_MAX)
                        text = self._helpers.bytesToString(full[offset:clip_end])
                        text = _redact_body(text)
                        text = _escape_control(text)
                        if body_len > BODY_MAX:
                            text += "...[truncated %d more bytes]" % (body_len - BODY_MAX)
                        body_repr = text
                elif method in BODY_METHODS_ALWAYS:
                    body_repr = "<empty>"

            parts = ["[" + tool + "]", str(status), method, url_str]
            if ct is not None:
                parts.append("CT=" + ct)
            if body_repr is not None:
                parts.append("BODY=" + body_repr)
            self._write_line(" ".join(parts))
        except Exception as e:
            print("[!] burp_logger: " + str(e))
