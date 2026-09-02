#!/usr/bin/env bash
# fm-verify.sh - produce and record firstmate's own verification evidence for a
# task's exact commit, and record what was deliberately bypassed.
#
# `run` never accepts a claim: it executes the command itself in the task's
# worktree and records the real exit code. Nothing here can write "passed" for
# something that did not pass. The ledger format, the merge gate, and why the
# gate is local rather than CI-shaped are owned by bin/fm-verify-lib.sh.
#
# Usage:
#   fm-verify.sh run <task-id>
#   fm-verify.sh run <task-id> --step <name> -- <command> [args...]
#   fm-verify.sh bypass <task-id> (--step <name> | --all) --why <reason> --by <who>
#   fm-verify.sh show <task-id>
#
# `run <task-id>` with no --step runs every step the project declares in
# <config>/verify/<project-name>, a local gitignored file of `<step> = <command>`
# lines. Those declared steps are also what the merge gate requires to be
# present and passing, so declaring a step is how a project raises its own bar:
# a declared step that did not run is a SKIPPED step, and the merge refuses.
# With no declaration the gate still requires a passing run bound to the exact
# commit, which is the floor, not the ceiling.
#
# `run` refuses a dirty worktree, refuses a worktree carrying gitignored
# untracked content (a build cache a prior occupant of a reused worktree could
# have left behind, invisible to `git status` because ignored files are never
# "dirty"), and refuses to record if HEAD moved while the commands were
# running. Evidence that does not describe a known tree state is not evidence.
#
# `bypass` is the honest account of something firstmate authorized to be
# skipped or waved through - a force-approved gate, a hook-disabled push, a
# dark CI board. Recording one can only make merging harder, never easier, so
# there is no incentive to omit it; the merge gate then refuses until the named
# steps have real passing evidence for the exact commit, or the merge is
# explicitly overridden.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-verify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-verify-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  echo "error: $1" >&2
  exit 1
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
case "$1" in
  -h|--help) usage; exit 0 ;;
esac
[ "$#" -ge 2 ] || { usage >&2; exit 2; }

ACTION=$1
ID=$2
shift 2
fm_pr_task_id_valid "$ID" || die "invalid task id"

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || die "no metadata for task $ID"
LEDGER=$(fm_verify_ledger_path "$STATE" "$ID")

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# --- show -------------------------------------------------------------------

if [ "$ACTION" = show ]; then
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  if [ ! -f "$LEDGER" ]; then
    printf 'no verification evidence recorded for %s\n' "$ID"
    exit 0
  fi
  printf '%-9s %-20s %-40s %s\n' KIND WHEN COMMIT DETAIL
  while IFS=$'\t' read -r kind ts sha f4 f5 f6; do
    [ -n "$kind" ] || continue
    when=$(date -r "$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
      || date -d "@$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
      || printf '%s' "$ts")
    printf '%-9s %-20s %-40s %s | %s | %s\n' "$kind" "$when" "$sha" "$f4" "$f5" "$f6"
  done < "$LEDGER"
  exit 0
fi

# --- bypass -----------------------------------------------------------------

if [ "$ACTION" = bypass ]; then
  BY_STEPS=
  BY_ALL=0
  BY_WHY=
  BY_WHO=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --step)
        [ "$#" -ge 2 ] || die "--step needs a step name"
        fm_verify_step_name_valid "$2" || die "invalid step name '$2'"
        BY_STEPS="${BY_STEPS:+$BY_STEPS,}$2"
        shift 2
        ;;
      --all) BY_ALL=1; shift ;;
      --why)
        [ "$#" -ge 2 ] || die "--why needs a reason"
        BY_WHY=$2
        shift 2
        ;;
      --by)
        [ "$#" -ge 2 ] || die "--by needs who authorized the bypass"
        BY_WHO=$2
        shift 2
        ;;
      *) die "unknown bypass argument: $1" ;;
    esac
  done
  if [ "$BY_ALL" -eq 1 ]; then
    [ -z "$BY_STEPS" ] || die "--all and --step are mutually exclusive"
    BY_STEPS='*'
  fi
  [ -n "$BY_STEPS" ] || die "bypass needs --step <name> (repeatable) or --all"
  [ -n "$BY_WHY" ] || die "bypass needs --why <reason>: an unexplained bypass is the thing this record exists to prevent"
  [ -n "$BY_WHO" ] || die "bypass needs --by <who authorized it>"

  # A bypass is bound to the commit it was taken at when there is one, purely
  # so the ledger reads chronologically. The gate deliberately applies every
  # bypass to the whole task regardless of commit: an unscoped or unsuperseded
  # bypass must not age out of relevance.
  WT=$(meta_value worktree)
  SHA='-'
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    SHA=$(git -C "$WT" rev-parse HEAD 2>/dev/null || printf '%s' '-')
    fm_verify_sha_valid "$SHA" || SHA='-'
  fi
  # bin/fm-verify-lib.sh owns why a bypass is written twice and what the gate
  # does with each copy; a partial write is reported as exactly that, because the
  # ledger half it did land keeps refusing the merge.
  BY_RC=0
  fm_verify_record_bypass "$LEDGER" "$META" "$SHA" "$BY_STEPS" "$BY_WHY" "$BY_WHO" || BY_RC=$?
  case "$BY_RC" in
    0) ;;
    2)
      die "the bypass is recorded in the verification ledger but could not be copied into the task record at $META; the ledger record is deliberately kept, so merging $ID still refuses until those steps have passing evidence for the exact commit - repair the task record rather than recording the bypass again"
      ;;
    *)
      die "could not append the bypass to the verification ledger; nothing was recorded as bypassed"
      ;;
  esac
  printf 'recorded bypass of %s for %s (%s), in both the ledger and the task record\n' \
    "$BY_STEPS" "$ID" "$BY_WHY"
  printf 'Merging %s now refuses until those steps have passing evidence for the\n' "$ID"
  printf 'exact commit, or the merge is explicitly overridden.\n'
  exit 0
fi

[ "$ACTION" = run ] || { usage >&2; exit 2; }

# --- run --------------------------------------------------------------------

STEP_NAME=
CMD=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --step)
      [ "$#" -ge 2 ] || die "--step needs a step name"
      fm_verify_step_name_valid "$2" || die "invalid step name '$2'"
      STEP_NAME=$2
      shift 2
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        CMD+=("$1")
        shift
      done
      ;;
    *) die "unknown run argument: $1" ;;
  esac
done

if [ "${#CMD[@]}" -gt 0 ] && [ -z "$STEP_NAME" ]; then
  die "an ad-hoc command needs --step <name> so the evidence says what it checked"
fi
if [ -n "$STEP_NAME" ] && [ "${#CMD[@]}" -eq 0 ]; then
  die "--step <name> needs -- <command> to run"
fi

WT=$(meta_value worktree)
PROJECT=$(meta_value project)
[ -n "$WT" ] && [ -d "$WT" ] || die "task $ID has no worktree to verify"
git -C "$WT" rev-parse --git-dir >/dev/null 2>&1 || die "task worktree is not a git checkout: $WT"

# Uncommitted work means the commands would test something no merge will ever
# land. Refuse rather than record evidence for a tree that does not exist.
if [ -n "$(git -C "$WT" status --porcelain 2>/dev/null | head -1)" ]; then
  die "worktree $WT has uncommitted changes; commit them first so the evidence describes the commit being merged"
fi

# Gitignored untracked content never shows up as "dirty" above, but a reused
# pooled worktree can carry a stale build cache (node_modules, target/, a
# coverage dir) from a prior occupant's different commit. Running the declared
# commands against that leftover state can hide or invent a failure at random,
# so refuse rather than silently record evidence for an unknown tree. The
# operator resolves this deliberately (usually `git -C <worktree> clean -fdX`
# to drop the ignored content, then reinstalling whatever the declared steps
# need) rather than having firstmate itself delete build output it cannot tell
# apart from something intentionally kept.
IGNORED=$(git -C "$WT" status --porcelain --ignored 2>/dev/null | grep '^!! ' | head -3)
if [ -n "$IGNORED" ]; then
  die "worktree $WT carries gitignored untracked content that predates this run and could taint the result:
$IGNORED
Remove it first (for example: git -C \"$WT\" clean -ffdX) and reinstall whatever the verification steps need, so the evidence describes a known tree state."
fi

SHA_BEFORE=$(git -C "$WT" rev-parse HEAD 2>/dev/null) || die "cannot read HEAD in $WT"
fm_verify_sha_valid "$SHA_BEFORE" || die "cannot read a full commit id in $WT"

RESULTS=
OUTCOME=passed

# record_step <name> <status>: accumulate one truthful step result.
record_step() {
  printf '== %s: %s\n' "$1" "$2"
  [ "$2" = passed ] || OUTCOME=failed
  RESULTS="${RESULTS:+$RESULTS,}$1:$2"
}

if [ "${#CMD[@]}" -gt 0 ]; then
  # Ad-hoc: run the caller's argv exactly as given, with no shell re-parsing.
  printf '== %s: %s\n' "$STEP_NAME" "${CMD[*]}"
  if ( cd "$WT" && "${CMD[@]}" ); then
    record_step "$STEP_NAME" passed
  else
    record_step "$STEP_NAME" failed
  fi
else
  CONFIG_FILE=$(fm_verify_config_path "$CONFIG" "$PROJECT")
  # An unusable declaration (a symlink, a directory) is refused by
  # fm_verify_config_steps below rather than mistaken for "declares nothing", so
  # only a genuinely absent file reaches this message.
  if [ -z "$CONFIG_FILE" ] || { [ ! -e "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ]; }; then
    die "no verification steps declared for this project.
Declare them in ${CONFIG_FILE:-$CONFIG/verify/<project>} as '<step> = <command>' lines,
or record one ad-hoc step:
  fm-verify.sh run $ID --step <name> -- <command>"
  fi
  STEPS_TSV=$(fm_verify_config_steps "$CONFIG_FILE") || exit 1
  [ -n "$STEPS_TSV" ] || die "$CONFIG_FILE declares no steps"
  # The whole step list is read into memory BEFORE anything runs, so no step
  # command can consume the list it is being read from and silently skip the
  # steps after it - a partial run must never be recordable as a complete one.
  STEP_NAMES=()
  STEP_CMDS=()
  while IFS=$'\t' read -r name cmd; do
    [ -n "$name" ] || continue
    STEP_NAMES+=("$name")
    STEP_CMDS+=("$cmd")
  done <<< "$STEPS_TSV"
  [ "${#STEP_NAMES[@]}" -gt 0 ] || die "$CONFIG_FILE declares no steps"
  # Declared steps are shell command lines written by the operator into a
  # firstmate-private config file, so they run through the shell deliberately.
  # Each runs with stdin on /dev/null: a step that reads stdin must neither eat
  # anything of firstmate's nor block waiting for a terminal that is not there.
  i=0
  while [ "$i" -lt "${#STEP_NAMES[@]}" ]; do
    name=${STEP_NAMES[$i]}
    cmd=${STEP_CMDS[$i]}
    i=$((i + 1))
    printf '== %s: %s\n' "$name" "$cmd"
    if ( cd "$WT" && eval "$cmd" ) </dev/null; then
      record_step "$name" passed
    else
      record_step "$name" failed
    fi
  done
fi

[ -n "$RESULTS" ] || die "no verification step ran"

# A command that commits, rebases, or amends invalidates its own evidence.
SHA_AFTER=$(git -C "$WT" rev-parse HEAD 2>/dev/null) || die "cannot re-read HEAD in $WT"
if [ "$SHA_AFTER" != "$SHA_BEFORE" ]; then
  die "HEAD moved from $SHA_BEFORE to $SHA_AFTER while verifying; nothing recorded, re-run against the final commit"
fi

fm_verify_append "$LEDGER" verify "$SHA_BEFORE" "$OUTCOME" "$RESULTS" "-" \
  || die "could not record the verification result"

printf 'recorded %s for %s at %s (%s)\n' "$OUTCOME" "$ID" "$SHA_BEFORE" "$RESULTS"
[ "$OUTCOME" = passed ] || exit 1
