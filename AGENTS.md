# AGENTS.md

Guidance for AI agents (and humans) working on this repo. Read
[ARCHITECTURE.md](ARCHITECTURE.md) before changing any behavior.

## What this is
`git-undo-redo` - operation-level undo/redo for git. One bash script
([`git-undo-redo`](git-undo-redo)) that's a **multi-call binary**: it dispatches
on `basename "$0"` and is installed (via [`install.sh`](install.sh)) symlinked or
copied to `git-undo`, `git-redo`, `git-oplog`, `git-opstatus`, `git-take` on `PATH`. Each
command takes `-g`/`--global` and `-l`/`--local`; `git undo N` / `git redo N` move N
steps (refusing, and reporting the available count, if N is too many). **Global walks**
one entry at a time (`_ou_walk`, incl. the `-i` picker) so `undo N` == N manual undos
and intermediate branch effects are reapplied; **local jumps** straight to the target
(`_ou_local_goto`) since a single branch has no checkout entries to walk through.
`--staged`/`-s` (undo or redo) navigates normally, then stages the one commit directly
above the landing (`git restore`, no HEAD move) for the "committed too early" flow;
refuses if there's no commit there. It's a post-step - don't fold it into navigation.
The "commit above" is read from the **landing branch's local edit log**
(`_ou_above_commit`), not the global timeline - so a global undo whose global neighbor
is a checkout can still stage when that branch has a commit above (it pre-checks, so a
miss fails atomically). `git take [N]` (`_ou_take`) is the standalone version: stage the
commit N entries above the current point (default 1) with **no** navigation at all -
the after-the-fact `--staged`, and the only way to reach several commits up at once.
Always edit-based (current branch's log); needs a clean tree and a non-detached HEAD.
Every dispatcher first runs `"$@"` through `_ou_unbundle` (mapfile, `set -u`-guarded),
which splits a single-dash, all-letters token like `-ls` into `-l -s` - so short flags
bundle. A count stays a separate arg (`-l3` is left intact and so stays "unknown"; use
`-l 3`); long `--flags` and bare numbers pass through untouched.

## How to run / test
- No build step. To exercise it: copy the script to the five `git-*` names in a
  temp dir on `PATH`, then drive it in throwaway repos (`git init` in a
  `mktemp -d`). The umbrella `git-undo-redo <cmd>` form also works for dev.
- `bash -n git-undo-redo` to syntax-check.
- Interactive paths (`-i`) need a TTY; without a pty, verify their logic by
  invoking the internal helpers directly.

## Conventions / guardrails
- **Don't reintroduce rejected designs** (see ARCHITECTURE.md → Rejected
  alternatives). In particular: don't let `_ou_sync` record only the net HEAD
  (breaks per-commit undo), don't read the reflog for *navigation*, and never let
  `_ou_restore` **detach** a branch HEAD (restore onto the op's recorded branch,
  recreating it if deleted). `_ou_restore` resets to the entry's **own sha for every
  kind, checkout edges included** - don't special-case checkout to keep the branch's
  live tip; that desyncs the cursor from HEAD and makes the next sync log a phantom
  op (and strands a multi-step undo across a checkout on the wrong commit). Label any
  HEAD/branch move the tool makes (`GIT_REFLOG_ACTION` for resets, `symbolic-ref -m
  "git-undo: …"` for switches) so the seed strips it back out.
- **Two oplogs, kept independent.** Global (`-g`, the shared HEAD log) and local
  (`-l`, per-branch edit logs under `.git/git-undo-redo/local/<branch>/`) are separate
  and self-syncing - don't stitch them or make one depend on the other's cursor.
  `-l` only ever resets the current branch; it refuses on a detached HEAD. Both
  cold seeds (global from HEAD's reflog, local from the branch's) reconstruct a
  prime *only* for an edit recorded right after a stripped `git-undo:`/`git-redo:`
  hop - never from the topology of unmarked history (commits, merges, fast-forwards,
  manual resets), which invented phantom primes before merges. Keep the two seeds
  symmetric (a local-first undo labels HEAD's reflog, so the global seed needs it
  too) and don't make reconstruction key off first-parent shape alone. Live, too:
  `_ou_local_sync` treats a tip move whose branch-reflog top is a `git-undo:`/`git-redo:`
  label as cross-scope navigation, not an edit - if it lands on a state already in
  the per-branch log it just repositions the cursor (safe because branch reflogs hold
  only that branch's own tip-moves), so the live local log stays as clean as a reseed.
  Do NOT apply that stripping to `_ou_sync` (global): the global log records every op
  by design - the asymmetry is intentional.
- **Keep the surfaces in sync** when the command/flag surface changes: the script
  help (`_ou_help_*`, `_ou_usage`), the README command table, and `index.html`.
- All flags have long + short forms **except `--reset`** (long-only by design, so
  it can't be fat-fingered). `git oplog --reset` rebuilds the oplog from the reflog
  (it does NOT wipe - re-deriving is the model; never anchor a single entry instead).
  No within-command duplicate short letters. Defaults:
  `undoredo.default` (global|local), `undoredo.oplog` (full|compact), and
  `undoredo.color` (auto|always|never); flags override.
- **Output color** is via the `C_*` vars set by `_ou_colors` (empty unless a TTY /
  `always`). Keep them empty-safe so piped output stays byte-identical to no-color;
  pad text fields *before* wrapping in color so alignment isn't thrown off by codes.
  Help screens (`-h`) are intentionally left plain.
- `OU_SEED_LIMIT` is an internal cold-start bound - keep it out of user-facing
  docs/help.
- Tracking lives only in `.git/git-undo-redo/` and `refs/git-undo-redo/keep/`; never
  pollute `refs/heads`, tags, or HEAD's reflog beyond labeled reset entries.
- **GC protection is the headline guarantee - two invariants keep it honest.** (1)
  `_ou_keep_all` MUST dedup the shas before `git update-ref --stdin`: it's one atomic
  transaction that aborts the whole batch on a repeated ref, and reflogs repeat a sha
  non-consecutively after any reset/amend/rebase/switch - so a missing dedup silently
  protects nothing. (2) `_ou_restore`/`_ou_local_restore` return the reset's exit and
  every caller checks it: a failed restore must error and NOT advance the cursor, never
  print a success line. Don't remove the dedup or the exit checks.
- License is MIT-0; keep the `SPDX-License-Identifier: MIT-0` headers.

## Files
- `git-undo-redo` - the tool.   `install.sh` - cross-platform installer.
- `README.md` - usage.   `index.html` - GitHub Pages landing page (light/dark).
- `ARCHITECTURE.md` - design + decision log.   `LICENSE` - MIT-0.
