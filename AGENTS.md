# AGENTS.md

## 1) Purpose & Scope
This document defines how **any agent or tool** (including Codex) must operate in this repository:
- **Reads & searches:** always allowed.
- **Writes/edits:** **propose first**, do not apply without explicit approval.
- **Executions:** always allowed for read-only tasks (e.g., searches); anything risky requires approval.

---

## 2) Change Policy (must follow)
Before modifying files, the agent must:

1. **Explain the plan** (what will change and why).
2. **Show a unified diff** of the proposed edits (exact patch).
3. **Wait for explicit approval** before applying any change.

Additional rules:
- Keep changes **minimal** (only what’s necessary). No mass reformatting.
- Include a **test/verification note** and a **rollback note** in the proposal.
- If >10 files or >500 LOC change, split into smaller patches unless approved.

---

## 3) Read/Search Policy
- Use **ripgrep (rg.exe) directly** for all repository searches.
- **Do NOT** shell through `powershell -Command` for searches.
- Output format must be: `path:line:match`
- Never modify files as part of a read/search operation.

### Canonical command (Windows)
```powershell
rg.exe -n --hidden --no-messages --glob '!.git' -- "<regex>" "C:\Mach4Hobby\Profiles\BLP\Scripts"
```

### Rules for searches
- Always include: `-n --hidden --no-messages --glob '!.git'`
- For a **single file**, pass that file path instead of the project root.
- For **multi-line** patterns: add `-U` and use a single-line regex with `(?s)`.
- If you need lookaheads/backrefs: add `-P` (PCRE2).
- Prefer **multiple `-e` flags** or a **pattern file** (`-f`) over giant `|` alternations.

### Examples
```powershell
# Repo-wide
rg.exe -n --hidden --no-messages --glob '!.git' -- "btnDustAuto|btnVacAuto|btnSoftLimits" "C:\Mach4Hobby\Profiles\BLP\Scripts"

# Single file (functions & timers)
rg.exe -n --hidden --no-messages --glob '!.git' -- "function\s+PLC_Init|wxTimer" "C:\Mach4Hobby\Profiles\BLP\Scripts\System\ScreenLoad.txt"

# Multiline function body
rg.exe -n -U --hidden --no-messages --glob '!.git' -- "(?s)function\s+Screen\w+.*?end\b" "C:\Mach4Hobby\Profiles\BLP\Scripts\System\ScreenLoad.txt"
```

---

## 4) Patch Proposal Format (what to submit for approval)
**Header (plain text):**
- **Intent:** one sentence describing the change.
- **Scope:** files touched; brief list.
- **Risk:** low/med/high; why.
- **Verification:** how you tested or will test.
- **Rollback:** how to revert if needed.

**Then the unified diff**, e.g.:
```diff
diff --git a/Dependencies/SystemLib.txt b/Dependencies/SystemLib.txt
@@
- luamc.mcSignalSetState(handle, (state and 1 or 0))
+ local on = (type(state)=="number" and state~=0) or (state==true)
+ luamc.mcSignalSetState(handle, on and 1 or 0)
```

Wait for explicit approval before applying.

---

## 5) Safety & Restrictions
- **No persistent writes** without approval (agents must propose a patch).
- **No network access** unless explicitly approved for the task.
- **No spawning external processes** that can alter files, unless approved.
- If a write is required by a tool flow, **stop and propose a patch** instead.

---

## 6) Windows & PowerShell Notes (if PS is unavoidable)
- Prefer **direct `rg.exe`**, not `powershell -Command`.
- If you must run a quoted path in PowerShell, use the **call operator** `&`:
  ```powershell
  & "C:\Program Files\ripgrep\rg.exe" -n --hidden --no-messages --glob '!.git' -- "<regex>" "<path>"
  ```
- To pass complex regex safely, prefer **multiple `-e`** or a **pattern file** rather than inline escaping.

---

## 7) Nice-to-have Conventions
- Use **small, reviewable patches**.
- Use **clear commit messages** if/when approved to apply:
  - `scope: one-line intent`
  - blank line
  - short rationale + test/verification steps

---

**TL;DR**  
Read/search freely with **rg.exe**.  
For edits: **plan → diff → wait for approval → apply**.
