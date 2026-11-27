---
name: ccg
description: >-
  CCG (Claude + Codex + Gemini) universal 4-phase multi-model workflow
  (Align -> Multi-Model Debate & Plan Gate -> Incremental Coding -> Senior Diff Review)
  backed by Magpie Gateway. Activate whenever the user mentions "ccg" / "/ccg", wants
  multiple models to discuss/design a solution, wants a clear plan before editing code,
  or asks for a senior code review on changes.
---

# CCG (Claude · Codex · Gemini): Universal Multi-Model Workflow

This skill turns **any** coding or chat agent into a disciplined multi-model team (`ccg`) by orchestrating your Magpie Gateway groups (`group/plan-review` and `group/code-pro`) without extra CLI dependencies.

## 0. Fast-Path Threshold (简单任务免互博规则)

To avoid wasting quota and latency on trivial edits:
- **Skip Phase 2 (`debate`)** ONLY when the task is a single-file tweak (≤ 20 lines), a plain config/typo edit, a pure factual question, or when the user explicitly says "直接改" (unless the user explicitly invoked `ccg` / `/ccg`).
- **Run the Full 4-Phase Workflow** whenever the user invokes `ccg` / `/ccg`, or when designing a new feature, refactoring across files, debugging an unclear root cause, or touching security/networking/data schemas.

## 1. Strict 4-Phase Protocol

### Phase 1: Align & Clarify (先对齐，再讨论)
1. Read the relevant files/environment first; never guess paths, schemas, or existing behavior.
2. If the user's goal, constraints, or acceptance criteria have any ambiguity, ask concise, plain-language questions in Chinese before moving to Phase 2.

### Phase 2: Multi-Model Debate & Plan Gate (CCG 多模型互博定方案)
Run the CCG script in **`debate`** mode so two adversarial engineering perspectives analyze the task and cross-critique each other:
- **Architect (`group/plan-review` — Claude/Gemini perspective)**: Runs a Pre-Mortem (assumes the change will fail in production and hunts for architectural flaws, edge cases, security risks, and state bugs).
- **Engineer (`group/code-pro` — Codex/GPT perspective)**: Designs the simplest, minimal-diff, concrete step-by-step implementation and pushes back against over-engineering.

**Windows (PowerShell):**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>/scripts/ccg.ps1" `
  -Mode debate -Prompt "<USER_TASK_AND_CONSTRAINTS>" [-ContextFile "<FILE_1>","<FILE_2>"]
```
*(Both `"a.py","b.py"` array syntax and `"a.py,b.py"` comma-separated strings are supported.)*

**macOS / Linux (Python 3):**
```bash
python3 "<SKILL_DIR>/scripts/ccg.py" debate \
  --prompt "<USER_TASK_AND_CONSTRAINTS>" [--context-file "<FILE_1>" "<FILE_2>"]
```

After reading the debate output:
1. If `[WARN / DEGRADED]` appears (one side failed all retries), note that only one model responded.
2. Synthesize **one** clear, jargon-free Step-by-Step implementation plan in Chinese (files to touch, key logic, risks mitigated, and verification commands).
3. **HARD STOP**: Present the plan and ask the user to confirm (e.g., `"确认按此方案开始修改吗？"`) before editing any files.

### Phase 3: Incremental Coding (常规主力编码)
Once the user approves:
1. Implement changes in small, verified steps (avoid oversized single tool-call payloads).
2. Run relevant tests, syntax checks, or smoke checks immediately after edits.
3. If you hit a tricky bug or design fork mid-way, run `consult` mode for a quick second opinion:
   - Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>/scripts/ccg.ps1" -Mode consult -Prompt "<SPECIFIC_QUESTION>"`
   - macOS/Linux: `python3 "<SKILL_DIR>/scripts/ccg.py" consult --prompt "<SPECIFIC_QUESTION>"`

### Phase 4: Senior Diff Review (CCG 高级模型最终审核)
Before declaring completion on non-trivial code changes:
1. Run `review` mode to send `git diff` **plus newly created untracked files** (or explicit `-ContextFile` / `--context-file`) to `group/plan-review`:
   - Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>/scripts/ccg.ps1" -Mode review [-RepoPath "<REPO_DIR>"] [-ContextFile "<FILE_1>","<FILE_2>"]`
   - macOS/Linux: `python3 "<SKILL_DIR>/scripts/ccg.py" review [--repo "<REPO_DIR>"] [--context-file "<FILE_1>" "<FILE_2>"]`
2. Triage findings:
   - **`[Blocker]`**: Must fix and re-verify before reporting done.
   - **`[Concern]`**: Fix or explicitly highlight to the user with rationale.
   - **`[Nit]`**: Optional polish.

## 2. Configuration

Scripts read endpoint & key in this precedence order (no secrets are stored in this skill):
1. Environment variables (`MAGPIE_BASE_URL`, `MAGPIE_API_KEY`) or local config `~/.ccg.json` (also supports legacy `~/.magpie-council.json`; chmod `600` on macOS/Linux)
2. CLI overrides (`-BaseUrl` / `-ApiKey` or `--base-url` / `--api-key`)

`~/.ccg.json` (`%USERPROFILE%\.ccg.json` on Windows):
```json
{
  "baseUrl": "http://10.89.10.199:3425/v1",
  "apiKey": "YOUR_GATEWAY_KEY",
  "planModel": "group/plan-review",
  "codeModel": "group/code-pro",
  "timeoutSec": 120
}
```
