<p align="center"><img src="logo.png" width="80" alt="git-undo-redo logo"></p>

# git-undo-redo

Operation-level **undo / redo for git**: `git undo` reverses your last
HEAD-moving operation (commit, merge, rebase, reset, branch-switch checkout,
*whatever* it was), and `git redo` re-applies it. Like an editor's
<kbd>Ctrl</kbd>+<kbd>Z</kbd> / <kbd>Ctrl</kbd>+<kbd>Y</kbd>, but for git
operations, and without polluting your branches or refs.

It tracks its own operation log (oplog) in an *orthogonal* space inside `.git`,
in the spirit of [Jujutsu](https://github.com/martinvonz/jj)'s operation log.
The oplog is **append-only**: undoing and then doing something new never discards
what you undid past; it stays in the log, ready to walk back to.

```console
$ git undo
↶ Undo (commit) → a1b2c3d Add login form  (undo: 4 · redo: 1)

$ git redo
↷ Redo (commit) → e4f5a6b Wire up validation  (undo: 5 · redo: 0)
```

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

## Commands

| Command | What it does |
| --- | --- |
| `git undo` | Reverse your last operation (commit, merge, rebase, reset, branch switch). Global by default. |
| `git undo N` / `git redo N` | Undo / redo `N` steps at once (e.g. `git undo 3`). Refuses and reports how many are available if `N` is too many. Works with `-g`/`-l`. |
| `git undo -l` / `--local` | Undo the last *edit* on the branch you're currently on, using that branch's own log. Stays on your branch; switch to any branch and undo its last edit without being pulled elsewhere. |
| `git undo -g` / `--global` | Force the global (shared operation log) undo, regardless of your configured default. |
| `git redo` / `-l` / `-g` | Re-apply an operation (or, with `-l`, an edit on the current branch) you undid. |
| `git undo -s` / `--staged` | Undo as usual, but leave the commit directly above where you land **staged** (uncommitted) instead of removing its changes - the "I committed too early, let me edit and re-commit" flow. Fails if there's no commit directly above. Works with `-g`/`-l`/`N` and on `git redo` too. |
| `git take` | Stage the changes from the commit directly above your current point **without moving** - the after-the-fact version of `--staged`, for when you already undid and forgot it. Edit-based (reads the current branch's log); needs a clean tree and a branch. |
| `git take N` | Same, but reach `N` commits up (e.g. `git take 3`). Unlike `undo --staged`, `take` can grab a commit several steps above in one shot. Refuses, changing nothing, if there aren't `N` commits above you. |
| `git undo -i` / `git redo -i` | Open the operation-log picker and drop straight to a point you choose (press `t` to toggle prime anchors). Same screen as `git oplog -i`. |
| `git oplog` | Show the operation log, newest first, with `@` marking where you are. `-g`/`--global` (default) shows the shared log; `-l`/`--local` shows the current branch's edit log. (`-c`/`--compact` hides prime anchors; `-f`/`--full` is the default.) |
| `git oplog --interactive` | Show the log (global or local via `-g`/`-l`) and drop straight to a point you pick (`-i`; `-c`/`-f` set the initial view, `t` toggles it in-screen). A cursor move, not a new operation. |
| `git oplog --reset` | Drop the tracked oplog so it rebuilds cleanly from git's reflog on the next command (a rebuild, not a wipe - recent history stitches back; accumulated tracking older than the reflog, prime anchors, and any wedged state are dropped). Your commits and files are untouched. |
| `git opstatus` | Show the current `HEAD` and how many undo / redo steps remain, for the shared log (`-g`/`--global`, default) or the current branch's edits (`-l`/`--local`). |

`git config undoredo.default` (`global`, the default, or `local`) governs the scope of a bare `git undo` / `git redo` / `git oplog` / `git opstatus`. `git config undoredo.oplog` (`full`, the default, or `compact`) sets the default `git oplog` view. `git config undoredo.color` (`auto`, the default, or `always` / `never`) controls colored output: `auto` colors only when writing to a terminal (and honors `NO_COLOR`), so piped output stays plain. Short flags can be bundled - `git oplog -lc` is `git oplog -l -c`, `git undo -ls` is
`git undo -l -s`, and so on (a count stays separate: `git undo -l 3`, not `-l3`).
Flags always override the config. Every command takes `-h` for help - use `-h`, not
`--help`, after `git undo`: git itself reserves `git <cmd> --help` for a manual-page
lookup (it never reaches this tool), so `git undo --help` reports "documentation file
not found" rather than showing help. (`-h` is passed straight through, and the binaries
also accept `--help` directly, e.g. `git-undo --help`.)

```console
$ git opstatus
HEAD is at: a1b2c3d Add login form
Available globally (undo: 4 · redo: 1)

$ git oplog
Global operation log (newest first; @ = current position):
     5  commit    e4f5a6b Wire up validation
 @   4  commit    a1b2c3d Add login form
     3  commit′   9c0ffee Refactor parser     ← prime mark (′): the state you resumed from when you acted after undoing
     2  commit    9c0ffee Refactor parser
     1  commit    1b2c3d4 Initial parser
     0  commit    0a1b2c3 Project skeleton
```

### Global vs local

Two undo scopes share the same model but answer different questions:

- **`git undo`** (global, the default) reverses your last *operation* (including
  branch switches, resets, and merges) and is branch-aware: it lands you back on
  the branch that op was on, recreating it if you'd deleted it, and never detaches.
- **`git undo -l`** (local) steps back one *edit* on the branch you're currently
  on, using that branch's own log. It only ever moves your branch, so you can hop
  to any branch and undo its last edit without being pulled elsewhere.

Global, when your last *operation* moved `HEAD` - say you switched from a
`feature` branch back to `main` (which sits at a different commit) - that switch
is what global undo reverses, landing you back on `feature`:

```console
$ git undo
↶ Undo (checkout) → 1f3a9c2 Add parser tests  (undo: 6 · redo: 1)
```

Local, on `main`, undoing the last *edit made on main* without leaving the branch
(its own log and counter):

```console
$ git undo --local
↶ Undo edit on main → 9c0ffee Refactor parser  (undo: 2 · redo: 1)

$ git oplog --local
Local edit log for 'main' (newest first; @ = current position):
     3  commit    7d1e0a4 Add login form
 @   2  commit    9c0ffee Refactor parser
     1  commit    1b2c3d4 Initial parser
     0  commit    0a1b2c3 Project skeleton

$ git opstatus --local
On branch main, HEAD is at: 9c0ffee Refactor parser
Available on this branch (undo: 2 · redo: 1)
```

### Keeping the changes (`git undo -s`, `git take`)

The classic "committed too early" fix: undo, but keep that commit's changes
**staged** to edit and re-commit, instead of reversing them.

```console
$ git undo -s
↶ Undo (commit) → 9d902ce Wire up validation  (undo: 1 · redo: 1)
   ↥ staged the changes from 62e6931 wip: half-done refactor - edit and re-commit
```

Already ran a plain `git undo` and *then* realized you wanted those changes back?
`git take` does the same after the fact - it stages the commit just above you,
without moving `HEAD`:

```console
$ git undo
↶ Undo (commit) → 9d902ce Wire up validation  (undo: 1 · redo: 1)

$ git take
↥ Took the changes from 62e6931 wip: half-done refactor - staged onto 9d902ce Wire up validation, edit and commit.
```

`git take N` reaches the `N`th commit above and stages its files *wholesale* (the
full snapshot - so only files that actually differ from where you are show up,
and you get that commit's version of each, not any in-between one).

## How it works

- **An oplog of operations.** All tracking lives in an orthogonal space, never
  polluting (or read back from) git's own ref/reflog space:
  - `.git/git-undo-redo/timeline` - the operation log: one line per op (`sha`,
    kind, and the branch it was on), oldest first. This is what undo/redo walk.
  - `.git/git-undo-redo/cursor` - where `HEAD` currently sits.
  - `refs/git-undo-redo/keep/<sha>` - one ref per state ever seen, so git's garbage
    collector can never reclaim an undone or abandoned commit.
- **Branch-aware, and never detaches.** Each op records the branch it was on, so
  undo/redo land you back on *that* branch. Undoing a branch-switch checkout just
  puts you back on the branch you were on; any other op moves that branch's tip.
  If the branch was deleted, it's recreated at the recorded commit - so you're
  never left on a detached HEAD.
- **Append-only with prime anchors.** The oplog is never truncated. Act after
  undoing back to a point `B` and it records a prime anchor `B′` then your new
  op, so undo lands where you made the change and the path you undid past is
  still there to walk back through. Nothing is ever lost.
- **Global and local logs (separation of concerns).** Alongside the shared
  operation log, each branch gets its own append-only edit log under
  `.git/git-undo-redo/local/<branch>/`, seeded from that branch's reflog and using
  the same cursor + prime model. `git undo -g` walks the shared log; `git undo -l`
  walks the current branch's edits and only ever moves that branch. The two are
  independent; each absorbs the other's effects through its own sync.
- **Seeded from the reflog, then maintained live.** On first use each log is
  stitched from the relevant reflog (HEAD's for global, the branch's for local),
  with the tool's own hops stripped - so even cold, the first `git undo` reverses
  your last real operation. After that it appends ops as you go; no hooks, no daemon.
- **The reflog stays useful as raw history.** The tool only *writes* labeled
  `git-undo:` / `git-redo:` entries and never reads the reflog for navigation,
  so `git reflog` remains a clean, durable backstop for anything older than the
  oplog or created between tool runs.

## Behavior notes

- **Clean tree required.** Undo/redo move `HEAD`, so they refuse to run with
  uncommitted changes to *tracked* files. Untracked files are fine.
- **Your working tree follows.** Undo/redo reset to the recorded state, so your *files*
  move with `HEAD` - which is exactly what makes recovering a bad `git reset --hard`
  work. It's a full reverse by default; if you instead want to *keep* the undone
  commit's changes to edit (the "committed too early" case), use `git undo --staged`
  / `-s`, which leaves them staged. Already undid without it? `git take` stages that
  commit's changes onto where you are now, no need to redo first.
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
- **Off-tool granularity (it samples, it doesn't hook).** With no hooks or daemon,
  git-undo-redo records the *net* change to `HEAD` since your last command. New
  **commits** between runs are stitched in individually (undo steps through them one
  at a time); a *divergent* move (reset / rebase / branch-switch) is recorded as a
  single step. (There's one excursion this can't see - see [Known limitations](#known-limitations).)

## Known limitations

One honest trade-off, a direct consequence of the design (no hooks, no daemon). **It
doesn't lose data.**

- **A between-command round-trip that returns to the same commit isn't tracked.**
  Because the tool *samples* `HEAD` on each command instead of using hooks, an excursion
  that happens entirely between two `git undo`-family commands and lands `HEAD` back on
  the same commit - branch off, commit on a side branch, switch back - leaves nothing for
  it to record, so `git undo` won't replay it. The side-branch work is safe (it's on its
  branch and in git's reflog; `git checkout <branch>` brings it back), and running any
  `git undo` / `redo` / `oplog` while you're on the side branch captures it normally.
  This is the price of having no background process. (The cold first-use seed, which
  reads the whole reflog, *does* see such excursions.)

(Undo reverting your working tree - rather than "uncommit and keep my changes" - used to
be listed here, but `git undo --staged` now covers that case: see the
[command table](#commands).)

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
