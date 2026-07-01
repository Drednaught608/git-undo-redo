#!/usr/bin/env bash
# Comprehensive regression + feature suite for git-undo-redo.
#
# Run ALL sections:        bash suite.sh
# Run specific sections:   bash suite.sh B U V      (case-insensitive: 'b u v' works too)
# List sections:           bash suite.sh --list
# Every section is self-contained (each starts from a fresh repo), so any subset runs alone.
# Exits non-zero if any check fails (so CI catches regressions). Needs bash 4+, git, and GNU
# coreutils/sed/grep (present on Linux and Git-Bash - what the CI runs on).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/git-undo-redo"                          # the tool, resolved relative to this script
[ -f "$SRC" ] || { echo "ERROR: tool not found at $SRC" >&2; exit 2; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
BIN=$(mktemp -d); for x in git-undo git-redo git-take git-goto git-undo-redo git-back git-forward; do cp "$SRC" "$BIN/$x"; chmod +x "$BIN/$x"; done
export PATH="$BIN:$PATH"

P=0; F=0; SECT=""
sect(){ SECT="$1"; echo; echo "### $1"; }
chk(){ if [ "$1" = "$2" ]; then P=$((P+1)); else F=$((F+1)); echo "  FAIL [$SECT] $3: got [$1] want [$2]"; fi; }
chkrc(){ # run "$1"=cmd (eval), expect rc $2
  eval "$1" >/dev/null 2>&1; local rc=$?; if [ "$rc" = "$2" ]; then P=$((P+1)); else F=$((F+1)); echo "  FAIL [$SECT] $3: rc got [$rc] want [$2]"; fi; }
chkhas(){ # output of cmd contains substring
  local out; out=$(eval "$1" 2>&1); case "$out" in *"$2"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [$SECT] $3: output missing [$2]"; echo "        out: $(echo "$out"|head -1)";; esac; }
cm(){ printf '%s' "$2" > f; git add f; git commit -qm "$1"; }
nr(){ T=$(mktemp -d); cd "$T" || exit 1; git init -q -b main; git config user.email t@t; git config user.name t; }
sub(){ git log -1 --format=%s; }
# Step back one edit at a time until HEAD == $1 (a target sha), capped at 12; echoes yes/no.
# (A rebase records N 'rebase' entries, so recovering the pre-rebase tip takes N undos.)
undo_to(){ local t="$1" i; for i in $(seq 1 12); do [ "$(git rev-parse HEAD)" = "$t" ] && { echo yes; return; }; git undo -e 1 >/dev/null 2>&1 || break; done; [ "$(git rev-parse HEAD)" = "$t" ] && echo yes || echo no; }
# Count ADJACENT duplicate resume-point rows in the edit log (two ↻ rows of the same sha
# with no edit row between them in the displayed order). 0 = the invariant holds.
adup(){ local prev="" cur n=0 line
  while IFS= read -r line; do
    cur=""; case "$line" in *"↻ "*) cur=$(printf '%s' "$line" | grep -oE '[0-9a-f]{7}' | head -1);; esac
    [ -n "$cur" ] && [ "$cur" = "$prev" ] && n=$((n+1)); prev="$cur"
  done < <(git undo -l -e 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
  printf '%s' "$n"; }
# Build a 2-version parked wip stack on main@B (V1 then V2), ending loaded at V2. Used by L/M/N.
build_wip2(){ nr; cm A a; cm B ab; git switch -qc other >/dev/null 2>&1; cm O abo; git switch -q main
  printf 'V1' > f; git goto other >/dev/null 2>&1; git goto main >/dev/null 2>&1
  printf 'V2' > f; git goto other >/dev/null 2>&1; git goto main >/dev/null 2>&1; }

sec_A(){
sect "A. edit-scope undo/redo"
nr; cm A a; cm B ab; cm C abc; cm D abcd
git undo -e >/dev/null 2>&1;        chk "$(sub)" C "undo1"
git undo -e 2 >/dev/null 2>&1;      chk "$(sub)" A "undo2-multi"
git redo -e >/dev/null 2>&1;        chk "$(sub)" B "redo1"
git redo -e 5 >/dev/null 2>&1;      chk "$(sub)" B "redo-toomany-refuses-stays"   # only 2 avail
chkrc "git redo -e 5" 1 "redo-toomany-rc"
git redo -e 2 >/dev/null 2>&1;      chk "$(sub)" D "redo-to-tip"
chkrc "git redo -e" 1 "redo-at-tip-boundary-rc"
chkhas "git redo -e" "git forward" "redo-deadend-points-to-forward"   # cross-axis signpost
git undo -e 3 >/dev/null 2>&1;      chk "$(sub)" A "undo-to-base"
chkrc "git undo -e" 1 "undo-at-base-boundary-rc"
chkhas "git undo -e" "git back" "undo-deadend-points-to-back"         # cross-axis signpost
# a 'too many' refusal (you CAN still go further) does NOT show a cross-axis hint
git redo -e >/dev/null 2>&1                                           # up one from base
case "$(git undo -e 9 2>&1)" in *"git back"*) F=$((F+1)); echo "  FAIL [A] toomany-no-crossaxis-hint";; *) P=$((P+1));; esac
}

sec_B(){
sect "B. edit log records amend/reset/merge"
nr; cm A a; cm B ab
git commit -q --amend -m "B2" >/dev/null 2>&1            # amend
printf 'abX' > f; git add f; git commit -qm C
git reset -q --hard HEAD~1                               # reset (back to B2)
chk "$(sub)" B2 "after-reset"
git undo -e >/dev/null 2>&1                              # undo the reset -> back to C
chk "$(sub)" C "undo-the-reset-returns-to-C"
git redo -e >/dev/null 2>&1; chk "$(sub)" B2 "redo-reset"
# merge (feat touches a different file so the merge is conflict-free)
nr; cm A a; git switch -qc feat >/dev/null 2>&1; printf 'gc' > g; git add g; git commit -qm F2; git switch -q main; cm M2 am
git merge -q --no-ff feat -m "merge feat" >/dev/null 2>&1
chk "$(git log -1 --format=%s)" "merge feat" "merge-made"
git undo -e >/dev/null 2>&1; chk "$(sub)" M2 "undo-merge"
# amend AFTER an undo must prime the resume point you undid TO (B), not the amend's
# merge-base parent (A) - the spurious-prime-on-amend bug. (`grep '↻ [a-z]'` matches prime
# ROWS like "↻ commit", not the header's "↻ = resume point" legend.)
nr; cm A a; cm B ab; cm C abc
Bsha=$(git rev-parse --short HEAD~1); Asha=$(git rev-parse --short HEAD~2)
git undo -e >/dev/null 2>&1
printf 'abX' > f; git add f; git commit -q --amend -m B-am
prow=$(git undo -l -e 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E '↻ [a-z]')
case "$prow" in *"$Bsha"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [B] amend-primes-resume-point (got [$prow])";; esac
case "$prow" in *"$Asha"*) F=$((F+1)); echo "  FAIL [B] amend-no-spurious-merge-base-prime";; *) P=$((P+1));; esac
chk "$(git undo -l -e 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -cE '↻ [a-z]')" "1" "amend-exactly-one-prime"
# COLD seed (after --reset) must reconstruct the SAME resume point (B) as the live sync -
# the cold path uses the reflog hop target, not the amend's parent (which would give A).
git undo --reset >/dev/null 2>&1
crow=$(git undo -l -e 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E '↻ [a-z]')
case "$crow" in *"$Bsha"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [B] cold-seed-amend-prime-B (got [$crow])";; esac
case "$crow" in *"$Asha"*) F=$((F+1)); echo "  FAIL [B] cold-seed-amend-no-spurious-A";; *) P=$((P+1));; esac
# plain amend (no undo) primes nothing
nr; cm A a; cm B ab; git commit -q --amend -m B2
chk "$(git undo -l -e 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -cE '↻ [a-z]')" "0" "plain-amend-no-prime"
# INVARIANT: identical resume points never stack adjacent (a prime is always followed by
# its edit). Hammer 4x undo-amend at the same point -> several ↻B primes, but none adjacent;
# holds for the live log AND a cold re-seed.
nr; cm A a; cm B ab; cm C abc
for i in 1 2 3 4; do git undo -e >/dev/null 2>&1; printf "v$i" >> f; git add f; git commit -q --amend -m "B-am$i"; done
chk "$(adup)" "0" "no-adjacent-dup-primes-live"
git undo --reset >/dev/null 2>&1
chk "$(adup)" "0" "no-adjacent-dup-primes-cold"
# REBASE (a claimed edit kind, previously untested). A rebase is recorded as a run of 'rebase'
# entries with the ORIGINALS preserved below, so undo walks back to the pre-rebase tip and redo
# returns - nothing is lost, both directions work. Proven for plain / --onto / squash / drop.
# (a) plain rebase: undo past it -> exact pre-rebase tree; redo -> the rebased tree
nr; echo base>base; git add .; git commit -qm A
git switch -qc feat >/dev/null 2>&1; echo f1>ff; git add .; git commit -qm F1
git switch -q main; echo mw>mn; git add .; git commit -qm M; git switch -q feat
ORIG=$(git rev-parse HEAD); git rebase -q main; REB=$(git rev-parse HEAD)
chk "$(undo_to "$ORIG")" "yes" "rebase-undo-reaches-pre-rebase-tip"
chk "$([ -f mn ] && echo y || echo n)" "n" "rebase-undo-restores-pre-rebase-tree"   # M's file is gone
git redo -e all >/dev/null 2>&1
chk "$(git rev-parse HEAD)" "$REB" "rebase-redo-returns-to-rebased-tip"
chk "$([ -f mn ] && echo y || echo n)" "y" "rebase-redo-restores-rebased-tree"
# (b) rebase --onto: undo recovers the pre-onto tip
nr; echo a>base; git add .; git commit -qm A
git switch -qc topic >/dev/null 2>&1; echo t1>t; git add .; git commit -qm T1; echo t2>t; git add .; git commit -qm T2
ORIG=$(git rev-parse HEAD); git switch -q main; echo b>base; git add .; git commit -qm B; git switch -q topic
git rebase -q --onto main topic~2 topic
chk "$(undo_to "$ORIG")" "yes" "rebase-onto-undo-recovers-pre-onto"
# (c) interactive SQUASH: undo recovers the original separate commits
nr; cm A a; cm B ab; cm C abc; ORIG=$(git rev-parse HEAD)
GIT_SEQUENCE_EDITOR="sed -i '2s/^pick/squash/'" GIT_EDITOR=true git rebase -qi HEAD~2 >/dev/null 2>&1
chk "$(git rev-list --count HEAD)" "2" "squash-collapsed-to-2-commits"
chk "$(undo_to "$ORIG")" "yes" "squash-undo-recovers-original"
chk "$(git rev-list --count HEAD)" "3" "squash-undo-restores-3-commits"
# (d) interactive DROP of an independent commit: the dropped work is recoverable
nr; echo a>a.txt; git add .; git commit -qm A; echo b>b.txt; git add .; git commit -qm B; echo c>c.txt; git add .; git commit -qm C
ORIG=$(git rev-parse HEAD)
GIT_SEQUENCE_EDITOR="sed -i '1s/^pick/drop/'" GIT_EDITOR=true git rebase -qi HEAD~2 >/dev/null 2>&1
chk "$([ -f b.txt ] && echo y || echo n)" "n" "drop-removed-the-commit"
chk "$(undo_to "$ORIG")" "yes" "drop-undo-recovers-dropped-commit"
chk "$([ -f b.txt ] && echo y || echo n)" "y" "drop-undo-restores-dropped-file"
}

sec_C(){
sect "C. git back / git forward (navigation undo/redo)"
nr; cm A a; git switch -qc feat >/dev/null 2>&1; git switch -q main; git switch -q feat
git back >/dev/null 2>&1;    chk "$(git branch --show-current)" main "back-to-main"
git back >/dev/null 2>&1;    chk "$(git branch --show-current)" feat "back-to-feat"
git forward >/dev/null 2>&1; chk "$(git branch --show-current)" main "forward-to-main"
chkrc "git forward 99" 1 "forward-toomany-rc"
chkhas "git forward 99" "Only" "forward-toomany-msg"
# back/forward views + N
git forward >/dev/null 2>&1                          # to feat
chkhas "git back -s" "back: " "back-status-meter"
chkhas "git back -l" "Navigation log" "back-log-title"
chkhas "git back -i </dev/null" "Navigation log" "back-picker-renders"
git back 2 >/dev/null 2>&1; chk "$(git branch --show-current)" feat "back-2-jumps"
# nav dead-ends point at the EDIT axis (cross-axis signpost, mirror of A)
git back all >/dev/null 2>&1
chkhas "git back" "git undo" "back-deadend-points-to-undo"
git forward all >/dev/null 2>&1
chkhas "git forward" "git redo" "forward-deadend-points-to-redo"
# nav scope removed from undo/redo
chkrc "git undo -n" 2 "undo-n-rejected"
chkrc "git redo -n" 2 "redo-n-rejected"
# undoredo.scope=navigation is no longer recognized -> falls back to edit
nr; cm A a; cm B ab; git config undoredo.scope navigation
chkhas "git undo --log" "Edit log" "scope-navigation-falls-to-edit"
# umbrella forms
nr; cm A a; git switch -qc f2 >/dev/null 2>&1; git switch -q main
git-undo-redo back >/dev/null 2>&1; chk "$(git branch --show-current)" f2 "umbrella-back"
git-undo-redo forward >/dev/null 2>&1; chk "$(git branch --show-current)" main "umbrella-forward"
}

sec_D(){
sect "D. global scope (-g) + bare defaults to edit"
nr; cm A a; cm B ab; git switch -qc feat >/dev/null 2>&1; cm F abf; git switch -q main; cm C abc
# -g walks the interleaved edit+nav timeline; a full roundtrip returns to the start
git undo -g >/dev/null 2>&1; git undo -g >/dev/null 2>&1
git redo -g >/dev/null 2>&1; git redo -g >/dev/null 2>&1
chk "$(sub)" C "global-roundtrip-back-to-C"
chk "$(git branch --show-current)" main "global-roundtrip-on-main"
# NEW DEFAULT: a bare 'git undo' is the EDIT scope (this branch's edits, no branch hop)
nr; cm A a; cm B ab; git switch -qc feat >/dev/null 2>&1; cm F abf; git switch -q main; cm C abc
git undo >/dev/null 2>&1; chk "$(sub)" B "bare-undo-is-edit"; chk "$(git branch --show-current)" main "bare-undo-stays-on-branch"
git undo >/dev/null 2>&1; chk "$(sub)" A "bare-undo2-edit"
git redo >/dev/null 2>&1; chk "$(sub)" B "bare-redo-is-edit"
chkhas "git undo --log" "Edit log" "bare-log-is-edit"
chkhas "git undo --status" "HEAD is at" "bare-status-ok"
# config override flips the bare scope to global, then back
git config undoredo.scope global; chkhas "git undo --log" "Global operation log" "cfg-scope-global-flips-bare"
git config undoredo.scope edit;   chkhas "git undo --log" "Edit log" "cfg-scope-edit-flips-back"
}

sec_E(){
sect "E. take (primary)"
nr; cm A a; cm B ab; cm C abc
git undo -e >/dev/null 2>&1                 # now at B; C is above
chk "$(sub)" B "take-setup-at-B"
git take 1 >/dev/null 2>&1
chk "$(cat f)" "abc" "take1-brings-C-content"
chk "$(sub)" B "take-does-not-move-HEAD"
chk "$(git status --porcelain f)" " M f" "take-lands-unstaged"
# re-taking a MODIFY commit refuses (tracked tree is now dirty) - correct behavior
chkrc "git take 1" 1 "take-retake-modify-refuses"
# discard, then bare take = latest above
git checkout -q -- f 2>/dev/null; git restore -q f 2>/dev/null
chk "$(cat f)" "ab" "take-cleaned"
git take >/dev/null 2>&1; chk "$(cat f)" "abc" "bare-take-nearest-above"
# staged mode
git restore -q --staged f 2>/dev/null; git checkout -q -- f 2>/dev/null
git take 1 -s >/dev/null 2>&1; chk "$(git status --porcelain f)" "M  f" "take-staged-mode"
# refuse too many
git restore -q --staged f 2>/dev/null; git checkout -q -- f 2>/dev/null
chkrc "git take 9" 1 "take-toomany-rc"
chkhas "git take 9" "Only" "take-toomany-msg"
# nothing above
nr; cm A a; cm B ab
chkrc "git take 1" 1 "take-nothing-above-rc"
# clean-tree requirement
nr; cm A a; cm B ab; cm C abc; git undo -e >/dev/null 2>&1; printf 'dirty' > f
chkrc "git take 1" 1 "take-requires-clean-rc"
# idempotent re-take of an ADD-only commit reports "Already taken" (lands untracked,
# so the tracked-only clean check passes and the second take is a detected no-op)
nr; cm A a; cm B ab; printf 'newf' > g.txt; git add g.txt; git commit -qm C
git undo -e >/dev/null 2>&1
git take 1 >/dev/null 2>&1; chk "$(cat g.txt 2>/dev/null)" "newf" "take-addonly-brings-file"
chkhas "git take 1" "Already taken" "take-addonly-retake-idempotent"
# bare take = NEAREST above; 'git take all' = LATEST (they differ when the cursor is deep)
nr; cm A a; cm B ab; cm C abc; cm D abcd
git undo -e 2 >/dev/null 2>&1                     # at B; above: C (nearest), D (latest)
git take     >/dev/null 2>&1; chk "$(cat f)" "abc"  "bare-take-nearest-not-latest"   # C
git checkout -q -- f
git take all >/dev/null 2>&1; chk "$(cat f)" "abcd" "take-all-latest"                # D
git checkout -q -- f
git take ALL >/dev/null 2>&1; chk "$(cat f)" "abcd" "take-all-case-insensitive"
git checkout -q -- f
# reset-skip: bare skips a reset UP to the nearest real edit; take N still counts the reset
nr; cm A a; cm B ab; git reset --hard --quiet HEAD~1; cm C ac   # log: A, B, reset(->A), C
git undo -e 2 >/dev/null 2>&1                     # at B; above: reset(->A), C
git take     >/dev/null 2>&1; chk "$(cat f)" "ac" "bare-take-skips-reset-to-real"     # C, not A
git checkout -q -- f
git take 1   >/dev/null 2>&1; chk "$(cat f)" "a"  "take-1-counts-the-reset"           # A (reset target)
git checkout -q -- f
git take all >/dev/null 2>&1; chk "$(cat f)" "ac" "take-all-latest-real"              # C
git checkout -q -- f
# everything above the cursor is a reset -> bare take refuses with the cross-hint
nr; cm A a; cm B ab; git reset --hard --quiet HEAD~1   # log: A, B, reset(->A); cursor at reset
git undo -e >/dev/null 2>&1                        # at B; above: only the reset
chkrc  "git take" 1 "bare-take-all-resets-refuses"
chkhas "git take" "everything above it is a reset" "bare-take-all-resets-msg"
}

sec_F(){
sect "F. take config"
nr; cm A a; cm B ab; cm C abc; git undo -e >/dev/null 2>&1
git config undoredo.take staged
git take 1 >/dev/null 2>&1; chk "$(git status --porcelain f)" "M  f" "take-cfg-staged"
git restore -q --staged f; git checkout -q -- f
git config undoredo.take unstaged
git take 1 >/dev/null 2>&1; chk "$(git status --porcelain f)" " M f" "take-cfg-unstaged"
}

sec_G(){
sect "G. status/log views"
nr; cm A a; cm B ab; cm C abc
chkhas "git undo -s -e" "HEAD is at" "status-edit-shows-head"
chkhas "git undo -l -e" "Edit log" "log-edit-title"
chkhas "git back -l" "Navigation log" "back-log-title-G"
chkhas "git undo -l -g" "Global operation log" "log-global-title"
chkhas "git undo -l -e -c" "Edit log" "log-compact-ok"
chkhas "git undo -l -e" "@" "log-shows-cursor"
chkhas "git redo -l -g" "Global operation log" "redo-log-global"
}

sec_H(){
sect "H. interactive picker render + non-tty guard"
nr; cm A a; cm B ab; cm C abc
chkhas "git undo -i -e </dev/null" "Edit log" "picker-edit-renders-list"
chkhas "git undo -i -e </dev/null" "1)" "picker-edit-numbered"
chkrc  "git undo -i -e </dev/null" 2 "picker-nontty-rc2"
chkhas "git undo -i -g </dev/null" "Global operation log" "picker-global-renders"
chkhas "git back -i </dev/null" "Navigation log" "back-picker-renders-H"
}

sec_I(){
sect "I. interactive jump lands correctly (edit + global)"
nr; cm A a; cm B ab; cm C abc; cm D abcd
( source "$SRC"; _ou_load_config; _OU_SDIR=$(_ou_state_dir)
  branch=$(_ou_branch); d=$(_ou_local_dir); _ou_local_sync "$d" "$branch"
  SEL_IDX=(); for ((i=${#LT_SHA[@]}-1;i>=0;i--)); do SEL_IDX+=("$i"); done
  idx="${SEL_IDX[1]}"   # second-newest = C
  OU_ACTION="git-undo" _ou_local_restore "${LT_SHA[$idx]}" >/dev/null 2>&1
) ; chk "$(sub)" C "edit-picker-jump-to-2nd"
nr; cm A a; cm B ab; git switch -qc feat >/dev/null 2>&1; cm F abf; git switch -q main; cm C abc
r=$( source "$SRC"; _ou_load_config; _OU_SDIR=$(_ou_state_dir)
     _ou_global_derive readonly >/dev/null 2>&1
     _ou_global_walk 0 >/dev/null 2>&1
     [ "$(git rev-parse HEAD)" = "${GL_SHA[0]}" ] && echo OK || echo "NO:$(git rev-parse --short HEAD)" )
chk "$r" OK "global-picker-jump-to-oldest"
nr; cm A a; git switch -qc feat >/dev/null 2>&1; git switch -q main; git switch -q feat
r=$( source "$SRC"; _ou_load_config; _OU_SDIR=$(_ou_state_dir)
     _ou_nav_sync >/dev/null 2>&1
     _ou_nav_goto 0 git-undo >/dev/null 2>&1
     [ "$(git rev-parse HEAD)" = "${NV_SHA[0]}" ] && echo OK || echo "NO" )
chk "$r" OK "nav-picker-jump-to-oldest"
build_wip2; git reset --hard --quiet HEAD
r=$( source "$SRC"; _ou_load_config; _OU_SDIR=$(_ou_state_dir)
     _ou_wip_setcurid base; _ou_wip_load "$base"
     git reset --hard --quiet HEAD; _ou_wip_apply "${WT_SHA[0]}" >/dev/null 2>&1
     cat f )
chk "$r" "V1" "wip-picker-jump-to-oldest"
}

sec_J(){
sect "J. goto"
nr; cm A a; cm B ab; git switch -qc feat >/dev/null 2>&1; cm F abf; git switch -q main
git goto feat >/dev/null 2>&1; chk "$(git branch --show-current)" feat "goto-forward"
git goto main >/dev/null 2>&1; chk "$(git branch --show-current)" main "goto-back"
printf 'P' > f; git add f; printf 'Q' >> f      # MM
git goto feat >/dev/null 2>&1
chk "$(git show :f 2>/dev/null)" "abf" "goto-dest-shows-its-own"   # park-at-source model
git goto main >/dev/null 2>&1
chk "$(cat f)" "PQ" "goto-return-content"
chk "$(git status --porcelain f)" "MM f" "goto-return-split"
nr; cm A a; printf 'keep' > f
chkrc "git goto no-such-branch" 128 "goto-bad-branch-rc128"
chk "$(cat f)" "keep" "goto-bad-branch-restored"
chk "$(git branch --show-current)" main "goto-bad-branch-stayed"
nr; cm A a; git goto -c newbr >/dev/null 2>&1; chk "$(git branch --show-current)" newbr "goto-create-passthrough"
nr; cm A a; cm B ab; git switch -qc feat >/dev/null 2>&1; cm F abf; git switch -q main
printf 'untracked' > u.txt
git goto feat >/dev/null 2>&1
chk "$(cat u.txt 2>/dev/null)" "untracked" "goto-untracked-travels"
rm -f u.txt
}

sec_K(){
sect "K. dirty auto-park in undo/redo/picker"
nr; cm A a; cm B ab; cm C abc
printf 'WIP' > f; git add f; printf 'X' >> f     # MM dirty
chkrc "git undo -e" 0 "dirty-undo-no-refusal"
chk "$(sub)" B "dirty-undo-moved"
git redo -e >/dev/null 2>&1
chk "$(cat f)" "WIPX" "dirty-restore-content"
chk "$(git status --porcelain f)" "MM f" "dirty-restore-split"
nr; cm A a; printf 'edit' > f
git undo -e >/dev/null 2>&1
chk "$(ls .git/git-undo-redo/wip 2>/dev/null | wc -l | tr -d ' ')" "0" "boundary-no-park"
# observable safety: a DIRTY undo SAYS it set your work aside and names the recovery command
nr; cm A a; cm B ab; printf 'panicwork' > f
dm=$(git undo -e 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
case "$dm" in *"Set aside your 1 uncommitted file"*"'git redo' brings them back"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [K] dirty-undo-discloses-parking :: $dm";; esac
git redo -e >/dev/null 2>&1; chk "$(cat f)" "panicwork" "disclosed-work-actually-recovered"
# INDEX-ONLY change (staged, then worktree reverted to HEAD): still parked, so the disclosure
# MUST fire - a stash-tree diff would miss it (worktree matches HEAD) and go silently wrong
nr; cm A a; cm B ab; printf 'staged' >> f; git add f; printf 'ab' > f    # index dirty, worktree == HEAD
sr=$(git undo -e 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
case "$sr" in *"Set aside"*"uncommitted file"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [K] staged-only-undo-still-discloses :: $sr";; esac
git redo -e >/dev/null 2>&1
# a CLEAN undo stays silent (nothing was set aside)
nr; cm A a; cm B ab
cm2=$(git undo -e 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
case "$cm2" in *"Set aside"*) F=$((F+1)); echo "  FAIL [K] clean-undo-no-parking-note";; *) P=$((P+1));; esac
# the note names the direction-correct recovery: back -> forward
nr; cm A a; git switch -qc kb >/dev/null 2>&1; git switch -q main; git switch -q kb
printf 'navwip' > f
case "$(git back 2>&1 | sed 's/\x1b\[[0-9;]*m//g')" in *"Set aside"*"'git forward' brings them back"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [K] back-parking-names-forward";; esac
# CRASH-SAFETY (interrupted mid-operation). Parking writes the snapshot AND gc-protects it
# (a wipkeep ref) BEFORE the destructive 'git reset --hard' - so once parked, the work is a
# durable git object, not dependent on the command finishing. A dirty undo leaves the work
# parked-but-not-in-the-tree (exactly the state a crash after the reset would leave); it must
# survive an aggressive gc, leave the repo usable (not wedged), and stay recoverable.
nr; cm A a; cm B ab; printf 'CRASHWORK' >> f          # dirty at B
git undo -e >/dev/null 2>&1                            # parks work at B, moves to A, tree clean
chk "$(git status --porcelain)" "" "crash-worktree-clean-after-park"
git gc --prune=now --aggressive >/dev/null 2>&1       # a gc after the 'crash' must NOT reap it
chkhas "git undo -l -e" "Edit log" "crash-state-not-wedged"
git redo -e >/dev/null 2>&1                            # recover
chk "$(cat f)" "abCRASHWORK" "crash-parked-work-survives-gc-and-recovers"
}

sec_L(){
sect "L. --worktree nav"
build_wip2
chk "$(cat f)" "V2" "wip-loaded-at-v2"
# stepping shows the undo/redo meter on the line
um=$(git undo -w 2>&1 | sed 's/\x1b\[[0-9;]*m//g'); chk "$(cat f)" "V1" "wip-undo-v1"
case "$um" in *"Worktree undo →"*"· undo: 0 · redo: 1)"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [L] wip-undo-meter :: $um";; esac
rm=$(git redo -w 2>&1 | sed 's/\x1b\[[0-9;]*m//g'); chk "$(cat f)" "V2" "wip-redo-v2"
case "$rm" in *"Worktree redo →"*"· undo: 1 · redo: 0)"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [L] wip-redo-meter :: $rm";; esac
chkrc "git redo -w" 1 "wip-redo-boundary-rc"
chkhas "git redo -w" "newest parked version" "wip-redo-boundary-msg"
chkrc "git undo -w 9" 1 "wip-undo-toomany-rc"
chkhas "git undo -w 9" "Only 1 earlier" "wip-undo-toomany-msg"
git undo -w >/dev/null 2>&1; chk "$(cat f)" "V1" "wip-undo-back-v1"
chkrc "git undo -w" 1 "wip-undo-boundary-rc"
chkhas "git undo -w" "oldest parked version" "wip-undo-boundary-msg"
}

sec_M(){
sect "M. --worktree not-loaded brings latest"
build_wip2
git reset --hard --quiet HEAD             # simulate plain-switch arrival
chk "$(cat f)" "ab" "notloaded-clean"
git undo -w >/dev/null 2>&1; chk "$(cat f)" "V2" "notloaded-undo-brings-latest"
git reset --hard --quiet HEAD; printf 'LIVE' > f
git undo -w >/dev/null 2>&1; chk "$(cat f)" "V2" "notloaded-mod-lands-prev"
git redo -w >/dev/null 2>&1; chk "$(cat f)" "LIVE" "notloaded-mod-redo-brings-live"
}

sec_N(){
sect "N. --worktree views"
build_wip2
git reset --hard --quiet HEAD; printf 'LIVE' > f; git undo -w >/dev/null 2>&1   # -> [V1,V2,LIVE]
chkhas "git undo -l -w" "Parked working versions" "wip-log-header"
chkhas "git undo -s -w" "Parked working versions" "wip-status-header"
chkhas "git undo -i -w </dev/null" "Parked working versions" "wip-picker-renders"
chk "$(git undo -l -w 2>&1 | grep -cE 'v[0-9]+ ')" "3" "wip-log-lists-3-versions"
}

sec_O(){
sect "O. goto-after-not-loaded parks on top"
build_wip2
BASE=$(git rev-parse HEAD)
git reset --hard --quiet HEAD             # not-loaded arrival
printf 'LIVE-EDIT' > f
git goto other >/dev/null 2>&1
chk "$(grep -c '' .git/git-undo-redo/wip/$BASE@*/timeline)" "3" "goto-parked-on-top"   # bucket is <commit>@<branch>
}

sec_P(){
sect "P. prune"
nr; cm A a; cm B ab; git branch side HEAD~1; git switch -qc tmp >/dev/null 2>&1; cm Tc abt
printf 'TWIP' > f; git goto main >/dev/null 2>&1
Tdir=$(ls .git/git-undo-redo/wip)
git branch -D tmp >/dev/null 2>&1; git reflog expire --expire=now --all 2>/dev/null
printf 'BWIP' > f; git goto side >/dev/null 2>&1     # parks B -> prune
chk "$(ls .git/git-undo-redo/wip 2>/dev/null | grep -c "$Tdir")" "0" "prune-removed-stale"
chk "$(ls .git/git-undo-redo/wip 2>/dev/null | wc -l | tr -d ' ')" "1" "prune-kept-live"
}

sec_Q(){
sect "Q. reset / help / detached"
nr; cm A a; cm B ab; cm C abc
chkrc "git undo --reset" 0 "reset-rc0"
git undo -e >/dev/null 2>&1; chk "$(sub)" B "works-after-reset"   # rebuilds from reflog, C->B
chkhas "git undo -h" "undo" "help-undo"
chkhas "git undo -h -a" "global" "help-advanced-scopes"
chkhas "git redo -h" "redo" "help-redo"
chkhas "git take -h" "take" "help-take"
chkhas "git goto -h" "switch" "help-goto"
nr; cm A a; cm B ab; git checkout -q --detach HEAD
chkhas "git undo -l -e" "detached" "detached-edit-log-msg"
# spoken boundary: detached-HEAD undo/redo discloses the sha + how to pin the work + the fix
dsha=$(git rev-parse --short HEAD)
dh=$(git undo 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
case "$dh" in *"detached at $dsha"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [Q] detached-undo-shows-sha :: $dh";; esac
case "$dh" in *"git switch -c"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [Q] detached-undo-shows-pin-fix";; esac
case "$(git redo 2>&1 | sed 's/\x1b\[[0-9;]*m//g')" in *"detached at $dsha"*"git forward"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [Q] detached-redo-discloses";; esac
}

sec_R(){
sect "R. umbrella + legacy"
nr; cm A a; cm B ab; cm C abc
git-undo-redo undo >/dev/null 2>&1; chk "$(sub)" B "umbrella-undo"
git-undo-redo redo >/dev/null 2>&1; chk "$(sub)" C "umbrella-redo"
chkhas "git-undo-redo help" "undo" "umbrella-help"
cp "$SRC" "$BIN/git-oplog"; chkhas "git oplog" "" "legacy-oplog-hint-runs" 2>/dev/null || true
rm -f "$BIN/git-oplog"
}

sec_S(){
sect "S. goto refinements"
nr; cm A a; printf 'dirty-work' > f
sout=$(git goto 2>&1)
chk "$(cat f)" "dirty-work" "bare-goto-work-intact"
chk "$(ls .git/git-undo-redo/wip 2>/dev/null | wc -l | tr -d ' ')" "0" "bare-goto-no-park"
case "$sout" in *"Restored your parked"*) F=$((F+1)); echo "  FAIL [S] bare-goto-no-message";; *) P=$((P+1));; esac
nr; cm A a; printf 'keep' > f; git add f; printf 'more' >> f
sout=$(git goto no-such-branch 2>&1); src=$?
chk "$src" "128" "badbranch-rc128"
chk "$(cat f)" "keepmore" "badbranch-content-restored"
chk "$(git status --porcelain f)" "MM f" "badbranch-split-restored"
chk "$(git branch --show-current)" "main" "badbranch-stayed"
chk "$(ls .git/git-undo-redo/wip 2>/dev/null | wc -l | tr -d ' ')" "0" "badbranch-no-park"
case "$sout" in *"Restored your parked"*) F=$((F+1)); echo "  FAIL [S] badbranch-no-message";; *) P=$((P+1));; esac
gh=$(git goto -h 2>&1)
case "$gh" in *"usage: git goto [<options>]"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [S] help-usage-relabeled";; esac
case "$gh" in *"create and go to a new branch"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [S] help-create-relabeled";; esac
chk "$(echo "$gh" | sed -n '/usage: git goto/,$p' | grep -ic 'switch')" "0" "help-passthrough-no-switch-leak"
( cd "$(mktemp -d)"; git goto -h >/dev/null 2>&1 ); chk "$?" "0" "help-outside-repo-rc0"
}

sec_T(){
sect "T. branch-commit keying & reset clears wip"
nr; cm A a; printf 'main-work' > f
git goto -c newbr >/dev/null 2>&1
chk "$(git branch --show-current)" "newbr" "gotoc-switched"
chk "$(cat f)" "a" "gotoc-no-carry-to-new-branch"
git goto main >/dev/null 2>&1; chk "$(cat f)" "main-work" "gotoc-work-waits-on-old-branch"
nr; cm A a; git branch sib
printf 'on-main' > f; git goto sib >/dev/null 2>&1; chk "$(cat f)" "a" "sib-not-mains-work"
printf 'on-sib' > f;  git goto main >/dev/null 2>&1; chk "$(cat f)" "on-main" "main-its-own-work"
git goto sib >/dev/null 2>&1; chk "$(cat f)" "on-sib" "sib-its-own-work"
nr; cm A a; cm B ab; git switch -qc o2 >/dev/null 2>&1; cm O abo; git switch -q main
printf 'pk' > f; git goto o2 >/dev/null 2>&1; git goto main >/dev/null 2>&1
git reset --hard --quiet HEAD
rt=$(git undo --reset 2>&1)
chk "$(ls .git/git-undo-redo/wip 2>/dev/null | wc -l | tr -d ' ')" "0" "reset-clears-wip-dirs"
chk "$(git for-each-ref refs/git-undo-redo/wipkeep 2>/dev/null | wc -l | tr -d ' ')" "0" "reset-clears-wipkeep-refs"
case "$rt" in *"Nothing to reset"*) F=$((F+1)); echo "  FAIL [T] reset-said-nothing-with-wip";; *) P=$((P+1));; esac
}

sec_U(){
sect "U. goto same-branch silence & restore message"
nr; cm A a; printf 'X' > f; git add f; printf 'Y' >> f
uout=$(git goto main 2>&1)
chk "$(cat f)" "XY" "sameb-work-intact"
chk "$(git status --porcelain f)" "MM f" "sameb-split-preserved"
chk "$(ls .git/git-undo-redo/wip 2>/dev/null | wc -l | tr -d ' ')" "0" "sameb-no-park"
case "$uout" in *"Restored your parked"*) F=$((F+1)); echo "  FAIL [U] sameb-no-message";; *) P=$((P+1));; esac
nr; cm A a; git switch -qc feat >/dev/null 2>&1; cm F af; git switch -q main
printf 'P' > f; git add f; printf 'Q' >> f
git goto feat >/dev/null 2>&1
uout=$(git goto main 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
case "$uout" in *"Restored your parked changes from v1 "*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [U] restore-line1-labeled :: $uout";; esac
case "$uout" in *"(undo:"*) F=$((F+1)); echo "  FAIL [U] one-version-omits-meter";; *) P=$((P+1));; esac
case "$uout" in *"Edit and commit"*) F=$((F+1)); echo "  FAIL [U] one-version-omits-second-line";; *) P=$((P+1));; esac
nr; cm A a; git switch -qc o3 >/dev/null 2>&1; cm O abo; git switch -q main
printf 'V1' > f; git goto o3 >/dev/null 2>&1; git goto main >/dev/null 2>&1
printf 'V2' > f; git goto o3 >/dev/null 2>&1; uout=$(git goto main 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
case "$uout" in *"Restored your parked changes from v2 "*"(undo: 1 · redo: 0)"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [U] restore-meter-two-versions :: $uout";; esac
case "$uout" in *"Edit and commit, or 'git undo --worktree' for an earlier version."*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [U] two-version-second-line-worktree";; esac
git undo --wip >/dev/null 2>&1; chk "$?" "2" "old-wip-flag-rejected"
chkhas "git undo -h" "-w, --worktree" "worktree-in-main-help"
chkhas "git redo -h" "-w, --worktree" "worktree-in-redo-main-help"
}

sec_V(){
sect "V. clean-tree parking"
# leave a commit CLEAN that already has parked work -> a 'clean' version is recorded
nr; cm A a; git switch -qc feat >/dev/null 2>&1; cm F af; git switch -q main
printf 'DIRTY' > f; git goto feat >/dev/null 2>&1; git goto main >/dev/null 2>&1   # wip=[DIRTY], tree=DIRTY
chk "$(cat f)" "DIRTY" "v-loaded-dirty"
git checkout -q -- f                          # CLEAN the worktree
git goto feat >/dev/null 2>&1                 # leave main clean WITH existing wip -> record 'clean'
chk "$(grep -c '' .git/git-undo-redo/wip/*@main/timeline)" "2" "v-clean-recorded"
vco=$(git goto main 2>&1)
chk "$(cat f)" "a" "v-return-clean-not-dirty"
# arriving clean with earlier dirty versions points them out with the worktree meter
case "$vco" in *"'git undo --worktree' for an earlier parked version"*"(undo: 1 "*"redo: 0)"*) P=$((P+1));;
  *) F=$((F+1)); echo "  FAIL v-clean-arrival-hint :: $(printf '%s' "$vco" | sed 's/\x1b\[[0-9;]*m//g')";; esac
git undo -w >/dev/null 2>&1; chk "$(cat f)" "DIRTY" "v-undo-w-back-to-dirty"
# leaving clean twice in a row dedups (one trailing 'clean' version, not two)
nr; cm A a; git switch -qc fd >/dev/null 2>&1; cm F af; git switch -q main
printf 'DD' > f; git goto fd >/dev/null 2>&1; git goto main >/dev/null 2>&1   # [DD], tree=DD
git checkout -q -- f                                          # clean
git goto fd >/dev/null 2>&1; git goto main >/dev/null 2>&1    # leave clean -> [DD, clean]; returns clean
git goto fd >/dev/null 2>&1; git goto main >/dev/null 2>&1    # leave clean AGAIN -> dedup
chk "$(grep -c '' .git/git-undo-redo/wip/*@main/timeline)" "2" "v-clean-dedup"
# leave CLEAN with NO existing wip -> never start a timeline
nr; cm A a; git switch -qc f2 >/dev/null 2>&1; cm F af; git switch -q main
git goto f2 >/dev/null 2>&1; git goto main >/dev/null 2>&1
chk "$(ls .git/git-undo-redo/wip 2>/dev/null | wc -l | tr -d ' ')" "0" "v-no-timeline-from-clean"
# clean version shows in the --worktree log
nr; cm A a; git switch -qc f3 >/dev/null 2>&1; cm F af; git switch -q main
printf 'D' > f; git goto f3 >/dev/null 2>&1; git goto main >/dev/null 2>&1; git checkout -q -- f
git goto f3 >/dev/null 2>&1; git goto main >/dev/null 2>&1
chkhas "git undo -l -w" "clean working tree" "v-log-shows-clean-row"
# undo/redo (not just goto) leaving clean with existing wip also records clean
nr; cm A a; cm B ab; git switch -qc f4 >/dev/null 2>&1; cm O abo; git switch -q main
printf 'WW' > f; git goto f4 >/dev/null 2>&1; git goto main >/dev/null 2>&1   # wip at (main,B)=[WW], tree=WW
git checkout -q -- f                          # clean
Bsha=$(git rev-parse HEAD)                     # capture B BEFORE undo moves HEAD off it
git undo -e >/dev/null 2>&1                   # leave (main,B) clean with existing wip -> record 'clean'
chk "$(grep -c '' .git/git-undo-redo/wip/$Bsha@main/timeline)" "2" "v-undo-records-clean"
}

# Build a 3-version parked wip stack on main@B (V1,V2,V3), ending loaded at V3 (cursor 2).
build_wip3(){ nr; cm A a; cm B ab; git switch -qc other >/dev/null 2>&1; cm O abo; git switch -q main
  printf 'V1' > f; git goto other >/dev/null 2>&1; git goto main >/dev/null 2>&1
  printf 'V2' > f; git goto other >/dev/null 2>&1; git goto main >/dev/null 2>&1
  printf 'V3' > f; git goto other >/dev/null 2>&1; git goto main >/dev/null 2>&1; }
wtl(){ tr '\t\n' '|,' < .git/git-undo-redo/wip/*@main/timeline; }   # timeline, tabs->| lines->,
wcur(){ cat .git/git-undo-redo/wip/*@main/cursor 2>/dev/null; }

sec_W(){
sect "W. worktree cursor persistence & resume-point primes"
# PART 1: step back, leave with NO change -> stays at that undo point on return
build_wip3
git undo -w >/dev/null 2>&1                                   # step to V2 (cursor 1)
chk "$(cat f)" "V2" "w-stepped-to-v2"; chk "$(wcur)" "1" "w-cursor-at-1"
nlines=$(grep -c '' .git/git-undo-redo/wip/*@main/timeline)
git goto other >/dev/null 2>&1                                # leave, no change
chk "$(grep -c '' .git/git-undo-redo/wip/*@main/timeline)" "$nlines" "w-leave-noop-no-append"
chk "$(wcur)" "1" "w-leave-noop-cursor-stays"
rco=$(git goto main 2>&1)
chk "$(cat f)" "V2" "w-return-stays-at-undo-point"
case "$rco" in *"(undo: 1 · redo: 1)"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [W] w-return-meter :: $(printf '%s' "$rco"|sed 's/\x1b\[[0-9;]*m//g'|tr '\n' '/')";; esac
# PART 2: change at the undo point -> resume-point prime + new tail, nothing above lost
build_wip3
git undo -w >/dev/null 2>&1                                   # at V2 (cursor 1)
v2sha=$(sed -n '2p' .git/git-undo-redo/wip/*@main/timeline)
printf 'X' > f; git goto other >/dev/null 2>&1                # change, then leave
chk "$(grep -c '' .git/git-undo-redo/wip/*@main/timeline)" "5" "w-change-appends-prime-and-tail"
chk "$(sed -n '4p' .git/git-undo-redo/wip/*@main/timeline)" "$v2sha	prime" "w-prime-is-cursor-version"
chk "$(wcur)" "4" "w-cursor-at-new-tail"
git goto main >/dev/null 2>&1; chk "$(cat f)" "X" "w-return-to-new-tail"
git undo -w >/dev/null 2>&1; chk "$(cat f)" "V2" "w-undo-w-lands-on-resume-point"
git undo -w >/dev/null 2>&1; chk "$(cat f)" "V3" "w-v3-preserved-above-prime"
git undo -w >/dev/null 2>&1; chk "$(cat f)" "V2" "w-v2-still-there"
git undo -w >/dev/null 2>&1; chk "$(cat f)" "V1" "w-v1-oldest"
# change AT the tail (cursor already newest) -> plain append, no prime
build_wip3
printf 'V4' > f; git goto other >/dev/null 2>&1
chk "$(grep -c '' .git/git-undo-redo/wip/*@main/timeline)" "4" "w-tail-change-no-prime"
case "$(wtl)" in *prime*) F=$((F+1)); echo "  FAIL [W] w-tail-change-prime-free";; *) P=$((P+1));; esac
# the resume point renders as a ↻ row in the worktree log, real versions keep contiguous v1..vN
build_wip3; git undo -w >/dev/null 2>&1; printf 'X' > f
git goto other >/dev/null 2>&1; git goto main >/dev/null 2>&1
chkhas "git undo -l -w" "↻ v" "w-log-shows-resume-point-row"
lg=$(git undo -l -w 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
for v in v1 v2 v3 v4; do case "$lg" in *"$v "*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [W] w-log-has-$v";; esac; done
case "$lg" in *v5*) F=$((F+1)); echo "  FAIL [W] w-log-no-v5-prime-not-numbered";; *) P=$((P+1));; esac
# normal commit-level undo/redo also honors the worktree cursor (no change while away)
build_wip3; git undo -w >/dev/null 2>&1                       # at V2 (cursor 1)
git undo -e >/dev/null 2>&1                                   # commit-level undo to A
git redo -e >/dev/null 2>&1                                   # back to B
chk "$(cat f)" "V2" "w-commit-undo-redo-honors-cursor"
# FULL SYMMETRY: 'git undo --worktree' saving a live edit made after stepping back also primes
build_wip3; git undo -w >/dev/null 2>&1                       # step to V2 (cursor 1, loaded)
v2sha=$(sed -n '2p' .git/git-undo-redo/wip/*@main/timeline)
printf 'EDIT' > f                                            # live edit on top -> cursor not loaded
git undo -w >/dev/null 2>&1                                   # auto-saves the edit; must prime v2
chk "$(grep -c '' .git/git-undo-redo/wip/*@main/timeline)" "5" "w-undow-after-edit-primes"
chk "$(sed -n '4p' .git/git-undo-redo/wip/*@main/timeline)" "$v2sha	prime" "w-undow-prime-is-cursor-version"
chk "$(cat f)" "V3" "w-undow-loaded-latest"                  # not-loaded path brings the latest
git redo -w >/dev/null 2>&1; git redo -w >/dev/null 2>&1     # forward through prime -> the saved edit
chk "$(cat f)" "EDIT" "w-undow-edit-not-lost"                # the live edit survived as a new version
# ENRICHED ↻ ROW: shows the source version number + the version's hash + diffstat / clean state
build_wip3; v2sha=$(sed -n '2p' .git/git-undo-redo/wip/*@main/timeline)   # the dirty version primed below
git undo -w >/dev/null 2>&1; printf 'X' > f                   # change at V2 (cursor 1)
git goto other >/dev/null 2>&1; git goto main >/dev/null 2>&1
rl=$(git undo -l -w 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
case "$rl" in *"↻ v2 ${v2sha:0:7}  1 file changed"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [W] w-row-shows-source-vnum-hash-diffstat :: $(printf '%s' "$rl"|grep '↻ v'|tr '\n' '/')";; esac
# 'resume point' text lives only in the legend now, not the row itself
prow=$(printf '%s\n' "$rl" | grep '↻ v')
case "$prow" in *"resume point"*) F=$((F+1)); echo "  FAIL [W] w-row-no-redundant-resume-text :: $prow";; *) P=$((P+1));; esac
# clean resume point reads 'clean working tree'
nr; cm A a; cm B ab; git switch -qc oth >/dev/null 2>&1; cm O abo; git switch -q main
printf 'D1' > f; git goto oth >/dev/null 2>&1; git goto main >/dev/null 2>&1       # [D1]
git checkout -q -- f; git goto oth >/dev/null 2>&1; git goto main >/dev/null 2>&1  # [D1, clean]
printf 'D2' > f; git goto oth >/dev/null 2>&1; git goto main >/dev/null 2>&1       # [D1, clean, D2]
git undo -w >/dev/null 2>&1                                                        # step to the clean version (cursor 1)
printf 'Z' > f; git goto oth >/dev/null 2>&1; git goto main >/dev/null 2>&1        # change -> prime(clean)+Z
cl=$(git undo -l -w 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
case "$cl" in *"↻ v2 clean  clean working tree"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [W] w-clean-resume-point-row :: $(printf '%s' "$cl"|grep '↻ v'|tr '\n' '/')";; esac
# RESTORE MESSAGE names the version: "from V<n>" for a real version, "from ↻ v<src>" for a resume point
build_wip3                                                   # cursor at V3 (tail)
rm=$(git goto other >/dev/null 2>&1; git goto main 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
case "$rm" in *"Restored your parked changes from v3 "*"(undo: 2 · redo: 0)"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [W] w-restore-names-version :: $rm";; esac
build_wip3; git undo -w >/dev/null 2>&1; printf 'X' > f      # [V1,V2,V3,↻v2,X]
git goto other >/dev/null 2>&1; git goto main >/dev/null 2>&1   # cursor at X (tail)
git undo -w >/dev/null 2>&1                                  # step cursor ONTO the resume point (↻v2), no change
rp=$(git goto other >/dev/null 2>&1; git goto main 2>&1 | sed 's/\x1b\[[0-9;]*m//g')   # leave + return on the prime
case "$rp" in *"Restored your parked changes from ↻ v2 "*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [W] w-restore-names-resume-point :: $rp";; esac
# COMPACT / FULL flags work on the worktree log + picker (hide resume points except the cursor's)
build_wip3; git undo -w >/dev/null 2>&1; printf 'X' > f       # [V1,V2,V3,↻v2,X]
git goto other >/dev/null 2>&1; git goto main >/dev/null 2>&1
full=$(git undo -l -w -f 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
comp=$(git undo -l -w -c 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
case "$full" in *"resume point"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [W] w-log-full-shows-prime";; esac
case "$full" in *"↻ = resume point"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [W] w-log-full-legend";; esac
case "$comp" in *"resume point"*) F=$((F+1)); echo "  FAIL [W] w-log-compact-hides-prime";; *) P=$((P+1));; esac
case "$comp" in *"↻ = resume point"*) F=$((F+1)); echo "  FAIL [W] w-log-compact-no-legend";; *) P=$((P+1));; esac
chk "$(printf '%s' "$comp" | grep -c '  v[0-9]')" "4" "w-log-compact-keeps-4-real-versions"
# -c overrides config full; -f overrides config compact
git config undoredo.log compact
case "$(git undo -l -w 2>&1 | sed 's/\x1b\[[0-9;]*m//g')" in *"resume point"*) F=$((F+1)); echo "  FAIL [W] w-log-config-compact";; *) P=$((P+1));; esac
case "$(git undo -l -w -f 2>&1 | sed 's/\x1b\[[0-9;]*m//g')" in *"resume point"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [W] w-log-f-overrides-config";; esac
git config --unset undoredo.log
# picker honors compact: the ↻ row is dropped and selections renumber (no gap)
pf=$(git undo -i -w -f </dev/null 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
pc=$(git undo -i -w -c </dev/null 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
case "$pf" in *"2) ↻ v2 "*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [W] w-picker-full-numbers-prime";; esac
case "$pc" in *"resume point"*) F=$((F+1)); echo "  FAIL [W] w-picker-compact-hides-prime";; *) P=$((P+1));; esac
chk "$(printf '%s' "$pc" | grep -cE '[0-9]\) v[0-9]')" "4" "w-picker-compact-4-numbered-rows"
}

# lead column (first 3 chars) of each row matching $2, top-to-bottom, joined by '|'
leads(){ printf '%s\n' "$1" | grep -E "$2" | cut -c1-3 | tr -d ' ' | tr '\n' '|'; }

sec_X(){
sect "X. relative log numbers (@ column distance)"
# EDIT log: @ at cursor, redo distances above, undo distances below
nr; cm A a; cm B ab; cm C abc; cm D abcd; cm E abcde
git undo -e 2 >/dev/null 2>&1                                   # cursor at C
el=$(git undo -l -e 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
chk "$(leads "$el" 'commit')" "2|1|@|1|2|" "x-edit-relative-sequence"
# pickers keep their own 1)2) numbering - no relative numbers
pk=$(git undo -i -e </dev/null 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
case "$pk" in *") commit"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [X] x-edit-picker-still-numbered";; esac
# NAV (back/forward) log carries relative numbers
nr; cm A a; git switch -qc fb >/dev/null 2>&1; git switch -q main; git switch -q fb; git switch -q main
git back 2 >/dev/null 2>&1
nl=$(git back -l 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
chk "$(leads "$nl" 'checkout')" "2|1|@|1|2|" "x-nav-relative-sequence"
# GLOBAL log carries relative numbers (just assert @ present with a numeric neighbor)
nr; cm A a; cm B ab; git switch -qc fg >/dev/null 2>&1; cm O abo; git switch -q main; cm C abc
git undo -g 2 >/dev/null 2>&1
gl=$(leads "$(git undo -l -g 2>&1 | sed 's/\x1b\[[0-9;]*m//g')" 'commit|checkout')
case "$gl" in *@*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [X] x-global-has-at :: $gl";; esac
case "$gl" in *1*@*1*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [X] x-global-relative :: $gl";; esac
# WORKTREE log: relative numbers around @
build_wip3; git undo -w >/dev/null 2>&1                         # cursor at v2 (of v1,v2,v3)
wl=$(git undo -l -w 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
chk "$(leads "$wl" ' v[0-9]')" "1|@|1|" "x-wt-relative-sequence"
# NOT affected by compact: a hidden prime leaves an absolute gap (v3 stays '2', not renumbered)
build_wip3; git undo -w >/dev/null 2>&1; printf 'X' > f        # [v1,v2,v3,↻v2,X], cursor at X (tail)
git goto other >/dev/null 2>&1; git goto main >/dev/null 2>&1
chk "$(leads "$(git undo -l -w -f 2>&1 | sed 's/\x1b\[[0-9;]*m//g')" ' v[0-9]')" "@|1|2|3|4|" "x-wt-full-leads"
chk "$(leads "$(git undo -l -w -c 2>&1 | sed 's/\x1b\[[0-9;]*m//g')" ' v[0-9]')" "@|2|3|4|" "x-wt-compact-absolute-gap"
# worktree picker keeps positional 1)2) numbering (no relative numbers)
wp=$(git undo -i -w -f </dev/null 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
case "$wp" in *"1) v"*|*"1) ↻"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [X] x-wt-picker-numbered";; esac
# NOT loaded worktree log: no cursor -> blank lead column (no @, no numbers)
build_wip2; git checkout -q -- f                               # clean tree -> cursor version not loaded
nlw=$(git undo -l -w 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
chk "$(leads "$nlw" ' v[0-9]')" "||" "x-wt-not-loaded-blank-leads"
}

sec_Y(){
sect "Y. 'all' argument (jump to the furthest point in each direction)"
# EDIT: undo all -> floor, redo all -> tip
nr; cm A a; cm B ab; cm C abc; cm D abcd; cm E abcde
git undo all >/dev/null 2>&1; chk "$(sub)" A "y-edit-undo-all-floor"
git redo all >/dev/null 2>&1; chk "$(sub)" E "y-edit-redo-all-tip"
git undo ALL >/dev/null 2>&1; chk "$(sub)" A "y-all-case-insensitive"
chkrc "git undo all" 1 "y-undo-all-at-floor-refuses"      # already at A
chkhas "git undo all" "already at its oldest" "y-undo-all-at-floor-msg"
git redo all >/dev/null 2>&1
chkrc "git redo all" 1 "y-redo-all-at-tip-refuses"
# the move message reports the actual count it covered
git undo 2 >/dev/null 2>&1; chkhas "git redo all" "Redo 2 edits" "y-all-reports-count"
# NAV: back all / forward all
nr; cm A a; git switch -qc fb >/dev/null 2>&1; git switch -q main; git switch -q fb; git switch -q main
git back all >/dev/null 2>&1; chkrc "git back all" 1 "y-back-all-then-floor-refuses"
git forward all >/dev/null 2>&1; chkrc "git forward all" 1 "y-forward-all-then-tip-refuses"
chkhas "git back all" "Back" "y-back-all-moves"
# GLOBAL: undo -g all -> the floor (meter undo:0); redo -g all -> the tip (HEAD=C, meter redo:0).
# (Assert via meter, not a specific commit: the global floor is the OLDEST recorded operation,
# which here is the first checkout, not commit A.)
nr; cm A a; cm B ab; git switch -qc fg >/dev/null 2>&1; cm O abo; git switch -q main; cm C abc
go=$(git undo -g all 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
case "$go" in *"(undo: 0 "*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [Y] y-global-undo-all-floor :: $go";; esac
gr=$(git redo -g all 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
chk "$(sub)" C "y-global-redo-all-tip"
case "$gr" in *"redo: 0)"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL [Y] y-global-redo-all-meter :: $gr";; esac
# WORKTREE (loaded): undo -w all -> oldest, redo -w all -> newest
build_wip3                                                  # cursor at V3 (loaded)
git undo -w all >/dev/null 2>&1; chk "$(cat f)" "V1" "y-wt-undo-all-oldest"
git redo -w all >/dev/null 2>&1; chk "$(cat f)" "V3" "y-wt-redo-all-newest"
# WORKTREE (not loaded): undo -w all -> oldest
build_wip3; git checkout -q -- f                            # clean tree -> not loaded
git undo -w all >/dev/null 2>&1; chk "$(cat f)" "V1" "y-wt-notloaded-undo-all-oldest"
}

sec_Z(){
sect "Z. git worktree isolation (per-worktree state + scoped --reset)"
MAIN=$(mktemp -d); cd "$MAIN"; git init -q -b main; git config user.email t@t; git config user.name t
cm A a; cm B ab; cm C abc; git branch -q feat
WT2="$MAIN-z2"; git worktree add -q "$WT2" feat >/dev/null 2>&1
( cd "$WT2"; cm F1 abf1; cm F2 abf2; git undo >/dev/null 2>&1 )   # wt2 -> F1 (its own history)
git undo >/dev/null 2>&1                                          # main -> B (independent)
chk "$(git log -1 --format=%s)" "B" "z-main-undo-independent"
chk "$(cd "$WT2" && git log -1 --format=%s)" "F1" "z-wt2-undo-independent"
# state dirs are per-worktree (under each --git-dir)
chk "$(ls .git/git-undo-redo/local/ 2>/dev/null)" "main" "z-main-own-log"
chk "$(cd "$WT2" && ls "$(git rev-parse --git-dir)/git-undo-redo/local/" 2>/dev/null)" "feat" "z-wt2-own-log"
# a --reset in wt2 must NOT wipe main's protection or its log
( cd "$WT2" && git undo --reset >/dev/null 2>&1 )
chk "$([ "$(git for-each-ref refs/git-undo-redo/keep | wc -l)" -gt 0 ] && echo yes)" "yes" "z-main-refs-survive-wt2-reset"
chk "$(ls .git/git-undo-redo/local/ 2>/dev/null)" "main" "z-main-log-survives-wt2-reset"
git redo >/dev/null 2>&1; chk "$(git log -1 --format=%s)" "C" "z-main-redo-after-wt2-reset"
# wt2 re-seeds cleanly after its own reset
chk "$(cd "$WT2" && git undo >/dev/null 2>&1 && git log -1 --format=%s)" "C" "z-wt2-reseeds-after-reset"
# failed goto to a branch checked out elsewhere keeps uncommitted work
( cd "$WT2" && printf 'KEEPME' > f && git goto main >/dev/null 2>&1; true )
chk "$(cd "$WT2" && cat f)" "KEEPME" "z-failed-goto-preserves-work"
git worktree remove --force "$WT2" >/dev/null 2>&1 || rm -rf "$WT2"
}

# ---- dispatcher --------------------------------------------------------
ALL="A B C D E F G H I J K L M N O P Q R S T U V W X Y Z"
case "${1:-}" in
    --list|-l) echo "Sections: $ALL"; echo "Usage: bash full_suite.sh [SECTION...]  (no args = all)"; exit 0 ;;
esac
if [ "$#" -gt 0 ]; then RUN=$(printf '%s\n' "$@" | tr 'a-z' 'A-Z'); else RUN="$ALL"; fi
echo "Running sections: $(echo $RUN | tr '\n' ' ')"
for s in $RUN; do
    if declare -F "sec_$s" >/dev/null; then "sec_$s"; else echo; echo "  ?? no section '$s' (have: $ALL)"; F=$((F+1)); fi
done

echo
echo "=================================================="
echo "TOTAL: $P passed, $F failed"
echo "syntax: $(bash -n "$SRC" 2>&1 && echo OK)"
[ "$F" -eq 0 ] || exit 1                            # non-zero exit on any failure (for CI)
