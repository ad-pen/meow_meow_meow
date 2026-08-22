# Build rehearsal procedure

The `/home/kali` bug in `ad.sh` survived every rehearsal we did, because the
practice VM's user happened to be named `kali`. Half the installs silently landed
in the wrong directory and the verification then reported NOT FOUND for tools
that had installed fine. Nothing about that is exotic — it is what happens when
you rehearse on the machine you develop on.

A rehearsal only counts if the box is **clean** and **not shaped like your dev box**.

---

## Ground rules

1. **Fresh snapshot every time.** Not "I removed dropzone and re-ran it." Revert
   the VM. Half of what these scripts do is edit dotfiles and system config, and
   those edits are guarded — a second run down a guarded path proves nothing about
   the first run.
2. **The user must NOT be named `kali`.** Create `operator` or use your own name.
   This single rule is what would have caught the bug above.
3. **Rehearse the network you will have**, not your home fibre. If the VDI is
   slow or filtered, that is the run that matters.
4. **Two people, two boxes, same morning.** Different accounts, different
   hardware. Divergence between them is the finding.

## The run

| # | Step | What you are checking |
|---|---|---|
| 1 | Revert to a clean Kali snapshot; log in as a non-`kali` user | baseline |
| 2 | `git clone` the repo the way an operator would, into a path with no spaces | path assumptions |
| 3 | `time bash start.sh` | record the wall time |
| 4 | Open a **new** terminal — is the uniform applied? Is the prompt normal? | `terminal_uniform.sh`, and that we did not break the shell |
| 5 | Run three commands, one with a password in it, then `cat ~/.zsh_history_readable` | logging is live **and** the password is `[REDACTED]` |
| 6 | Start Burp, send one Repeater request, `tail ~/.burp_history_readable` | the extension auto-loaded and writes |
| 7 | `time bash all.sh` — answer the preflight prompt | record wall time; preflight should pass cleanly after steps 4-6 |
| 8 | Read the **verification summary** line by line. Every FAIL and WARN is a finding | this is the whole point |
| 9 | `time bash ad.sh`, same treatment | |
| 10 | `ls ~/dropzone` and confirm it is in **your** home, not `/home/kali` | the original bug |
| 11 | Re-run `all.sh` and `ad.sh` | idempotency: second run must be fast and mostly "already installed" |
| 12 | `bash smol-all.sh` on a **second** clean snapshot | the emergency path, timed |

## Pin the artifacts (do this once, on a trusted network)

The manifest in `lib.sh` ships with every sha256 set to `TBD`, because a hash
nobody computed is worse than no hash - it looks like verification while
verifying nothing. During a rehearsal:

```
bash pins.sh --show      # what is pinned and what still tracks a moving target
bash pins.sh --write     # download everything, record the real hashes into lib.sh
git commit lib.sh        # a pin only helps if everyone builds from the same one
bash pins.sh --verify    # run again the week before the event: drift check
```

After that, `all.sh` and `ad.sh` verify every download against the manifest and
refuse to accept a mismatch quietly. Each box also writes `~/pins.lock` with what
it actually got - **diff that file between two operators' boxes; any difference
is a build that will not reproduce.**

## What to record

Put these in `team-todo.md` after each rehearsal — they are the numbers you plan
the engagement morning around:

- wall time for `start.sh`, `all.sh`, `ad.sh`, `smol-all.sh`
- the pin summary: how many artifacts were unpinned, and any sha256 mismatch
- the PASS / WARN / FAIL counts from each verification summary
- the exact contents of the `APT packages that FAILED to install` line
- anything that needed a human to intervene

## The checks that catch real bugs

These are the ones worth being deliberate about, because each maps to a failure
we have actually seen or narrowly avoided:

- **`ls ~/dropzone`** — wrong-home bug.
- **A FAIL in verification that is actually a script bug, not a missing tool.**
  Verification now runs tools rather than locating them, so a FAIL means the tool
  genuinely does not work. Do not wave any of them through.
- **`head -c 100 ~/dropzone/privesc/linpeas.sh`** — if the network has a captive
  portal or an intercepting proxy, downloads land as HTML with a 200 status.
  `check_payload` catches this now; confirm it fires by testing on the real link.
- **Password redaction** — run `nxc smb 10.0.0.1 -u admin -p 'Summer2026!'` and
  confirm the log shows `ad[REDACTED]` and `[REDACTED]`, not the password.
- **A second `qterminal` opened *and closed*** — the `chattr +i` lock must hold;
  without it, a closing qterminal reverts the uniform.
- **Log out and back in** — this is when the docker group, the PATH additions and
  the shell hooks actually take effect. Several things "work" only after this.

## Known assumptions the scripts still make

Not bugs today, but they are what a rehearsal on an unusual box would expose:

- `$HOME` contains no spaces (`mkdir -p ~/dropzone` is unquoted in places).
- The user's login shell is zsh or bash — `command_logging.sh` writes to both,
  but a third shell (fish) gets no logging at all.
- `sudo` works without a password prompt for the duration, via the keepalive loop.
- An X session exists for the terminal uniform and screenshot tools to matter.
