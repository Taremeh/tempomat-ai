#!/bin/sh
# Installs AI Tempomat: Apple's command line tools if they're missing, a clone of this
# repository, and the app built from it in ~/Applications. Run it with:
#
#   curl -fsSL https://raw.githubusercontent.com/Taremeh/tempomat-ai/main/scripts/install.sh | sh
#
# TEMPOMAT_DIR is the folder for the clone (~/tempomat-ai unless you set it), and TEMPOMAT_REPO
# the repository to clone. Running it again updates the clone and rebuilds the app.
#
# Everything is in functions and main runs on the last line, so a partly downloaded script does
# nothing. The functions are one block, which sh reads whole before it runs any of it, so a cut in
# the middle can't leave a word that runs as a command either (find, say). Piped to sh, the script
# itself is stdin, so every command that could read stdin gets </dev/null instead.

{

say() {
    printf '%s\n' "$*"
}

die() {
    printf '\n%s\n' "$*" >&2
    exit 1
}

check_mac() {
    if [ "$(uname -s)" != Darwin ]; then
        die "AI Tempomat is a macOS app, and this isn't a Mac."
    fi
    if [ "$(id -u)" = 0 ]; then
        die "Run this as yourself, without sudo: the app and its clone go into your home folder."
    fi
    macos=$(sw_vers -productVersion </dev/null) || macos=
    case ${macos%%.*} in
        '' | *[!0-9]*) die "Couldn't read the macOS version." ;;
    esac
    if [ "${macos%%.*}" -lt 14 ]; then
        die "AI Tempomat needs macOS 14 or later, and this Mac has macOS $macos."
    fi
}

# Swift and git come with Apple's command line tools. macOS installs them after asking in a dialog.
check_command_line_tools() {
    if xcode-select -p >/dev/null 2>&1 </dev/null; then
        return 0
    fi
    say "AI Tempomat is built from source, which needs Apple's command line tools."
    say "macOS asks whether to install them: click Install. This script goes on once they're in, and waits up to 30 minutes."
    xcode-select --install >/dev/null 2>&1 </dev/null || true
    waited=0
    while ! xcode-select -p >/dev/null 2>&1 </dev/null; do
        if [ "$waited" -ge 1800 ]; then
            die "The command line tools still aren't installed. Install them with xcode-select --install, then run this again."
        fi
        sleep 5
        waited=$((waited + 5))
    done
    say "The command line tools are installed."
}

# Package.swift needs Swift 6, which older command line tools don't have.
check_swift() {
    swift_said=$(swift --version 2>&1 </dev/null) || true
    swift_version=$(printf '%s\n' "$swift_said" | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -n 1)
    case ${swift_version%%.*} in
        '' | *[!0-9]*)
            if [ -z "$swift_said" ]; then
                die "Couldn't find Swift in the command line tools. Reinstall them with xcode-select --install, then run this again."
            fi
            case $swift_said in
                # Tools that a macOS update left behind: xcode-select still names them, but they're gone.
                *'xcrun: error'*)
                    die "The command line tools are incomplete, as often after a macOS update. Reinstall them with xcode-select --install, then run this again." ;;
            esac
            # Xcode's license not accepted yet, say. Swift's own words name the fix.
            die "Couldn't run Swift. swift --version said:
$(printf '%s\n' "$swift_said" | head -n 4)
Once that's sorted out, run this again."
            ;;
    esac
    if [ "${swift_version%%.*}" -lt 6 ]; then
        die "AI Tempomat needs Swift 6 or later, and this Mac has Swift $swift_version. Update the command line tools in System Settings > General > Software Update (or update Xcode, if that's what xcode-select -p shows), then run this again. If Software Update offers no newer tools, update macOS first: Apple's Swift 6 tools need macOS 14.5 or later."
    fi
}

# What a repository URL points to, to compare two of them: owner/name for a remote (https or ssh,
# with or without .git), or the full path for a repository on this Mac.
repo_id() (
    url=${1#file://}
    case $url in
        /* | ./* | ../*)
            cd "$url" 2>/dev/null && pwd -P || printf '%s\n' "$url"
            ;;
        *)
            url=${url%/}
            url=${url%.git}
            printf '%s\n' "$url" | tr ':' '/' | awk -F/ '{ print tolower($(NF - 1) "/" $NF) }'
            ;;
    esac
)

# Clones the repository into DIR, or updates the clone already there. Anything else in DIR is left alone.
get_source() {
    if [ ! -e "$DIR" ] && [ ! -L "$DIR" ]; then
        say "Cloning AI Tempomat into $DIR."
        git clone "$REPO" "$DIR" </dev/null || die "Couldn't clone $REPO. The lines above say why."
        return 0
    fi
    top=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null </dev/null) || top=
    if [ -z "$top" ] || [ "$(cd "$top" && pwd -P)" != "$(cd "$DIR" && pwd -P)" ]; then
        die "$DIR already exists and isn't a clone of AI Tempomat, so this script leaves it alone. Move it away, or clone somewhere else:
  curl -fsSL $SCRIPT_URL | TEMPOMAT_DIR=/path/to/folder sh"
    fi
    origin=$(git -C "$DIR" remote get-url origin 2>/dev/null </dev/null) || origin=
    if [ -z "$origin" ] || [ "$(repo_id "$origin")" != "$(repo_id "$REPO")" ]; then
        die "$DIR is a clone of ${origin:-another repository}, not of $REPO, so this script leaves it alone. Move it away, or clone somewhere else:
  curl -fsSL $SCRIPT_URL | TEMPOMAT_DIR=/path/to/folder sh"
    fi
    say "Updating the clone in $DIR."
    git -C "$DIR" pull --ff-only </dev/null ||
        die "Couldn't update $DIR with git pull --ff-only. The lines above say why. Once that's sorted out (changes of your own there, say), run this again."
}

build_and_install() {
    say "Building the app. The first build takes a few minutes."
    (cd "$DIR" && ./scripts/build-app.sh --install) </dev/null ||
        die "The build failed. The lines above say why. Once it's fixed, run this again, or ./scripts/build-app.sh --install in $DIR."
}

# The version a claude binary reports, such as 2.1.308, or nothing.
claude_version() {
    "$1" --version 2>/dev/null </dev/null | sed -n '1s/^\([0-9][0-9.]*\).*/\1/p'
}

# Whether version $1 is below version $2, number by number.
version_below() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | head -n 1)" = "$1" ]
}

# The claude binary AI Tempomat runs, into $claude and $claude_version: the claudePath setting if
# there is one, else the newest of the usual places and the copies bundled with the desktop app.
find_claude() {
    claude=
    claude_version=
    custom=$(defaults read local.ai-tempomat claudePath 2>/dev/null </dev/null) || custom=
    if [ -n "$custom" ]; then
        case $custom in
            "~/"*) custom=$HOME/${custom#"~/"} ;;
        esac
        # A setting whose binary is gone is passed over, as the app does.
        if [ -f "$custom" ] && [ -x "$custom" ]; then
            claude=$custom
            claude_version=$(claude_version "$custom") || claude_version=
            return 0
        fi
    fi
    for candidate in /opt/homebrew/bin/claude /usr/local/bin/claude \
        "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" "$HOME/.npm-global/bin/claude" \
        "$HOME/Library/Application Support/Claude/claude-code"/*/*/claude.app/Contents/MacOS/claude; do
        [ -f "$candidate" ] && [ -x "$candidate" ] || continue
        version=$(claude_version "$candidate") || version=
        # The app skips a copy that doesn't run.
        [ -n "$version" ] || continue
        if [ -z "$claude" ] || version_below "$claude_version" "$version"; then
            claude=$candidate
            claude_version=$version
        fi
    done
    [ -n "$claude" ]
}

# Whether claude is signed in to a Claude plan, as AI Tempomat checks it: yes, no, other (signed
# in some other way, such as a Console account) or unknown.
plan_login() (
    # Without what a parent Claude Code session exports, as the app runs it, so the CLI reports its own login.
    for name in $(env | sed -n 's/^\(CLAUDE[A-Za-z0-9_]*\)=.*/\1/p; s/^\(ANTHROPIC_[A-Za-z0-9_]*\)=.*/\1/p'); do
        if [ "$name" != CLAUDE_CONFIG_DIR ]; then unset "$name"; fi
    done
    cd /
    # A CLI without the auth command would take "auth status" for a prompt.
    if ! "$1" --help 2>/dev/null </dev/null | grep -q '^ *auth '; then
        echo unknown
        return 0
    fi
    status=$("$1" auth status 2>/dev/null </dev/null) || true
    if ! logged_in=$(printf '%s' "$status" | plutil -extract loggedIn raw -o - - 2>/dev/null); then
        echo unknown
        return 0
    fi
    method=$(printf '%s' "$status" | plutil -extract authMethod raw -o - - 2>/dev/null) || method=
    if [ "$logged_in" != true ]; then
        echo no
    elif [ "$method" = claude.ai ]; then
        echo yes
    else
        echo other
    fi
)

# Says what's left to do in the panel. The sign-in itself is the app's job, not this script's.
report_claude() {
    if ! find_claude; then
        elsewhere=$(command -v claude 2>/dev/null) || elsewhere=
        if [ -n "$elsewhere" ]; then
            # The app can't run this copy yet, so its login says nothing about the panel.
            say "Claude Code is at $elsewhere, where AI Tempomat doesn't look. If the panel offers Install Claude Code, you can point the app at this copy instead:"
            say "  defaults write local.ai-tempomat claudePath '$elsewhere'"
            say "After that, click Sign in in the panel if it asks."
        else
            say "Claude Code isn't installed yet. Click Install Claude Code in the panel: it runs Anthropic's installer in a Terminal window. Then click Sign in."
        fi
        return 0
    fi
    # Older versions don't report usage (the README's 2.1.29x).
    if [ -n "$claude_version" ] && version_below "$claude_version" 2.1.290; then
        say "Claude Code $claude_version is too old to report your limits. Update it with claude update (or your package manager), and the panel picks the new version up."
        return 0
    fi
    case $(plan_login "$claude") in
        yes) say "Claude Code is signed in to your Claude plan, so the panel shows your limits right away." ;;
        no) say "Claude Code isn't signed in to your Claude plan yet. Click Sign in in the panel, and approve in your browser." ;;
        other) say "Claude Code is signed in, but not to a Claude plan (a Console account, say). Click Sign in in the panel: it replaces that login with your plan's." ;;
        *) say "If the panel says Claude Code isn't signed in, click Sign in there." ;;
    esac
}

main() {
    set -eu
    # cd prints the folder it found through CDPATH, which would end up in $(cd … && pwd).
    unset CDPATH
    GIT_TERMINAL_PROMPT=0
    export GIT_TERMINAL_PROMPT
    DIR=${TEMPOMAT_DIR:-$HOME/tempomat-ai}
    REPO=${TEMPOMAT_REPO:-https://github.com/Taremeh/tempomat-ai.git}
    SCRIPT_URL=https://raw.githubusercontent.com/Taremeh/tempomat-ai/main/scripts/install.sh

    check_mac
    check_command_line_tools
    check_swift
    get_source
    DIR=$(cd "$DIR" && pwd)
    build_and_install

    say ""
    say "AI Tempomat is in your menu bar, at the top right of the screen. Click the gauge to open its panel."
    report_claude
    say "The app updates itself from $DIR (the Update button in the panel pulls and builds there), so keep that folder."
}

}

main "$@"
