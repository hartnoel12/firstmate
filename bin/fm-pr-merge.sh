#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
#
# The merge is REFUSED unless firstmate holds local verification evidence for
# the PR's exact head commit (bin/fm-verify-lib.sh owns that contract). The
# forge's own checks are corroboration, never the requirement, because this
# fleet's CI goes dark on budget and a gate that cannot be satisfied when it
# matters is a gate that gets routed around.
#
# Usage: fm-pr-merge.sh <task-id> <pr-url> [--override-unverified <reason>]
#          [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-verify-lib.sh
. "$SCRIPT_DIR/fm-verify-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2

# The override is parsed here, before the -- separator, so it can never be
# mistaken for a flag to forward to the forge CLI.
OVERRIDE_REASON=
OVERRIDE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --override-unverified)
      if [ "$#" -lt 2 ]; then
        echo "error: --override-unverified needs a reason" >&2
        exit 2
      fi
      OVERRIDE=1
      OVERRIDE_REASON=$2
      shift 2
      ;;
    --override-unverified=*)
      OVERRIDE=1
      OVERRIDE_REASON=${1#--override-unverified=}
      shift
      ;;
    *) break ;;
  esac
done
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

# --- verification gate ------------------------------------------------------
#
# The commit being merged is the PR's head as the forge reports it, recorded by
# fm-pr-check.sh above. Binding evidence to a commit firstmate merely assumes is
# the head would defeat the whole point, so an unresolvable head refuses.
PR_HEAD=$(grep '^pr_head=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
# fm-pr-check.sh records pr_head only when the task's worktree is still on disk.
# A returned worktree must not turn the honest path into an override, so ask the
# forge directly before giving up. Still fail closed if it cannot answer.
if [ -z "$PR_HEAD" ] && command -v gh >/dev/null 2>&1; then
  if DIRECT_HEAD=$(gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$DIRECT_HEAD"; then
    PR_HEAD=$DIRECT_HEAD
  fi
fi
LEDGER=$(fm_verify_ledger_path "$STATE" "$ID")
PROJECT=$(grep '^project=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
CONFIG_FILE=$(fm_verify_config_path "$CONFIG" "$PROJECT")
REQUIRED=$(fm_verify_required_steps "$CONFIG_FILE") || exit 1

if [ -z "$PR_HEAD" ]; then
  FM_VERIFY_REFUSAL="the forge did not report a head commit for $URL, so no verification evidence can be bound to what would be merged"
  GATE_OK=1
else
  GATE_OK=0
  fm_verify_gate "$LEDGER" "$PR_HEAD" "$REQUIRED" || GATE_OK=1
fi

if [ "$GATE_OK" -ne 0 ]; then
  if [ "$OVERRIDE" -ne 1 ]; then
    fm_verify_refusal_report \
      "bin/fm-pr-merge.sh $ID $URL" \
      "bin/fm-verify.sh run $ID"
    exit "$FM_VERIFY_REFUSE_EXIT"
  fi
  GATE_REFUSAL=$FM_VERIFY_REFUSAL
  if ! fm_verify_override_valid "$OVERRIDE_REASON"; then
    echo "REFUSED: $FM_VERIFY_REFUSAL" >&2
    exit "$FM_VERIFY_REFUSE_EXIT"
  fi
  fm_verify_record_override "$LEDGER" "$META" "${PR_HEAD:-unknown}" "$OVERRIDE_REASON" "$URL" \
    || { echo "REFUSED: the override could not be recorded, so it will not be taken" >&2; exit "$FM_VERIFY_REFUSE_EXIT"; }
  fm_verify_override_announce "${PR_HEAD:-unknown}" "$OVERRIDE_REASON" "$GATE_REFUSAL"
elif [ "$OVERRIDE" -eq 1 ]; then
  echo "note: --override-unverified was not needed; $PR_HEAD has verification evidence ($FM_VERIFY_EVIDENCE)" >&2
else
  printf 'verified: %s (%s)\n' "$PR_HEAD" "$FM_VERIFY_EVIDENCE"
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
