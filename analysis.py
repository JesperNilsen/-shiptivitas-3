"""Runs the named queries in answer.sql against shiptivity.db and draws the task 3 charts.

Usage:  python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
        .venv/bin/python analysis.py

The SQL lives only in answer.sql. Each query there starts with a `-- name: <id>` line, and
this script runs that exact text, so the charts can never drift from the submitted queries.
"""
import re
import sqlite3
from datetime import date
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.dates as mdates  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402

ROOT = Path(__file__).parent
CHARTS = ROOT / "charts"
LAUNCH = date(2018, 6, 2)

# Reference palette (light mode): one hue for the data, neutrals for context.
SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK_2 = "#52514e"
INK_3 = "#8a8984"
GRID = "#e6e5e1"
BLUE = "#2a78d6"
NEUTRAL = "#c9c8c2"


def load_queries(path):
    """Split answer.sql into {name: sql} using the `-- name:` markers."""
    queries, name, lines = {}, None, []
    for line in path.read_text().splitlines():
        marker = re.match(r"--\s*name:\s*(\w+)", line)
        if marker:
            if name:
                queries[name] = "\n".join(lines)
            name, lines = marker.group(1), []
        elif line.startswith("-- PART") and name:
            queries[name] = "\n".join(lines)
            name, lines = None, []
        elif name and not line.startswith("."):  # skip sqlite3 shell dot-commands
            lines.append(line)
    if name:
        queries[name] = "\n".join(lines)
    return queries


def run(db, sql):
    cur = db.execute(sql)
    cols = [c[0] for c in cur.description]
    return [dict(zip(cols, row)) for row in cur.fetchall()]


def style(ax):
    ax.set_facecolor(SURFACE)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.spines["bottom"].set_color(INK_3)
    ax.tick_params(colors=INK_2, labelsize=9, length=0)
    ax.yaxis.grid(True, color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)


def title(fig, headline, subtitle):
    fig.text(0.055, 0.955, headline, fontsize=14, fontweight="bold", color=INK, va="top")
    fig.text(0.055, 0.885, subtitle, fontsize=9.5, color=INK_2, va="top")


def dau_chart(daily, summary):
    days = [date.fromisoformat(r["day"]) for r in daily]
    users = [r["active_users"] for r in daily]
    colors = [BLUE if d >= LAUNCH else NEUTRAL for d in days]
    before = next(r for r in summary if r["period"] == "before launch")
    after = next(r for r in summary if r["period"] == "after launch")

    fig, ax = plt.subplots(figsize=(11, 5.2), dpi=200, facecolor=SURFACE)
    fig.subplots_adjust(left=0.055, right=0.98, top=0.78, bottom=0.11)
    style(ax)
    ax.bar(days, users, width=0.8, color=colors, linewidth=0)

    for row, d0, d1 in (
        (before, date.fromisoformat(before["first_day"]), LAUNCH),
        (after, LAUNCH, date.fromisoformat(after["last_day"])),
    ):
        avg = row["avg_daily_active_users"]
        ax.hlines(avg, d0, d1, color=INK, linewidth=2)
        label = f"{'Before' if row is before else 'After'} launch: {avg:.1f} users/day"
        ax.annotate(label, (d0, avg), xytext=(6, 7), textcoords="offset points",
                    fontsize=9.5, color=INK, fontweight="bold",
                    bbox={"boxstyle": "round,pad=0.3", "facecolor": SURFACE,
                          "edgecolor": "none", "alpha": 0.92})

    ax.axvline(LAUNCH, color=INK_2, linewidth=1, linestyle=(0, (4, 3)))
    ax.annotate("Kanban board launched\n2 Jun 2018", (LAUNCH, max(users)),
                xytext=(-6, 0), textcoords="offset points", ha="right", va="top",
                fontsize=9, color=INK_2)

    ax.set_ylabel("Daily active users", color=INK_2, fontsize=9.5)
    ax.xaxis.set_major_locator(mdates.MonthLocator())
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%b\n%Y"))
    ax.set_xlim(days[0], days[-1])
    ax.set_ylim(0, max(users) + 2)
    ratio = after["avg_daily_active_users"] / before["avg_daily_active_users"]
    title(fig,
          f"Daily active users rose {ratio:.1f}x after the Kanban board launched",
          "Distinct users who logged in each day (UTC), 3 Feb 2018 to 1 Feb 2019. "
          "Black lines are each period's average;\ndays with no logins count as 0. "
          "Grey = before launch, blue = after.")
    out = CHARTS / "dau_before_after.png"
    fig.savefig(out, facecolor=SURFACE)
    plt.close(fig)
    return out


def status_chart(distribution, daily):
    fig, (left, right) = plt.subplots(1, 2, figsize=(11, 5.2), dpi=200, facecolor=SURFACE,
                                      gridspec_kw={"width_ratios": [1, 1.5], "wspace": 0.22})
    fig.subplots_adjust(left=0.055, right=0.98, top=0.76, bottom=0.12)

    # Left: cards by number of status changes.
    style(left)
    counts = [r["status_changes"] for r in distribution]
    cards = [r["cards"] for r in distribution]
    total = sum(cards)
    bars = left.bar(counts, cards, width=0.7, color=BLUE, linewidth=0)
    for bar, n in zip(bars, cards):
        left.annotate(f"{n}", (bar.get_x() + bar.get_width() / 2, n), xytext=(0, 3),
                      textcoords="offset points", ha="center", fontsize=9, color=INK)
    notes = {0: "never left\nthe backlog", 2: "backlog →\nin progress →\ncomplete"}
    for x, text in notes.items():
        if x in counts:
            n = cards[counts.index(x)]
            left.annotate(text, (x, n), xytext=(0, 16), textcoords="offset points",
                          ha="center", fontsize=8, color=INK_2)
    left.set_xticks(counts)
    left.set_xlabel("Status changes per card", color=INK_2, fontsize=9.5)
    left.set_ylabel("Cards", color=INK_2, fontsize=9.5)
    left.set_ylim(0, max(cards) * 1.45)
    left.set_title(f"By card ({total} cards)", loc="left", fontsize=10.5, color=INK,
                   fontweight="bold")

    # Right: the same changes per day since launch.
    style(right)
    days = [date.fromisoformat(r["day"]) for r in daily]
    changes = [r["status_changes"] for r in daily]
    right.bar(days, changes, width=0.8, color=BLUE, linewidth=0)
    quiet = sum(1 for c in changes if c == 0)
    right.set_title(f"By day since launch (none on {quiet} of {len(days)} days)", loc="left",
                    fontsize=10.5, color=INK, fontweight="bold")
    right.set_ylabel("Status changes", color=INK_2, fontsize=9.5)
    right.xaxis.set_major_locator(mdates.MonthLocator())
    right.xaxis.set_major_formatter(mdates.DateFormatter("%b\n%Y"))
    right.set_xlim(days[0], days[-1])

    moved = total - (cards[counts.index(0)] if 0 in counts else 0)
    title(fig,
          f"{sum(c * n for c, n in zip(counts, cards))} status changes: most cards move twice, "
          f"{cards[counts.index(0)] if 0 in counts else 0} never move",
          f"Status changes per card in card_change_history ({moved} of {total} cards moved). "
          "The row that records a card's creation is\nnot counted. "
          "Data runs from launch (2 Jun 2018) to 1 Feb 2019.")
    out = CHARTS / "status_changes_by_card.png"
    fig.savefig(out, facecolor=SURFACE)
    plt.close(fig)
    return out


def show(title_text, rows):
    print(f"\n{title_text}")
    if rows:
        cols = list(rows[0])
        print("  " + " | ".join(cols))
        for r in rows:
            print("  " + " | ".join(str(r[c]) for c in cols))


def main():
    CHARTS.mkdir(exist_ok=True)
    queries = load_queries(ROOT / "answer.sql")
    db = sqlite3.connect(ROOT / "shiptivity.db")
    r = {name: run(db, sql) for name, sql in queries.items()}

    for name in ("dau_before_after", "cards_by_change_count", "monthly_engagement",
                 "user_cohorts", "signups_by_month", "status_transitions", "card_cycle_time",
                 "card_flow_by_month", "card_wait_times", "logins_vs_moves_after_launch"):
        show(name, r[name])
    print("\nWrote", dau_chart(r["dau_daily"], r["dau_before_after"]).relative_to(ROOT))
    print("Wrote", status_chart(r["cards_by_change_count"],
                                r["status_changes_daily"]).relative_to(ROOT))


if __name__ == "__main__":
    main()
