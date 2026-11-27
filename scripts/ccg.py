#!/usr/bin/env python3
"""
CCG (Claude-Codex-Gemini) - Zero-dependency cross-platform multi-model orchestrator.
Calls Magpie Gateway (/v1/chat/completions) for debate, consult, and review modes.
"""

import argparse
import concurrent.futures
import json
import os
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        try:
            _stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

RETRYABLE_HTTP_CODES = {408, 429, 500, 502, 503, 504}


def load_config(args):
    cfg = {
        "baseUrl": "http://10.89.10.199:3425/v1",
        "apiKey": "",
        "planModel": "group/plan-review",
        "codeModel": "group/code-pro",
        "timeoutSec": 120,
    }
    cfg_path = Path.home() / ".ccg.json"
    if not cfg_path.exists():
        cfg_path = Path.home() / ".magpie-council.json"
    if cfg_path.exists():
        if os.name != "nt":
            try:
                mode = stat.S_IMODE(cfg_path.stat().st_mode)
                if mode & 0o077:
                    print(
                        f"[WARN] {cfg_path} has permissive mode {oct(mode)}; consider chmod 600.",
                        file=sys.stderr,
                    )
            except Exception:
                pass
        try:
            with cfg_path.open("r", encoding="utf-8") as f:
                data = json.load(f)
            for k in cfg:
                if k in data and data[k] not in (None, ""):
                    cfg[k] = data[k]
        except Exception as e:
            print(f"[WARN] Failed to parse {cfg_path}: {e}", file=sys.stderr)

    if os.environ.get("MAGPIE_BASE_URL"):
        cfg["baseUrl"] = os.environ["MAGPIE_BASE_URL"]
    if os.environ.get("MAGPIE_API_KEY"):
        cfg["apiKey"] = os.environ["MAGPIE_API_KEY"]
    if getattr(args, "base_url", None):
        cfg["baseUrl"] = args.base_url
    if getattr(args, "api_key", None):
        cfg["apiKey"] = args.api_key

    if not cfg["apiKey"]:
        raise RuntimeError(
            "Missing Magpie API key. Set MAGPIE_API_KEY or create ~/.ccg.json."
        )
    cfg["baseUrl"] = cfg["baseUrl"].rstrip("/")
    return cfg


def normalize_paths(raw_paths):
    expanded = []
    for item in raw_paths or []:
        if not item:
            continue
        p = Path(item)
        if not p.exists() and "," in item:
            for part in item.split(","):
                part = part.strip()
                if part:
                    expanded.append(part)
        else:
            expanded.append(item)
    return expanded


def read_bounded_file(fp, limit):
    with fp.open("rb") as bf:
        sample = bf.read(min(4096, limit + 1))
        if b"\x00" in sample:
            return None, True
    with fp.open("r", encoding="utf-8", errors="replace") as tf:
        return tf.read(limit + 1), False


def read_context_files(paths, max_chars=24000):
    norm = normalize_paths(paths)
    if not norm:
        return ""
    chunks = []
    used = 0
    for p in norm:
        fp = Path(p)
        if not fp.is_file():
            chunks.append(f"### File: {p} (not found or not a file)")
            continue
        remaining = max_chars - used
        if remaining <= 0:
            chunks.append(f"### File: {p} (omitted due to context budget)")
            continue
        try:
            text, is_bin = read_bounded_file(fp, remaining)
        except Exception as e:
            chunks.append(f"### File: {p} (read error: {e})")
            continue
        if is_bin:
            chunks.append(f"### File: {p} (binary file skipped)")
            continue
        if len(text) > remaining:
            text = text[:remaining] + "\n...[truncated]..."
        used += len(text)
        chunks.append(f"### File: {p}\n```\n{text}\n```")
    return "\n\n".join(chunks)


def get_git_diff(repo_path, max_chars=30000):
    r_unstaged = subprocess.run(
        ["git", "-C", repo_path, "diff"],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=10,
    )
    if r_unstaged.returncode != 0:
        raise RuntimeError(f"git diff failed in {repo_path}: {r_unstaged.stderr.strip()}")

    r_staged = subprocess.run(
        ["git", "-C", repo_path, "diff", "--cached"],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=10,
    )
    if r_staged.returncode != 0:
        raise RuntimeError(f"git diff --cached failed in {repo_path}: {r_staged.stderr.strip()}")

    r_untracked = subprocess.run(
        ["git", "-C", repo_path, "ls-files", "--others", "--exclude-standard"],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=10,
    )
    untracked_files = [
        line.strip() for line in r_untracked.stdout.splitlines() if line.strip()
    ] if r_untracked.returncode == 0 else []

    sections = []
    used = 0
    tracked_diff = "\n".join(x for x in [r_staged.stdout.strip(), r_unstaged.stdout.strip()] if x)
    if tracked_diff:
        if len(tracked_diff) > max_chars:
            tracked_diff = tracked_diff[:max_chars] + "\n...[diff truncated]..."
        sections.append(f"### Tracked Git Diff\n```diff\n{tracked_diff}\n```")
        used += len(tracked_diff)

    for rel in untracked_files:
        rem = max_chars - used
        if rem <= 0:
            sections.append(f"### Untracked New File: {rel} (omitted due to budget)")
            continue
        fp = Path(repo_path) / rel
        if not fp.is_file():
            continue
        try:
            text, is_bin = read_bounded_file(fp, rem)
        except Exception as e:
            sections.append(f"### Untracked New File: {rel} (read error: {e})")
            continue
        if is_bin:
            sections.append(f"### Untracked New File: {rel} (binary skipped)")
            continue
        if len(text) > rem:
            text = text[:rem] + "\n...[truncated]..."
        used += len(text)
        sections.append(f"### Untracked New File: {rel}\n```\n{text}\n```")

    if not sections:
        r_status = subprocess.run(
            ["git", "-C", repo_path, "status", "--short"],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=10,
        )
        return f"(No tracked diff or untracked files; git status:\n{r_status.stdout.strip()})"
    return "\n\n".join(sections)


def extract_served_model(resp_headers, body, requested_model):
    served = body.get("model") or requested_model
    upstream = None
    for hk in ("x-magpie-model", "x-upstream-model", "x-magpie-provider", "openai-model"):
        val = resp_headers.get(hk)
        if val and val != served:
            upstream = val
            break
    return f"{served} [{upstream}]" if upstream else served


def call_model(cfg, model, system_prompt, user_prompt, max_tokens=8192, max_retries=2):
    url = f"{cfg['baseUrl']}/chat/completions"
    payload = json.dumps({
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "max_tokens": max_tokens,
    }).encode("utf-8")

    last_err = ""
    for attempt in range(max_retries + 1):
        req = urllib.request.Request(
            url,
            data=payload,
            headers={
                "Authorization": f"Bearer {cfg['apiKey']}",
                "Content-Type": "application/json; charset=utf-8",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=int(cfg["timeoutSec"])) as resp:
                raw_bytes = resp.read()
                body = json.loads(raw_bytes.decode("utf-8", errors="replace"))
                hdrs = {k.lower(): v for k, v in resp.headers.items()}
            choice = (body.get("choices") or [{}])[0]
            msg = choice.get("message") or {}
            content = (msg.get("content") or msg.get("reasoning_content") or "").strip()
            if choice.get("finish_reason") == "length":
                content += "\n\n[WARN: Output truncated due to max_tokens=8192 limit]"
            served = extract_served_model(hdrs, body, model)
            return {"ok": True, "model": served, "text": content}
        except urllib.error.HTTPError as e:
            err_body = e.read().decode("utf-8", errors="replace")[:300]
            last_err = f"HTTP {e.code}: {err_body}"
            if e.code in RETRYABLE_HTTP_CODES and attempt < max_retries:
                time.sleep(1.5 * (attempt + 1))
                continue
            return {"ok": False, "model": model, "text": last_err}
        except Exception as e:
            last_err = f"Error: {e}"
            if attempt < max_retries:
                time.sleep(1.5 * (attempt + 1))
                continue
            return {"ok": False, "model": model, "text": last_err}
    return {"ok": False, "model": model, "text": last_err}


def run_debate(cfg, prompt, context, rounds):
    arch_sys = (
        "You are the Adversarial Architect (Pre-Mortem Reviewer) in the CCG council. "
        "Assume the naive solution will fail in production: uncover hidden assumptions, concurrency/state traps, "
        "security boundaries, and edge cases, then propose a resilient architecture & verification plan. Respond in Chinese."
    )
    eng_sys = (
        "You are the Pragmatic Staff Engineer in the CCG council. "
        "Optimize for simplicity, minimal code churn, zero unnecessary abstractions, and concrete step-by-step execution "
        "with exact file boundaries and failure handling. Respond in Chinese."
    )
    user_msg = f"## Task\n{prompt}"
    if context:
        user_msg += f"\n\n## Context\n{context}"

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        f_arch = pool.submit(call_model, cfg, cfg["planModel"], arch_sys, user_msg)
        f_eng = pool.submit(call_model, cfg, cfg["codeModel"], eng_sys, user_msg)
        arch_r1 = f_arch.result()
        eng_r1 = f_eng.result()

    print("=== [Round 1] Architect (Pre-Mortem & Architecture) ===")
    print(f"(model: {arch_r1['model']})\n{arch_r1['text']}\n")
    print("=== [Round 1] Engineer (Pragmatic Minimal Implementation) ===")
    print(f"(model: {eng_r1['model']})\n{eng_r1['text']}\n")

    if not arch_r1["ok"] and not eng_r1["ok"]:
        return False

    if not (arch_r1["ok"] and eng_r1["ok"]):
        failed_side = "Architect" if not arch_r1["ok"] else "Engineer"
        print(
            f"[WARN / DEGRADED] {failed_side} failed after retries; Round 2 cross-critique skipped (single-model degraded mode)!\n"
        )
        return True

    if rounds >= 2:
        critique_sys = (
            "You are reviewing a peer model's engineering proposal. Point out concrete flaws, "
            "missing edge cases, unnecessary complexity, or security risks, then state the optimal merged steps. "
            "Be concise and respond in Chinese."
        )
        arch_r2_prompt = (
            f"Original Task:\n{prompt}\n\nYour Proposal:\n{arch_r1['text']}\n\n"
            f"Peer Engineer Proposal:\n{eng_r1['text']}\n\nCritique the peer proposal and merge into the best final plan."
        )
        eng_r2_prompt = (
            f"Original Task:\n{prompt}\n\nYour Proposal:\n{eng_r1['text']}\n\n"
            f"Peer Architect Proposal:\n{arch_r1['text']}\n\nCritique the peer proposal and flag any over-engineering or feasibility issues."
        )
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            f_a2 = pool.submit(call_model, cfg, cfg["planModel"], critique_sys, arch_r2_prompt)
            f_e2 = pool.submit(call_model, cfg, cfg["codeModel"], critique_sys, eng_r2_prompt)
            arch_r2 = f_a2.result()
            eng_r2 = f_e2.result()

        print("=== [Round 2] Architect Cross-Critique & Merged Plan ===")
        print(f"(model: {arch_r2['model']})\n{arch_r2['text']}\n")
        print("=== [Round 2] Engineer Cross-Critique ===")
        print(f"(model: {eng_r2['model']})\n{eng_r2['text']}\n")
    return True


def run_review(cfg, prompt, context, repo_path):
    diff_text = get_git_diff(repo_path) if repo_path else ""
    rev_sys = (
        "You are a strict Senior Code Reviewer. Audit the changes (both tracked diffs and newly created files) "
        "for bugs, security issues, missing edge cases, encoding/concurrency traps, and regressions. "
        "Categorize every finding strictly as [Blocker], [Concern], or [Nit] with exact file/line references. "
        "If clean, state LGTM. Respond in Chinese."
    )
    parts = []
    if prompt:
        parts.append(f"## Review Goal\n{prompt}")
    if diff_text:
        parts.append(f"## Repository Changes\n{diff_text}")
    if context:
        parts.append(f"## Files Context\n{context}")
    if not parts:
        raise RuntimeError("Review requires --repo, --context-file, or --prompt.")

    res = call_model(cfg, cfg["planModel"], rev_sys, "\n\n".join(parts))
    print("=== Senior Diff Review ===")
    print(f"(model: {res['model']})\n{res['text']}\n")
    return res["ok"]


def run_consult(cfg, prompt, context):
    con_sys = (
        "You are a Senior Technical Advisor. Give a direct, grounded, pragmatic recommendation "
        "and point out pitfalls to avoid. Respond in Chinese."
    )
    user_msg = prompt + (f"\n\n## Context\n{context}" if context else "")
    res = call_model(cfg, cfg["planModel"], con_sys, user_msg)
    print("=== Technical Advisor ===")
    print(f"(model: {res['model']})\n{res['text']}\n")
    return res["ok"]


def main():
    parser = argparse.ArgumentParser(description="CCG (Claude-Codex-Gemini) multi-model orchestrator")
    parser.add_argument("mode", choices=["debate", "review", "consult"])
    parser.add_argument("--prompt", "-p", default="", help="Task description or question")
    parser.add_argument("--context-file", "-f", nargs="*", default=[], help="Optional context files")
    parser.add_argument("--repo", "-r", default="", help="Git repository path for review mode")
    parser.add_argument("--rounds", type=int, default=2, choices=[1, 2], help="Debate rounds (1 or 2)")
    parser.add_argument("--base-url", default="", help="Override Magpie base URL")
    parser.add_argument("--api-key", default="", help="Override Magpie API key (prefer ~/.ccg.json)")
    args = parser.parse_args()

    try:
        cfg = load_config(args)
        context = read_context_files(args.context_file)

        if args.mode == "debate":
            if not args.prompt:
                raise RuntimeError("--prompt is required for debate mode.")
            ok = run_debate(cfg, args.prompt, context, args.rounds)
        elif args.mode == "review":
            ok = run_review(cfg, args.prompt, context, args.repo)
        else:
            if not args.prompt:
                raise RuntimeError("--prompt is required for consult mode.")
            ok = run_consult(cfg, args.prompt, context)

        if not ok:
            sys.exit(1)
    except Exception as e:
        print(f"[ERROR] {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
