#!/usr/bin/env bash
# fm-verify-lib.sh - firstmate's own truthful account of what a task's exact
# commit was verified against, and the fail-closed merge refusal built on it.
#
# WHY THIS IS NOT A CI CHECK. The obvious gate - "refuse unless GitHub reports
# every check green" - is unenforceable in this fleet by design of its budget.
# Actions minutes run out, checks go dark, and a gate that cannot be satisfied
# when it matters most is a gate agents route around. Verification here is
# LOCAL: evidence that a command actually ran, at this exact commit, and exited
# zero. Forge checks remain welcome corroboration and are never the requirement.
#
# WHY FIRSTMATE KEEPS ITS OWN RECORD. no-mistakes is a separate installed tool
# and firstmate cannot change how it records. Verified 2026-07-26 against the
# real ~/.no-mistakes/state.sqlite for run 01KYG4AK1MJJT2939M25AX7FAY, whose ci
# step was force-approved over three failing checks: every step_results row
# reads `completed|0` and its ci step_rounds row reads
# `round=1, trigger_type=initial, selection_source=NULL, fix_summary=NULL` -
# byte-identical to a step that genuinely passed. A record that overstates what
# was verified is worse than no record, so the gate never consults that one.
# See docs/verification/merge-verification-gate.md.
#
# THE LEDGER: state/<id>.verification, private (0600), append-only, one record
# per line, TAB-separated, first field is the record kind. Writers sanitize TAB
# and newline out of every field, so the line count is the record count.
#
#   verify   <epoch> <sha>      <outcome>  <steps>  <note>
#   bypass   <epoch> <sha>      <what>     <why>    <by>
#   override <epoch> <sha>      <path>     <reason> <by>
#
#   sha      full 40-hex commit the record is bound to ('-' for an unbound
#            bypass, which can never be superseded by evidence)
#   outcome  passed | failed - derived from real exit codes, never asserted
#   steps    name:passed,name:failed,... in the order they ran
#   what     comma-separated bypassed step names, or '*' for "the whole run"
#
# THE GATE (fm_verify_gate) refuses unless ALL of these hold for the exact
# commit being merged:
#
#   1. a verify record exists whose sha equals that commit - a run on the same
#      BRANCH is not evidence, because the branch moves;
#   2. that record's outcome is passed and every step in it is passed;
#   3. every step the project declares required (config/verify/<project>) has a
#      passing record in it - a declared step absent from the run is a SKIPPED
#      step, and skipped is not passed;
#   4. no bypass recorded against the task survives. A bypass naming steps is
#      superseded only by positive evidence: each named step must itself appear
#      passing in the winning record for this exact commit. An unbound or '*'
#      bypass can never be superseded, so it always refuses.
#
# Rule 4 is what makes an unaccounted-for bypass fail CLOSED. Recording a
# bypass cannot make a merge easier - only harder - so the record has no
# incentive to be omitted, and omitting it is the one failure mode firstmate
# must not reward.
#
# Sourced by bin/fm-verify.sh, bin/fm-pr-merge.sh, bin/fm-merge-local.sh, and
# the tests. No side effects on source. set -u / set -e safe.

# Exit code every verification refusal uses, distinct from the gate-agent
# refusal (3) so a caller or test can tell the two apart.
# shellcheck disable=SC2034  # Read by the sourcing merge scripts and the tests.
FM_VERIFY_REFUSE_EXIT=4

# Environment acknowledgement the override demands in addition to its flag.
# Two deliberate acts, so an override is never something a hurried agent
# stumbles into as the path of least resistance.
FM_VERIFY_OVERRIDE_ACK_VALUE='i-accept-merging-unverified-work'

# Shortest reason the override accepts. A reason has to name the environmental
# breakage; "ci down" leaves nothing behind for the next reader.
FM_VERIFY_OVERRIDE_MIN_REASON=24

# --- field hygiene ----------------------------------------------------------

# fm_verify_field_clean <text>: echo <text> with TAB, CR, and LF folded to
# single spaces and surrounding whitespace trimmed, so it cannot break the
# record framing. An empty result echoes '-'.
fm_verify_field_clean() {
  local s=${1:-}
  s=$(printf '%s' "$s" | tr '\t\r\n' '   ')
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  [ -n "$s" ] || s='-'
  printf '%s' "$s"
}

# fm_verify_step_name_valid <name>: step names are the ledger's only structured
# field, so keep them to a shape that can never collide with the ',' and ':'
# separators.
fm_verify_step_name_valid() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# fm_verify_sha_valid <sha>: a full 40-hex commit id. Short shas are rejected
# on purpose - the whole point is binding evidence to one exact commit.
fm_verify_sha_valid() {
  case "${1:-}" in
    *[!0-9a-f]*) return 1 ;;
    ????????????????????????????????????????) return 0 ;;
  esac
  return 1
}

# --- ledger paths and writing ----------------------------------------------

# fm_verify_ledger_path <state-dir> <task-id>
fm_verify_ledger_path() {
  printf '%s/%s.verification' "$1" "$2"
}

# fm_verify_append <ledger> <kind> <sha> <f4> <f5> <f6>: append one record with
# 0600 permissions. Refuses a symlinked or non-regular ledger rather than
# following it somewhere else.
fm_verify_append() {
  local ledger=$1 kind=$2 sha=$3 f4=$4 f5=$5 f6=$6 now
  if [ -e "$ledger" ] && { [ -L "$ledger" ] || [ ! -f "$ledger" ]; }; then
    echo "error: verification ledger is unavailable" >&2
    return 1
  fi
  now=$(date +%s 2>/dev/null) || return 1
  ( umask 077
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$kind" "$now" "$sha" \
      "$(fm_verify_field_clean "$f4")" \
      "$(fm_verify_field_clean "$f5")" \
      "$(fm_verify_field_clean "$f6")" >> "$ledger" ) || return 1
  chmod 0600 "$ledger" 2>/dev/null || true
}

# --- declared required steps ------------------------------------------------

# fm_verify_config_path <config-dir> <project-path>: the optional per-project
# declaration of what a complete verification is. Keyed on the project
# directory's basename, the same name the project registry uses. Echoes nothing
# when the project name is unusable as a single path segment.
fm_verify_config_path() {
  local config_dir=$1 project=$2 name
  [ -n "$project" ] || return 0
  name=$(basename -- "$project")
  case "$name" in
    ''|.|..|.*|*/*) return 0 ;;
    *[!A-Za-z0-9._-]*) return 0 ;;
  esac
  printf '%s/verify/%s' "$config_dir" "$name"
}

# fm_verify_config_steps <config-file>: echo one "<step>\t<command>" line per
# declared step. Blank lines and # comments are ignored; a line without '=' or
# with an unusable step name is a configuration error, reported and refused, so
# a typo silently lowers no bar.
#
# Absent is the one silent success: a project that declares nothing is a
# legitimate case and leaves the gate at its floor. A declaration that EXISTS
# but is unusable - a symlink, a directory, a device - is NOT the same thing as
# no declaration, and must never be read as one: that would quietly drop a
# project from its own declared bar back to the floor. It is reported and
# refused, the way this library refuses a symlinked ledger.
fm_verify_config_steps() {
  local file=$1 line name cmd
  [ -n "$file" ] || return 0
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    return 0
  fi
  if [ -L "$file" ] || [ ! -f "$file" ]; then
    echo "error: $file: verification step declaration must be a regular file, not a symlink or special file" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*|[[:space:]]*'#'*) continue ;;
    esac
    case "$line" in
      *=*) ;;
      *)
        [ -z "$(fm_verify_field_clean "$line")" ] && continue
        echo "error: $file: expected '<step> = <command>', got: $line" >&2
        return 1
        ;;
    esac
    name=${line%%=*}
    cmd=${line#*=}
    name=$(fm_verify_field_clean "$name")
    cmd=$(fm_verify_field_clean "$cmd")
    if ! fm_verify_step_name_valid "$name"; then
      echo "error: $file: invalid step name '$name'" >&2
      return 1
    fi
    if [ "$cmd" = '-' ]; then
      echo "error: $file: step '$name' declares no command" >&2
      return 1
    fi
    printf '%s\t%s\n' "$name" "$cmd"
  done < "$file"
}

# fm_verify_required_steps <config-file>: comma-separated declared step names,
# empty when the project declares none.
fm_verify_required_steps() {
  local steps out
  steps=$(fm_verify_config_steps "$1") || return 1
  out=$(printf '%s' "$steps" | cut -f1 | paste -sd, - 2>/dev/null) || return 1
  printf '%s' "$out"
}

# --- the gate ---------------------------------------------------------------

# Set by fm_verify_gate on refusal: one plain sentence naming what is missing.
FM_VERIFY_REFUSAL=''
# Set by fm_verify_gate on success: the steps that carried the commit, for the
# merge output, so a passing gate still says what it actually checked.
FM_VERIFY_EVIDENCE=''

# fm_verify_gate <ledger> <sha> <required-csv>: 0 when the exact commit has
# genuine, complete, unbypassed local verification evidence. 1 otherwise, with
# FM_VERIFY_REFUSAL explaining which of the four rules failed.
fm_verify_gate() {  # <ledger> <sha> <required-csv>
  local ledger=$1 sha=$2 required=${3:-}
  local kind rec_sha win_outcome='' win_steps='' found=0
  local outcome steps what why pair name status req verified=''
  local -a parts=()

  FM_VERIFY_REFUSAL=''
  FM_VERIFY_EVIDENCE=''

  if ! fm_verify_sha_valid "$sha"; then
    FM_VERIFY_REFUSAL="cannot identify the exact commit to merge, so no verification evidence can be bound to it"
    return 1
  fi
  if [ ! -f "$ledger" ] || [ -L "$ledger" ]; then
    FM_VERIFY_REFUSAL="no verification evidence has been recorded for this task"
    return 1
  fi

  # Rule 1: the winning record is the LAST verify record bound to this exact
  # commit. Later re-verification of the same commit supersedes earlier runs;
  # a run on any other commit is not evidence for this one.
  while IFS=$'\t' read -r kind _ rec_sha outcome steps _; do
    [ "$kind" = verify ] || continue
    [ "$rec_sha" = "$sha" ] || continue
    win_outcome=$outcome
    win_steps=$steps
    found=1
  done < "$ledger"

  if [ "$found" -eq 0 ]; then
    FM_VERIFY_REFUSAL="no local verification run is recorded for commit $sha (a run on the same branch is not evidence: the branch moves)"
    return 1
  fi

  # Rule 2: the run genuinely passed, step by step.
  if [ "$win_outcome" != passed ]; then
    FM_VERIFY_REFUSAL="the verification run recorded for commit $sha did not pass (outcome: $win_outcome)"
    return 1
  fi
  if [ -z "$win_steps" ] || [ "$win_steps" = '-' ]; then
    FM_VERIFY_REFUSAL="the verification run recorded for commit $sha checked nothing"
    return 1
  fi
  IFS=',' read -r -a parts <<< "$win_steps"
  for pair in "${parts[@]}"; do
    name=${pair%%:*}
    status=${pair#*:}
    if [ -z "$name" ] || [ "$name" = "$pair" ]; then
      FM_VERIFY_REFUSAL="the verification record for commit $sha is malformed and cannot be trusted"
      return 1
    fi
    if [ "$status" != passed ]; then
      FM_VERIFY_REFUSAL="verification step '$name' is recorded as $status for commit $sha"
      return 1
    fi
    verified="$verified,$name,"
  done

  # Rule 3: a declared step missing from the run was skipped, and skipped is
  # not passed.
  if [ -n "$required" ]; then
    IFS=',' read -r -a parts <<< "$required"
    for req in "${parts[@]}"; do
      [ -n "$req" ] || continue
      case "$verified" in
        *",$req,"*) ;;
        *)
          FM_VERIFY_REFUSAL="required verification step '$req' has no passing record for commit $sha (declared for this project but not run)"
          return 1
          ;;
      esac
    done
  fi

  # Rule 4: any recorded bypass survives unless the exact commit has positive
  # evidence for every step it named.
  while IFS=$'\t' read -r kind _ _ what why _; do
    [ "$kind" = bypass ] || continue
    if [ "$what" = '*' ] || [ "$what" = '-' ]; then
      FM_VERIFY_REFUSAL="an unscoped bypass is recorded against this task ($why) and nothing can supersede it"
      return 1
    fi
    IFS=',' read -r -a parts <<< "$what"
    for name in "${parts[@]}"; do
      [ -n "$name" ] || continue
      case "$verified" in
        *",$name,"*) ;;
        *)
          FM_VERIFY_REFUSAL="a bypass of '$name' is recorded against this task ($why) and '$name' has no passing record for commit $sha"
          return 1
          ;;
      esac
    done
  done < "$ledger"

  # shellcheck disable=SC2034  # Read by the sourcing merge scripts.
  FM_VERIFY_EVIDENCE=$win_steps
  return 0
}

# --- the override -----------------------------------------------------------

# fm_verify_override_valid <reason>: 0 when the caller supplied both halves of
# the deliberate act. Sets FM_VERIFY_REFUSAL with the missing half otherwise.
fm_verify_override_valid() {  # <reason>
  local reason=${1:-}
  FM_VERIFY_REFUSAL=''
  if [ "${#reason}" -lt "$FM_VERIFY_OVERRIDE_MIN_REASON" ]; then
    FM_VERIFY_REFUSAL="--override-unverified needs a reason of at least $FM_VERIFY_OVERRIDE_MIN_REASON characters naming the concrete breakage"
    return 1
  fi
  if [ "${FM_MERGE_OVERRIDE_ACK:-}" != "$FM_VERIFY_OVERRIDE_ACK_VALUE" ]; then
    FM_VERIFY_REFUSAL="--override-unverified also requires FM_MERGE_OVERRIDE_ACK=$FM_VERIFY_OVERRIDE_ACK_VALUE in the environment"
    return 1
  fi
  return 0
}

# fm_verify_override_announce <sha> <reason> <refusal>: the loud half. Printed
# to BOTH stdout and stderr so it survives whichever stream the caller keeps.
fm_verify_override_announce() {  # <sha> <reason> <refusal>
  local sha=$1 reason=$2 refusal=$3 banner
  banner=$(cat <<EOF
################################################################################
##  MERGING WITHOUT VERIFICATION EVIDENCE
##  commit : $sha
##  gate   : $refusal
##  reason : $reason
##  This override is recorded in the task's verification ledger and metadata.
################################################################################
EOF
)
  printf '%s\n' "$banner"
  printf '%s\n' "$banner" >&2
}

# --- the override's copy in task metadata -----------------------------------
#
# bin/fm-pr-lib.sh parses a task's .meta under a strict rule: after the pr= line
# nothing but pr_head= and a short x_* allowlist may appear, because everything
# else there is treated as post-recording injection. An override reason is
# operator free text - precisely what that guard exists to reject - so appending
# the note would invalidate the metadata for every later reader of it (the armed
# poll's retirement receipt, the check migration's canonicality test). The note
# is therefore INSERTED BEFORE the first pr= line, through the same
# temp-file-then-mv rewrite bin/fm-pr-check.sh uses, preserving 0600, the single
# link, and the containing device. The ledger stays the primary trail; this copy
# must never cost the metadata it rides along in.

fm_verify_file_device() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %d "$1" 2>/dev/null
  else
    stat -c %d "$1" 2>/dev/null
  fi
}

fm_verify_file_link_count() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

# The rewrite's temp file is a 0600 copy of the task's metadata, including the
# operator's free-text override reason, and it lives in the state directory
# beside the real thing. bin/fm-teardown.sh removes only the named per-task
# files, so a stranded copy would outlive its task. It is therefore removed on
# every return path AND on signal, the way bin/fm-pr-check.sh guards its own
# .fm-pr-meta temp. The signal handlers are installed only when the sourcing
# script has none of its own, so a caller's traps are deferred to rather than
# overwritten; the explicit removal covers that case.
FM_VERIFY_META_TMP=''
FM_VERIFY_META_TRAP_OWNED=0

fm_verify_meta_tmp_cleanup() {
  [ -z "${FM_VERIFY_META_TMP:-}" ] || rm -f -- "$FM_VERIFY_META_TMP"
  FM_VERIFY_META_TMP=''
}

fm_verify_meta_trap_arm() {
  FM_VERIFY_META_TRAP_OWNED=0
  [ -z "$(trap -p EXIT HUP INT TERM 2>/dev/null)" ] || return 0
  trap fm_verify_meta_tmp_cleanup EXIT
  trap 'fm_verify_meta_tmp_cleanup; exit 1' HUP INT TERM
  FM_VERIFY_META_TRAP_OWNED=1
}

fm_verify_meta_trap_disarm() {
  [ "${FM_VERIFY_META_TRAP_OWNED:-0}" -eq 1 ] || return 0
  trap - EXIT HUP INT TERM
  FM_VERIFY_META_TRAP_OWNED=0
}

# fm_verify_meta_compose <meta> <tmp> <note>: copy <meta> to <tmp> with <note>
# inserted before the first pr= line, or appended when there is none. Every
# write is checked, so a filesystem that fills partway through fails the whole
# operation instead of producing a plausible-looking truncation.
fm_verify_meta_compose() {  # <meta> <tmp> <note>
  local meta=$1 tmp=$2 note=$3 line inserted=0
  : > "$tmp" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$inserted" -eq 0 ]; then
      case "$line" in
        pr=*)
          printf '%s\n' "$note" >> "$tmp" || return 1
          inserted=1
          ;;
      esac
    fi
    printf '%s\n' "$line" >> "$tmp" || return 1
  done < "$meta"
  [ "$inserted" -eq 1 ] || printf '%s\n' "$note" >> "$tmp" || return 1
  return 0
}

# The note is operator free text, so every comparison against it is a whole-line
# shell string comparison. Nothing here interpolates it into a pattern language:
# awk's -v applies escape processing, and a reason containing a backslash would
# then fail to match the very line it was written from, refusing an override
# that was recorded perfectly well.

# fm_verify_meta_note_count <file> <note>: how many whole lines equal <note>.
fm_verify_meta_note_count() {  # <file> <note>
  local file=$1 note=$2 line n=0
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$line" = "$note" ]; then
        n=$((n + 1))
      fi
    done < "$file"
  fi
  printf '%s' "$n"
}

# fm_verify_meta_lines <file> [skip-note]: echo <file> a line at a time, so a
# missing final newline compares equal to a present one. With [skip-note], the
# FIRST line equal to it is dropped.
fm_verify_meta_lines() {  # <file> [skip-note]
  local file=$1 skip=${2:-} line dropped=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$dropped" -eq 0 ] && [ -n "$skip" ] && [ "$line" = "$skip" ]; then
      dropped=1
      continue
    fi
    printf '%s\n' "$line"
  done < "$file"
}

# fm_verify_meta_rewrite_faithful <meta> <tmp> <note> <before>: 0 only when
# <tmp> is <meta> with exactly one more <note> line than the <before> count and
# nothing else changed, moved, or lost. Proving the note landed is not enough:
# the note is inserted immediately before pr=, which bin/fm-pr-check.sh writes
# last, so a truncation right after the note would leave the note present and
# the pr= identity gone. The count is a DELTA rather than an absolute, because a
# task taking a second override with the same commit and the same reason already
# carries an identical note line and must still be able to record.
fm_verify_meta_rewrite_faithful() {  # <meta> <tmp> <note> <before>
  local meta=$1 tmp=$2 note=$3 before=$4 after
  after=$(fm_verify_meta_note_count "$tmp" "$note") || return 1
  [ "$after" -eq $((before + 1)) ] || return 1
  fm_verify_meta_lines "$tmp" "$note" | cmp -s - <(fm_verify_meta_lines "$meta")
}

# fm_verify_meta_note_override <meta> <sha> <reason>: write one
# merged_unverified=<sha>|<reason> line into <meta>, before its first pr= line
# or at the end when it has none. The original is left untouched unless the
# replacement is proven complete, because an override that cannot be recorded
# is an override that is not taken.
fm_verify_meta_note_override() {  # <meta> <sha> <reason>
  local meta=$1 sha=$2 reason=$3 dir device note before rc=0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(fm_verify_file_link_count "$meta")" = 1 ] || return 1
  dir=$(dirname -- "$meta")
  device=$(fm_verify_file_device "$dir") || return 1
  [ -n "$device" ] || return 1
  [ "$(fm_verify_file_device "$meta")" = "$device" ] || return 1
  note="merged_unverified=$sha|$(fm_verify_field_clean "$reason")"
  before=$(fm_verify_meta_note_count "$meta" "$note") || return 1

  fm_verify_meta_trap_arm
  FM_VERIFY_META_TMP=$(mktemp "$dir/.fm-verify-meta.XXXXXX") || {
    fm_verify_meta_trap_disarm
    return 1
  }
  if ! fm_verify_meta_compose "$meta" "$FM_VERIFY_META_TMP" "$note" \
    || ! fm_verify_meta_rewrite_faithful "$meta" "$FM_VERIFY_META_TMP" "$note" "$before" \
    || ! chmod 0600 "$FM_VERIFY_META_TMP" \
    || [ "$(fm_verify_file_device "$FM_VERIFY_META_TMP")" != "$device" ] \
    || [ ! -f "$meta" ] || [ -L "$meta" ] \
    || [ "$(fm_verify_file_link_count "$meta")" != 1 ]; then
    rc=1
  fi
  # Corroboration when the PR library is loaded: metadata that parsed as a
  # canonical PR identity before must still parse as one after. A task with no
  # pr= line never parsed, and is held to the faithful-copy check alone.
  if [ "$rc" -eq 0 ] && declare -f fm_pr_metadata_identity_parse >/dev/null 2>&1; then
    if fm_pr_metadata_identity_parse "$meta" \
      && ! fm_pr_metadata_identity_parse "$FM_VERIFY_META_TMP"; then
      rc=1
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    mv -f -- "$FM_VERIFY_META_TMP" "$meta" || rc=1
  fi
  fm_verify_meta_tmp_cleanup
  fm_verify_meta_trap_disarm
  return "$rc"
}

# fm_verify_record_override <ledger> <meta> <sha> <reason> <path>: the durable
# half. Writes the override to the ledger AND to task metadata, so the trail
# survives losing either one. Fails the merge if it cannot record - an
# unrecorded override is exactly the thing this whole file exists to prevent.
fm_verify_record_override() {  # <ledger> <meta> <sha> <reason> <path>
  local ledger=$1 meta=$2 sha=$3 reason=$4 path=$5 by
  by=${USER:-${LOGNAME:-unknown}}
  fm_verify_append "$ledger" override "$sha" "$path" "$reason" "$by" || return 1
  # A task with no metadata at all still gets its ledger record. Metadata that
  # exists but cannot be rewritten safely refuses, rather than losing the copy
  # silently.
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    fm_verify_meta_note_override "$meta" "$sha" "$reason" || return 1
  fi
  return 0
}

# fm_verify_refusal_report <merge-command> <verify-command>: the standard
# refusal block. Names what is missing, then the two ways forward, honest first.
fm_verify_refusal_report() {  # <merge-command> <verify-command>
  {
    printf 'REFUSED: %s\n' "$FM_VERIFY_REFUSAL"
    printf '\n'
    printf 'Nothing is merged. Firstmate will not land a commit it has no local\n'
    printf 'evidence for; forge checks are corroboration, never the requirement.\n'
    printf '\n'
    printf 'To merge honestly, verify this exact commit and record the result:\n'
    printf '  %s\n' "$2"
    printf '\n'
    printf 'If the verification itself is environmentally broken, the escape hatch is\n'
    printf 'deliberate, loud, and permanently recorded against the task:\n'
    printf '  FM_MERGE_OVERRIDE_ACK=%s \\\n' "$FM_VERIFY_OVERRIDE_ACK_VALUE"
    printf '    %s --override-unverified "<what is broken, and why merging anyway is right>"\n' "$1"
  } >&2
}
