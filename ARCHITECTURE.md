# Architecture & design notes

This is the "why" behind `git-undo-redo`. The [README](README.md) covers usage;
the script header in [`git-undo-redo`](git-undo-redo) summarizes the model. This
file records the design decisions and the alternatives we rejected, so future
work builds on them instead of re-deriving (or accidentally reverting) them.

## What it is

Operation-level undo/redo for git. `git undo` reverses your last *HEAD-moving
operation* (commit, merge, rebase, reset, branch-switch checkout), and `git
redo` re-applies it. It's modeled on Jujutsu's operation log: a private,
append-only **oplog** kept in an orthogonal space inside `.git`, independent of
git's reflog.

There are two undo axes (separation of concerns): **global** (`-g`, the default)
walks the shared operation log of everything HEAD did; **local** (`-l`) walks the
current branch's own edits via a per-branch oplog, moving only that branch. The
default for a bare `git undo`/`git redo` is `git config undoredo.default`
(global|local).

## The model

- **Oplog = a flat, append-only list of operations.** Each entry is
  `<sha>\t<kind>\t<branch>` (kind ∈ commit/merge/rebase/reset/checkout/cherry-pick/
  revert/am/pull/clone/prime/seed/other; branch = the ref HEAD was on at that
  state, empty if unknown/detached). A cursor marks where HEAD currently sits.
  Undo/redo are pure cursor moves; the entry's `kind` and `branch` decide how HEAD
  is restored.
- **Seeded once from the reflog, then self-owned.** On first use the oplog is
  stitched from git's reflog (the record of operations), with the tool's own
  labeled hops stripped and consecutive dupes collapsed. The branch per historical
  entry is recovered by reading the reflog's `checkout: moving from A to B`
  messages while walking newest→oldest. After that the reflog is **never read for
  navigation** - new operations are appended incrementally (sync records the live
  branch).
- **Restore is branch-aware and never detaches.** Each state carries the branch it
  was on, so restore switches HEAD to *that* branch (if needed) and resets it to the
  state's recorded sha. *Every* entry - branch-switch checkouts included - restores
  to its own sha, so the cursor always matches HEAD and a later sync sees no phantom
  change. If the branch was **deleted**, it is recreated at the recorded commit. A branch
  HEAD is never detached. (Entries with no recorded branch - legacy/cold/detached -
  use a heuristic that still never detaches.) The tool's own HEAD moves are
  labeled - reset via `GIT_REFLOG_ACTION`, branch switch via `symbolic-ref -m` - so
  the seed strips them and never re-ingests them.
- **Append-only with prime anchors.** The oplog is never truncated. When you act
  after undoing back to a point `B`, a prime marker `B′` (a logical copy of `B`'s
  state) is appended, then your new op `D`:

  ```
  oplog: [A, B, C, B′, D]
  undo from D → B′ (where you made D) → C (preserved) → B → A
  ```

  The prime records `D`'s true predecessor at the right place in the flat list,
  so undo lands correctly *and* nothing you undid past is lost.
- **GC-proof & reflog-independent.** Every state ever seen gets a keep-ref
  (`refs/git-undo-redo/keep/<sha>`), so git's garbage collector can never reclaim it
  - undo/redo work even after the reflog fully expires. (Verified: works with the
  reflog nuked and `gc --prune=now`.)
- **Per-branch "local" oplogs.** Alongside the global oplog, each branch has its
  own append-only edit log (same `<sha>\t<kind>` + cursor + prime model), seeded
  from that branch's reflog (which *is* its edit history) with our hops stripped.
  `git undo -l` walks it and resets only the current branch - so you can switch to
  any branch and undo its last edit without being pulled elsewhere. The global and
  local logs are independent; each absorbs the other's effects via its own sync
  (a local move is just another HEAD move the global sync later records, and vice
  versa). The cold seed reconstructs prime anchors it can't see directly - but a
  prime can *only* be born from one of our own hops (an undo-then-reapply done
  before the log existed), and those carry a `git-undo:`/`git-redo:` reflog label
  that the seed strips. So reconstruction is driven by those labels: the edit
  recorded right after a stripped hop, if it attached to an earlier recorded state
  rather than its predecessor, gets that parent anchored before it. Unmarked
  history (ordinary commits, merges, fast-forwards, manual `git reset`) never
  yields a reconstructed prime. **Both** seeds do this - the global seed from
  HEAD's reflog, the local seed from the branch's - because either undo scope
  labels HEAD's reflog, so a local-first undo must still reconstruct correctly
  when the global log is later cold-seeded (and vice versa).
- **Unbounded retention.** The oplog accumulates forever (rebuilt only by
  `git oplog --reset`). This is safe - see Performance.

## Configuration

Three `git config` keys (read at runtime; per-invocation flags always override):

- `undoredo.default` = `global` | `local` (default `global`) - the scope of a bare
  `git undo` / `git redo` / `git oplog` / `git opstatus` (each also takes
  `-g`/`--global` and `-l`/`--local`).
- `undoredo.oplog` = `full` | `compact` (default `full`) - the default `git oplog`
  view (`-c`/`-f` override).
- `undoredo.color` = `auto` | `always` | `never` (default `auto`) - colored output.
  `auto` colors only when stdout is a TTY and `NO_COLOR` is unset.

## Color

ANSI color (`_ou_colors`) mirrors the landing page's terminal demo palette: undo
pink, redo purple, the `@` cursor green, op kinds amber, meters/branches/titles
grey, errors red. Color is gated by `undoredo.color` / `NO_COLOR` / a TTY check;
the `C_*` vars are empty when disabled, so piped or redirected output is
byte-identical plain text. Text fields are padded *before* being wrapped in color
so alignment is unaffected. Help screens (`-h`) are intentionally left plain.

## On-disk layout

```
.git/git-undo-redo/timeline          the global oplog, "<sha>\t<kind>\t<branch>", oldest first
.git/git-undo-redo/cursor            0-based index of the current global position
.git/git-undo-redo/local/<branch>/   a per-branch oplog (timeline "<sha>\t<kind>" + cursor)
refs/git-undo-redo/keep/<sha>        one ref per state (GC protection); packed by git gc
```

(`<branch>` is the branch name with `/` percent-encoded so it's one path component.)

Nothing leaks into `refs/heads`, tags, or HEAD's reflog meaning. The only reflog
footprint is the labeled `git-undo:` / `git-redo:` / `git-recover:` reset entries
that undo/redo inherently produce (and which we strip back out on seed).

## Operation flow

- **seed** (`_ou_seed`): stitch the oplog from `git reflog` (filtered), recovering
  each entry's branch from `checkout:` messages, cap at `OU_SEED_LIMIT` (cold-start
  bound only), keep-ref all states in one batched `update-ref --stdin`.
- **sync** (`_ou_sync`): before every command, reconcile HEAD vs the parked
  cursor. The reflog top's kind decides how: a forward move that's actual *commits*
  → stitch each (`rev-list --reverse --first-parent`) as its own op; a forward move
  that's a single non-commit op (a branch switch / ff-merge / rebase to a descendant)
  → one op of that kind, not mislabeled `commit`; a divergent move → one op. If the
  cursor was below the top, insert a prime first.
- **undo / redo** (`_ou_goto` / `_ou_walk`): each step restores one state on its
  recorded branch (switch to that branch if needed, reset it to the entry's sha -
  uniform for every kind, checkout included; recreate the branch if deleted; never
  detach). After a bounds check (refuse and change nothing if N exceeds the available
  count, reporting how many are available), `git undo N` / `git redo N` and the `-i`
  picker **walk** the cursor one entry at a time via `_ou_walk` - so global `undo 3`
  is exactly three `git undo`s, faithfully reapplying each intermediate operation
  (e.g. recreating a branch you undid past). The global log is an *operation* log, so
  walking is the only way "what you see is what you get." Bare `undo`/`redo` is N=1.
- **`--staged` (`-s`) is a thin post-step, not a navigation change.** Undo/redo navigate
  exactly as normal, then `_ou_stage_apply` runs `git restore --source=<above> --staged
  --worktree :/` to leave the **one commit directly above the landing** staged (index +
  worktree), without moving HEAD - so the cursor still equals HEAD, you just have a dirty
  tree (the "committed too early, let me edit and re-commit" flow). Always one commit,
  never a chain (even for `undo --staged 3`).
  - **One rule, every path: the staged commit is the `git take` rule.** `--staged` is
    *defined* as "navigate (global or local, as the command says), then stage the commit
    directly above the landing in **that branch's LOCAL edit log**" - identical to bare
    `git take`. So `git undo --staged`, `git undo -l --staged`, the `git redo` forms, and
    `git take` all share one staging semantic; only the navigation differs. There is no
    `kind == commit` test anymore (a branch reflog holds only that branch's own tip-moves,
    never a checkout, so *any* entry above is a takeable commit) - the only check is
    "is there an entry above there." Global `--staged` finds the landing's neighbor via
    `_ou_above_commit <landing-branch> <landing-sha>` (loading/seeding that branch's log),
    which is why undoing a *checkout* still stages when the branch you land on has a commit
    above. Local `--staged` reads the same position from its already-synced `LT_*`. Both
    pre-check before navigating, so a "no commit above" case fails atomically and changes
    nothing. (Retired `_ou_stage_check`: its kind gate was the lone inconsistency.)
- **`git take [N]`** (`_ou_take` / public `git-take`): the fifth command, and the only
  one that is *purely* a stage with **no navigation**. It syncs the current branch's
  local log, then `_ou_stage_apply`s the commit `N` entries above the cursor (default 1)
  onto the worktree - HEAD and the cursor never move. It's the after-the-fact `--staged`
  (run it when you undid and forgot `-s`) and, uniquely, `N` can reach several commits
  up in one shot (undo/redo `--staged` only ever take the one directly above). Always
  edit-based; refuses on a detached HEAD, a dirty tree, or when `N` exceeds what's above.
- **local undo / redo** (`_ou_undo_local` / `_ou_redo_local`): the `-l` path -
  sync the current branch's own oplog (`_ou_local_seed` / `_ou_local_sync`) and
  **jump** its cursor straight to the target index (`_ou_local_goto`, one reset),
  resetting only that branch (`_ou_local_restore`). A per-branch log has no checkout
  entries, so a jump is identical to walking - and the redo counter still shows the
  real N. Refuses when HEAD is detached (no branch to scope to).
- **oplog** (`_ou_oplog_print`): render a log with `@` at the cursor; `-g`/`-l`
  pick the global or current-branch log (default `undoredo.default`), `-c` hides
  primes, `-i` is an interactive picker (cursor move, no new op; local picks reset
  the branch and save the local cursor, global picks save the global oplog).
- **reset** (`_ou_reset`, `git oplog --reset`): delete the global timeline/cursor,
  all per-branch logs, and keep-refs. Next command re-seeds from the live reflog -
  i.e. it rebuilds, it doesn't permanently wipe (re-deriving is the model).
- Both seeds anchor their cursor on the *actual* HEAD/branch tip (not just the
  newest entry), so a prior tool hop that moved it back doesn't misplace it.

## Decision log

- **Operation-level, not commit-graph navigation.** Undo means "reverse what I
  did," so cold-start `git undo` after a `reset` brings the commits back directly
  - a commit-graph walker would just step further up the surviving line.
- **Seed from the reflog once, then never read it for navigation.** Re-reading
  the reflog makes the tool read its *own* resets back as if they were user edits,
  producing a zig-zag. A self-owned oplog avoids that.
- **Prime anchors over truncation or naive append.** This is the only way to be
  linear + correct + lossless at once (see Rejected alternatives).
- **Seed prime reconstruction is driven by our reflog labels, not topology.** A
  reconstructed prime can only come from one of our own stripped `git-undo:` /
  `git-redo:` hops - the sole way to return to an earlier state yet leave no
  surviving anchor (a manual `git reset` leaves an unstripped entry that anchors
  itself; an ordinary commit/merge/fast-forward abandons nothing). Inferring primes
  from topology alone ("first parent isn't the predecessor") invents phantom primes
  before every merge (a `Merge pull request` whose first parent is the base) and
  even mishandles `--amend`. So both seeds (global from HEAD's reflog, local from
  the branch's) flag the kept entry immediately after each stripped hop and
  reconstruct only for those. The global seed needs this as much as the local one:
  a tool undo lands a label in HEAD's reflog even when it was a local-first undo,
  so a later global cold-seed must reconstruct the prime or it strands a global
  undo on the abandoned commit. Don't revert to a topological guess, and keep the
  two seeds symmetric.
- **Global vs local as two independent oplogs, not one stitched view.** `-l`
  (per-branch edit undo) is a *separate* append-only log per branch, reusing the
  global cursor + prime machinery but keyed to the branch tip. We rejected
  deriving `-l` from the global oplog: undo derives cleanly, but *redo* needs to
  follow the live lineage past abandoned commits, which is fragile from a filtered
  view. A dedicated per-branch log makes redo correct and free. We also rejected
  *stitching* the two logs into one timeline (timestamp merges are coarser than
  the per-stream order, and it multiplies cursor state) - keeping them independent,
  each self-syncing, is simpler and more reliable.
- **Local live sync drops cross-scope navigation; global keeps every op.** A branch
  reflog records only that branch's own tip-moves - branch switches are HEAD-only -
  so a `git-undo:`/`git-redo:` label on top of it unambiguously marks a cross-scope
  tool hop (e.g. a global undo that moved this branch), not a new edit. `_ou_local_sync`
  treats such a hop as navigation: if it landed on a state already in the per-branch
  log, it just repositions the cursor (like the seed) instead of recording a
  redundant `undo`/`redo`-kind op - so the live local log matches a cold reseed and
  interleaving `-g`/`-l` on one branch doesn't bloat it. The global log is left as-is
  on purpose: it's the comprehensive HEAD operation log and *should* record every op,
  so we don't strip there. (Asymmetry by design - a per-branch edit log wants only
  edits; the global log wants everything.)
- **Record the branch per op; restore onto it; recreate it if deleted; never
  detach.** Each entry stores the branch HEAD was on (recovered from `checkout:`
  reflog messages at seed, captured live afterward). Restore uses it: switch to that
  branch (if needed) and reset it to the entry's sha - uniformly, checkout edges
  included, so the cursor and HEAD never disagree. A deleted branch is recreated at
  the recorded commit. This keeps the
  type-aware logic but feeds it real data instead of guessing the branch with
  `for-each-ref` - which is what detached HEAD (no branch at the state, common
  after merges) and reset the wrong branch (a switch swallowed into a gap). An
  earlier worry that a "stored ref" couldn't be reconstructed from a cold reflog is
  handled by parsing the `checkout:` messages; entries we still can't resolve keep
  an empty branch and use a heuristic that never detaches. The tool's own HEAD
  moves are labeled (reset via `GIT_REFLOG_ACTION`, switch via `symbolic-ref -m`)
  so the seed strips them.
- **Every restored state resets to its own sha - checkout edges included.** An
  earlier design kept the branch's *live* tip when restoring a checkout edge (a
  switch is "just" HEAD navigation). But then parking the cursor on a checkout entry
  left HEAD at the tip while the entry's recorded sha differed: the cursor and HEAD
  desynced, the next `sync` logged a phantom op, and stepping `git undo` across a
  checkout stranded HEAD on the wrong commit (cursor said one place, HEAD was at
  another). Resetting *every* entry to its own sha makes each oplog point a true
  self-contained snapshot, so undo, redo, and the `-i` jump all agree and the cursor
  always equals HEAD. The trade: navigating onto/through a checkout whose branch has
  since advanced resets that branch back to the recorded sha (the later commits stay
  gc-protected and are reachable by redo). Don't reintroduce keep-the-live-tip.
- **Global walks every point; local jumps.** `undo N` / `redo N` and the picker on
  the *global* log step the cursor one entry at a time (`_ou_walk`), because global is
  an operation log: the same destination commit can leave a *different repo* depending
  on the path (walking past a branch switch recreates/repoints that branch; a single
  jump skips it). Walking guarantees `undo N` == N manual undos - what you see is what
  you get - at the cost of N resets. The *local* log is a single branch with no
  checkout entries, so walking and jumping are provably identical; it jumps straight
  to the target (`_ou_local_goto`, one reset) for speed. Counters stay positional
  (after `undo 3`, redo shows 3) in both: the steps are real. We considered jumping
  globally too (and grouping `undo N` as one atomic redo) and rejected both - they
  make `undo N` diverge from manual stepping on cross-branch spans. Don't make global
  jump.
- **keep-refs for retention.** Navigation must not depend on reflog expiry, so
  every state is pinned by a ref. This also makes retention effectively infinite.
  *Dedup the shas before the batch:* `_ou_keep_all` writes them in one
  `git update-ref --stdin`, which is a single atomic transaction and aborts the WHOLE
  batch on a repeated ref (`multiple updates for ref ... not allowed`). A sha recurs
  non-consecutively in the reflog after any reset / amend / rebase / branch-switch,
  so without the dedup the seed silently (`2>/dev/null`) protected *nothing* and the
  GC-proof guarantee was a lie on first use. Keep the dedup.
- **Restore must report failure, never fake success.** `_ou_restore` /
  `_ou_local_restore` return the reset's exit status, and every caller (`_ou_goto`,
  `_ou_walk`, `_ou_local_goto`, the undo/redo entry points, the picker) checks it:
  on a failed reset (e.g. a commit missing on a pre-fix repo) they abort with a clear
  error and DON'T advance the cursor. The old code ignored the exit, so a destroyed
  object produced a cheerful success line while HEAD never moved - the worst failure
  mode for a "nothing is lost" tool. Don't drop the exit checks.
- **Pull model, no hook.** `sync` captures the *net* HEAD change per command. So two
  between-run things are invisible to the global log: ops created and abandoned
  entirely, and - more subtly - an excursion that returns HEAD to the *same commit*
  (branch off, commit on a side branch, switch back), where the net comparison sees
  nothing. No data is lost (the side work is on its own ref + the reflog); it's just
  not in the oplog, so `git undo` won't replay it. The *cold seed* (which reads the
  whole reflog) DOES see such excursions - only live sync misses them. Detecting them
  live would mean reading the HEAD reflog for advancement on every command (perf, plus
  the same "which duplicate entry was the parked one" ambiguity as the keep-ref bug) -
  declined; the reflog stays the backstop.
  A `reference-transaction` hook was considered and **declined** for complexity.
- **Per-commit stitching across gaps, but classify by the reflog top.** A gap of
  actual commits is reconstructed commit by commit; a gap that's a single non-commit
  op - a branch switch / ff-merge / rebase to a descendant, or any divergent move -
  collapses to one op tagged with its real kind (from the reflog top, the same signal
  the seed uses, so live sync and seed agree). The forward branch must check the kind
  before stitching, else those moves get mislabeled `commit`. Either way undo lands on
  a valid keep-ref'd state - gaps never break, they only coarsen granularity. (A
  *mixed* between-run gap, e.g. commit-then-switch, still coarsens to the last op; we
  don't correlate each reflog entry to each commit - that ambiguity isn't worth it.)
- **`--reset` rebuilds, it doesn't wipe.** `git oplog --reset` drops the tracked
  state so the next command re-seeds from the reflog - re-deriving is the whole model,
  so a one-entry "anchor at HEAD" would amputate the stitching and lose history before
  the reset. (Was named `--clear`, which wrongly implied a permanent wipe.) Long-flag
  only, no short alias, so it can't be fat-fingered; all other flags have long+short.
- **`OU_SEED_LIMIT` is internal.** It bounds only the one-time cold-start seed;
  it's not documented in the README/help, and places no cap on accumulation.

## Rejected alternatives

- **Naive reflog-walk for navigation** → zig-zag: the tool's own undo/redo resets
  get read back as user edits.
- **Naive append `[A,B,C,D]`** (no prime) → undoing `D` lands on `C`, but `D`'s
  parent is `B`. Wrong state / wrong lineage.
- **Editor-style truncation `[A,B,D]`** → correct undo, but `C` is erased from the
  linear undo path. We wanted nothing lost.
- **Full undo tree** → rejected as too complex; the prime model is the flat
  linearization of that branch point.
- **`reference-transaction` hook** → would give per-op capture with no gaps, but
  adds install complexity and coexistence concerns. Pull model + reflog backstop
  chosen instead.
- **Strip-our-hops-and-walk-the-reflog for navigation** → stripping removes *our*
  hops but not the *user's* own resets/checkouts, which are navigation-not-edits
  and would still zig-zag.
- **Guessing the branch at restore via `for-each-ref --points-at`** → detached HEAD
  when no branch sat at the state (the old `git checkout --detach` fallback, common
  after merges) and reset the wrong branch when a switch was swallowed into a gap.
  Replaced by recording the branch per op and recreating it when deleted. (Kept as
  the fallback only for entries with no recorded branch.)

## Performance (measured at ~250 ops)

- **git's own commands are unaffected** - `git status` was identical with and
  without our refs (they're not on git's hot path; keep-refs get packed by gc).
- **undo / redo / opstatus are ~constant** regardless of oplog size (their cost is
  fixed git-subprocess overhead, not oplog length).
- **`git oplog` is ~constant** after batching subject lookups into ~one `git log`
  per 256 entries (was O(n) subprocesses - 13s at 250 entries, now ~0.5s).
- **Disk is trivial** - ~tens of bytes per oplog entry; the only variable object
  cost is *abandoned* states pinned by keep-refs (bounded by what you discard).
- Other speedups: git-dir cached per run; keep-refs created via batched
  `update-ref --stdin`.

## Working on this code

- It's one bash script ([`git-undo-redo`](git-undo-redo)), a **multi-call binary**:
  it dispatches on `basename "$0"`. Install symlinks/copies it to `git-undo`,
  `git-redo`, `git-oplog`, `git-opstatus`, `git-take`. The umbrella `git-undo-redo
  <cmd>` form is for development.
- **Test** by copying the script to those five names on `PATH`, then driving it in
  throwaway repos (`git init` in `mktemp -d`). Interactive paths (`-i`) need a TTY;
  verify their logic by exercising the helpers directly when no pty is available.
- **Keep the surfaces in sync** when changing the command/flag surface: the script
  help (`_ou_help_*`, `_ou_usage`), the README command table, and `index.html`.
- **Don't reintroduce rejected designs** (above) - especially: don't make `sync`
  record only the net HEAD (breaks per-commit undo), don't read the reflog for
  navigation, and don't let `_ou_restore` detach a branch HEAD (restore onto the
  recorded branch, recreating it if deleted). If you add a code path that moves
  HEAD or a branch, label its reflog entry (`GIT_REFLOG_ACTION` for resets,
  `symbolic-ref -m "git-undo: …"` for switches) so the seed strips it.
- Runs anywhere bash + git exist: macOS, Linux, Windows Git-Bash/WSL (and via
  Git-for-Windows' bundled bash, `git undo` works from PowerShell/CMD too).
```
