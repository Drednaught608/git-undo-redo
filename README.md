<p align="center"><img src="logo.png" width="80" alt="git-undo-redo logo"></p>

# git-undo-redo

**`git undo` and `git redo` are <kbd>Ctrl</kbd>+<kbd>Z</kbd> /
<kbd>Ctrl</kbd>+<kbd>Y</kbd> for git.** `git undo` reverses your last change - a commit,
an amend, even a bad `git reset --hard` - and your working tree follows. `git redo`
re-applies it. Committed too soon? `git take` brings a commit's changes back so you can
keep editing instead of reversing them.

No new tool, no new workflow: it reads git's own reflog, never rewrites your branches or
refs, and writes nothing outside `.git/`. Unlike
[jj](https://github.com/martinvonz/jj) or git-branchless, you don't change how you use
git to benefit - you just type `git undo`.

```console
$ git undo                 # reverse your last commit (your files follow)
↶ Undo → 5394925 Add login form on main  (undo: 1 · redo: 1)

$ git redo                 # ...changed your mind
↷ Redo → 5207efa Wire up validation on main  (undo: 2 · redo: 0)
```

**Recover a bad reset** - the rescue people actually reach for:

```console
$ git reset --hard HEAD~2  # oops, wiped two commits
HEAD is now at 8c7a0d5 Project skeleton

$ git undo                 # ...back: commits and working tree restored
↶ Undo → 5207efa Wire up validation on main  (undo: 2 · redo: 1)
```

**Committed too early** - undo, then `git take` to keep the changes and re-edit:

```console
$ git undo
↶ Undo → 4d83dad Add parser on main  (undo: 0 · redo: 1)

$ git take                 # the work is back in your tree, unstaged
↥ Took the changes from ad92e07 wip: half-done refactor - in your working tree (unstaged), edit and commit.
```

That's the whole everyday tool: **`git undo`, `git redo`, `git take`.** It also tracks
branch switches and keeps a full, browsable undo history with finer-grained scopes - but
that's optional power, under **Advanced** and **How it works** below. You never need any
of it for the three commands above.

## Install

One-liner (macOS, Linux, and Windows **Git-Bash** / WSL - all the same):

```bash
curl -fsSL https://raw.githubusercontent.com/Drednaught608/git-undo-redo/main/install.sh | bash
```

Or from a clone:

```bash
git clone https://github.com/Drednaught608/git-undo-redo
cd git-undo-redo
./install.sh                 # installs into ~/.local/bin
./install.sh --bin ~/bin     # ...or a directory of your choice
```

The installer drops five commands (`git-undo`, `git-redo`, `git-oplog`,
`git-opstatus`, `git-take`) into the target directory. If that directory isn't on your
`PATH` yet, it offers to add the line to your shell's rc file (`~/.bashrc` or
`~/.zshrc`) for you; decline and it just prints the command to run yourself.

### Requirements

- **git** and a **bash** environment.
  - macOS / Linux: already present.
  - Windows: **Git for Windows** is all you need - its bundled bash runs the
    script, so `git undo` works from PowerShell or CMD, not just the Git-Bash
    terminal. (WSL works too.)

## Command reference

Day to day it's just `git undo`, `git redo`, and `git take` (above). The rest - scopes,
the history browser, status - is optional power, summarized here and explained under
**Advanced** and **How it works** below.

| Command | What it does |
| --- | --- |
| `git undo` | Undo your single most recent operation across **both** your edits and your branch switches, in chronological order (an edit reset or a nav checkout, whichever was most recent). Global scope is the default; a step can move you to another branch (the message names where you land). |
| `git undo -n` / `--navigation` | Undo your last *branch switch / checkout* - a single **atomic** move back to where you were (works on a detached HEAD too). Never walks. |
| `git undo -g` / `--global` | Undo your single most recent operation across **both** axes, in chronological order (an edit reset or a nav checkout, whichever was most recent). Derived live by merging the two per-axis logs by time. |
| `git undo -e` / `--edit` | Limit to just this branch's edits, regardless of your configured default. |
| `git undo N` / `git redo N` | Undo / redo `N` steps at once (e.g. `git undo 3`). Refuses and reports how many are available if `N` is too many. With `-e`/`-n` it's a direct jump; with `-g` it **walks** `N` steps (each dispatched to its own axis), so `undo -g 3` equals three undos. |
| `git redo` / `-e` / `-n` / `-g` | Re-apply your last operation across both axes (`-g`, default), an edit (`-e`), or a branch switch (`-n`) that you undid. |
| `git take` | Copy the branch's **latest** edit (the top of the edit log) into your files **without moving** `HEAD` - the common flow is `git undo` to look back, then `git take` to pull your newest work in. Lands unstaged by default. Edit-based (reads the current branch's log); needs a clean tree and a branch. |
| `git take N` | Reach the commit `N` entries above your current point (so `git take 1` is the closest one above you, `git take 2` further up). Applies that commit's full tree wholesale. Refuses, changing nothing, if there are fewer than `N` commits above you. |
| `git undo -i` / `git redo -i` | Open the picker for the chosen scope (global by default, `-e` for edit, `-n` for navigation) and drop straight to a point you choose (press `t` to toggle prime anchors). Same screen as `git oplog -i`. |
| `git oplog` | Show the composed **global log**, newest first, with `@` marking where you are. `-e`/`--edit` shows the current branch's **edit log**, `-n`/`--navigation` the **navigation log**. (`-c`/`--compact` hides prime anchors; `-f`/`--full` is the default.) |
| `git oplog --interactive` | Show the log (edit, navigation, or global via `-e`/`-n`/`-g`) and drop straight to a point you pick (`-i`; `-c`/`-f` set the initial view, `t` toggles it in-screen). A cursor move; for navigation it's a single atomic checkout. |
| `git oplog --reset` | Drop the tracked logs (navigation + per-branch edit logs) so they rebuild cleanly from git's reflog on the next command (a rebuild, not a wipe - recent history stitches back; accumulated tracking older than the reflog, prime anchors, and any wedged state are dropped). Your commits and files are untouched. |
| `git opstatus` | Show the current `HEAD` and how many undo / redo steps remain, globally across both axes (default), for the current branch's edits (`-e`/`--edit`), or the navigation log (`-n`/`--navigation`). |

`git config undoredo.default` (`global`, the default, or `edit` / `navigation`) governs the scope of a bare `git undo` / `git redo` / `git oplog` / `git opstatus`. `git config undoredo.oplog` (`full`, the default, or `compact`) sets the default `git oplog` view. `git config undoredo.take` (`unstaged`, the default, or `staged`) sets where `git take` lands the changes. `git config undoredo.color` (`auto`, the default, or `always` / `never`) controls colored output: `auto` colors only when writing to a terminal (and honors `NO_COLOR`), so piped output stays plain. Short flags can be bundled - `git oplog -nc` is `git oplog -n -c`, and so on (a count stays separate: `git undo -e 3`, not `-e3`).
Flags always override the config. Every command takes `-h` for help - use `-h`, not
`--help`, after `git undo`: git itself reserves `git <cmd> --help` for a manual-page
lookup (it never reaches this tool), so `git undo --help` reports "documentation file
not found" rather than showing help. (`-h` is passed straight through, and the binaries
also accept `--help` directly, e.g. `git-undo --help`.)

```console
$ git opstatus
HEAD is at: a1b2c3d Add login form
Available globally (all operations, in order) (undo: 4 · redo: 1)

$ git oplog
Global operation log (newest first; @ = current position):
     5  commit    main (at e4f5a6b Wire up validation)
 @   4  commit    main (at a1b2c3d Add login form)
     3  checkout  main (at 9c0ffee Refactor parser)
     2  checkout  feature (at edf1cd2 Scaffold routes)
     1  commit    main (at 1b2c3d4 Initial parser)
     0  commit    main (at 0a1b2c3 Project skeleton)
```

## Keeping changes with `git take`

`git undo` reverses your last commit (a full reverse). When you instead want to *keep*
the undone commit's changes - "committed too early, let me edit and re-commit" - undo as
normal, then `git take` pulls your newest work back into the tree without moving `HEAD`:

```console
$ git undo
↶ Undo → 9880b83 Project skeleton on main  (undo: 1 · redo: 2)

$ git take
↥ Took the changes from b0577c0 Refactor parser - in your working tree (unstaged), edit and commit.
```

Bare `git take` copies the branch's **latest** edit (the top of the edit log) into your
files, without moving `HEAD`. (It skips a trailing **reset** - a reset moves backward, so
taking it would grab an older state - and uses the latest real edit instead; a commit
above a reset is still taken normally.) The changes land **unstaged** by default (ordinary
working-tree edits); `-s`/`--staged` stages them instead, and `git config undoredo.take`
(`unstaged` | `staged`) sets the default. `git take N` reaches the commit `N` entries
above your current point (so `git take 1` is the closest one above you, `git take 2`
further up) and applies its files *wholesale* (the full snapshot - so only files that
actually differ from where you are show up, you get that commit's version of each rather
than any in-between one, and deletions are handled). It needs a clean tree and a branch,
and refuses, changing nothing, if there's nothing above you (or fewer than `N` commits).

## Advanced: edit, navigation, and global scopes

You can stop at `git undo` / `git redo` / `git take` - this section is for when you want
finer control, and most users never need it. Git has two kinds of "undo," along its two
kinds of movable pointer - a branch tip (your work) and `HEAD` (where you're standing).
The tool keeps an append-only log for each, plus a third **global** scope (the default)
that composes them in time order. The three are fully orthogonal:

- **`git undo`** (global, the default) steps back your single most recent operation
  across *both* axes, in chronological order - whatever you did last, be it a commit, a
  switch, or a reset. Each step is dispatched to its own axis (an edit reset or a nav
  checkout), so a step can move you to another branch (the message names where you land)
  and `git undo N` **walks** `N` steps - `undo 3` equals three undos. It's derived live
  by merging the two durable per-axis logs by time; it's never stored as a third log
  (only a cursor is kept), so it survives reflog expiry.
- **`git undo -e`** (edit) steps back one *edit* on the branch you're
  currently on - commit, reset, merge, rebase, amend - using that branch's own log.
  It only ever moves the current branch's tip, so you can hop to any branch and undo
  its last edit without being pulled elsewhere.
- **`git undo -n`** (navigation) steps back one *position change* - a branch switch
  or checkout (a detached checkout too). It's a single atomic `git checkout` back to
  where you were, never a walk.

Edit, on `main`, undoing the last edit made on main (its own log and counter):

```console
$ git undo -e
↶ Undo edit on main → 9c0ffee Refactor parser  (undo: 2 · redo: 1)
```

Navigation - you switched from `feature` back to `main`; `git undo -n` puts you
back on `feature` in one checkout:

```console
$ git undo -n
↶ Undo (checkout) → on feature  (undo: 6 · redo: 1)

$ git oplog -n
Navigation log (newest first; @ = current position):
 @   3  checkout  feature (at 1f3a9c2 Add parser tests)
     2  checkout  main (at a1b2c3d Add login form)
     1  checkout  feature (at edf1cd2 Scaffold routes)
     0  checkout  main (at 0a1b2c3 Project skeleton)
```

Global - your most recent operation, whichever axis it was on (a bare `git undo`).
Here the last thing you did was a commit on `main`, so `git undo` steps that back; the
composed log shows both axes in one timeline:

```console
$ git undo
↶ Undo → 40778a3 Initial parser on main  (undo: 4 · redo: 1)

$ git oplog -g
Global operation log (newest first; @ = current position):
     5  commit    main (at 40778a3 Initial parser)
 @   4  checkout  main (at 40778a3 Initial parser)
     3  checkout  feature (at 40778a3 Initial parser)
     2  commit    main (at ebbb41f Refactor parser)
     1  commit    feature (at cbdb5f3 Scaffold routes)
     0  commit    main (at b6e29a4 Project skeleton)
```

Edit and navigation are atomic in their own domain: an edit is a single reset of one
branch, a navigation is a single checkout. Neither has to "walk" through unrelated
steps - which is the whole point of keeping them apart. Global is the one scope that
*does* walk, one step per axis, since each step may belong to a different axis.

## How it works

You never need any of this to use the tool - it's here for the curious and for
contributors.

- **Two durable logs, one source.** Both logs are *projections* of git's **HEAD
  reflog** - the chronological record of every move HEAD makes - filtered two ways:
  - the **navigation log** keeps the checkout/switch moves (position changes);
  - each branch's **edit log** keeps the edits (commit, reset, merge, rebase, amend)
    made while that branch was active, attributed by tracking the active branch
    through the reflog's `checkout: moving from A to B` messages.

  But they don't just *live* in the reflog: they **persist to disk**, and each entry
  stores the reflog's **event time**. The reflog is read to seed and refresh them
  while it lives; after that the durable logs are the source - so undo/redo *and* the
  global view keep working after git expires the HEAD reflog. (Edit entries fall back
  to a commit's committer-time only for legacy logs written without a stored
  timestamp.) Tracking lives in its own space inside `.git/git-undo-redo/` (`nav/` and
  `local/<branch>/`, each a timeline + cursor), plus `refs/git-undo-redo/keep/<sha>` -
  one ref per state ever seen, so git's gc can never reclaim an undone or abandoned
  commit.
- **Global is derived, never stored.** The global scope merges the two durable logs
  by their stored event times into one chronological throughline (dropping each axis's
  internal scaffolding, keeping prime anchors), then walks it - dispatching each step
  to an edit reset or a nav checkout. It's never written as a third log; only the
  global cursor (`.git/git-undo-redo/global/cursor`, a single integer) is kept. Reading
  the durable logs rather than the live reflog is exactly what lets it survive reflog
  expiry.
- **Cursors self-heal.** Each axis's cursor self-heals to wherever `HEAD` / the branch
  tip actually is, so the edit, navigation, and global views stay correct and
  orthogonal even after a cross-axis global walk or a manual `git checkout` / `reset`.
  You can global-undo into another branch, manually check out back, and that branch's
  edit redos are still right where you left them - and vice-versa for navigation.
- **Durable against branch deletion.** Because the edit log is read from the HEAD
  reflog and not from a branch's own reflog, deleting (or recreating) a branch never
  loses its edit history - `git branch -d` deletes the branch reflog, but the edits
  are still in HEAD's, attributable to that branch. (This is also how a `git undo`
  that recreates a branch can still step through its edits.)
- **Append-only with prime anchors.** Neither log is ever truncated. Act after
  undoing back to a point `B` and it records a prime anchor `B′` then your new entry,
  so undo lands where you resumed and the path you undid past is still there to walk
  back through. Nothing is ever lost. (A prime shows as that kind with a prime mark,
  e.g. `commit′` in the edit log, `checkout′` in the navigation log.)
- **Atomic in each domain.** An edit is a single `reset` of one branch; a navigation
  is a single `checkout` (recreating the branch if you'd deleted it, never detaching
  unless you asked to). So `git undo N` is a direct jump to that point, not a walk
  through unrelated steps - the one exception being `git undo -g N`, which walks, since
  each step may belong to a different axis.
- **Seeded from the reflog, then maintained live.** On first use each log is stitched
  from the HEAD reflog (the tool's own labeled hops stripped) - so even cold, the
  first `git undo` reverses your last real edit and `git undo -n` your last switch.
  After that each maintains itself: the navigation log re-reads new checkouts from the
  reflog; an edit log samples its branch tip and stitches in new commits. No hooks, no
  daemon.
- **The reflog stays a clean backstop.** The tool's own moves are written as labeled
  `git-undo:` / `git-redo:` entries (so a re-seed strips them), and `git reflog`
  remains a usable, durable record of anything older than the logs.

## Behavior notes

- **Clean tree required.** Undo/redo move `HEAD`, so they refuse to run with
  uncommitted changes to *tracked* files. Untracked files are fine.
- **Your working tree follows.** Undo/redo reset to the recorded state, so your *files*
  move with `HEAD` - which is exactly what makes recovering a bad `git reset --hard`
  work. It's a full reverse; if you instead want to *keep* the undone commit's changes
  to edit (the "committed too early" case), undo as normal, then run `git take` to copy
  that commit's files onto where you are now (unstaged by default, or `-s` to stage).
- **Nothing is discarded.** The oplog is append-only: undo, then do something
  new, and what you undid past is preserved (anchored by a prime entry) - you can
  keep undoing back through it. Redo is available until you perform a new op.
- **Local only.** Everything happens in your local repo - `undo`/`redo` move
  your branch pointer and write tracking under `.git/`. Nothing is ever pushed,
  fetched, or sent to a remote. (Undoing commits you've already pushed is the
  usual "don't rewrite shared history" caution - the tool won't push for you,
  but your local branch would then diverge from the remote; use `git revert`
  for history others already have.)
- **History grows with use.** On first use the oplog is seeded from your recent
  reflog; after that every operation is appended, so it accumulates the full
  history of what you've done - rebuilt only by `git oplog --reset`.
- **`git oplog --reset`** drops the tracked oplog and its gc protections so the next
  command rebuilds it cleanly from git's reflog. It's a *rebuild*, not a wipe: the
  reflog is exactly what the tool seeds from, so your recent history stitches back in
  - what's dropped is accumulated tracking older than the reflog, prime anchors, and
  any wedged state. Anything the reflog no longer reaches stays only in git's reflog
  until it expires. (Long flag only, by design, so it can't be triggered by accident.)
- **No hooks, no daemon.** Each log catches up from the reflog when you run a command.
  The navigation log re-reads every checkout since last time (so even a switch-away-
  and-back is recorded); an edit log samples its branch tip and stitches in new commits
  one at a time. Between commands nothing runs.

## Known limitations

Two clean boundaries, both direct consequences of reading everything from the HEAD
reflog. **Neither loses data** - git's own reflog still backstops what falls outside.

- **Off-branch tip-moves aren't in the edit log (at cold seed).** A move that changes
  a branch's tip *without* moving `HEAD` - `git branch -f other X` while you're on
  `main`, a fetch updating a tracking branch, a rebase relocating a branch you're not
  on - never enters the HEAD reflog, so it isn't in that branch's edit log when it's
  first seeded. (Once you're working on the branch, the live tip-sampling picks such
  moves up going forward.) The commits themselves are safe in git's reflog.
- **A commit made on a detached `HEAD` isn't tracked.** It moved `HEAD` but no branch
  tip, so it belongs to no branch's edit log and isn't a navigation either. It's a rare,
  advanced case; the commit stays in git's reflog (and `git checkout -b` from it brings
  it back).

(Two things that *used* to be listed here are now handled: undo reverting your working
tree is covered by `git take`, and a between-command switch-away-and-back is now read
straight from the reflog by the navigation log.)

## Uninstall

```bash
./install.sh --uninstall            # from a clone
# or, if you don't have the repo handy:
rm -f ~/.local/bin/git-{undo,redo,oplog,opstatus,take}
```

This removes only the commands. Each repo's undo/redo tracking lives in its own
`.git/git-undo-redo/` and is left alone; delete that directory (`rm -rf
.git/git-undo-redo`) to remove it from a repo, or `git oplog --reset` to rebuild
it fresh from the reflog.

## License

[MIT No Attribution (MIT-0)](LICENSE) - an [OSI-approved](https://opensource.org/license/mit-0)
permissive license with the same spirit as MIT, minus the attribution requirement.
Use, modify, and distribute it however you like; you don't even need to keep the notice.
