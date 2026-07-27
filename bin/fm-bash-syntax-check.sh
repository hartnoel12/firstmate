#!/usr/bin/env bash
# fm-bash-syntax-check.sh - parse every canonical shell root under a chosen Bash.
#
# Firstmate ships to macOS fleets, where /bin/bash is Bash 3.2.57. Bash 3.2's
# parser is stricter than Bash 4/5 in one way that matters here: it tracks quote
# state through a heredoc body while scanning for the closing `)` of a command
# substitution. So this parses under Bash 5 and fails under Bash 3.2:
#
#     TEXT=$(cat <<EOF
#     ... firstmate's authority check ...
#     EOF
#     )
#
# The apostrophe opens a quote that never closes, and the whole script fails to
# parse - not just that string. Quoting the delimiter (<<'EOF') does NOT help;
# backslash-escaping the apostrophe parses but emits a literal backslash into the
# output. The only robust form is to keep the heredoc out of the command
# substitution by putting it in a function body, which is always top level:
#
#     text() {
#       cat <<EOF
#     ... firstmate's authority check ...
#     EOF
#     }
#     TEXT=$(text)
#
# THE RULE: never open a heredoc inside `$( )`. Put it in a function and call it.
#
# A `bash -n` sweep that runs under Bash 5 cannot see any of this, so it proves
# nothing about the fleet. --require-bash32 exists to make that failure loud:
# without it a CI job can silently degrade to a newer Bash and pass vacuously.
#
# The file set comes from `bin/fm-lint.sh --list-roots`, the single owner of
# firstmate's canonical shell roots, so the two checks cannot drift apart.
#
# Usage:
#   fm-bash-syntax-check.sh                     parse-check with $FM_SYNTAX_BASH or /bin/bash
#   fm-bash-syntax-check.sh --bash <path>       parse-check with an explicit interpreter
#   fm-bash-syntax-check.sh --require-bash32    fail unless that interpreter is Bash 3.2.x
#   fm-bash-syntax-check.sh --help              print this usage
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-bash-syntax-check.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
cd "$ROOT" || exit 1

usage() {
  sed -n '2,40{s/^# \{0,1\}//;s/^#$//;p;}' "$SELF"
}

BASH_BIN=${FM_SYNTAX_BASH:-/bin/bash}
REQUIRE_BASH32=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --bash)
      [ "$#" -ge 2 ] || { printf 'fm-bash-syntax-check.sh: --bash requires a path.\n' >&2; exit 2; }
      BASH_BIN=$2
      shift 2
      ;;
    --bash=*) BASH_BIN=${1#*=}; shift ;;
    --require-bash32) REQUIRE_BASH32=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'fm-bash-syntax-check.sh: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [ ! -x "$BASH_BIN" ]; then
  printf 'fm-bash-syntax-check.sh: no executable Bash at %s\n' "$BASH_BIN" >&2
  exit 127
fi

# shellcheck disable=SC2016  # deliberate: $BASH_VERSION must expand in the target interpreter, not here.
VERSION=$("$BASH_BIN" -c 'printf "%s" "$BASH_VERSION"' 2>/dev/null)
if [ -z "$VERSION" ]; then
  printf 'fm-bash-syntax-check.sh: could not read the Bash version of %s\n' "$BASH_BIN" >&2
  exit 127
fi

if [ "$REQUIRE_BASH32" -eq 1 ]; then
  case "$VERSION" in
    3.2.*) ;;
    *)
      printf 'fm-bash-syntax-check.sh: --require-bash32 given, but %s is Bash %s.\n' \
        "$BASH_BIN" "$VERSION" >&2
      printf 'fm-bash-syntax-check.sh: a newer Bash parses the 3.2 heredoc hazard fine, so this run would prove nothing.\n' >&2
      exit 1
      ;;
  esac
fi

printf 'fm-bash-syntax-check.sh: %s (Bash %s)\n' "$BASH_BIN" "$VERSION" >&2

ROOTS=$("$SELF_DIR/fm-lint.sh" --list-roots) || {
  printf 'fm-bash-syntax-check.sh: could not read the canonical root set from fm-lint.sh --list-roots.\n' >&2
  exit 2
}

checked=0
failed=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if [ ! -f "$path" ]; then
    printf 'fm-bash-syntax-check.sh: missing root %s\n' "$path" >&2
    failed=$((failed + 1))
    continue
  fi
  checked=$((checked + 1))
  if ! output=$("$BASH_BIN" -n "$path" 2>&1); then
    failed=$((failed + 1))
    printf '%s\n' "$output" >&2
  elif [ -n "$output" ]; then
    printf '%s\n' "$output" >&2
  fi
done <<ROOTLIST
$ROOTS
ROOTLIST

if [ "$checked" -eq 0 ]; then
  printf 'fm-bash-syntax-check.sh: no shell roots were checked.\n' >&2
  exit 2
fi

if [ "$failed" -ne 0 ]; then
  printf 'fm-bash-syntax-check.sh: %s of %s roots failed to parse under Bash %s.\n' \
    "$failed" "$checked" "$VERSION" >&2
  exit 1
fi

printf 'fm-bash-syntax-check.sh: %s roots parse cleanly under Bash %s.\n' "$checked" "$VERSION" >&2
