#!/usr/bin/env python3
"""Aggregate Codex token usage for an orchestrated session.

Codex writes one rollout JSONL file per thread under ~/.codex/sessions.
Subagent threads carry the root thread id in `session_id`, so grouping the
files by that value gives the full cost of one orchestrated task, split by
thread, role, and model.

Usage:
  scripts/token_usage.py --list [--date YYYY-MM-DD]
  scripts/token_usage.py --root <root-thread-id-or-prefix> [--format md|json]
  scripts/token_usage.py --latest

Standard library only. Read-only: it never modifies the session files.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

USAGE_KEYS = (
    "input_tokens",
    "cached_input_tokens",
    "output_tokens",
    "reasoning_output_tokens",
    "total_tokens",
)


def empty_usage() -> dict[str, int]:
    return {k: 0 for k in USAGE_KEYS}


def add_usage(target: dict[str, int], usage: dict) -> None:
    for k in USAGE_KEYS:
        target[k] += int(usage.get(k) or 0)


def parse_ts(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def iter_rollouts(sessions_dir: Path, date: str | None):
    if date:
        y, m, d = date.split("-")
        base = sessions_dir / y / m / d
        if not base.is_dir():
            return
        yield from sorted(base.glob("rollout-*.jsonl"))
        return
    yield from sorted(sessions_dir.rglob("rollout-*.jsonl"))


def read_meta(path: Path) -> dict | None:
    try:
        with path.open("r", encoding="utf-8") as fh:
            first = fh.readline()
    except OSError:
        return None
    try:
        obj = json.loads(first)
    except json.JSONDecodeError:
        return None
    if obj.get("type") != "session_meta":
        return None
    return obj.get("payload") or {}


def thread_role(meta: dict) -> tuple[str, str]:
    """Return (role, nickname) for a thread."""
    source = meta.get("source")
    if isinstance(source, dict):
        sub = source.get("subagent") or {}
        if isinstance(sub, str):
            return sub, ""
        spawn = sub.get("thread_spawn")
        if isinstance(spawn, dict):
            return spawn.get("agent_role") or "subagent", spawn.get("agent_nickname") or ""
        other = sub.get("other")
        if other:
            return str(other), ""
    if meta.get("id") == meta.get("session_id"):
        return "root", ""
    return meta.get("thread_source") or "unknown", ""


def analyze_thread(path: Path, meta: dict) -> dict:
    role, nickname = thread_role(meta)
    per_model: dict[str, dict[str, int]] = defaultdict(empty_usage)
    responses: dict[str, int] = defaultdict(int)
    model = None
    effort = None
    first_ts = parse_ts(meta.get("timestamp"))
    last_ts = first_ts
    last_total = None
    rate_first = None
    rate_last = None

    with path.open("r", encoding="utf-8") as fh:
        for line in fh:
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = parse_ts(obj.get("timestamp"))
            if ts and (last_ts is None or ts > last_ts):
                last_ts = ts
            kind = obj.get("type")
            payload = obj.get("payload") or {}
            if kind == "turn_context":
                model = payload.get("model") or model
                effort = payload.get("effort") or effort
            elif kind == "token_usage_record" or (
                kind == "event_msg" and payload.get("type") == "token_usage_record"
            ):
                # One record per model response; `usage` is the per-response delta.
                usage = payload.get("usage") or {}
                key = model or "unknown"
                add_usage(per_model[key], usage)
                responses[key] += 1
            elif kind == "event_msg":
                sub = payload.get("type")
                if sub == "token_count":
                    info = payload.get("info") or {}
                    if info.get("total_token_usage"):
                        last_total = info["total_token_usage"]
                    limits = payload.get("rate_limits")
                    if limits:
                        if rate_first is None:
                            rate_first = limits
                        rate_last = limits

    # Older Codex builds may not emit token_usage_record; fall back to the
    # cumulative counter attributed to the last active model.
    if not per_model and last_total:
        add_usage(per_model[model or "unknown"], last_total)

    return {
        "id": meta.get("id"),
        "parent_thread_id": meta.get("parent_thread_id"),
        "role": role,
        "nickname": nickname,
        "model": model,
        "effort": effort,
        "cwd": meta.get("cwd"),
        "cli_version": meta.get("cli_version"),
        "started": first_ts,
        "ended": last_ts,
        "per_model": dict(per_model),
        "responses": dict(responses),
        "cumulative_total": last_total,
        "rate_first": rate_first,
        "rate_last": rate_last,
        "path": str(path),
    }


def collect_sessions(sessions_dir: Path, date: str | None) -> dict[str, list[tuple[Path, dict]]]:
    sessions: dict[str, list[tuple[Path, dict]]] = defaultdict(list)
    for path in iter_rollouts(sessions_dir, date):
        meta = read_meta(path)
        if not meta:
            continue
        root = meta.get("session_id") or meta.get("id")
        sessions[root].append((path, meta))
    return sessions


def is_guardian(role: str) -> bool:
    return role in {"guardian", "guardian_review"}


def fmt_int(n: int) -> str:
    return f"{n:,}"


def fmt_pct(limits: dict | None, key: str) -> str:
    if not limits or not limits.get(key):
        return "-"
    return f"{limits[key].get('used_percent', '-')}%"


def fmt_duration(start: datetime | None, end: datetime | None) -> str:
    if not start or not end:
        return "-"
    seconds = int((end - start).total_seconds())
    return f"{seconds // 60}m{seconds % 60:02d}s"


def render_markdown(root_id: str, threads: list[dict], include_guardian: bool) -> str:
    root = next((t for t in threads if t["role"] == "root"), None)
    counted = [t for t in threads if include_guardian or not is_guardian(t["role"])]
    skipped = [t for t in threads if t not in counted]

    starts = [t["started"] for t in threads if t["started"]]
    ends = [t["ended"] for t in threads if t["ended"]]
    wall = fmt_duration(min(starts), max(ends)) if starts and ends else "-"

    lines: list[str] = []
    lines.append(f"### Session `{root_id[:8]}`")
    lines.append("")
    if root:
        lines.append(f"- cwd: `{root['cwd']}`")
        lines.append(f"- codex: `{root['cli_version']}`")
    lines.append(f"- threads: {len(threads)} ({len(counted)} counted, {len(skipped)} auto-review skipped)")
    lines.append(f"- wall time: {wall}")
    if root and root["rate_first"] and root["rate_last"]:
        rf, rl = root["rate_first"], root["rate_last"]
        plan = rl.get("plan_type") or "-"
        lines.append(
            f"- rate limit ({plan}): 5h {fmt_pct(rf, 'primary')} -> {fmt_pct(rl, 'primary')}, "
            f"7d {fmt_pct(rf, 'secondary')} -> {fmt_pct(rl, 'secondary')}"
        )
    lines.append("")

    lines.append("| Thread | Role | Model / effort | Responses | Uncached in | Cached in | Output | Reasoning | Total | Duration |")
    lines.append("|---|---|---|---:|---:|---:|---:|---:|---:|---:|")
    grand = empty_usage()
    by_model: dict[str, dict[str, int]] = defaultdict(empty_usage)
    by_model_responses: dict[str, int] = defaultdict(int)
    for t in counted:
        for model, usage in sorted(t["per_model"].items()):
            uncached = usage["input_tokens"] - usage["cached_input_tokens"]
            label = t["role"] + (f" ({t['nickname']})" if t["nickname"] else "")
            effort = t["effort"] if model == t["model"] else "?"
            lines.append(
                f"| `{t['id'][:8]}` | {label} | {model} / {effort} | {t['responses'].get(model, 0)} | "
                f"{fmt_int(uncached)} | {fmt_int(usage['cached_input_tokens'])} | {fmt_int(usage['output_tokens'])} | "
                f"{fmt_int(usage['reasoning_output_tokens'])} | {fmt_int(usage['total_tokens'])} | "
                f"{fmt_duration(t['started'], t['ended'])} |"
            )
            add_usage(grand, usage)
            add_usage(by_model[model], usage)
            by_model_responses[model] += t["responses"].get(model, 0)
    lines.append("")

    lines.append("| Model | Threads | Responses | Uncached in | Cached in | Output | Reasoning | Total |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|")
    for model, usage in sorted(by_model.items()):
        n_threads = sum(1 for t in counted if model in t["per_model"])
        uncached = usage["input_tokens"] - usage["cached_input_tokens"]
        lines.append(
            f"| {model} | {n_threads} | {by_model_responses[model]} | {fmt_int(uncached)} | "
            f"{fmt_int(usage['cached_input_tokens'])} | {fmt_int(usage['output_tokens'])} | "
            f"{fmt_int(usage['reasoning_output_tokens'])} | {fmt_int(usage['total_tokens'])} |"
        )
    g_uncached = grand["input_tokens"] - grand["cached_input_tokens"]
    lines.append(
        f"| **all** | {len(counted)} | {sum(by_model_responses.values())} | {fmt_int(g_uncached)} | "
        f"{fmt_int(grand['cached_input_tokens'])} | {fmt_int(grand['output_tokens'])} | "
        f"{fmt_int(grand['reasoning_output_tokens'])} | {fmt_int(grand['total_tokens'])} |"
    )
    if grand["input_tokens"]:
        pct = 100.0 * grand["cached_input_tokens"] / grand["input_tokens"]
        lines.append("")
        lines.append(f"Cache hit rate on input: {pct:.1f}%")
    if skipped:
        lines.append("")
        lines.append(
            "Skipped auto-review threads: "
            + ", ".join(f"`{t['id'][:8]}` ({t['model'] or 'unknown'})" for t in skipped)
            + ". Pass `--include-guardian` to count them."
        )
    return "\n".join(lines)


def to_json(root_id: str, threads: list[dict], include_guardian: bool) -> str:
    def clean(t: dict) -> dict:
        out = dict(t)
        out["started"] = t["started"].isoformat() if t["started"] else None
        out["ended"] = t["ended"].isoformat() if t["ended"] else None
        out["counted"] = include_guardian or not is_guardian(t["role"])
        return out

    return json.dumps({"root": root_id, "threads": [clean(t) for t in threads]}, indent=2)


def list_sessions(sessions: dict[str, list[tuple[Path, dict]]], limit: int) -> None:
    rows = []
    for root_id, items in sessions.items():
        metas = [m for _, m in items]
        root_meta = next((m for m in metas if m.get("id") == root_id), None)
        started = parse_ts((root_meta or metas[0]).get("timestamp"))
        roles = [thread_role(m)[0] for m in metas if m.get("id") != root_id]
        n_sub = sum(1 for r in roles if not is_guardian(r))
        rows.append((started or datetime.min.replace(tzinfo=timezone.utc), root_id, n_sub, (root_meta or metas[0]).get("cwd")))
    rows.sort(reverse=True)
    print("started (UTC)       root id   subagents  cwd")
    for started, root_id, n_sub, cwd in rows[:limit]:
        print(f"{started.strftime('%Y-%m-%d %H:%M'):<19} {root_id[:8]}  {n_sub:>9}  {cwd}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sessions-dir", default=os.path.expanduser("~/.codex/sessions"))
    parser.add_argument("--date", help="Only scan rollouts for this day (YYYY-MM-DD). Much faster.")
    parser.add_argument("--list", action="store_true", help="List root sessions and their subagent counts.")
    parser.add_argument("--limit", type=int, default=20, help="Rows to show with --list.")
    parser.add_argument("--root", help="Root thread id (or unique prefix) to report on.")
    parser.add_argument("--latest", action="store_true", help="Report on the most recent session that spawned subagents.")
    parser.add_argument("--include-guardian", action="store_true", help="Count Codex auto-review threads in totals.")
    parser.add_argument("--format", choices=("md", "json"), default="md")
    args = parser.parse_args(argv)

    sessions_dir = Path(args.sessions_dir)
    if not sessions_dir.is_dir():
        print(f"sessions dir not found: {sessions_dir}", file=sys.stderr)
        return 2

    sessions = collect_sessions(sessions_dir, args.date)
    if not sessions:
        print("no rollouts found", file=sys.stderr)
        return 1

    if args.list:
        list_sessions(sessions, args.limit)
        return 0

    root_id = None
    if args.root:
        matches = [r for r in sessions if r.startswith(args.root)]
        if len(matches) != 1:
            print(f"--root matched {len(matches)} sessions; give a longer prefix", file=sys.stderr)
            return 2
        root_id = matches[0]
    elif args.latest:
        candidates = []
        for rid, items in sessions.items():
            subs = [m for _, m in items if m.get("id") != rid and not is_guardian(thread_role(m)[0])]
            if subs:
                root_meta = next((m for _, m in items if m.get("id") == rid), items[0][1])
                candidates.append((parse_ts(root_meta.get("timestamp")) or datetime.min.replace(tzinfo=timezone.utc), rid))
        if not candidates:
            print("no session with subagents found", file=sys.stderr)
            return 1
        root_id = max(candidates)[1]
    else:
        parser.print_help()
        return 2

    threads = [analyze_thread(path, meta) for path, meta in sessions[root_id]]
    order = {"root": 0}
    threads.sort(key=lambda t: (order.get(t["role"], 1), t["started"] or datetime.max.replace(tzinfo=timezone.utc)))

    if args.format == "json":
        print(to_json(root_id, threads, args.include_guardian))
    else:
        print(render_markdown(root_id, threads, args.include_guardian))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
