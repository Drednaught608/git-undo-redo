#!/usr/bin/env bash
# SPDX-License-Identifier: MIT-0
#
# Installer for git-undo-redo - works the same on macOS, Linux, and Windows
# (Git-Bash / WSL). Installs five git subcommands: git undo, git redo,
# git oplog, git opstatus, git take.
#
# Usage:
#   Local (from a clone of this repo):
#       ./install.sh
#
#   Remote one-liner (works in Git-Bash on Windows too):
#       curl -fsSL https://raw.githubusercontent.com/Drednaught608/git-undo-redo/main/install.sh | bash
#
#   Options / env:
#       --bin DIR           install into DIR (default: $HOME/.local/bin)
#       --uninstall         remove the installed commands
#       GIT_UNDO_REDO_BIN   same as --bin
#       GIT_UNDO_REDO_SRC   URL to fetch git-undo-redo from when no local copy
#
set -euo pipefail

# Where the script is fetched from when there is no local copy beside us.
SRC_URL="${GIT_UNDO_REDO_SRC:-https://raw.githubusercontent.com/Drednaught608/git-undo-redo/main/git-undo-redo}"
BIN_DIR="${GIT_UNDO_REDO_BIN:-$HOME/.local/bin}"
PRIMARY="git-undo"
ALIASES=(git-redo git-oplog git-opstatus git-take)
ALL=("$PRIMARY" "${ALIASES[@]}")

# Did the user pin a directory (--bin / env)? If so we install exactly there;
# otherwise we may adopt an existing install's location to update it in place.
BIN_EXPLICIT=0
[ -n "${GIT_UNDO_REDO_BIN:-}" ] && BIN_EXPLICIT=1

# ANSI colors (same palette as git-undo-redo; empty = plain output). auto colors
# only to a TTY; honors NO_COLOR and `git config undoredo.color` (auto|always|never).
C_RESET="" C_OK="" C_ERR="" C_WARN="" C_INFO="" C_DIM=""
_init_colors() {
    case "$(git config --get undoredo.color 2>/dev/null || true)" in
        never)  return ;;
        always) ;;
        *)      { [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; } || return ;;
    esac
    local e=$'\033'
    C_RESET="$e[0m"
    C_OK="$e[38;2;87;227;137m"      # green  #57e389
    C_ERR="$e[38;2;255;82;119m"     # red    #ff5277
    C_WARN="$e[38;2;245;196;81m"    # amber  #f5c451
    C_INFO="$e[38;2;255;111;156m"   # pink   #ff6f9c
    C_DIM="$e[38;2;154;157;180m"    # grey   #9a9db4
}
_init_colors

die() { echo "${C_ERR}❌ $*${C_RESET}" >&2; exit 1; }

# ---- argument parsing -----------------------------------------------
DO_UNINSTALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --bin)        BIN_DIR="${2:?--bin needs a directory}"; BIN_EXPLICIT=1; shift 2 ;;
        --bin=*)      BIN_DIR="${1#*=}"; BIN_EXPLICIT=1; shift ;;
        --uninstall)  DO_UNINSTALL=1; shift ;;
        -h|--help)    sed -n '3,20p' "$0" 2>/dev/null || true; exit 0 ;;
        *)            die "Unknown option: $1" ;;
    esac
done

# ---- uninstall ------------------------------------------------------
if [ "$DO_UNINSTALL" -eq 1 ]; then
    removed=0
    for n in "${ALL[@]}"; do
        if [ -e "$BIN_DIR/$n" ] || [ -L "$BIN_DIR/$n" ]; then
            rm -f "$BIN_DIR/$n" && removed=$((removed + 1))
        fi
    done
    echo "${C_OK}🧹 Removed $removed command(s) from $BIN_DIR.${C_RESET}"
    echo "${C_DIM}   (Your repos' undo/redo tracking lives in each repo's .git and is untouched.)${C_RESET}"
    exit 0
fi

# ---- locate the source -----------------------------------------------
# Prefer a copy sitting next to this installer (i.e. a local clone); only
# fall back to downloading when piped through curl with no local file.
here=""
case "${BASH_SOURCE[0]:-}" in
    ""|-|/dev/stdin|/dev/fd/*|bash) here="" ;;            # piped via curl | bash
    *) here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" ;;
esac

tmp=""
cleanup() { [ -n "$tmp" ] && rm -f "$tmp"; }
trap cleanup EXIT

if [ -n "$here" ] && [ -f "$here/git-undo-redo" ]; then
    IMPL="$here/git-undo-redo"
    echo "${C_INFO}→ Installing from local file:${C_RESET} $IMPL"
else
    tmp="$(mktemp)"
    echo "${C_INFO}→ Downloading from:${C_RESET} $SRC_URL"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$SRC_URL" -o "$tmp" || die "Download failed (curl)."
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$tmp" "$SRC_URL" || die "Download failed (wget)."
    else
        die "Need curl or wget to download (or run this from a local clone)."
    fi
    [ -s "$tmp" ] || die "Downloaded file is empty."
    head -1 "$tmp" | grep -q '^#!' || die "Downloaded file doesn't look like the script."
    IMPL="$tmp"
fi

# ---- detect a prior install (treat re-runs as updates) ---------------
# Where is git-undo already, if anywhere? (on PATH, resolved to a real dir)
PRIOR="$(command -v "$PRIMARY" 2>/dev/null || true)"
PRIOR_DIR=""
[ -n "$PRIOR" ] && PRIOR_DIR="$(cd "$(dirname "$PRIOR")" 2>/dev/null && pwd)"

# If the user didn't pin a directory and there's an existing install in a
# different (writable) directory, update it in place - so the normal install
# command replaces whatever's already there instead of leaving two copies.
if [ "$BIN_EXPLICIT" -eq 0 ] && [ -n "$PRIOR_DIR" ] && [ "$PRIOR_DIR" != "$BIN_DIR" ] && [ -w "$PRIOR_DIR" ]; then
    echo "${C_INFO}→ Found an existing install at $PRIOR_DIR; updating it there.${C_RESET}"
    BIN_DIR="$PRIOR_DIR"
fi

# Is this an update (something already at the target) and, if so, a no-op?
UPDATING=0; UNCHANGED=0
if [ -e "$BIN_DIR/$PRIMARY" ]; then
    UPDATING=1
    cmp -s "$IMPL" "$BIN_DIR/$PRIMARY" 2>/dev/null && UNCHANGED=1
fi

# ---- install ---------------------------------------------------------
mkdir -p "$BIN_DIR" || die "Could not create $BIN_DIR"

# The primary is a real copy; the aliases are symlinks to it where the OS
# allows (so updates follow), falling back to copies (e.g. on Windows).
cp "$IMPL" "$BIN_DIR/$PRIMARY" || die "Could not write $BIN_DIR/$PRIMARY"
chmod +x "$BIN_DIR/$PRIMARY" 2>/dev/null || true

for n in "${ALIASES[@]}"; do
    rm -f "$BIN_DIR/$n"
    if ln -s "$PRIMARY" "$BIN_DIR/$n" 2>/dev/null; then
        :
    else
        cp "$BIN_DIR/$PRIMARY" "$BIN_DIR/$n"
    fi
    chmod +x "$BIN_DIR/$n" 2>/dev/null || true
done

if [ "$UPDATING" -eq 1 ] && [ "$UNCHANGED" -eq 1 ]; then
    echo "${C_OK}✅ Already up to date: ${ALL[*]}${C_RESET}"
    echo "${C_DIM}   in $BIN_DIR${C_RESET}"
elif [ "$UPDATING" -eq 1 ]; then
    echo "${C_OK}🔄 Updated: ${ALL[*]}${C_RESET}"
    echo "${C_DIM}   in $BIN_DIR${C_RESET}"
else
    echo "${C_OK}✅ Installed: ${ALL[*]}${C_RESET}"
    echo "${C_DIM}   into $BIN_DIR${C_RESET}"
fi

# Warn about any *other* copy still on PATH that this run didn't replace
# (e.g. an old install left behind when you point --bin somewhere new).
oldifs=$IFS; IFS=:
for d in $PATH; do
    if [ -n "$d" ] && [ "$d" != "$BIN_DIR" ] && [ -e "$d/$PRIMARY" ]; then
        echo "${C_WARN}⚠  Another copy is still on your PATH at $d/$PRIMARY${C_RESET}"
        echo "${C_DIM}   To remove it:  rm -f \"$d\"/git-{undo,redo,oplog,opstatus}${C_RESET}"
    fi
done
IFS=$oldifs

# ---- PATH check ------------------------------------------------------
# Print the manual instructions (the fallback when the user declines or there's
# no terminal to prompt at, e.g. piped through curl in a non-interactive shell).
print_path_instructions() {
    echo "    echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.bashrc   # bash / Git-Bash"
    echo "    echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc    # zsh (macOS default)"
    echo
    echo "Then restart your shell.  Then:  git undo -h"
}

case ":$PATH:" in
    *":$BIN_DIR:"*)
        echo
        echo "${C_OK}You're set.${C_RESET} Try:  git undo -h"
        ;;
    *)
        # Pick the rc file for the user's login shell.
        case "${SHELL:-}" in
            */zsh) RC="$HOME/.zshrc" ;;
            *)     RC="$HOME/.bashrc" ;;
        esac
        EXPORT_LINE="export PATH=\"$BIN_DIR:\$PATH\""

        echo
        echo "${C_WARN}⚠  $BIN_DIR is not on your PATH yet.${C_RESET}"

        # Ask, reading from the terminal even when this script is piped (curl | bash).
        # The subshell open-test detects a *usable* /dev/tty (a bare `[ -r /dev/tty ]`
        # can pass when there's no controlling terminal, then error on open) and
        # swallows the open error. No tty -> skip the prompt and print instructions.
        # Default is No; we only edit a shell file on an explicit yes.
        ans=""
        if ( exec 3</dev/tty ) 2>/dev/null; then
            printf "${C_DIM}   Add it to %s for you now? [y/N]${C_RESET} " "$RC"
            read -r ans < /dev/tty 2>/dev/null || ans=""
            echo
        fi

        case "$ans" in
            y|Y|yes|YES)
                if [ -f "$RC" ] && grep -qF "$BIN_DIR" "$RC" 2>/dev/null; then
                    echo "${C_DIM}   Already present in $RC - nothing to add.${C_RESET}"
                    echo "   To use it in ${C_INFO}this${C_RESET} terminal right now, run:"
                    echo "       ${C_INFO}$EXPORT_LINE${C_RESET}"
                elif printf '\n# Added by the git-undo-redo installer\n%s\n' "$EXPORT_LINE" >> "$RC" 2>/dev/null; then
                    echo "   ${C_OK}✅ Added to $RC${C_RESET} - new terminals will have it automatically."
                    echo "   To use it in ${C_INFO}this${C_RESET} terminal right now, run:"
                    echo "       ${C_INFO}$EXPORT_LINE${C_RESET}"
                    echo "   (a child process can't change this shell's PATH for you, so paste that once.)"
                else
                    echo "${C_WARN}   Could not write $RC. Add it yourself, then restart your shell:${C_RESET}"
                    echo
                    print_path_instructions
                fi
                ;;
            *)
                echo "   Add it yourself, then restart your shell:"
                echo
                print_path_instructions
                ;;
        esac
        ;;
esac
