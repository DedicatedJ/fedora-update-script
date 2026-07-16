#!/usr/bin/env python3

# ============================================================
# Rich Update Report Viewer (v3)
#
# Reads the machine-readable .summary sidecar written by
# update-system.sh. All structured data comes from the sidecar;
# the raw log is only referenced for deep-dive.
#
# Usage:
#   rich_update_viewer.py                    # latest summary
#   rich_update_viewer.py <file.summary>     # specific summary
#   rich_update_viewer.py <file.log>         # matching summary
# ============================================================

import sys
from pathlib import Path

from rich.console import Console
from rich.table import Table
from rich import box

console = Console()

LOG_DIR = Path.home() / ".local/share/system-updates"

PALETTE = {
    "accent": "cyan",
    "accent_strong": "bold cyan",
    "muted": "dim",
    "ok": "green",
    "warn": "yellow",
    "bad": "red",
    "line": "blue",
}

# ============================================================
# Loading
# ============================================================

def pick_summary_file() -> Path:
    if len(sys.argv) > 1:
        p = Path(sys.argv[1])
        if p.suffix == ".log":
            p = p.with_suffix(".summary")
        if not p.exists():
            console.print(f"[red]Summary file not found:[/red] {p}")
            console.print("[dim]Older logs predate the .summary sidecar; re-run the update script once to generate one.[/dim]")
            sys.exit(1)
        return p
    summaries = sorted(LOG_DIR.glob("update-*.summary"))
    if not summaries:
        console.print(f"[red]No update summaries found in {LOG_DIR}[/red]")
        console.print("[dim]Run the update script once to generate one.[/dim]")
        sys.exit(1)
    return summaries[-1]


def parse_summary(path: Path) -> dict:
    data = {
        "meta": {},
        "dnf_upg": [],   # (key, old, new)
        "dnf_ins": [],   # (key, ver)
        "dnf_rem": [],   # (key, ver)
        "flatpak": [],   # ref
        "fw_upd": [],    # (device, old, new)
        "step_ok": [],
        "step_skip": [],
        "step_fail": [],
    }
    for raw in path.read_text(errors="replace").splitlines():
        if not raw.strip():
            continue
        parts = raw.split("|")
        kind = parts[0]
        if kind == "meta" and len(parts) >= 3:
            data["meta"][parts[1]] = "|".join(parts[2:])
        elif kind == "dnf_upg" and len(parts) == 4:
            data["dnf_upg"].append((parts[1], parts[2], parts[3]))
        elif kind == "dnf_ins" and len(parts) == 3:
            data["dnf_ins"].append((parts[1], parts[2]))
        elif kind == "dnf_rem" and len(parts) == 3:
            data["dnf_rem"].append((parts[1], parts[2]))
        elif kind == "flatpak" and len(parts) == 2:
            data["flatpak"].append(parts[1])
        elif kind == "fw_upd" and len(parts) == 4:
            data["fw_upd"].append((parts[1], parts[2], parts[3]))
        elif kind in ("step_ok", "step_skip", "step_fail") and len(parts) == 2:
            data[kind].append(parts[1])
    return data


# ============================================================
# Render sections (retro uplink style, matches update-system.sh)
# ============================================================

LINE_W = 60
H_LINE = "\u2501" * LINE_W


def section(title: str):
    console.print(f"[bold {PALETTE['line']}]{H_LINE}[/bold {PALETTE['line']}]")
    console.print(f"[{PALETTE['accent_strong']}]  {title}[/{PALETTE['accent_strong']}]")
    console.print(f"[bold {PALETTE['line']}]{H_LINE}[/bold {PALETTE['line']}]")
    console.print()


def leader(label: str, value_markup: str, width: int = 26):
    dots = "." * max(3, width - len(label))
    console.print(
        f"  [{PALETTE['accent']}]\u00b7[/{PALETTE['accent']}] {label} "
        f"[{PALETTE['muted']}]{dots}[/{PALETTE['muted']}] {value_markup}",
        highlight=False,
    )


def render_header(summary_path: Path, meta: dict):
    console.print()
    console.print(f"[bold {PALETTE['accent']}]> SYSTEM UPDATE REPORT[/bold {PALETTE['accent']}]")
    health = meta.get("health", "UNKNOWN")
    badge = PALETTE["ok"] if health == "OK" else PALETTE["warn"]
    leader("Timestamp", f"[{PALETTE['accent']}]{meta.get('timestamp', 'Unknown')}[/{PALETTE['accent']}]")
    leader("Health", f"[bold {badge}]\\[ {health} ][/bold {badge}]")
    leader("Summary", f"[{PALETTE['muted']}]{summary_path}[/{PALETTE['muted']}]")
    if meta.get("log"):
        leader("Log", f"[{PALETTE['muted']}]{meta['log']}[/{PALETTE['muted']}]")
    console.print()


def render_summary_row(data: dict):
    section("CHANNEL STATUS")

    dnf_count = len(data["dnf_upg"]) + len(data["dnf_ins"]) + len(data["dnf_rem"])
    fw_status = data["meta"].get("firmware", "unknown")

    dnf_color = PALETTE["ok"] if dnf_count else PALETTE["muted"]
    fp_color = PALETTE["ok"] if data["flatpak"] else PALETTE["muted"]
    if fw_status.startswith("updated"):
        fw_color = PALETTE["ok"]
    elif "failed" in fw_status:
        fw_color = PALETTE["bad"]
    elif "no updates" in fw_status:
        fw_color = PALETTE["muted"]
    else:
        fw_color = PALETTE["warn"]

    dnf_word = "CHANGE" if dnf_count == 1 else "CHANGES"
    leader("DNF", f"[bold {dnf_color}]\\[ {dnf_count} {dnf_word} ][/bold {dnf_color}]")
    fp_count = len(data["flatpak"])
    fp_word = "UPDATE" if fp_count == 1 else "UPDATES"
    leader("Flatpak", f"[bold {fp_color}]\\[ {fp_count} {fp_word} ][/bold {fp_color}]")
    leader("Firmware", f"[bold {fw_color}]\\[ {fw_status.upper()} ][/bold {fw_color}]")
    console.print()


def striped(style: str, idx: int) -> str:
    return f"{style} dim" if idx % 2 else style


def render_dnf(data: dict):
    section("DNF :: SYSTEM PACKAGES")

    if not data["dnf_upg"] and not data["dnf_ins"] and not data["dnf_rem"]:
        console.print("  [dim]No package changes recorded in this run.[/dim]")
        console.print()
        return

    if data["dnf_upg"]:
        t = Table(box=box.SIMPLE_HEAVY, show_header=True, header_style="bold green", padding=(0, 2))
        t.add_column("UPGRADED", style="green")
        t.add_column("OLD", style="dim")
        t.add_column("NEW", style="green")
        for idx, (key, old, new) in enumerate(data["dnf_upg"]):
            t.add_row(key, old, new, style=striped("green", idx))
        console.print(t)

    if data["dnf_ins"]:
        t = Table(box=box.SIMPLE_HEAVY, show_header=True, header_style="bold cyan", padding=(0, 2))
        t.add_column("NEWLY INSTALLED", style="cyan")
        t.add_column("VERSION", style="cyan")
        for idx, (key, ver) in enumerate(data["dnf_ins"]):
            t.add_row(key, ver, style=striped("cyan", idx))
        console.print(t)

    if data["dnf_rem"]:
        t = Table(box=box.SIMPLE_HEAVY, show_header=True, header_style="bold yellow", padding=(0, 2))
        t.add_column("REMOVED", style="yellow")
        t.add_column("VERSION", style="yellow")
        for idx, (key, ver) in enumerate(data["dnf_rem"]):
            t.add_row(key, ver, style=striped("yellow", idx))
        console.print(t)

    console.print()


def render_flatpak(apps: list):
    section("FLATPAK :: APP UPDATES")

    if not apps:
        console.print("  [dim]No Flatpak updates recorded.[/dim]")
    else:
        t = Table(box=box.SIMPLE_HEAVY, show_header=True, header_style="bold green", padding=(0, 2))
        t.add_column("UPDATED REFS", style="green")
        for idx, ref in enumerate(apps):
            t.add_row(ref, style=striped("green", idx))
        console.print(t)

    console.print()


def render_firmware(data: dict):
    section("FIRMWARE :: FWUPD")

    status = data["meta"].get("firmware", "unknown")
    if status.startswith("updated"):
        color = "green"
    elif "failed" in status:
        color = "red"
    elif "no updates" in status:
        color = "dim"
    else:
        color = "yellow"

    leader("Status", f"[{color}]\\[ {status.upper()} ][/{color}]")

    if data["fw_upd"]:
        console.print()
        t = Table(box=box.SIMPLE_HEAVY, show_header=True, header_style="bold green", padding=(0, 2))
        t.add_column("DEVICE", style="green")
        t.add_column("OLD", style="dim")
        t.add_column("NEW", style="green")
        for idx, (dev, old, new) in enumerate(data["fw_upd"]):
            t.add_row(dev, old, new, style=striped("green", idx))
        console.print(t)

    console.print()


def render_steps(data: dict):
    if not data["step_skip"] and not data["step_fail"]:
        return
    section("STEPS")
    if data["step_skip"]:
        console.print(f"  [bold {PALETTE['warn']}]Skipped:[/bold {PALETTE['warn']}]")
        for s in data["step_skip"]:
            console.print(f"    [dim]\u00b7 {s}[/dim]")
    if data["step_fail"]:
        console.print(f"  [bold {PALETTE['bad']}]Failed:[/bold {PALETTE['bad']}]")
        for s in data["step_fail"]:
            console.print(f"    [{PALETTE['bad']}]\u2718 {s}[/{PALETTE['bad']}]")
    console.print()


def render_reboot(meta: dict):
    reason = meta.get("reboot", "none")
    if reason and reason != "none":
        red_line = "\u2501" * LINE_W
        console.print(f"[bold {PALETTE['bad']}]{red_line}[/bold {PALETTE['bad']}]")
        console.print(f"[bold {PALETTE['bad']}]  !! REBOOT RECOMMENDED[/bold {PALETTE['bad']}]")
        console.print(f"  [{PALETTE['warn']}]{reason}[/{PALETTE['warn']}]", highlight=False)
        console.print("  [dim]Reboot when convenient to activate.[/dim]")
        console.print(f"[bold {PALETTE['bad']}]{red_line}[/bold {PALETTE['bad']}]")
        console.print()


def render_footer():
    console.print(f"[bold {PALETTE['ok']}]> END OF TRANSMISSION \u2588[/bold {PALETTE['ok']}]")
    console.print()


# ============================================================
# Main
# ============================================================

def main():
    summary_path = pick_summary_file()
    data = parse_summary(summary_path)

    render_header(summary_path, data["meta"])
    render_summary_row(data)
    render_dnf(data)
    render_flatpak(data["flatpak"])
    render_firmware(data)
    render_steps(data)
    render_reboot(data["meta"])
    render_footer()


if __name__ == "__main__":
    main()
