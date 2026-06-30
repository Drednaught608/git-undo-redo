<p align="center"><img src="logo.png" width="80" alt="git-undo-redo logo"></p>

# git-undo-redo

**`git undo` and `git redo` are <kbd>Ctrl</kbd>+<kbd>Z</kbd> /
<kbd>Ctrl</kbd>+<kbd>Y</kbd> for git.** `git undo` reverses your last change - a commit,
an amend, even a bad `git reset --hard` - and your working tree follows. `git redo`
re-applies it. Committed too soon? `git take` brings a commit's changes back so you can
keep editing instead of reversing them. And `git goto` switches branches like `git
switch`, parking your uncommitted work and restoring it when you return - so you never
have to stash first.

No new tool, no new workflow: it reads git's own reflog, never rewrites your branches or
refs, and writes nothing outside `.git/`. Unlike
[jj](https://github.com/martinvonz/jj) or git-branchless, you don't change how you use
git to benefit - you just type `git undo`.

```console
$ git undo                 # reverse your last commit (your files follow)
↶ Undo edit on main → 5207efa Wire up validation  (undo: 1 · redo: 1)

$ git redo                 # ...changed your mind
↷ Redo edit on main → 5394925 Add login form  (undo: 2 · redo: 0)
```

**Recover a bad reset** - the rescue people actually reach for:

```console
$ git reset --hard HEAD~2  # oops, wiped two commits
HEAD is now at 8c7a0d5 Project skeleton

$ git undo                 # ...back: commits and working tree restored
↶ Undo edit on main → 5394925 Add login form  (undo: 2 · redo: 1)
```

**Committed too early** - undo, then `git take` to keep the changes and re-edit:

```console
$ git undo
↶ Undo edit on main → 4d83dad Add parser  (undo: 0 · redo: 1)

$ git take                 # the work is back in your tree, unstaged
↥ Took the changes from ad92e07 wip: half-done refactor - in your working tree (unstaged), edit and commit.
```

**Switch branches without the stash dance** - `git goto` is `git switch` that parks your
uncommitted work and brings it back when you return (it creates branches with `-c` and
jumps to remotes too, just like `git switch`):

```console
$ git goto feature         # dirty tree? it's parked for you, no "commit or stash first"
Switched to branch 'feature'

$ git goto main            # ...and your half-finished work is waiting when you return
Switched to branch 'main'
↜ Restored your parked changes from 65245e8
```

That's the whole everyday tool: **`git undo`, `git redo`, `git take`, and `git goto`.** It
also keeps a full, browsable undo history with finer-grained scopes - but that's optional
power, under **Advanced** and **How it works** below. You never need any of it for the
four commands above.

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

The installer drops four commands (`git-undo`, `git-redo`, `git-take`, `git-goto`) into
the target directory. If that directory isn't on your
`PATH` yet, it offers to add the line to your shell's rc file (`~/.bashrc` or
`~/.zshrc`) for you; decline and it just prints the command to run yourself.

### Requirements

- **git** and a **bash** environment.
  - macOS / Linux: already present.
  - Windows: **Git for Windows** is all you need - its bundled bash runs the
    script, so `git undo` works from PowerShell or CMD, not just the Git-Bash
    terminal. (WSL works too.)

## Command reference

Day to day it's `git undo`, `git redo`, `git take`, and `git goto` (above). The rest -
scopes, the history browser, status - is optional power, summarized here and explained
under **Advanced** and **How it works** below.

| Command | What it does |
| --- | --- |
| `git undo` | Undo the last edit on this branch - a commit, an amend, a reset - whichever was most recent; your files follow. This is the default. (Add `-g` to undo across branch switches too, or change the default with `undoredo.scope`.) |
| `git undo -e` / `--edit` | Undo just this branch's edits (commit, reset, merge, rebase, amend) - the default scope, stated explicitly. |
| `git undo -n` / `--navigation` | Undo just your last *branch switch / checkout* - one move back to where you were (works on a detached HEAD too). |
| `git undo -g` / `--global` | Undo your single most recent change across **both** your edits and your branch switches, whichever came last. A step can move you to another branch (the message says where you land). |
| `git undo N` / `git redo N` | Undo / redo `N` at once (e.g. `git undo 3`). Refuses and reports how many are available if `N` is too many. |
| `git redo` / `-e` / `-n` / `-g` | Re-apply your last undone change - this branch's edits by default (`-e`), a branch switch (`-n`), or across everything (`-g`). |
| `git take` | Copy the branch's **latest** edit (the top of the edit log) into your files **without moving** `HEAD` - the common flow is `git undo` to look back, then `git take` to pull your newest work in. Lands unstaged by default. Edit-based (reads the current branch's log); needs a clean tree and a branch. |
| `git take N` | Reach the commit `N` entries above your current point (so `git take 1` is the closest one above you, `git take 2` further up). Applies that commit's full tree wholesale. Refuses, changing nothing, if there are fewer than `N` commits above you. |
| `git goto <branch>` | `git switch` that handles your uncommitted work for you instead of refusing. Parks your dirty **tracked** files (staged **and** unstaged) against the commit you leave - they leave the working tree - switches, then restores whatever you'd parked against the commit you land on, no manual stash/pop. Your work waits where you left it (not on the new branch); per-commit, so changes left against different commits each come back where you left them. Untracked files travel with the switch as usual; your `git stash` stack is never touched. All `git switch` options pass through. |
| `git undo --status` / `-s` | Show the current `HEAD` and how many undo / redo steps remain, for the current branch's edits (default), across everything (`-g`), or branch switches (`-n`). Read-only; `git redo --status` shows the same thing. |
| `git undo --log` / `-l` | Show the current branch's **edit log**, newest first, with `@` marking where you are. `-g`/`--global` shows the composed **global log**, `-n`/`--navigation` the **navigation log**. (`-c`/`--compact` hides resume points (↻); `-f`/`--full` is the default.) Read-only. |
| `git undo -i` / `--interactive` | Show that log (edit, navigation, or global via `-e`/`-n`/`-g`) as a picker and drop straight to a point you choose (`-c`/`-f` set the initial density, `t` toggles it in-screen). A cursor move; for navigation it's a single atomic checkout. |
| `git undo --reset` | Drop the tracked logs (navigation + per-branch edit logs) so they rebuild cleanly from git's reflog on the next command (a rebuild, not a wipe - recent history stitches back; accumulated tracking older than the reflog, resume points, and any wedged state are dropped). Also clears parked working-tree versions (from `git goto` / `git undo --worktree`). Your commits and current working tree are untouched. Long form only. |
| `git undo --worktree` / `-w` | Step **back** through earlier parked versions of your **uncommitted work** at the current commit, without moving `HEAD` (`git redo -w` steps forward). Every `git goto` / dirty undo / redo snapshots the worktree, so this is your worktree's own undo history. If you reached the commit with a plain `git switch` (so the parked work isn't loaded), the first `git undo --worktree` brings your **latest** parked version back into the worktree - saving any current edits as a new version first, so nothing is lost. Add `--log` / `--status` / `--interactive` to list the versions, see where you are, or pick one to load. Refuses at the ends, and if you ask for more than exist. Stale parked versions are pruned automatically once git itself can no longer reach the commit they belong to. |

Behavior is configurable via `git config` - the scope of a bare command, the `--log` density, where `git take` lands, and color. See **[Configuration](#configuration)** below; flags always override the config. Short flags can be bundled - `git undo -nl` is `git undo -n -l`, and so on (a count stays separate: `git undo -e 3`, not `-e3`).
`git undo -h` shows the everyday flags (status, log, the picker); `git undo -h -a`
(`--advanced`) adds the scopes (`-e`/`-n`/`-g`) and `--reset`. Use `-h`, not `--help`,
after `git undo`: git itself reserves
`git <cmd> --help` for a manual-page lookup (it never reaches this tool), so
`git undo --help` reports "documentation file not found" rather than showing help. (`-h`
is passed straight through, and the binaries also accept `--help` directly, e.g.
`git-undo --help`.)

```console
$ git undo --status
HEAD is at: a1b2c3d Add login form
Available globally (all operations, in order) (undo: 4 · redo: 1)

$ git undo --log
Global operation log (newest first; @ = current position):
     5  commit    main (at e4f5a6b Wire up validation)
 @   4  commit    main (at a1b2c3d Add login form)
     3  checkout  main (at 9c0ffee Refactor parser)
     2  checkout  feature (at edf1cd2 Scaffold routes)
     1  commit    main (at 1b2c3d4 Initial parser)
     0  commit    main (at 0a1b2c3 Project skeleton)
```

## Configuration

Everything is optional - the defaults are what you get out of the box. Set a key per
repo with `git config`, or everywhere with `git config --global`; a per-command flag
always overrides the config for that run.

Here is the full `[undoredo]` section as it would appear in your `~/.gitconfig`. Each
value shown **is the default**; the comment lists the choices, so you can copy the block
and edit a value in place:

```ini
[undoredo]
    scope = edit        # edit | global | navigation   - scope of a bare undo/redo (and --status / --log)
    log   = full        # full | compact               - density of `git undo --log`
    take  = unstaged    # unstaged | staged            - where `git take` puts the changes
    color = auto        # auto | always | never        - colored output (auto = only to a terminal)
```

Or set them one at a time from the shell:

```bash
git config undoredo.scope global     # make a bare `git undo` span edits + branch switches
git config undoredo.log   compact    # hide resume points in `git undo --log`
git config --global undoredo.take staged   # everywhere: `git take` stages by default
```

## Keeping changes with `git take`

`git undo` reverses your last commit (a full reverse). When you instead want to *keep*
the undone commit's changes - "committed too early, let me edit and re-commit" - undo as
normal, then `git take` pulls your newest work back into the tree without moving `HEAD`:

```console
$ git undo
↶ Undo edit on main → 9880b83 Project skeleton  (undo: 1 · redo: 2)

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
finer control, and most users never need it. There are really two kinds of "undo": your
**edits** on a branch, and your **branch switches**. The tool keeps a separate log for
each, plus a third **global** scope that composes both, newest first. The three are
independent:

- **`git undo`** (edit, the default) steps back one *edit* on the branch you're currently
  on - commit, reset, merge, rebase, amend - using that branch's own log. It only moves
  the current branch's tip, so you can hop to any branch and undo its last edit. `-e`
  states this scope explicitly, and `git undo 3` is just three undos.
- **`git undo -n`** (navigation) steps back one *branch switch / checkout* (a detached
  checkout too) - one `git checkout` back to where you were.
- **`git undo -g`** (global) steps back your single most recent change across *both* your
  edits and your branch switches - whatever you did last, be it a commit, a switch, or a
  reset. A step can move you to another branch (the message says where you land). It's
  built on demand from the other two logs, never stored separately, so it keeps working
  even after git expires its reflog.

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

$ git undo --log -n
Navigation log (newest first; @ = current position):
 @   3  checkout  feature (at 1f3a9c2 Add parser tests)
     2  checkout  main (at a1b2c3d Add login form)
     1  checkout  feature (at edf1cd2 Scaffold routes)
     0  checkout  main (at 0a1b2c3 Project skeleton)
```

Global - your most recent change, whichever kind it was. `git undo -g` steps back across
both axes; here the last thing you did was a commit on `main`, so it steps that back, and
the composed log shows both kinds in one timeline:

```console
$ git undo -g
↶ Undo → 40778a3 Initial parser on main  (undo: 4 · redo: 1)

$ git undo --log -g
Global operation log (newest first; @ = current position):
     5  commit    main (at 40778a3 Initial parser)
 @   4  checkout  main (at 40778a3 Initial parser)
     3  checkout  feature (at 40778a3 Initial parser)
     2  commit    main (at ebbb41f Refactor parser)
     1  commit    feature (at cbdb5f3 Scaffold routes)
     0  commit    main (at b6e29a4 Project skeleton)
```

Edit and navigation each move in one step: an edit is a single reset of one branch, a
branch switch is a single checkout. Neither has to replay unrelated steps - which is the
whole point of keeping them apart. Global is the one scope that goes step by step, since
each step may be an edit or a switch.

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
  by their stored event times into one timeline (dropping each log's internal
  scaffolding, keeping resume points), then steps through it - each step an edit reset
  or a branch checkout. It's never written as a third log; only the
  global cursor (`.git/git-undo-redo/global/cursor`, a single integer) is kept. Reading
  the durable logs rather than the live reflog is exactly what lets it survive reflog
  expiry.
- **Cursors self-heal.** Each log's cursor self-heals to wherever `HEAD` / the branch
  tip actually is, so the edit, navigation, and global views stay correct and
  independent even after a global undo into another branch or a manual `git checkout` / `reset`.
  You can global-undo into another branch, manually check out back, and that branch's
  edit redos are still right where you left them - and vice-versa for navigation.
- **Durable against branch deletion.** Because the edit log is read from the HEAD
  reflog and not from a branch's own reflog, deleting (or recreating) a branch never
  loses its edit history - `git branch -d` deletes the branch reflog, but the edits
  are still in HEAD's, attributable to that branch. (This is also how a `git undo`
  that recreates a branch can still step through its edits.)
- **Append-only with resume points.** Neither log is ever truncated. Act after
  undoing back to a point `B` and it records a **resume point** at `B` then your new
  entry, so undo lands where you carried on and the path you undid past is still there
  to walk back through. Nothing is ever lost. (A resume point shows the underlying kind
  marked with `↻`, e.g. `↻ commit` in the edit log, `↻ checkout` in the navigation log -
  the log header explains it whenever one is present.)
- **Atomic in each domain.** An edit is a single `reset` of one branch; a navigation
  is a single `checkout` (recreating the branch if you'd deleted it, never detaching
  unless you asked to). So `git undo N` is a direct jump to that point, not a step-by-step
  replay - the one exception being `git undo -g N`, which goes one at a time, since each
  step may be an edit or a switch.
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

- **Uncommitted work is parked, not refused (and not lost).** Undo/redo move `HEAD`, so
  your uncommitted *tracked* changes (staged **and** unstaged) briefly leave the working
  tree - they're parked against the commit you leave and restored when you return (the same
  engine as `git goto`), so you never have to commit or stash first. **A change that
  disappears when you `git undo` comes straight back when you `git redo`** - it's set aside,
  not deleted. Untracked files stay in place; your `git stash` stack is untouched. (If the
  work somehow can't be safely parked - a rare ref/disk failure - undo refuses rather than
  risk it.)
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
  history of what you've done - rebuilt only by `git undo --reset`.
- **`git undo --reset`** drops the tracked oplog and its gc protections so the next
  command rebuilds it cleanly from git's reflog. It's a *rebuild*, not a wipe: the
  reflog is exactly what the tool seeds from, so your recent history stitches back in
  - what's dropped is accumulated tracking older than the reflog, resume points, and
  any wedged state. It also clears parked working-tree versions (from `git goto` /
  `git undo --worktree`), so it's a full reset of the tool's state; your current working tree
  is left as-is. Anything the reflog no longer reaches stays only in git's reflog until
  it expires. (Long flag only, by design, so it can't be triggered by accident.)
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
# or the same remote link, no clone needed:
curl -fsSL https://raw.githubusercontent.com/Drednaught608/git-undo-redo/main/install.sh | bash -s -- --uninstall
```

The `bash -s -- --uninstall` form passes the flag through to the piped script. Either
way it removes the commands from wherever they are on your `PATH` (and the default
directory), so no clone is required.

This removes only the commands. Each repo's undo/redo tracking lives in its own
`.git/git-undo-redo/` and is left alone; delete that directory (`rm -rf
.git/git-undo-redo`) to remove it from a repo, or `git undo --reset` to rebuild
it fresh from the reflog.

## License

[MIT No Attribution (MIT-0)](LICENSE) - an [OSI-approved](https://opensource.org/license/mit-0)
permissive license with the same spirit as MIT, minus the attribution requirement.
Use, modify, and distribute it however you like; you don't even need to keep the notice.
