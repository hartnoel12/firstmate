#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's immutable ship branch recorded in
# state/<task-id>.meta ("fm/<id>" for records created before that field existed).
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
# The task's existing per-task control lock serializes the captain-hold check
# through that fast-forward. A still-held or unreadable row refuses before the
# merge, so a captain approval must be recorded as an `answer --release` before
# this entrypoint is invoked. The lock ends when the fast-forward returns;
# docs/captain-hold-lifecycle.md owns the accepted merge-to-cleanup residual.
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

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-verify-lib.sh
. "$SCRIPT_DIR/fm-verify-lib.sh"
if [ "$#" -lt 1 ] || ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid local merge request" >&2
  exit 2
fi
ID=$1
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
    *) echo "error: invalid local merge request" >&2; exit 2 ;;
  esac
done

fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
META="$STATE/$ID.meta"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness and never lands (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor). This action is deliberately NOT
# relocated under the away-posture record: unlike the PR merge it has no
# record-side grant gate of its own, so a parked main keeps it held for the
# captain's return. This precedes reading the task record, because the wrong
# actor is refused for its role whatever it says.
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)"

[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
MERGE_EXPECTED_SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN

MERGE_CONTROL_LOCK=
MERGE_META_LOCK=
merge_control_cleanup() {
  [ -z "$MERGE_META_LOCK" ] || fm_lock_release "$MERGE_META_LOCK" || true
  [ -z "$MERGE_CONTROL_LOCK" ] || fm_lock_release "$MERGE_CONTROL_LOCK" || true
}
trap merge_control_cleanup EXIT
MERGE_CONTROL_LOCK="$STATE/.control-$ID.lock"
fm_lock_acquire_wait "$MERGE_CONTROL_LOCK"
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: task $ID changed while waiting to merge; refusing: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
if [ "$FM_BACKLOG_META_SPAWN_GEN" != "$MERGE_EXPECTED_SPAWN_GEN" ]; then
  echo "error: task $ID changed incarnation while waiting to merge; refusing" >&2
  exit 1
fi

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

BRANCH=$(grep '^branch=' "$META" | cut -d= -f2- || true)
[ -n "$BRANCH" ] || BRANCH="fm/$ID"
if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  echo "error: task $ID has an invalid recorded ship branch '$BRANCH'" >&2
  exit 1
fi
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
fm_verify_gate "$LEDGER" "$TIP" "$REQUIRED" "$META" "$CONFIG_FILE" "$PROJ" || GATE_OK=1

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
  # The metadata copy of the override is written under the task metadata lock,
  # like every other rewrite of that file.
  RECORD_RC=0
  MERGE_META_LOCK=$(fm_meta_lock_path "$META") && fm_lock_acquire_wait "$MERGE_META_LOCK" || RECORD_RC=1
  if [ "$RECORD_RC" -eq 0 ]; then
    fm_verify_record_override "$LEDGER" "$META" "${TIP:-unknown}" "$OVERRIDE_REASON" "$PROJ:$BRANCH" || RECORD_RC=1
    fm_lock_release "$MERGE_META_LOCK" || RECORD_RC=1
    MERGE_META_LOCK=
  fi
  [ "$RECORD_RC" -eq 0 ] \
    || { echo "REFUSED: the override could not be recorded, so it will not be taken" >&2; exit "$FM_VERIFY_REFUSE_EXIT"; }
  fm_verify_override_announce "${TIP:-unknown}" "$OVERRIDE_REASON" "$GATE_REFUSAL"
elif [ "$OVERRIDE" -eq 1 ]; then
  echo "note: --override-unverified was not needed; $TIP has verification evidence ($FM_VERIFY_EVIDENCE)" >&2
else
  printf 'verified: %s (%s)\n' "$TIP" "$FM_VERIFY_EVIDENCE"
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
hold_status=0
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" --distinguish-absent || hold_status=$?
case "$hold_status" in
  0)
    echo "error: task $ID is still held for the captain; release it before merging" >&2
    exit 1
    ;;
  1|3) ;;
  *)
    echo "error: could not determine whether task $ID is still held for the captain; refusing to merge" >&2
    exit 1
    ;;
esac
merge_status=0
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null || merge_status=$?
fm_lock_release "$MERGE_CONTROL_LOCK" || true
MERGE_CONTROL_LOCK=
[ "$merge_status" -eq 0 ] || exit "$merge_status"
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
# Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
[ ! -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/fleet-ledger" ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-fleet-ledger.sh" merged "$ID" local || true
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
