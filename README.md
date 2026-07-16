# Fedora Update Script

A Fedora system update script that does DNF, Flatpak, and firmware in one shot, then hands you a clean report instead of making you scroll back through a wall of package spam. Also it looks like you're hacking the Gibson while it runs. That part is not optional.

```
> ESTABLISHING UPLINK
  · DNF ..................... [ LINKED ]
  · Flatpak ................. [ LINKED ]
  · Firmware (LVFS) ......... [ LINKED ]
> HANDSHAKE ACCEPTED
> ACCESS GRANTED :: WE'RE IN █
```

I got tired of running three update commands, losing the output, and never knowing if I actually needed to reboot. So this happened.

## What it does

- **One command** updates everything: `dnf upgrade`, `flatpak update`, and `fwupdmgr` firmware, in that order, with per-step timing
- **Real change tracking**, not output scraping. It diffs rpm and flatpak snapshots before/after, so it survives dnf5 and flatpak changing their output format on a whim. Firmware detail comes from `fwupdmgr get-updates --json`
- **Reboot detection** that actually tells you *why*: running kernel vs newest installed kernel, core userspace upgrades (glibc, systemd, etc.), and staged firmware
- **Rich TUI report** at the end (via [rich](https://github.com/Textualize/rich)): channel status, upgraded/installed/removed tables, firmware devices, skipped steps, reboot warning
- **Machine-readable sidecar**: every run writes a `.summary` file the viewer parses, plus a full raw `.log`
- **Log rotation**: keeps the newest 45 log+summary pairs, prunes the rest automatically
- **Automation-safe**: every animation and pause is gated behind a TTY check. Pipe it, cron it, redirect it, and you get instant plain text with zero escape-code garbage. Exit codes pass through, so `update && something` works
- **The intro sequence**. Typewriter text, animated dot leaders, a SYNC decrypt effect, a blinking cursor. Pure 80s/90s terminal movie. Zero functional value. Would build again

## The pieces

| File | What it is |
|---|---|
| `update-system.sh` | The main script. Bash, does all the work |
| `rich_update_viewer.py` | Renders the report from the `.summary` sidecar. Python 3 + rich |
| `update` | Tiny wrapper that lives in your PATH and execs the main script |

## Requirements

- Fedora (or anything DNF-based, built and tested on Fedora)
- `flatpak` and `fwupd` are optional; steps skip cleanly if they're not installed
- Python 3 with `rich` for the report viewer:

```bash
pip install --user rich
```

No rich? The script detects that and falls back to a plain-text summary. You lose the pretty, not the info.

## Install

```bash
mkdir -p ~/scripts/update_script
cp update-system.sh rich_update_viewer.py ~/scripts/update_script/
cp update ~/scripts/
chmod +x ~/scripts/update_script/update-system.sh ~/scripts/update_script/rich_update_viewer.py ~/scripts/update
```

Make sure `~/scripts` is in your PATH (adjust the wrapper's target path if you put things elsewhere), then:

```bash
update --dry-run
```

Dry run walks the whole pipeline without changing anything, so you get the full show and a mostly-skipped report. Good first test.

## Usage

```bash
update                # full run: DNF + Flatpak + firmware, then the report
update --dry-run      # simulate DNF (--assumeno), skip Flatpak/firmware changes
update --security     # DNF security-only updates instead of full upgrade
update --cleanup      # run dnf autoremove after the upgrade
update --no-view      # skip the rich viewer, print the plain summary instead
```

Flags combine fine (`update --security --cleanup`).

### Reading old reports

Every run leaves a pair in `~/.local/share/system-updates/`:

```
update-20260715-191043.log        # full raw output
update-20260715-191043.summary    # structured data for the viewer
```

Re-render any past run:

```bash
~/scripts/update_script/rich_update_viewer.py                          # latest run
~/scripts/update_script/rich_update_viewer.py path/to/update-X.summary # specific run
~/scripts/update_script/rich_update_viewer.py path/to/update-X.log    # works too, finds the matching summary
```

## What a run looks like

Interactive terminal gets the cinematic open, then each step reports on one line, with any command output pushed into an indented block underneath so nothing ever lands on the status line:

```
  → Flatpak update
      Info: org.gnome.Platform is end-of-life
  → Flatpak update                              done (12s)
```

Then the report:

```
> SYSTEM UPDATE REPORT
  · Timestamp ................. 2026-07-15 19:11:59
  · Health .................... [ OK ]

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  CHANNEL STATUS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  · DNF ....................... [ 3 CHANGES ]
  · Flatpak ................... [ 1 UPDATE ]
  · Firmware .................. [ UPDATED 1 DEVICE(S) ]

...tables of exactly what changed...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  !! REBOOT RECOMMENDED
  kernel 7.1.3-200.fc44.x86_64 → 7.1.3-201.fc44.x86_64
  Reboot when convenient to activate.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

> END OF TRANSMISSION █
```

## Design notes

A few decisions worth knowing about if you're poking at the code:

- **Snapshot diffs over parsing.** Package changes come from comparing sorted `rpm -qa` / `flatpak list` snapshots taken before and after, via `comm`. DNF and Flatpak can reformat their output all they want
- **Long lists get truncated on screen** (15 per list) but the sidecar always has everything, so the viewer shows the full picture
- **fwupd progress spam** (`Downloading…`, `Writing…`, etc.) is filtered from both screen and log
- **`set -euo pipefail`** everywhere, and the sudo prompt gets its own line when credentials aren't cached so it can't smash into a status line
- **Everything cosmetic is `[ -t 1 ]` gated.** The FX helpers (`fx_type`, `fx_channel`, `fx_cursor_blink`, `fx_sleep`) all collapse to instant plain output when stdout isn't a terminal

## License

MIT. Do whatever you want with it.
