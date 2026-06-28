# AGENTS.md

Guidance for AI agents (and humans) working on this repo. Read
[ARCHITECTURE.md](ARCHITECTURE.md) before changing any behavior.

## What this is
`git-undo-redo` - undo/redo for git along its two axes, plus a derived global view. One
bash script ([`git-undo-redo`](git-undo-redo)) that's a **multi-call binary**: it
dispatches on `basename "$0"` and is installed (via [`install.sh`](install.sh)) symlinked
or copied to `git-undo`, `git-redo`, `git-oplog`, `git-opstatus`, `git-take` on `PATH`.

Two orthogonal logs, both seeded from git's **HEAD reflog** then **persisted to disk
with a per-entry reflog event-time** (so they outlive the reflog): the per-branch **edit
log** (`-e`/`--edit`) keeps the edits made on a branch; the **navigation log**
(`-n`/`--navigation`) keeps branch switches / checkouts. `git undo N` / `git redo N` jump
N steps in these scopes (refusing, and reporting the count, if too many) - **atomic in
both domains**: an edit is one `reset` of the current branch (`_ou_local_goto`), a
navigation is one `checkout` (`_ou_nav_goto`). No walking in the per-axis case - the old
single *mixed* global log needed it; splitting the axes removed the need and the
checkout/edit ambiguity.

The **global** view (`-g`/`--global`, shipped, and **the default scope** for a bare
command) is a *third, derived* one: `_ou_global_derive`
merges the two durable logs by their stored `ts` into one chronological throughline
(dropping the nav origin + edit floors, keeping primes) and `_ou_global_walk` walks it,
dispatching each step to an edit reset or a nav checkout - so `undo -g N` WALKS (the one
exception to "no walking"). Only `global/cursor` is stored; the throughline is rebuilt
each call, so `oplog -g` and `opstatus -g` agree. It reads the durable oplogs (not the
reflog), so it survives reflog expiry. Each per-axis sync **self-heals its cursor** to
where HEAD/the tip actually is, so the three views stay orthogonal and correct after a
global walk or a manual `git` move.

`git take` (`_ou_take`) copies a commit's full tree onto the worktree with **no**
navigation (HEAD/cursor never move): bare = the branch's **latest** edit (top of its
log), `git take N` = the commit N above current (`take 1` = closest). Lands **unstaged**
by default (`_ou_take_apply`, `git restore [--staged] --worktree`); `-u`/`-s` or
`undoredo.take` choose. Clean tree + non-detached HEAD. (The old `git undo --staged`/`-s`
post-step was **removed**; "keep the changes" is now `git undo` then `git take`.)

Every dispatcher first runs `"$@"` through `_ou_unbundle` (mapfile, `set -u`-guarded),
which splits a single-dash, all-letters token like `-en` into `-e -n` - so short flags
bundle. A count stays a separate arg (`-e3` is left intact and stays "unknown"; use
`-e 3`); long `--flags` and bare numbers pass through untouched.

## How to run / test
- No build step. To exercise it: copy the script to the five `git-*` names in a
  temp dir on `PATH`, then drive it in throwaway repos (`git init` in a
  `mktemp -d`). The umbrella `git-undo-redo <cmd>` form also works for dev.
- `bash -n git-undo-redo` to syntax-check.
- Interactive paths (`-i`) need a TTY; without a pty, verify their logic by
  invoking the internal helpers directly.

## Conventions / guardrails
- **Don't reintroduce rejected designs** (see ARCHITECTURE.md → Rejected alternatives).
  In particular: don't merge the two logs into one stored "global" log (the global view
  is *derived* each call by merging the two durable oplogs on their stored event time -
  never stored as a third log, never re-sourced from the reflog), don't make navigation
  *sample* the position (read new checkouts from the reflog against the `nav/seen` count
  watermark), don't seed an edit log from a branch's own reflog (use HEAD's, so it
  survives a delete+recreate), and don't let a per-axis sync trust a stored cursor that
  no longer matches HEAD (each must self-heal). Label any HEAD/branch move the tool makes
  with `GIT_REFLOG_ACTION` (resets AND checkouts) so the seed strips it; stamp any new
  timeline entry with its reflog event time so the global merge can order it.
- **Two orthogonal logs, both durable HEAD-reflog projections.** The navigation log
  (`.git/git-undo-redo/nav/`, entries `<sha>\t<kind>\t<ref>\t<ts>`) is the reflog's
  checkout moves; each edit log (`.git/git-undo-redo/local/<branch>/`, entries
  `<sha>\t<kind>\t<ts>`) is the reflog's edits made while that branch was active
  (attributed via the `checkout:` messages). `ts` is the reflog event time - the durable
  key the global merge orders by. They're independent and self-syncing - don't stitch
  them or make one depend on the other's cursor. Edit undo only ever resets the current
  branch and refuses on a detached HEAD; nav undo is one checkout (recreating a deleted
  branch, detaching only for a recorded detached position). Both cold seeds reconstruct a
  prime *only* for an entry recorded right after a stripped `git-undo:`/`git-redo:` hop -
  never from the topology of unmarked history (which invented phantom primes before
  merges); keep them symmetric. Nav sync re-reads new checkouts from the reflog (count
  watermark, so a net-zero round-trip is caught) and re-anchors its cursor to HEAD; edit
  sync samples its branch tip, stitches new commits via `rev-list`, and re-anchors to the
  tip (or the merge-base fork point when a new commit forked off a global-moved state).
- **Edit sync absorbs only OUR moves; a user's `git reset --hard <ancestor>` is RECORDED.**
  The self-heal reposition fires only when the branch reflog top is one of our hops
  (`git-undo`/`git-redo`/`git-recover`) or is gone (durable global walk); a user's reset
  leaves a `reset:` entry and is recorded as a new op, so `git undo` reverses it - the
  headline `reset --hard` rescue, which must work for a primed repo, not just a cold seed.
  Don't generalize the reposition to "any move onto a known state" (that swallowed the
  user's reset). Before recording, sync re-anchors to the branch's pre-move tip (2nd
  reflog entry) so a reset after a global walk doesn't inject a spurious prime.
- **Keep the surfaces in sync** when the command/flag surface changes: the script
  help (`_ou_help_*`, `_ou_usage`), the README command table, and `index.html`.
- All flags have long + short forms **except `--reset`** (long-only by design, so
  it can't be fat-fingered). `git oplog --reset` rebuilds the oplog from the reflog
  (it does NOT wipe - re-deriving is the model; never anchor a single entry instead).
  No within-command duplicate short letters. Defaults:
  `undoredo.default` (global|edit|navigation; default global), `undoredo.oplog` (full|compact),
  `undoredo.take` (unstaged|staged), and `undoredo.color` (auto|always|never); flags
  override.
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
  protects nothing. (2) `_ou_nav_restore`/`_ou_local_restore` return their exit and
  every caller checks it: a failed restore must error and NOT advance the cursor, never
  print a success line. Don't remove the dedup or the exit checks.
- **The global derive runs on every `oplog`/`opstatus`/`undo`/`redo`, so its hot path is
  fork-disciplined: on Windows MSYS every `$(...)`, pipe, and external command is an
  emulated `fork()` that dominates runtime (a process spawn costs far more than the work).
  Prefer builtins - parameter expansion over `basename`/`dirname`/`tr`/`cut`, `read -r var
  < file` (guarded by `[ -r file ]`, since a failed input redirect leaks past a trailing
  `2>/dev/null`) over `$(cat file)`, `mapfile`/`${#arr[@]}` over `| wc -l`, `read -r x <
  <(cmd)` over `cmd | head -1` - and the cached `_OU_SDIR`/`_OU_HEAD`/`_OU_BRANCH` (seeded
  by `_ou_require_repo` in one rev-parse) over re-calling `_ou_state_dir`/`_ou_head`/
  `_ou_branch`. Batch per-branch git (`for-each-ref` for tips) and precompute per-branch
  paths once (the `LDIR` map) instead of per loop. Don't reintroduce subshells here.
- License is MIT-0; keep the `SPDX-License-Identifier: MIT-0` headers.

## Files
- `git-undo-redo` - the tool.   `install.sh` - cross-platform installer.
- `README.md` - usage.   `index.html` - GitHub Pages landing page (light/dark).
- `ARCHITECTURE.md` - design + decision log.   `LICENSE` - MIT-0.
