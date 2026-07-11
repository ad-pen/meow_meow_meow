# CPTC12 — Attack-box setup (reference & archive)

Self-contained set of scripts to bootstrap a teammate's Kali box into a uniform,
logged pentest workstation for the engagement. Everything is in this directory;
`start.sh` finds the two helpers via its own path, so keep the files together.

## Run order

Run **as your normal user** (each script calls `sudo` itself — do NOT `sudo bash`,
or per-user config lands on root):

| # | Script | Purpose |
|---|--------|---------|
| 1 | `./start.sh` | Base packages (python, nmap, git…), SSH, XFCE + xRDP. Then installs command logging and the terminal uniform (calls the two helpers below). |
| 2 | `./all.sh` | Full tool suite into `~/dropzone` (recon, web, cracking, pivoting, privesc kit, wordlists, go tools…). Ends with a verification tally. |
| 3 | `./ad.sh` | Active Directory tooling (bloodhound/neo4j, netexec, certipy, kerbrute, impacket, ghostpack…). |

Helpers (invoked by `start.sh`, also runnable standalone):

- `command_logging.sh` — timestamped, cwd- and exit-code-tagged command log at
  `~/.zsh_history_readable` for **both zsh and bash**, with best-effort credential
  redaction. Idempotent; guarded so re-running is a no-op.
- `terminal_uniform.sh` — identical appearance (green-on-black, solid-black bg,
  FiraCode 10) for **both** `qterminal` (local) and `xfce4-terminal` (xRDP session),
  so report screenshots match. Idempotent; backs up each config to `*.cptcbak`.

## Notes / known gotchas

- **Logging lives in `start.sh` only.** The old inline `HISTSIZE`/`preexec` block was
  removed from `all.sh` — `command_logging.sh` supersedes it and refuses to run if
  those stale hooks are present in `~/.zshrc`.
- **Terminal uniform:** qterminal rewrites its config on exit, so apply it with
  qterminal closed (or log out/in). xfce4-terminal only needs a fresh window.
  The green (`#18b218`) is an approximation of qterminal's GreenOnBlack — tune the
  vars at the top of `terminal_uniform.sh` for an exact match.
- **`ad.sh` hardcodes `/home/kali/dropzone`** in its `mkdir`/`cd`, but later steps use
  `~/dropzone`/`$HOME/dropzone`. Correct only when the invoking user is `kali`; the
  paths diverge for any other user. (Carried over from the original — not yet fixed.)
- Python installs use `--break-system-packages` (required on current Kali's
  externally-managed Python); no venvs.
