# Architecture & design notes

This is the "why" behind `git-undo-redo`. The [README](README.md) covers usage;
the script header in [`git-undo-redo`](git-undo-redo) summarizes the model. This
file records the design decisions and the alternatives we rejected, so future
work builds on them instead of re-deriving (or accidentally reverting) them.

## What it is

Undo/redo for git along its two kinds of movable pointer - a branch tip and `HEAD`.
`git undo` steps back your last *edit* on the current branch (commit, reset, merge,
rebase, amend); `git undo -n` steps back your last *navigation* (branch switch /
checkout); `git undo -g` steps back your single most recent operation across *both*,
in chronological order. `git redo` re-applies. It's modeled on Jujutsu's operation
log: private, append-only logs in an orthogonal space inside `.git`.

The two axes are orthogonal and each **atomic in its own domain** - an edit is one
`reset` of one branch, a navigation is one `checkout` - so neither has to walk through
the other. They are **durable projections of one source**: git's HEAD reflog, filtered
two ways, then persisted to disk with a timestamp per entry so they outlive the reflog.
The **global** view (`-g`/`--global`) is a *third, derived* view: it merges the two
durable logs by those timestamps into one chronological throughline and walks it,
dispatching each step to its own axis - composed live at query time, never a third
stored log. **Global is the default scope** for a bare command; `git config
undoredo.default` (global|edit|navigation; default global) changes it.

## The model

- **Two durable logs, both projections of the HEAD reflog.** Every move HEAD makes is
  in its reflog, in order. We filter it two ways:
  - the **navigation log** keeps the `checkout: moving ...` entries (position changes);
  - each branch's **edit log** keeps the edits (commit/reset/merge/rebase/amend) made
    while that branch was active, attributed by tracking the active branch through the
    `checkout: moving from A to B` messages while walking newest→oldest.

  Each log is a flat, append-only list with a cursor; nav entries are
  `<sha>\t<kind>\t<ref>\t<ts>` (ref = branch name, empty = detached), edit entries
  `<sha>\t<kind>\t<ts>`. The `ts` is the **reflog event time** captured when the entry
  was recorded - the durable ordering key the global merge sorts by, so the logs (and
  the global view) keep working after git expires the reflog. (A nav entry needs a
  stored `ts` because its landing sha carries the wrong time; an edit entry's `ts` is
  effectively the commit's committer time, which legacy logs without the column fall
  back to.) Undo/redo are cursor moves; the entry decides how HEAD is restored.
- **A derived global view, never a third stored log.** `git undo -g` composes the two
  durable logs into one chronological throughline by **merging them on the stored
  `ts`** (dropping each axis's own scaffolding - the nav origin entry, the per-branch
  edit floors - and keeping prime anchors), then **walks** it, dispatching each step to
  an edit reset or a nav checkout. Because it reads the durable logs, not the reflog, it
  survives reflog expiry. The only stored global state is a cursor index
  (`global/cursor`); the throughline itself is rebuilt on every command, so `git oplog
  -g` and `git opstatus -g` always agree. Rows sort by `(ts, src, seq)` - ts the durable
  event time, then the source log, then the entry's index WITHIN that log - so for
  same-second entries each log's own order is preserved verbatim (the reflog is not
  consulted at all). `undo -g N` WALKS (each step may belong to a different axis) - the
  one place `undo N` is not a single atomic jump.
- **Each cursor self-heals to where HEAD actually is.** A cross-axis op (a global walk)
  or a manual `git checkout`/`reset` moves HEAD without going through a per-axis command,
  so a stored cursor can fall stale. On its next sync the nav log re-anchors its cursor
  to the branch/position HEAD is now on, and an edit log re-anchors to its current tip
  (and, when a new commit forked off a state a global walk had moved to, to that merge-
  base fork point). This is what keeps the three views orthogonal and correct after you
  mix them: global-undo into another branch, manually check out back, and that branch's
  edit redos are still exactly where you left them - and the same holds for navigation.
- **Durable against branch deletion.** The edit log is read from HEAD's reflog, NOT a
  branch's own reflog (which `git branch -d` deletes and a recreate never restores).
  So a deleted/recreated branch keeps its edit history, and a global walk that
  recreates a branch can still step through its edits. This is *why* both logs read
  from the durable HEAD reflog rather than the per-branch one.
- **Atomic restore per domain.** A nav entry is restored by one `git checkout` to its
  position (recreating a deleted branch; detaching only for a recorded detached
  position); an edit entry by one `git reset --hard` of the current branch. So
  `undo N` is a direct jump, not a walk. The tool's own HEAD moves are labeled - both
  the reset and the checkout via `GIT_REFLOG_ACTION` - so a re-seed strips them.
- **Append-only with prime anchors.** Neither log is truncated. Acting after undoing
  back to a point `B` appends a prime `B′` then your new entry `D`:

  ```
  log: [A, B, C, B′, D]
  undo from D → B′ (where you made D) → C (preserved) → B → A
  ```

  The prime records `D`'s true predecessor in the flat list, so undo lands correctly
  *and* nothing you undid past is lost. The cold seed reconstructs primes it can't see
  directly, but *only* from our own labeled hops (an undo-then-reapply): the entry
  recorded right after a stripped `git-undo:`/`git-redo:` hop, if it attached to an
  earlier recorded state rather than its predecessor, gets that anchored before it.
  Unmarked history (ordinary commits/merges/fast-forwards/manual reset) never yields a
  reconstructed prime.
- **GC-proof.** Every state seen gets a keep-ref (`refs/git-undo-redo/keep/<sha>`), so
  gc can never reclaim an undone or abandoned commit - undo/redo work even after the
  reflog fully expires. (Verified with the reflog nuked and `gc --prune=now`.)
- **Catch-up, not hooks.** No daemon. The navigation log re-reads new checkouts from
  the reflog each command - a count watermark (`nav/seen`) tracks how far it has
  consumed, so even a net-zero switch-away-and-back is caught (switches have no
  rev-list path; the reflog is their only record). An edit log samples its branch tip
  and stitches in new commits via `rev-list`.
- **Boundaries.** Off-branch tip-moves (`git branch -f`, a fetch) never move HEAD, so
  they're outside the model at cold seed - the live tip-sampling catches them going
  forward. A commit on a detached HEAD belongs to no branch's edit log (the
  detached-commit seam). Both stay safe in git's reflog. These are the *only* gaps,
  and they fall out cleanly from "everything derives from the HEAD reflog."
- **Unbounded retention.** Logs accumulate (rebuilt only by `git oplog --reset`). Safe
  - see Performance.

## Configuration

Four `git config` keys (read at runtime; per-invocation flags always override):

- `undoredo.default` = `global` | `edit` | `navigation` (default `global`) - the scope of
  a bare `git undo` / `git redo` / `git oplog` / `git opstatus` (each also takes
  `-g`/`--global`, `-e`/`--edit`, and `-n`/`--navigation`).
- `undoredo.oplog` = `full` | `compact` (default `full`) - the default `git oplog`
  view (`-c`/`-f` override).
- `undoredo.take` = `unstaged` | `staged` (default `unstaged`) - whether `git take`
  leaves its changes in the working tree (default) or staged (`-u`/`-s` override).
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
.git/git-undo-redo/nav/              the navigation log (timeline "<sha>\t<kind>\t<ref>\t<ts>", cursor, seen)
.git/git-undo-redo/local/<branch>/   a per-branch edit log (timeline "<sha>\t<kind>\t<ts>" + cursor)
.git/git-undo-redo/global/cursor     where you are in the (derived) global view - a single int
refs/git-undo-redo/keep/<sha>        one ref per state (GC protection); packed by git gc
```

(`<branch>` is the branch name with `/` percent-encoded so it's one path component.)

Nothing leaks into `refs/heads`, tags, or HEAD's reflog meaning. The only reflog
footprint is the labeled `git-undo:` / `git-redo:` / `git-recover:` reset entries
that undo/redo inherently produce (and which we strip back out on seed).

## Operation flow

- **navigation seed/sync** (`_ou_nav_seed` / `_ou_nav_sync`): the nav log is the HEAD
  reflog filtered to `checkout: moving ...` moves, with our labeled hops stripped and
  consecutive repeats collapsed; the oldest checkout's "from" is the origin position.
  Sync reads the new checkouts since a count watermark (`nav/seen` = total reflog
  entries last consumed) and appends them (each stamped with its reflog event time),
  priming if mid-undo. Reading the reflog (not the net position) is what catches a
  net-zero switch-away-and-back; the count watermark is what disambiguates an identical
  repeated switch sequence. Sync then **re-anchors the cursor** to the branch/position
  HEAD is actually on, so a prior global walk's checkout (which it skips as a labeled
  hop) doesn't leave the cursor stale.
- **navigation undo / redo** (`_ou_undo_nav` / `_ou_redo_nav` → `_ou_nav_goto`): one
  atomic `git checkout` to the target position - a branch by name, or the sha detached
  (recreating the branch if you'd deleted it). `undo N` is a single jump. Bounds-checked.
- **edit seed/sync** (`_ou_local_seed` / `_ou_local_sync`): the per-branch edit log is
  the HEAD reflog filtered to the edits made while THAT branch was active (active branch
  tracked through the `checkout: moving from A to B` messages, plus the branch's start
  tip as the floor) - **not** the branch's own reflog, so it survives a delete+recreate.
  Sync samples the branch tip and stitches new commits via `rev-list` (each stamped with
  its committer time; a ff-merge/reset tip-entry gets the branch's reflog event time
  instead, since it lands on an older commit whose own time would mis-order it). Cold-
  seed prime reconstruction runs off the same labeled hops as the nav seed. Sync also
  re-anchors, but ONLY for moves WE made: if the branch reflog top is one of our labeled
  hops (or is gone, leaving the durable global walk) and the tip is a state already in the
  log, it repositions the cursor instead of re-recording. A move WE did not make - a
  user's `git reset --hard <ancestor>`, which leaves a real `reset:` reflog entry - is
  instead RECORDED as a new operation, so `git undo` reverses it (recovering the discarded
  commits; this is the headline `reset --hard` rescue, and it must work for a primed repo,
  not just a cold seed). Before recording, sync corrects a stale cursor to the branch's
  actual pre-move tip (the 2nd branch-reflog entry), so a reset after a global walk records
  from where the branch really was, not a spot the walk left the cursor (which would inject
  a spurious prime and undo one step short). It also re-anchors to the merge-base fork point
  when a new commit forked off a state a global walk moved to, so that commit primes right.
- **edit undo / redo** (`_ou_undo_local` / `_ou_redo_local` → `_ou_local_goto`): jump
  the cursor straight to the target and one `git reset --hard` of the current branch
  (`_ou_local_restore`). Refuses on a detached HEAD (no branch to scope to).
- **global derive / walk** (`_ou_global_derive` → `_ou_global_walk` / `_ou_undo_global` /
  `_ou_redo_global`): first refresh both axes from the reflog while it lives (sync nav +
  seed/sync every branch's edit log - branch set = local-dir branches ∪ current ∪ every
  branch the nav log switched to), then **merge** their entries by stored `ts` into one
  oldest→first throughline (dropping the nav origin and the per-branch edit floors - the
  synthetic branch-point entries, tagged `floor`, already carried by the nav checkout-in -
  while keeping primes). Dropping by the `floor` tag (not by sha) is what keeps the initial
  branch's real genesis commit in the log even when a later checkout BACK to that branch
  shares its sha (a legacy log without the tag falls back to a sha match guarded by a root
  check, since a real floor always has a parent). Each entry already carries its branch
  (nav `ref`, edit dir), so restore is
  uniform: switch to that branch (recreate if deleted) and reset to the sha, or detach.
  The cursor is trusted while it matches HEAD and re-anchored otherwise, preferring the
  occurrence whose kind matches how you arrived (a reset hop = an edit landing, a bare
  checkout hop = a nav landing). `undo -g N` walks one step at a time.
- **`git take` / `git take N`** (`_ou_take` / public `git-take`): copy a commit's full
  tree onto the working tree with **no** navigation (HEAD and cursor never move). Bare
  `git take` grabs the branch's **latest** edit (the top of its edit log) - the "I undid
  to look around, now give me my newest work back" case - but **skips a trailing reset**:
  a reset moves backward, so a bare take landing on one would grab an older state (no
  intentional use), so it falls to the latest real edit (a commit ABOVE a reset is still
  taken; only a reset AT the top is skipped). `git take N` instead reaches the commit `N`
  entries above the current point (so `take 1` is the closest one above you), counting
  every entry including resets.
  `_ou_take_apply` runs `git restore --source=<commit> [--staged] --worktree :/`: by
  default worktree-only, so the changes land **unstaged** (the new default; the old
  always-staged behavior was found more annoying); `-s`/`--staged` (or
  `undoredo.take=staged`) also writes the index. Clean tree + a non-detached HEAD
  required. The removed `git undo --staged` flow is now just `git undo` then `git take`.
- **oplog / picker** (`_ou_show` → `_ou_oplog_print` / `_ou_oplog_interactive`): render
  the chosen log - `-e` edit / `-n` navigation (default `undoredo.default`). The printer
  reads a generic `TL_*` buffer that `_ou_show` copies the chosen log into. `-c` hides
  primes; `-i` is a picker (cursor move, no new op): an edit pick resets the branch and
  saves the edit cursor, a nav pick is one atomic checkout.
- **reset** (`_ou_reset`, `git oplog --reset`): delete the nav + per-branch logs and
  keep-refs; the next command re-seeds from the live reflog. A rebuild, not a wipe
  (re-deriving from the reflog *is* the model).
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
  even mishandles `--amend`. So both seeds (navigation and edit, both reading HEAD's
  reflog) flag the kept entry immediately after each stripped hop and reconstruct only
  for those. The same labeled hops drive primes in both logs - an edit undo and a nav
  undo each land a `git-undo:` label in HEAD's reflog. Don't revert to a topological
  guess, and keep the two seeds symmetric.
- **Two orthogonal logs, both projections of the HEAD reflog.** Edit (`-e`, per-branch)
  and navigation (`-n`) are separate append-only logs, each a filter of the *one*
  durable source: nav keeps the checkout moves, each edit log keeps the edits made while
  that branch was active. We rejected the old single *mixed* "global operation log": it
  conflated the two axes (so it had to **walk** to faithfully reverse), it was sampled
  (so it missed net-zero excursions), and the checkout/edit ambiguity caused the worst
  blind-test bug ("undo did something I didn't ask"). Splitting the axes makes each
  atomic and removes the ambiguity. The `-g`/`--global` view *composes* them at query
  time - derived, never a third stored log (see the next two entries).
- **Global is a derived merge of the durable oplogs, ordered by stored event time - not
  a reflog read.** `git undo -g` rebuilds one chronological throughline by merging the
  two persisted logs on each entry's stored reflog `ts` (nav's captured event time;
  edit's committer time, with a ff-merge/reset tip-entry overridden to its reflog event
  time so it doesn't sort at an old commit's age). We first considered deriving it from
  the HEAD reflog directly - simpler, but it vanishes the moment git expires the reflog,
  even though the same operations still live in our durable oplogs. Merging the oplogs
  instead makes the global view as durable as undo/redo. Only a cursor index is stored
  (`global/cursor`); the throughline is rebuilt each call (so oplog and opstatus agree).
  Rows sort by `(ts, src, seq)`: ts (the durable event time), then the source log, then
  the entry's index WITHIN that log. The `seq` key is load-bearing - WITHIN a source it
  ALWAYS decides same-second order, so a single branch's history is whatever its own log
  says and can never scramble. We do NOT tiebreak same-second entries by reflog position:
  a sha repeats in the reflog after any reset / checkout-back (a `reset --hard <ancestor>`
  leaves a `reset:` entry at an older commit's sha, our own undo a `git-undo` hop there),
  so a sha-keyed "newest occurrence" rank makes that commit inherit the newer occurrence's
  recency and reorders the same-second run - which is exactly how a reset rescue once came
  back non-monotonic (`c1,c3,c2,c4`). The only thing `(ts, src, seq)` gives up is the
  sub-second order of two DIFFERENT logs' entries in the same wall-clock second (resolved
  by src, stably); that can't reorder any one log. For that to hold, `src` must be STABLE
  across calls: branches are assigned src in SORTED order, because the gather order varies
  between derivations (dir glob vs nav refs, depending on which logs exist yet) and an
  unstable src would reorder same-second cross-branch entries and invalidate the stored
  cursor. Don't reintroduce a reflog-sourced (or otherwise stored) global log, don't add a
  reflog-rank tiebreak, and keep the branch order sorted.
- **Per-axis cursors self-heal to the real HEAD/tip - but only absorb OUR moves, never a
  user's edit.** `git undo -g` moves HEAD with labeled checkouts/resets the per-axis syncs
  skip, so each sync re-anchors its cursor to where HEAD actually is (nav → the current
  branch/position; edit → the current tip). The hard part is the edit axis: a user's `git
  reset --hard <ancestor>` and our own undo both just move the branch pointer to an older
  recorded commit, but they must be handled OPPOSITELY - our hop is absorbed (reposition
  the cursor), the user's reset is RECORDED (so `git undo` reverses it and recovers the
  discarded commits). The discriminator is the branch reflog label: our hops read back as
  `git-undo`/`git-redo`, a user's reset as `reset:`. Generalizing the self-heal to "absorb
  any move onto a known state" once broke this - it swallowed the user's `reset --hard` for
  every primed repo, defeating the headline rescue (it only worked on a cold seed). So:
  reposition only for our own labeled hops (or a vanished branch reflog = the durable
  global walk); record everything else. This is the orthogonality guarantee AND the reset
  rescue at once; don't trade one for the other. (See also the edit seed/sync flow.)
- **`git take` defaults to the branch's latest edit, unstaged; `--staged` is gone from
  undo/redo.** Bare `git take` grabs the top of the edit log (usual intent: you undid to
  look around, now want your newest work back), and `git take N` reaches the Nth entry
  above you. It lands changes **unstaged** by default (`-u`/`-s`, or `undoredo.take`),
  since staging-by-default proved more annoying than useful. The old `git undo --staged`
  / `-s` post-step was removed entirely: it was contrived next to "just `git undo`, then
  `git take`," which expresses the same intent with one orthogonal primitive instead of a
  flag bolted onto navigation. Don't re-add a staging flag to undo/redo.
- **The edit log reads HEAD's reflog, not the branch's own.** A branch reflog is deleted
  by `git branch -d` and never restored on recreate; HEAD's reflog keeps every on-branch
  edit (attributable by the surrounding `checkout:` messages) and is durable. So the edit
  log survives a delete+recreate, and a global walk that recreates a branch can still
  replay its edits. Two clean boundaries fall out and are accepted: off-branch tip-moves
  (never in HEAD's reflog; live tip-sampling re-catches them) and the detached-commit
  seam (on no branch). We rejected merging the branch reflog back in for those rare cases
  - the conditional/merge complexity wasn't worth it.
- **Navigation is read from the reflog with a count watermark, not sampled.** Position
  sampling misses a net-zero switch-away-and-back; switches have no rev-list path (unlike
  commits), so the reflog is their only record. Sync re-reads the new checkouts; the
  watermark is a count of total reflog entries consumed (`nav/seen`), because identical
  repeated switch sequences are indistinguishable by content. Our own nav moves are
  labeled via `GIT_REFLOG_ACTION` on the `checkout` (verified: it relabels the reflog
  subject), so the seed strips them and `git reflog` stays clean.
- **Atomic restore per domain - no walk.** An edit restores by one `git reset --hard`
  of the current branch; a navigation by one `git checkout` to its position (recreating
  a deleted branch, detaching only for a recorded detached position). `undo N` is a
  direct jump in both. A log is atomic-jumpable iff every entry is a complete,
  independently-restorable state - which both are, once the axes are separated. The old
  global had to walk *only* because it mixed position-moves and content-moves; that need
  is gone. Don't reintroduce a mixed walking log.
- **keep-refs for retention.** Navigation must not depend on reflog expiry, so
  every state is pinned by a ref. This also makes retention effectively infinite.
  *Dedup the shas before the batch:* `_ou_keep_all` writes them in one
  `git update-ref --stdin`, which is a single atomic transaction and aborts the WHOLE
  batch on a repeated ref (`multiple updates for ref ... not allowed`). A sha recurs
  non-consecutively in the reflog after any reset / amend / rebase / branch-switch,
  so without the dedup the seed silently (`2>/dev/null`) protected *nothing* and the
  GC-proof guarantee was a lie on first use. Keep the dedup.
- **Restore must report failure, never fake success.** `_ou_nav_restore` /
  `_ou_local_restore` return their checkout/reset exit status, and every caller
  (`_ou_nav_goto`, `_ou_local_goto`, the undo/redo entry points, the picker) checks it:
  on a failure (e.g. a commit missing on a pre-fix repo) they abort with a clear error
  and DON'T advance the cursor. The old code ignored the exit, so a destroyed object
  produced a cheerful success line while HEAD never moved - the worst failure mode for a
  "nothing is lost" tool. Don't drop the exit checks.
- **No hook; each log catches up from the reflog.** No daemon, no
  `reference-transaction` hook (considered, declined for complexity). Nav re-reads new
  checkouts each command against its count watermark - so the net-zero switch-away-and-
  back that the old *sampled* global missed is now caught. Edit sync samples the branch
  tip and stitches new commits via `rev-list` (commits have an ancestry path, so they're
  reconstructable without re-reading the reflog); a forward gap that's a single
  non-commit op (ff-merge / rebase to a descendant) is recorded as that one op, not
  mislabeled `commit`, by classifying the reflog top. The detached-commit seam and
  off-branch tip-moves are the only between-run things still outside the model (both safe
  in git's reflog) - and they're inherent boundaries, not sampling gaps.
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
- **Don't reintroduce rejected designs** (above) - especially: don't merge the two logs
  into one stored "global" log (the global view is *derived* each call by merging the two
  durable oplogs on their stored event time, never stored as a third log and never
  re-sourced from the reflog), don't make navigation *sample* the position (read new
  checkouts from the reflog against the count watermark), don't seed an edit log from a
  branch's own reflog (use HEAD's, so it survives a delete+recreate), and don't let a
  per-axis sync trust a stored cursor that no longer matches HEAD (each must self-heal).
  If you add a code path that moves HEAD or a branch, label its reflog entry with
  `GIT_REFLOG_ACTION` (for both resets and checkouts) so the seed strips it - and stamp
  any new timeline entry with its reflog event time so the global merge can order it.
- Runs anywhere bash + git exist: macOS, Linux, Windows Git-Bash/WSL (and via
  Git-for-Windows' bundled bash, `git undo` works from PowerShell/CMD too).
```
