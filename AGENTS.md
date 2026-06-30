# AGENTS.md

Guidance for AI agents (and humans) working on this repo. Read
[ARCHITECTURE.md](ARCHITECTURE.md) before changing any behavior.

## What this is
`git-undo-redo` - undo/redo for git along its two axes, plus a derived global view. One
bash script ([`git-undo-redo`](git-undo-redo)) that's a **multi-call binary**: it
dispatches on `basename "$0"` and is installed (via [`install.sh`](install.sh)) symlinked
or copied to `git-undo`, `git-redo`, `git-take`, `git-goto` on `PATH`. The old `git-oplog`
/ `git-opstatus` commands were folded into `git undo`/`git redo` as the `--log`/`-l` and
`--status`/`-s` flags (with `-c`/`--compact` and `-f`/`--full` for log density); the
removed names still dispatch to a one-line "moved to" hint (`_ou_moved_hint`).

`git goto` (`git-goto`) is a thin `git switch` forwarder that parks/restores the dirty
worktree (the work waits at the commit you leave; it is NOT carried onto the new branch). It
snapshots the tracked dirty tree UP FRONT (`git stash create`, preserving the
staged/unstaged split, so the user's stash stack is untouched), cleans, then `git switch
"$@"`. Only on a **successful** switch does it record the park (`_ou_wip_park base snap` -
the snapshot is passed in, not re-captured) against the commit left, and restore whatever
was parked against the destination (`_ou_wip_apply`: `git stash apply --index`, degrading
to a flat apply that stages per `undoredo.take` on conflict). On a **failed** switch it
silently `_ou_wip_apply`s the exact up-front snapshot back onto the unchanged branch and
records NO park - so a refused switch can never empty the worktree, leaves no `wip` trace,
and prints no stash message. A **bare** `git goto` (no target) forwards straight to `git
switch` and never parks (no auto-stash when nothing moves). A wip bucket is keyed by
BRANCH + COMMIT, not commit alone: the id is `<commit>@<branch>`, built fork-free via
`printf -v` by `_ou_wip_setid` (from known parts) and `_ou_wip_setcurid` (reads HEAD FRESH
in ONE call - `git rev-parse HEAD --abbrev-ref HEAD` - never the cached `_OU_BRANCH`, since
goto flips the branch mid-command). The `_ou_wip_before` path instead uses the already-cached
`_OU_HEAD`/`_OU_BRANCH` (HEAD hasn't moved yet) for a zero-fork id. This branch-qualifying is
what stops `git goto -c newbranch` (a new branch on the SAME commit) from pulling back the
work you left on the old branch - that work stays under `(old-branch, commit)`. Snapshots are ordered per id in
`.git/git-undo-redo/wip/<commit>@<branch>/timeline` and gc-protected under
`refs/git-undo-redo/wipkeep/<sha>` - its own namespace from `keep/`, but `git undo --reset`
clears BOTH (a full state reset; see `_ou_reset`). Untracked files are left in the worktree
(they travel with a switch). `git goto -h` prints the tool's own help PLUS `git switch -h`'s
option list relabeled `switch`->`goto` via `sed`, so the wrapper's reference stays current.
If the up-front snapshot can't be created on a dirty tree, goto refuses before cleaning,
so work is never lost.

The same park/restore engine backs **undo/redo and the picker** (`_ou_wip_before` before
a move, `_ou_wip_after` after): they no longer refuse on a dirty tree - the work is parked
against the commit you leave and restored against wherever HEAD lands (destination on
success, origin on a failed/cancelled move, so nothing strands). `_ou_require_clean` is no
longer the gate for undo/redo - parking is - and survives only as `git take`'s check and
the implicit "can't park -> refuse" fallback. Park happens AFTER the boundary/too-many
checks (never on a no-op), and once per command (a multi-step `-g` walk parks/restores
once, not per step).

**Clean-tree versions.** Leaving a commit (via `goto`, undo/redo) with a CLEAN tree records
a special `clean` sentinel version - but ONLY if that commit already has a timeline. This is
what makes "left it clean -> return clean" hold: without it, restoring the latest parked
version would resurrect a stale dirty state you'd discarded. A clean tree with NO existing
timeline records nothing (never start a timeline from clean). The sentinel is the literal
string `clean` in the timeline (not a sha): `_ou_wip_apply` treats it as a no-op (the caller
already reset to HEAD), `_ou_wip_restore` lands clean with no message, `_ou_wip_cursor_loaded`
calls it loaded iff the tree is currently clean, rows show "clean working tree", and it has no
`wipkeep` ref (nothing to gc-protect). Dedup is literal for `clean`, by-tree otherwise.

`git undo -w`/`git redo -w` (`--worktree`, a top-level undo/redo mode - NOT a scope like
`-e`/`-n`/`-g`, and shown in the main help) walk the parked-worktree timeline for the
current commit instead of moving HEAD (`_ou_wip_nav`), persisting the
position in `.git/git-undo-redo/wip/<base>/cursor`. It first asks whether the cursor's
version is actually in the worktree (`_ou_wip_cursor_loaded`: a fresh `git stash create`
tree vs the cursor snapshot's tree). Two paths:
- **Loaded** (got here via `goto` or a prior `--worktree`): step relative to the cursor.
  Boundary/too-many checks mirror the HEAD scopes (refuse-on-overshoot, "Only N
  earlier/newer parked version(s)"; never clamp).
- **Not loaded** (e.g. a plain `git switch` landed here and never restored the parked
  work, or there are live edits): don't step past what you can't see - `_ou_wip_stamp_live`
  saves any live edits as a new tail (nothing lost), then `git undo -w` LOADS the latest
  parked version (deeper counts step back from it); `git redo -w` just loads the latest.
  This mirrors `git goto`'s park-what-you-leave / restore-what-you-land-on behavior for the
  case where the auto-park hook never ran.

All snapshot applies go through `_ou_wip_apply`: `git stash apply --index` to preserve the
staged/unstaged split, degrading on an index conflict to a flat apply that then stages per
`undoredo.take` (default unstaged) - the one case where the split can't be reproduced lands
the way `git take` would. The `--worktree` mode also drives the views: `git undo --log -w`
(`_ou_wip_show`), `--status -w` (`_ou_wip_status`), and `--interactive -w` (`_ou_wip_picker`,
which loads a chosen version, stamping live edits first). Rows show `vN <short> <diffstat>`,
`@` marks the version currently in the worktree (none after a plain switch).

Auto-prune (`_ou_wip_prune`, fired after each successful park) is conservative: a wip
bucket is removed only when its COMMIT (the part before `@` in the id) is unreachable from
branches/tags/`keep` refs AND absent from `git reflog` (`_ou_wip_base_alive`) - i.e. git
itself could no longer restore it. Anything still recoverable by reflog is kept.

Two orthogonal logs, both seeded from git's **HEAD reflog** then **persisted to disk
with a per-entry reflog event-time** (so they outlive the reflog): the per-branch **edit
log** (`-e`/`--edit`) keeps the edits made on a branch; the **navigation log**
(`-n`/`--navigation`) keeps branch switches / checkouts. `git undo N` / `git redo N` jump
N steps in these scopes (refusing, and reporting the count, if too many) - **atomic in
both domains**: an edit is one `reset` of the current branch (`_ou_local_goto`), a
navigation is one `checkout` (`_ou_nav_goto`). No walking in the per-axis case - the old
single *mixed* global log needed it; splitting the axes removed the need and the
checkout/edit ambiguity.

The **global** view (`-g`/`--global`) is a *third, derived* one (the **edit** scope is
the default for a bare command - see `_ou_cfg_scope`): `_ou_global_derive`
merges the two durable logs by their stored `ts` into one chronological throughline
(dropping the nav origin + edit floors, keeping primes) and `_ou_global_walk` walks it,
dispatching each step to an edit reset or a nav checkout - so `undo -g N` WALKS (the one
exception to "no walking"). Only `global/cursor` is stored; the throughline is rebuilt
each call, so `git undo --log -g` and `git undo --status -g` agree. It reads the durable oplogs (not the
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
- **The global cursor is only valid inside a LIVE walk - guard it with the throughline
  length, not just sha/ref.** A position (sha, ref) repeats in the throughline (a branch
  revisited at the same commit), so "stored index still matches HEAD's sha/ref" is NOT
  enough to trust it: after a per-axis op moves HEAD on another axis (a `git undo -n` then
  a manual switch, a commit, etc.) the stored index can match HEAD at an *older duplicate*
  occurrence, making the global log disagree with the nav/edit logs and offer phantom redo.
  `_ou_global_goto` stores the index AND `${#GL_SHA[@]}`; the derive trusts it only when the
  length is unchanged (a pure global walk appends nothing), else re-anchors to where HEAD
  actually is (newest matching occurrence, kind-aware). Don't drop the length guard.
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
  help (`_ou_help_*`, `_ou_usage`), the README command table, and `index.html`. Undo/redo
  help is **two-tier**: `git undo -h` shows `_ou_help_undo` (the everyday flags - N and the
  views `-s`/`-l`/`-i`/`-c`/`-f`); `-h -a` / `-a` / `--advanced` shows `_ou_help_undo_full`
  (the complete set, which ADDS the scopes `-e`/`-n`/`-g` and `--reset`). A pre-scan in
  `git-undo`/`git-redo` routes between them. Keep BOTH tiers updated; the scopes and
  `--reset` stay in the full tier only (that's the whole point - scopes are the perceived
  complexity), while the views appear in both.
- **Exit-code convention: `undo`/`redo`/`take` exit 0 iff the requested end-state is
  reached, 1 when it could not be.** A no-op that means "couldn't do what you asked" -
  at the oldest/newest boundary, asked for more steps than exist, or nothing left to take
  (all the red 🛑 paths) - returns 1, like the "too many" case; don't let one of these
  drift back to `return 0`. The exceptions that stay 0: an explicit zero-count request
  (`undo 0`), a read-only view (`git undo --log`/`--status` on empty history), and a `take`
  whose tree is already present (idempotent success - reported as "Already taken", not
  "Took"). `take` detects that no-op by diffing full `git status` (untracked included)
  across the apply, since an add-only commit lands untracked and slips past the
  tracked-only clean check.
- All flags have long + short forms **except `--reset`** (long-only by design, so
  it can't be fat-fingered). `git undo --reset` (and `git redo --reset`) rebuilds the
  oplog from the reflog (it does NOT wipe - re-deriving is the model; never anchor a
  single entry instead). `--status`/`--log`/`--interactive` are mutually exclusive views.
  No within-command duplicate short letters. Defaults:
  `undoredo.scope` (edit|global|navigation; default edit), `undoredo.log` (full|compact),
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
- **The global derive runs on every `git undo`/`git redo` (the action and its `--status`/`--log`/`-i` views), so its hot path is
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
