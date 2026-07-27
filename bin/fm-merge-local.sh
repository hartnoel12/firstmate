#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
#
# local-only is the widest delivery path in the fleet: no PR, no forge checks,
# no reviewer. So the same verification refusal that guards bin/fm-pr-merge.sh
# guards this one, bound to the branch tip about to become the default branch.
# bin/fm-verify-lib.sh owns that contract.
#
# Usage: fm-merge-local.sh <task-id> [--override-unverified <reason>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-verify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-verify-lib.sh"

"$FM_ROOT/bin/fm-guard.sh" || true
ID=${1:?usage: fm-merge-local.sh <task-id> [--override-unverified <reason>]}
shift

OVERRIDE=0
OVERRIDE_REASON=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --override-unverified)
      [ "$#" -ge 2 ] || { echo "error: --override-unverified needs a reason" >&2; exit 2; }
      OVERRIDE=1
      OVERRIDE_REASON=$2
      shift 2
      ;;
    --override-unverified=*)
      OVERRIDE=1
      OVERRIDE_REASON=${1#--override-unverified=}
      shift
      ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

BRANCH="fm/$ID"
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

# --- verification gate ------------------------------------------------------
#
# The commit being merged is the branch tip itself: there is no forge in this
# path, so the tip is both the evidence anchor and exactly what lands.
TIP=$(git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH^{commit}" 2>/dev/null || true)
LEDGER=$(fm_verify_ledger_path "$STATE" "$ID")
CONFIG_FILE=$(fm_verify_config_path "$CONFIG" "$PROJ")
REQUIRED=$(fm_verify_required_steps "$CONFIG_FILE") || exit 1

GATE_OK=0
fm_verify_gate "$LEDGER" "$TIP" "$REQUIRED" || GATE_OK=1

if [ "$GATE_OK" -ne 0 ]; then
  if [ "$OVERRIDE" -ne 1 ]; then
    fm_verify_refusal_report \
      "bin/fm-merge-local.sh $ID" \
      "bin/fm-verify.sh run $ID"
    exit "$FM_VERIFY_REFUSE_EXIT"
  fi
  GATE_REFUSAL=$FM_VERIFY_REFUSAL
  if ! fm_verify_override_valid "$OVERRIDE_REASON"; then
    echo "REFUSED: $FM_VERIFY_REFUSAL" >&2
    exit "$FM_VERIFY_REFUSE_EXIT"
  fi
  fm_verify_record_override "$LEDGER" "$META" "${TIP:-unknown}" "$OVERRIDE_REASON" "$PROJ:$BRANCH" \
    || { echo "REFUSED: the override could not be recorded, so it will not be taken" >&2; exit "$FM_VERIFY_REFUSE_EXIT"; }
  fm_verify_override_announce "${TIP:-unknown}" "$OVERRIDE_REASON" "$GATE_REFUSAL"
elif [ "$OVERRIDE" -eq 1 ]; then
  echo "note: --override-unverified was not needed; $TIP has verification evidence ($FM_VERIFY_EVIDENCE)" >&2
else
  printf 'verified: %s (%s)\n' "$TIP" "$FM_VERIFY_EVIDENCE"
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
