# Tool Inventory — CPTC 12 Kali build

Everything the setup scripts in this repo install on a fresh Kali box, grouped by
who uses it. Generated from `start.sh`, `all.sh` and `ad.sh` — if you change an
install line in those, update this file in the same commit.

**Src** column: **S** = `start.sh` · **A** = `all.sh` · **D** = `ad.sh`

Run order: `start.sh` → (`all.sh` and the jVision server can run in parallel) → `ad.sh`.
Lost a box mid-engagement? `smol-all.sh` installs the critical path only, in minutes —
see its header. Before the event, build against `REHEARSAL.md`.

| File | What it is |
|---|---|
| `start.sh` | bootstrap: base packages, docker, desktop, the evidence layer |
| `all.sh` | full tool suite (~30 min), gated by a preflight prompt |
| `ad.sh` | AD/internal tools |
| `smol-all.sh` | emergency rebuild, critical path only (~5 min) |
| `lib.sh` | shared helpers + the artifact **pin manifest** (sourced by all.sh/ad.sh) |
| `pins.sh` | record / verify the pinned sha256 values — see `REHEARSAL.md` |
| `command_logging.sh` · `burp_logging.sh` · `burp_logger.py` · `terminal_uniform.sh` | the engagement-evidence layer |
| `~/pins.lock` | per-box record of what was actually downloaded — diff it between boxes |
`all.sh` will not start until the manual steps `start.sh` prints have been done — it
re-checks them and prompts `[N/y]`. Override with `SKIP_PREFLIGHT=1`.

---

## Web

| Tool | Src | Notes |
|---|---|---|
| `burpsuite` | A | Community only — Pro is banned; confirm which edition the apt package resolves to |
| Burp CPTC Engagement Logger + `jython-standalone-2.7.3.jar` | S | → `~/.BurpSuite/`, auto-load patched into `UserConfig*.json` |
| `zaproxy` | A | |
| `nuclei` | A | templates cloned to `~/dropzone/nuclei-templates` |
| `jwt_tool` | A | clone → `~/dropzone/jwt_tool`; run `python3 ~/dropzone/jwt_tool/jwt_tool.py` |
| `gobuster` | A | |
| `feroxbuster` | A | |
| `ffuf` | A | |
| `dirsearch` | A | |
| `wfuzz` | A | |
| `nikto` | A | |
| `whatweb` | A | |
| `sslscan` | A | TLS/cipher review |
| `cyberchef` | A | local, offline — safe for client data |
| `httpx` | A | Go → `~/go/bin` |
| `httprobe` | A | Go → `~/go/bin` |
| `subfinder` | A | Go → `~/go/bin` |
| `waybackurls` | A | Go → `~/go/bin`; needs egress, likely dead in-environment |

## AD / internal

| Tool | Src | Notes |
|---|---|---|
| `impacket-scripts` | D | apt package; `impacket-secretsdump` etc. |
| `netexec` (`nxc`) | A + D | in both, so non-AD operators get it too; `crackmapexec` was dropped |
| `bloodhound` | D | BloodHound CE 9.4.0 — own DB stack, `bloodhound-setup` then `bloodhound-start` |
| `bloodhound.py` | D | `bloodhound-python` collector |
| `neo4j` | D | listen addr configured only; **not** auto-started (no systemd unit, clashes with CE on 7474/7687) |
| `certipy-ad` | D | ADCS |
| `evil-winrm` | D | |
| `kerbrute` | D | binary → `/usr/local/bin` |
| `windapsearch` | D | binary → `/usr/local/bin` |
| `bloodyAD` | D | clone + `pip -r requirements.txt` |
| `PKINITtools` | D | clone; pairs with `minikerberos` |
| `Ghostpack-CompiledBinaries` | D | clone — Rubeus/SharpUp/etc. precompiled |
| `SharpEfsPotato` | D | clone + mono build (`mono-complete`, `mono-devel`) |
| `pypykatz` | A + D | |
| `minikerberos` | A + D | |
| `aardwolf` | D | RDP; non-fatal if the build fails |
| `responder` | A + D | |
| `enum4linux` | A + D | |
| `smbclient` / `smbmap` / `nbtscan` | A | SMB enum, used from the AD flow |

## Others

| Category | Tool | Src | Notes |
|---|---|---|---|
| Recon | `nmap` | S | also drives `jvisionclient.py` |
| Recon | `masscan` | A | |
| Recon | `dnsrecon` | A | |
| Recon | `onesixtyone`, `snmp` | A | SNMP |
| Recon | `sipvicious` | A | VoIP |
| Recon | `oscanner`, `tnscmd10g` | A | Oracle |
| Recon | `redis-tools` | A | |
| Recon | `smtp-user-enum` | A | |
| Credentials | `hashcat` | A | NTLM cracking for the AD flow; no GPU on the VDI |
| Credentials | `john` | A | |
| Credentials | `hydra` | A | |
| Credentials | `username-anarchy` | A | → `~/dropzone/` |
| Wordlists | `seclists` | A | apt → `/usr/share/seclists` |
| Wordlists | `kali-wordlists` | A | clone → `/usr/share/wordlists/kali-wordlists` |
| Wordlists | `rockyou.txt` | A | gunzipped in place |
| Exploitation | `metasploit-framework` | A | |
| Exploitation | `set` | A | SET — social engineering only if explicitly in scope |
| Exploitation | `aircrack-ng` | A | |
| Pivoting | `chisel` | A | → `/usr/local/bin` |
| Pivoting | `sshuttle` | A | |
| Pivoting | `proxychains4` | A | |
| Pivoting | `socat`, `netcat-traditional` | A | |
| Shells | `upshell` | A | TTY upgrade helper → `/usr/local/bin` |
| Privesc | `linpeas.sh` | A | → `~/dropzone/privesc/` |
| Privesc | `winpeas.exe` | A | pinned to release `20241011-2e37ba11` |
| Privesc | `PowerUp.ps1`, `privesc.ps1`, `PrivescCheck.ps1` | A | → `~/dropzone/privesc/` |
| Privesc | `pspy64` | A | → `~/dropzone/` |
| Cloud | `awscli` | A | |
| Cloud | `pacu` | A | pip |
| Cloud | `ScoutSuite` | A | pip |
| Cloud | `principalmapper` | A | pip — IAM privesc paths |
| Traffic | `wireshark` (`tshark`), `tcpdump` | A | |
| Forensics | `steghide`, `binwalk`, `exiftool` | A | |
| Containers | `docker.io`, `docker-compose` | S + A | in `start.sh` for jVision; `usermod -aG docker` in both |
| Evidence | `flameshot`, `scrot`, `maim` | A | screenshots for the report |
| Workspace | `tmux`, `screen`, `terminator` | A | |
| Workspace | `remmina` | A | RDP client |
| Workspace | `mc` | A | Midnight Commander |
| Editor | `sublime-text` | A | own apt repo |
| Reporting | `tesseract-ocr`, `python3-pytesseract` | A | OCR |
| Reporting | `python3-docx`, `python3-openpyxl`, `python3-pil` | A | docx + xlsx findings sheet + images |
| Reporting | `python3-pymupdf` + `python3-fitz` | A | **both** required — the `fitz` alias is a separate package |
| Reporting | `libreoffice-writer` | A | docx→pdf; trim first if disk is tight |
| Desktop | `kali-desktop-xfce`, `xorg`, `xrdp` | S | xRDP for Burp's GUI |
| Access | SSH service | S | enabled + started |
| Runtime | `python3`, `python3-pip`, `python3-venv` | S + A | |
| Runtime | `requests`, `pwntools`, `bs4`, `argparse` | S | jVision client deps |
| Runtime | `golang` | A | builds the 4 Go tools |
| Runtime | `openjdk-11-jdk` | A | Kali ships 17/21 — verify this package still exists; Burp needs a JRE |
| Build | `build-essential`, `python3-dev`, `libffi-dev` | D | lets `aardwolf` compile |
| Build | `mono-complete`, `mono-devel` | D | conditional, for SharpEfsPotato |
| Build | `apt-transport-https`, `libssl-dev` | A | |
| Base | `git`, `curl`, `wget` | S + A | |
| Fallback | `pipx` | D | only if apt `netexec` is unavailable |

---

## Where things land

| Path | What |
|---|---|
| `~/dropzone/` | clones and downloaded payloads |
| `~/dropzone/privesc/` | linpeas / winpeas / PowerUp / privesc / PrivescCheck |
| `/usr/local/bin/` | `chisel`, `upshell`, `kerbrute`, `windapsearch` |
| `~/go/bin/` | `httpx`, `httprobe`, `subfinder`, `waybackurls` |
| `/usr/share/wordlists/` | `rockyou.txt`, `kali-wordlists/` |
| `/usr/share/seclists/` | SecLists |
| `~/.BurpSuite/` | Jython jar + `burp_logger.py` |

## Engagement-evidence layer (not tools, but installed)

| Artifact | Written by | Path |
|---|---|---|
| Readable command log | `command_logging.sh` (zsh + bash hooks) | `~/.zsh_history_readable` |
| Burp HTTP log | `burp_logger.py` extension | `~/.burp_history_readable` |
| Uniform terminal | `terminal_uniform.sh` | qterminal + xfce4-terminal configs |

## Counts

62 apt in `all.sh` + 8 reporting deps + Sublime · 13 apt in `ad.sh` (+2 mono) ·
12 apt in `start.sh` · 5 pip (A) + 3 pip (D) · 4 Go · 9 direct downloads · 6 git clones.

## Gaps and open items

- **No mobile kit installed anywhere** — `apktool`, `jadx`, `frida`, `objection`, `MobSF`, `adb`.
  If the APK-to-endpoint-list flow is meant to run on the VDI, nothing here provides it.
- **`openjdk-11-jdk`** may no longer be in Kali's repos (17/21 are current). It would land
  silently in `APT_FAILED`; Burp needs a JRE. Verify on a real image.
- **`burpsuite` edition** — confirm the apt package is Community. Pro is banned.
- **jVision `dotnet:5.0` base images are EOL** — pre-pull and `docker save` them during prep
  so engagement day isn't the first time a failed pull is discovered.
- **Removed on purpose:** `sqlmap` and `SSTImap` — do not re-add them without asking.
- **Commented out, not installed:** Sliver C2, upstream Neo4j apt repo,
  `statistically-likely-usernames`, NaturalT314 ToolBox.
