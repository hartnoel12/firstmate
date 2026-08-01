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
#   1. at least one verify record exists whose sha equals that commit - a run on
#      the same BRANCH is not evidence, because the branch moves;
#   2. EVERY verify record for that commit passed, and no step named in any of
#      them is recorded failed (see PRECEDENCE below);
#   3. every step the project declares required (config/verify/<project>) is in
#      the passing union - a declared step absent from every run is a SKIPPED
#      step, and skipped is not passed;
#   4. no bypass recorded against the task survives, in EITHER durable record
#      (see TWO RECORDS below). A bypass naming steps is superseded only by
#      positive evidence: each named step must itself be in the passing union
#      for this exact commit. An unbound or '*' bypass can never be superseded,
#      so it always refuses.
#
# Rule 4 is what makes an unaccounted-for bypass fail CLOSED. Recording a
# bypass cannot make a merge easier - only harder - so the record has no
# incentive to be omitted, and omitting it is the one failure mode firstmate
# must not reward.
#
# PRECEDENCE, when one commit carries more than one run of the same step.
# The worst outcome wins and it is sticky: a step counts as passed only when it
# is recorded passed at least once and recorded failed no times, and a run whose
# outcome is not `passed` disqualifies its commit outright. Neither naive rule
# is acceptable here. Latest-wins is worse than useless, because the tree did
# not change between the two runs - the disagreement is the step's own
# nondeterminism, not progress - so resolving it in favour of the later pass
# makes re-running the cheapest way to launder a red result into a green one.
# First-wins has the mirror problem. Worst-wins states the honest reading: a
# step that passes sometimes and fails sometimes at one commit has not verified
# that commit. The ways past it are the honest ones that already exist - change
# the commit (fixing a flaky step is itself a code change, and a new commit gets
# a clean slate), record a bypass, or take the loud recorded override.
#
# TWO RECORDS FOR A BYPASS. A bypass is written to the ledger AND to the task's
# metadata (`bypassed=<what>|<why>`), the same belt-and-braces the override has
# always used, and the gate consults both. This is deliberately not the elegant
# design: it exists because the ledger is the one input the gate cannot verify
# for itself. Every other rule is checked against evidence the gate produces;
# rule 4 is checked against a record something else had to write, so losing that
# file, truncating its last line, or damaging one byte of it must not quietly
# turn a bypassed merge into a clean one. For the same reason every record this
# gate reads is parsed strictly: a line it cannot split into exactly six fields,
# or whose kind it does not recognise, refuses the merge instead of being
# skipped as noise.
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

# --- reading records back ---------------------------------------------------

# The record separator, as a variable so the split below can quote it into a
# pattern. Assigned once on source; harmless to reassign.
FM_VERIFY_TAB=$(printf '\t')
# The line separator, for walking records the gate accumulated itself. A command
# substitution cannot produce it: it strips trailing newlines.
FM_VERIFY_NL='
'

# fm_verify_record_split <line>: split one ledger line into exactly six fields,
# leaving them in FM_VERIFY_REC_*. Returns non-zero for anything else.
#
# `IFS=$'\t' read -r a b c ...` cannot be used for this. TAB is IFS whitespace,
# so read folds a run of tabs into a single separator: one empty field and every
# field after it shifts left, turning a bypass's `why` into its `what` with no
# error anywhere. Writers never emit an empty field (fm_verify_field_clean maps
# empty to '-'), so a line that needs that folding is a damaged line, and the
# gate must refuse it rather than read it wrong.
FM_VERIFY_REC_KIND=''
FM_VERIFY_REC_TS=''
FM_VERIFY_REC_SHA=''
FM_VERIFY_REC_F4=''
FM_VERIFY_REC_F5=''
FM_VERIFY_REC_F6=''
fm_verify_record_split() {  # <line>
  local rest=$1 field n=0
  FM_VERIFY_REC_KIND=''
  FM_VERIFY_REC_TS=''
  FM_VERIFY_REC_SHA=''
  FM_VERIFY_REC_F4=''
  FM_VERIFY_REC_F5=''
  FM_VERIFY_REC_F6=''
  while [ "$n" -lt 5 ]; do
    field=${rest%%"$FM_VERIFY_TAB"*}
    [ "$field" != "$rest" ] || return 1
    rest=${rest#*"$FM_VERIFY_TAB"}
    n=$((n + 1))
    case "$n" in
      1) FM_VERIFY_REC_KIND=$field ;;
      2) FM_VERIFY_REC_TS=$field ;;
      3) FM_VERIFY_REC_SHA=$field ;;
      4) FM_VERIFY_REC_F4=$field ;;
      5) FM_VERIFY_REC_F5=$field ;;
    esac
  done
  case "$rest" in
    *"$FM_VERIFY_TAB"*) return 1 ;;
  esac
  FM_VERIFY_REC_F6=$rest
  return 0
}

# --- the gate ---------------------------------------------------------------

# Set by fm_verify_gate on refusal: one plain sentence naming what is missing.
FM_VERIFY_REFUSAL=''
# Set by fm_verify_gate on success: the steps that carried the commit, for the
# merge output, so a passing gate still says what it actually checked.
FM_VERIFY_EVIDENCE=''

# fm_verify_csv_head <csv> / fm_verify_csv_tail <csv>: echo the first element of
# a comma-separated list, and everything after it, so the gate can walk one
# without building an array. An empty array expanded as
# "${a[@]}" is a fatal unbound-variable error under `set -u` on Bash 3.2, which
# is the system Bash on the macOS half of this fleet, so the gate walks strings.
fm_verify_csv_head() { printf '%s' "${1%%,*}"; }
fm_verify_csv_tail() {
  local csv=$1
  case "$csv" in
    *,*) printf '%s' "${csv#*,}" ;;
    *) printf '%s' '' ;;
  esac
}

# fm_verify_gate <ledger> <sha> <required-csv> [<meta>]: 0 when the exact commit
# has genuine, complete, unbypassed local verification evidence. 1 otherwise,
# with FM_VERIFY_REFUSAL explaining which of the four rules failed. <meta> is the
# task's metadata file, the bypass record's second home; omitting it consults the
# ledger alone.
fm_verify_gate() {  # <ledger> <sha> <required-csv> [<meta>]
  local ledger=$1 sha=$2 required=${3:-} meta=${4:-}
  local line kind outcome steps what why value
  local found=0 rest pair name status req run_failed=0
  local passed='' evidence='' first_failed_step='' bypasses=''

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

  # One strict pass over the ledger, the only read of it. Bypass records are
  # collected here and judged after the loop, once `passed` is complete, so no
  # rule needs to open the file a second time. `|| [ -n "$line" ]` keeps the
  # final record when the file lost its trailing newline: without it the LAST
  # line is dropped silently, and the last line is exactly where a freshly
  # recorded bypass is.
  while IFS= read -r line || [ -n "$line" ]; do
    # A blank line is not a record this file's writers can produce, so it is
    # damage, not noise: skipping it is how a NUL-truncated record disappears
    # (Bash 3.2's read stops at a NUL and hands back an empty line, where Bash 5
    # hands back the bytes after it).
    if [ -z "$line" ] || ! fm_verify_record_split "$line"; then
      FM_VERIFY_REFUSAL="the verification ledger holds a record this gate cannot read, so what was verified cannot be established"
      return 1
    fi
    kind=$FM_VERIFY_REC_KIND
    case "$kind" in
      verify|bypass|override) ;;
      *)
        FM_VERIFY_REFUSAL="the verification ledger holds a record of unknown kind '$kind', so what was verified cannot be established"
        return 1
        ;;
    esac
    if [ "$kind" = bypass ]; then
      bypasses="$bypasses$FM_VERIFY_REC_F4$FM_VERIFY_TAB$FM_VERIFY_REC_F5$FM_VERIFY_NL"
      continue
    fi
    [ "$kind" = verify ] || continue
    [ "$FM_VERIFY_REC_SHA" = "$sha" ] || continue
    found=1
    outcome=$FM_VERIFY_REC_F4
    steps=$FM_VERIFY_REC_F5
    case "$outcome" in
      passed|failed) ;;
      *)
        FM_VERIFY_REFUSAL="a verification run recorded for commit $sha has an unreadable outcome ('$outcome')"
        return 1
        ;;
    esac
    # Precedence (see header): a run that did not pass disqualifies its commit
    # outright, whatever a later run of the same commit says.
    [ "$outcome" = passed ] || run_failed=1
    if [ -z "$steps" ] || [ "$steps" = '-' ]; then
      continue
    fi
    rest=$steps
    while [ -n "$rest" ]; do
      pair=$(fm_verify_csv_head "$rest")
      rest=$(fm_verify_csv_tail "$rest")
      [ -n "$pair" ] || continue
      name=${pair%%:*}
      status=${pair#*:}
      if [ -z "$name" ] || [ "$name" = "$pair" ]; then
        FM_VERIFY_REFUSAL="a verification record for commit $sha is malformed and cannot be trusted"
        return 1
      fi
      case "$status" in
        passed)
          case "$passed" in
            *",$name,"*) ;;
            *) passed="$passed,$name,"; evidence="${evidence:+$evidence,}$name:passed" ;;
          esac
          ;;
        failed)
          [ -n "$first_failed_step" ] || first_failed_step=$name
          ;;
        *)
          FM_VERIFY_REFUSAL="verification step '$name' has an unreadable result ('$status') for commit $sha"
          return 1
          ;;
      esac
    done
  done < "$ledger"

  # Rule 1: some run is bound to this exact commit.
  if [ "$found" -eq 0 ]; then
    FM_VERIFY_REFUSAL="no local verification run is recorded for commit $sha (a run on the same branch is not evidence: the branch moves)"
    return 1
  fi

  # Rule 2: nothing recorded for this commit failed. Worst outcome wins, so a
  # later passing re-run of the same commit does not erase an earlier failure.
  if [ -n "$first_failed_step" ] || [ "$run_failed" -eq 1 ]; then
    if [ -n "$first_failed_step" ]; then
      why="step '$first_failed_step' is recorded failed"
    else
      why="a run for this commit is recorded failed"
    fi
    FM_VERIFY_REFUSAL="the verification recorded for commit $sha did not pass ($why); a later passing run of the same commit does not supersede that, because the code did not change between them"
    return 1
  fi
  if [ -z "$passed" ]; then
    FM_VERIFY_REFUSAL="the verification recorded for commit $sha checked nothing"
    return 1
  fi

  # Rule 3: a declared step missing from every run was skipped, and skipped is
  # not passed.
  rest=$required
  while [ -n "$rest" ]; do
    req=$(fm_verify_csv_head "$rest")
    rest=$(fm_verify_csv_tail "$rest")
    [ -n "$req" ] || continue
    case "$passed" in
      *",$req,"*) ;;
      *)
        FM_VERIFY_REFUSAL="required verification step '$req' has no passing record for commit $sha (declared for this project but not run)"
        return 1
        ;;
    esac
  done

  # Rule 4: any recorded bypass survives unless the exact commit has positive
  # evidence for every step it named. Both durable homes are consulted, because
  # this is the one rule the gate cannot check against evidence of its own. The
  # ledger's bypasses were collected by the single pass above; neither field can
  # hold a TAB or a newline, because the split rejects a seventh field and `read`
  # ends a record at the newline.
  rest=$bypasses
  while [ -n "$rest" ]; do
    line=${rest%%"$FM_VERIFY_NL"*}
    rest=${rest#*"$FM_VERIFY_NL"}
    [ -n "$line" ] || continue
    what=${line%%"$FM_VERIFY_TAB"*}
    why=${line#*"$FM_VERIFY_TAB"}
    fm_verify_bypass_survives "$what" "$why" "$passed" "$sha" && return 1
  done

  if [ -n "$meta" ] && [ -f "$meta" ] && [ ! -L "$meta" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        bypassed=*) ;;
        *) continue ;;
      esac
      value=${line#bypassed=}
      what=${value%%|*}
      if [ "$what" = "$value" ]; then
        why='-'
      else
        why=${value#*|}
      fi
      fm_verify_bypass_survives "$what" "$why" "$passed" "$sha" && return 1
    done < "$meta"
  fi

  # shellcheck disable=SC2034  # Read by the sourcing merge scripts.
  FM_VERIFY_EVIDENCE=$evidence
  return 0
}

# fm_verify_bypass_survives <what> <why> <passed-set> <sha>: 0 (and sets
# FM_VERIFY_REFUSAL) when this bypass still blocks the merge. An unscoped or
# unreadable `what` can never be superseded, so it always survives.
fm_verify_bypass_survives() {  # <what> <why> <passed-set> <sha>
  local what=$1 why=$2 passed=$3 sha=$4 rest name
  case "$what" in
    ''|'*'|'-')
      FM_VERIFY_REFUSAL="an unscoped bypass is recorded against this task ($why) and nothing can supersede it"
      return 0
      ;;
  esac
  rest=$what
  while [ -n "$rest" ]; do
    name=$(fm_verify_csv_head "$rest")
    rest=$(fm_verify_csv_tail "$rest")
    [ -n "$name" ] || continue
    case "$passed" in
      *",$name,"*) ;;
      *)
        FM_VERIFY_REFUSAL="a bypass of '$name' is recorded against this task ($why) and '$name' has no passing record for commit $sha"
        return 0
        ;;
    esac
  done
  return 1
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

# fm_verify_override_banner <sha> <reason> <refusal>: the banner text. It lives
# in a function body rather than inline in a `banner=$(cat <<EOF ...)`, because
# Bash 3.2 tracks quote state through a heredoc while scanning for the closing
# `)` of a command substitution: one apostrophe in an operator's override reason
# would break the parse of this whole file on a macOS fleet member.
# bin/fm-bash-syntax-check.sh's header owns that rule and its full rationale.
fm_verify_override_banner() {  # <sha> <reason> <refusal>
  local sha=$1 reason=$2 refusal=$3
  cat <<EOF
################################################################################
##  MERGING WITHOUT VERIFICATION EVIDENCE
##  commit : $sha
##  gate   : $refusal
##  reason : $reason
##  This override is recorded in the task's verification ledger and metadata.
################################################################################
EOF
}

# fm_verify_override_announce <sha> <reason> <refusal>: the loud half. Printed
# to BOTH stdout and stderr so it survives whichever stream the caller keeps.
fm_verify_override_announce() {  # <sha> <reason> <refusal>
  local banner
  banner=$(fm_verify_override_banner "$@")
  printf '%s\n' "$banner"
  printf '%s\n' "$banner" >&2
}

# --- the second home for bypasses and overrides -----------------------------
#
# bin/fm-pr-lib.sh parses a task's .meta under a strict rule: after the pr= line
# nothing but pr_head= and a short x_* allowlist may appear, because everything
# else there is treated as post-recording injection. An override reason and a
# bypass reason are operator free text - precisely what that guard exists to
# reject - so appending the note would invalidate the metadata for every later
# reader of it (the armed poll's retirement receipt, the check migration's
# canonicality test). The note is therefore INSERTED BEFORE the first pr= line,
# through the same temp-file-then-mv rewrite bin/fm-pr-check.sh uses, preserving
# 0600, the single link, and the containing device. bin/fm-pr-check.sh rebuilds
# the file by keeping every non-pr line and re-appending pr=/pr_head= last, so a
# note written here stays ahead of pr= across later PR recordings.
#
# Two notes ride along here:
#   merged_unverified=<sha>|<reason>   an override that was taken
#   bypassed=<what>|<why>              a gate firstmate authorized to be skipped
#
# The ledger stays the primary trail; these copies must never cost the metadata
# they ride along in.

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
# merged_unverified=<sha>|<reason> line into <meta>. An override that cannot be
# recorded is an override that is not taken.
fm_verify_meta_note_override() {  # <meta> <sha> <reason>
  fm_verify_meta_note_write "$1" "merged_unverified=$2|$(fm_verify_field_clean "$3")"
}

# fm_verify_meta_note_bypass <meta> <what> <why>: write one
# bypassed=<what>|<why> line into <meta>, the bypass record's second home.
fm_verify_meta_note_bypass() {  # <meta> <what> <why>
  fm_verify_meta_note_write "$1" "bypassed=$(fm_verify_field_clean "$2")|$(fm_verify_field_clean "$3")"
}

# fm_verify_meta_note_write <meta> <note>: write one <note> line into <meta>,
# before its first pr= line or at the end when it has none. The original is left
# untouched unless the replacement is proven complete.
fm_verify_meta_note_write() {  # <meta> <note>
  local meta=$1 note=$2 dir device before rc=0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(fm_verify_file_link_count "$meta")" = 1 ] || return 1
  dir=$(dirname -- "$meta")
  device=$(fm_verify_file_device "$dir") || return 1
  [ -n "$device" ] || return 1
  [ "$(fm_verify_file_device "$meta")" = "$device" ] || return 1
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

# fm_verify_record_bypass <ledger> <meta> <sha> <what> <why> <by>: the same
# durable half for a bypass. The ledger is the primary trail; the metadata note
# is the copy that survives losing it. A task with no metadata at all still gets
# its ledger record. Metadata that exists but cannot be written refuses, rather
# than losing the copy silently - and the ledger record is deliberately kept, so
# the bypass still blocks the merge while only its second home is missing. That
# case returns 2, so the caller can say which of the two homes is missing; 1 is
# the ledger append itself failing, where nothing was recorded.
fm_verify_record_bypass() {  # <ledger> <meta> <sha> <what> <why> <by>
  local ledger=$1 meta=$2 sha=$3 what=$4 why=$5 by=$6
  fm_verify_append "$ledger" bypass "$sha" "$what" "$why" "$by" || return 1
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    fm_verify_meta_note_bypass "$meta" "$what" "$why" || return 2
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
