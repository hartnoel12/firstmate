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
#   verify      <epoch> <sha> <outcome> <steps>  <note>
#   post-rebase <epoch> <sha> <outcome> <steps>  <note>
#   bypass      <epoch> <sha> <what>    <why>    <by>
#   override    <epoch> <sha> <path>    <reason> <by>
#
#   sha      full 40-hex commit the record is bound to ('-' for an unbound
#            bypass, which can never be superseded by evidence)
#   outcome  passed | failed - derived from real exit codes, never asserted
#   steps    name:passed,name:failed,... in the order they ran
#   note     for a verify record, `ignored=<count>:<digest>` - bin/fm-verify.sh
#            owns this: a stable digest of the worktree's gitignored untracked
#            paths at run time, so a later reader can tell whether two runs of
#            the same commit saw the same ignored-tree state. This gate never
#            reads or judges it; ignored content is recorded, never refused.
#            A post-rebase record's note is
#            `prior=<sha> carried=<steps|-> ignored=<count>:<digest>`: the
#            commit whose full record it relies on, and the declared steps it
#            did not run. The gate reads `prior=` and nothing else from it.
#   what     comma-separated bypassed step names, or '*' for "the whole run"
#
# A post-rebase record is the narrowed run POST-REBASE below describes. It is a
# distinct kind so no reader, human or gate, can mistake it for a full pass; a
# gate that predates the kind refuses it as unknown rather than misreading it.
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
#      step, and skipped is not passed. The one exception is a step CARRIED
#      from the prior of a post-rebase record bound to this commit, and only
#      when every POST-REBASE precondition below still holds at merge time;
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
# POST-REBASE. A rebase gives a branch a new head whose own change is the one
# already verified, on top of a newer upstream. Re-running every declared step
# there mostly re-proves what a rebase cannot have changed, but skipping them
# all is not safe either: a conflict-free rebase still breaks the build when the
# upstream changed something the branch calls, in a file the branch never
# touched, and nothing in the branch's own diff shows it. So a project may
# declare a post-rebase tier in config/verify/<project>, one
# `@post-rebase <step> <selector> [<pattern>...]` line per rule:
#
#   always                    every rebase re-runs the step
#   if-changed <pattern>...   re-run when a file matching a pattern differs
#                             between the prior and the new head
#   if-own-changed <pattern>... the same, restricted to files the branch's own
#                             change touches (the upstream's content was
#                             verified before it landed there)
#
# Patterns are shell `case` patterns matched against repository-relative paths,
# so `*` also matches `/`. Several rules for one step select it when any does.
# A tier must name only declared steps and include at least one `always` step,
# and a malformed tier line refuses both the run and the merge rather than
# reading as "no tier" - the same rule the declared step set already follows.
#
# `bin/fm-verify.sh run <task> --post-rebase <prior>` runs that tier, opt-in and
# never by default, and records a post-rebase record naming <prior>. It is
# accepted only while ALL of these hold. fm-verify.sh checks them before any
# step runs, and the gate checks them again at merge time from the ledger, the
# current declaration, and git, trusting nothing in the record beyond the step
# results it holds and the prior it names:
#
#   a. <prior> holds a FULL passing record on this task: every currently
#      declared step has a passing record bound to <prior> itself, and nothing
#      recorded there failed - exactly what rules 1-3 would accept for <prior>
#      with nothing carried. A step a post-rebase run carried is not a record at
#      its commit, so carried evidence can never anchor another rebase; the
#      original full record anchors any number of them, because rule b compares
#      against it directly.
#   b. the new head is a rebase of <prior>: the branch's own change - the diff
#      from where each commit forks off the project's upstream branch - is the
#      same on both sides, file for file, differing only in blob ids (`index`
#      lines) and hunk offsets. Reachability is deliberately not the test: a
#      rebased head does not contain its prior, and a head that does contain it
#      may carry new work. The diffs are taken with zero context lines, because
#      the upstream's own edits beside a branch hunk are not the branch's
#      change; any added or removed line, mode change, or file that differs
#      refuses, naming the files. The upstream is the project's default branch
#      as origin/HEAD names it (else main or master), as the remote-tracking
#      ref and as the local branch; a branch rebased onto any other base is
#      refused and verified in full.
#   c. every `always` step, and every step the diff between <prior> and the new
#      head selects, passed at the new head.
#
# A declared step the post-rebase run did not re-run is carried from <prior>
# for rule 3 alone. It does not supersede a bypass under rule 4, which still
# needs a passing record for the exact commit being merged.
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

# fm_verify_config_parse <config-file>: the one reader of a declaration. Echoes
# one "step<TAB><name><TAB><command>" line per declared step and one
# "rule<TAB><step><TAB><selector><TAB><patterns>" line per post-rebase tier
# rule (POST-REBASE above; patterns '-' for `always`), in file order, and only
# once the WHOLE file has validated, so no caller ever acts on part of one.
# Blank lines and # comments are ignored; a line without '=', an unusable step
# name, or a malformed tier line is a configuration error, reported and
# refused, so a typo silently lowers no bar.
#
# Absent is the one silent success: a project that declares nothing is a
# legitimate case and leaves the gate at its floor. A declaration that EXISTS
# but is unusable - a symlink, a directory, a device - is NOT the same thing as
# no declaration, and must never be read as one: that would quietly drop a
# project from its own declared bar back to the floor. It is reported and
# refused, the way this library refuses a symlinked ledger.
fm_verify_config_parse() {
  local file=$1 line name cmd rest selector patterns out='' declared=',' ruled=''
  local has_always=0
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
      '@post-rebase'|'@post-rebase '*|"@post-rebase$FM_VERIFY_TAB"*)
        rest=${line#@post-rebase}
        name='' selector='' patterns=''
        read -r name selector patterns <<< "$rest"
        patterns=$(printf '%s' "$patterns" | tr -s ' \t' '  ')
        if [ -z "$name" ] || [ -z "$selector" ]; then
          echo "error: $file: a post-rebase tier line needs a step and a selector: $line" >&2
          return 1
        fi
        if ! fm_verify_step_name_valid "$name"; then
          echo "error: $file: invalid step name '$name' in post-rebase tier line: $line" >&2
          return 1
        fi
        case "$selector" in
          always)
            if [ -n "$patterns" ]; then
              echo "error: $file: post-rebase step '$name' is always re-run and takes no path patterns: $line" >&2
              return 1
            fi
            patterns='-'
            has_always=1
            ;;
          if-changed|if-own-changed)
            if [ -z "$patterns" ]; then
              echo "error: $file: post-rebase selector '$selector' needs at least one path pattern: $line" >&2
              return 1
            fi
            ;;
          *)
            echo "error: $file: unknown post-rebase selector '$selector' (expected always, if-changed, or if-own-changed): $line" >&2
            return 1
            ;;
        esac
        ruled="$ruled$name,"
        out="${out}rule$FM_VERIFY_TAB$name$FM_VERIFY_TAB$selector$FM_VERIFY_TAB$patterns$FM_VERIFY_NL"
        continue
        ;;
      '@'*)
        echo "error: $file: unknown directive '${line%%[[:space:]]*}' (expected '@post-rebase <step> <selector> [<pattern>...]'): $line" >&2
        return 1
        ;;
    esac
    case "$line" in
      *=*) ;;
      *[![:space:]]*)
        echo "error: $file: expected '<step> = <command>', got: $line" >&2
        return 1
        ;;
      *) continue ;;
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
    declared="$declared$name,"
    out="${out}step$FM_VERIFY_TAB$name$FM_VERIFY_TAB$cmd$FM_VERIFY_NL"
  done < "$file"

  # Cross-checks that need the whole file: a tier step may be declared after the
  # rule that names it.
  rest=$ruled
  while [ -n "$rest" ]; do
    name=${rest%%,*}
    rest=${rest#*,}
    case "$declared" in
      *",$name,"*) ;;
      *)
        echo "error: $file: the post-rebase tier names undeclared step '$name'; declare it as '$name = <command>'" >&2
        return 1
        ;;
    esac
  done
  if [ -n "$ruled" ] && [ "$has_always" -eq 0 ]; then
    echo "error: $file: the post-rebase tier declares no '@post-rebase <step> always' step; a tier that can re-run nothing after a rebase cannot see the upstream breaking what the branch calls" >&2
    return 1
  fi
  printf '%s' "$out"
}

# fm_verify_config_select <config-file> <kind>: the fields after <kind> of every
# parsed line of that kind, one per line.
fm_verify_config_select() {  # <config-file> <kind>
  local parsed line
  parsed=$(fm_verify_config_parse "$1") || return 1
  while IFS= read -r line; do
    case "$line" in
      "$2$FM_VERIFY_TAB"*) printf '%s\n' "${line#"$2$FM_VERIFY_TAB"}" ;;
    esac
  done <<EOF
$parsed
EOF
}

# fm_verify_config_steps <config-file>: echo one "<step>\t<command>" line per
# declared step, validating the whole declaration first.
fm_verify_config_steps() {
  [ -n "${1:-}" ] || return 0
  fm_verify_config_select "$1" step
}

# fm_verify_required_steps <config-file>: comma-separated declared step names,
# empty when the project declares none.
fm_verify_required_steps() {
  local steps out
  steps=$(fm_verify_config_steps "$1") || return 1
  out=$(printf '%s' "$steps" | cut -f1 | paste -sd, - 2>/dev/null) || return 1
  printf '%s' "$out"
}

# fm_verify_rebase_rules <config-file>: one "<step>\t<selector>\t<patterns>"
# line per post-rebase tier rule, in file order; nothing when none is declared.
fm_verify_rebase_rules() {
  [ -n "${1:-}" ] || return 0
  fm_verify_config_select "$1" rule
}

# fm_verify_rebase_always <config-file>: comma-separated `always` tier steps,
# empty when the project declares no post-rebase tier.
fm_verify_rebase_always() {
  local rules line step selector out=','
  rules=$(fm_verify_rebase_rules "${1:-}") || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    step=${line%%"$FM_VERIFY_TAB"*}
    selector=${line#*"$FM_VERIFY_TAB"}
    selector=${selector%%"$FM_VERIFY_TAB"*}
    [ "$selector" = always ] || continue
    case "$out" in
      *",$step,"*) ;;
      *) out="$out$step," ;;
    esac
  done <<EOF
$rules
EOF
  out=${out#,}
  printf '%s' "${out%,}"
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

# fm_verify_ledger_read <ledger>: the one strict pass over the ledger. Leaves
# every verify and post-rebase record in FM_VERIFY_RUNS as
# "<kind>\t<sha>\t<outcome>\t<steps>\t<note>\n" and every bypass in
# FM_VERIFY_BYPASSES as "<what>\t<why>\n", in ledger order, so no rule needs to
# open the file a second time. 1, with FM_VERIFY_REFUSAL, on any record it
# cannot read. `|| [ -n "$line" ]` keeps the final record when the file lost its
# trailing newline: without it the LAST line is dropped silently, and the last
# line is exactly where a freshly recorded bypass is.
FM_VERIFY_RUNS=''
FM_VERIFY_BYPASSES=''
fm_verify_ledger_read() {  # <ledger>
  local line
  FM_VERIFY_RUNS=''
  FM_VERIFY_BYPASSES=''
  while IFS= read -r line || [ -n "$line" ]; do
    # A blank line is not a record this file's writers can produce, so it is
    # damage, not noise: skipping it is how a NUL-truncated record disappears
    # (Bash 3.2's read stops at a NUL and hands back an empty line, where Bash 5
    # hands back the bytes after it).
    if [ -z "$line" ] || ! fm_verify_record_split "$line"; then
      FM_VERIFY_REFUSAL="the verification ledger holds a record this gate cannot read, so what was verified cannot be established"
      return 1
    fi
    case "$FM_VERIFY_REC_KIND" in
      verify|post-rebase)
        FM_VERIFY_RUNS="$FM_VERIFY_RUNS$FM_VERIFY_REC_KIND$FM_VERIFY_TAB$FM_VERIFY_REC_SHA$FM_VERIFY_TAB$FM_VERIFY_REC_F4$FM_VERIFY_TAB$FM_VERIFY_REC_F5$FM_VERIFY_TAB$FM_VERIFY_REC_F6$FM_VERIFY_NL"
        ;;
      bypass)
        FM_VERIFY_BYPASSES="$FM_VERIFY_BYPASSES$FM_VERIFY_REC_F4$FM_VERIFY_TAB$FM_VERIFY_REC_F5$FM_VERIFY_NL"
        ;;
      override) ;;
      *)
        FM_VERIFY_REFUSAL="the verification ledger holds a record of unknown kind '$FM_VERIFY_REC_KIND', so what was verified cannot be established"
        return 1
        ;;
    esac
  done < "$1"
  return 0
}

# fm_verify_note_prior <note> <own-sha>: echo the one `prior=<sha>` a
# post-rebase record's note names. Non-zero when there is none, more than one,
# an unusable commit id, or the record's own commit.
fm_verify_note_prior() {  # <note> <own-sha>
  local note=" $1 " value
  case "$note" in
    *" prior="*) ;;
    *) return 1 ;;
  esac
  value=${note#*" prior="}
  case "$value" in
    *" prior="*) return 1 ;;
  esac
  value=${value%%" "*}
  fm_verify_sha_valid "$value" || return 1
  [ "$value" != "$2" ] || return 1
  printf '%s' "$value"
}

# fm_verify_tally <sha>: judge every loaded run bound to <sha>. Sets
#   FM_VERIFY_T_FOUND         1 when any verify or post-rebase record names it
#   FM_VERIFY_T_RUN_FAILED    1 when any of those runs did not pass
#   FM_VERIFY_T_FIRST_FAILED  the first step recorded failed there, if any
#   FM_VERIFY_T_PASSED        ",a,b," - every step recorded passed there
#   FM_VERIFY_T_EVIDENCE      "a:passed,b:passed" in first-seen order
#   FM_VERIFY_T_PRIORS        the priors its post-rebase records name
# 1, with FM_VERIFY_REFUSAL, when a record bound to <sha> is malformed.
FM_VERIFY_T_FOUND=0
FM_VERIFY_T_RUN_FAILED=0
FM_VERIFY_T_FIRST_FAILED=''
FM_VERIFY_T_PASSED=''
FM_VERIFY_T_EVIDENCE=''
FM_VERIFY_T_PRIORS=''
fm_verify_tally() {  # <sha>
  local sha=$1 rest line kind rsha outcome steps note srest pair name status prior
  FM_VERIFY_T_FOUND=0
  FM_VERIFY_T_RUN_FAILED=0
  FM_VERIFY_T_FIRST_FAILED=''
  FM_VERIFY_T_PASSED=''
    FM_VERIFY_T_EVIDENCE=''
  FM_VERIFY_T_PRIORS=''
  rest=$FM_VERIFY_RUNS
  while [ -n "$rest" ]; do
    line=${rest%%"$FM_VERIFY_NL"*}
    rest=${rest#*"$FM_VERIFY_NL"}
    kind=${line%%"$FM_VERIFY_TAB"*}
    line=${line#*"$FM_VERIFY_TAB"}
    rsha=${line%%"$FM_VERIFY_TAB"*}
    line=${line#*"$FM_VERIFY_TAB"}
    [ "$rsha" = "$sha" ] || continue
    outcome=${line%%"$FM_VERIFY_TAB"*}
    line=${line#*"$FM_VERIFY_TAB"}
    steps=${line%%"$FM_VERIFY_TAB"*}
    note=${line#*"$FM_VERIFY_TAB"}
    FM_VERIFY_T_FOUND=1
    case "$outcome" in
      passed|failed) ;;
      *)
        FM_VERIFY_REFUSAL="a verification run recorded for commit $sha has an unreadable outcome ('$outcome')"
        return 1
        ;;
    esac
    # Precedence (see header): a run that did not pass disqualifies its commit
    # outright, whatever a later run of the same commit says.
    [ "$outcome" = passed ] || FM_VERIFY_T_RUN_FAILED=1
    if [ "$kind" = post-rebase ]; then
      if ! prior=$(fm_verify_note_prior "$note" "$sha"); then
        FM_VERIFY_REFUSAL="a post-rebase record for commit $sha does not name one readable prior commit, so what it relies on cannot be established"
        return 1
      fi
      case " $FM_VERIFY_T_PRIORS " in
        *" $prior "*) ;;
        *) FM_VERIFY_T_PRIORS="${FM_VERIFY_T_PRIORS:+$FM_VERIFY_T_PRIORS }$prior" ;;
      esac
    fi
    if [ -z "$steps" ] || [ "$steps" = '-' ]; then
      continue
    fi
    srest=$steps
    while [ -n "$srest" ]; do
      pair=$(fm_verify_csv_head "$srest")
      srest=$(fm_verify_csv_tail "$srest")
      [ -n "$pair" ] || continue
      name=${pair%%:*}
      status=${pair#*:}
      if [ -z "$name" ] || [ "$name" = "$pair" ]; then
        FM_VERIFY_REFUSAL="a verification record for commit $sha is malformed and cannot be trusted"
        return 1
      fi
      case "$status" in
        passed)
          case "$FM_VERIFY_T_PASSED" in
            *",$name,"*) ;;
            *)
              FM_VERIFY_T_PASSED="${FM_VERIFY_T_PASSED:-,}$name,"
              FM_VERIFY_T_EVIDENCE="${FM_VERIFY_T_EVIDENCE:+$FM_VERIFY_T_EVIDENCE,}$name:passed"
              ;;
          esac
          ;;
        failed)
          [ -n "$FM_VERIFY_T_FIRST_FAILED" ] || FM_VERIFY_T_FIRST_FAILED=$name
          ;;
        *)
          FM_VERIFY_REFUSAL="verification step '$name' has an unreadable result ('$status') for commit $sha"
          return 1
          ;;
      esac
    done
  done
  return 0
}

# fm_verify_prior_full <prior> <required-csv>: 0 when the loaded ledger holds a
# FULL passing record for <prior> (POST-REBASE rule a). Otherwise 1, with
# FM_VERIFY_PRIOR_WHY saying what is missing.
FM_VERIFY_PRIOR_WHY=''
fm_verify_prior_full() {  # <prior> <required-csv>
  local rest req
  FM_VERIFY_PRIOR_WHY=''
  if ! fm_verify_tally "$1"; then
    FM_VERIFY_PRIOR_WHY=$FM_VERIFY_REFUSAL
    return 1
  fi
  if [ "$FM_VERIFY_T_FOUND" -eq 0 ]; then
    FM_VERIFY_PRIOR_WHY="no verification run is recorded for it on this task"
    return 1
  fi
  if [ -n "$FM_VERIFY_T_FIRST_FAILED" ]; then
    FM_VERIFY_PRIOR_WHY="step '$FM_VERIFY_T_FIRST_FAILED' is recorded failed there"
    return 1
  fi
  if [ "$FM_VERIFY_T_RUN_FAILED" -eq 1 ]; then
    FM_VERIFY_PRIOR_WHY="a run there is recorded failed"
    return 1
  fi
  if [ -z "$FM_VERIFY_T_PASSED" ]; then
    FM_VERIFY_PRIOR_WHY="the verification recorded there checked nothing"
    return 1
  fi
  rest=$2
  while [ -n "$rest" ]; do
    req=$(fm_verify_csv_head "$rest")
    rest=$(fm_verify_csv_tail "$rest")
    [ -n "$req" ] || continue
    case "$FM_VERIFY_T_PASSED" in
      *",$req,"*) ;;
      *)
        if [ -n "$FM_VERIFY_T_PRIORS" ]; then
          FM_VERIFY_PRIOR_WHY="declared step '$req' has no passing record there; a post-rebase run carried it, and a carried step never anchors another rebase"
        else
          FM_VERIFY_PRIOR_WHY="declared step '$req' has no passing record there"
        fi
        return 1
        ;;
    esac
  done
  return 0
}

# fm_verify_upstream_refs <repo>: the refs a task branch is rebased onto, one per
# line - the project's default branch (origin/HEAD's target, else main or
# master) as the remote-tracking ref and as the local branch, whichever exist.
fm_verify_upstream_refs() {  # <repo>
  local repo=$1 target name='' ref
  target=$(git -C "$repo" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null) || target=''
  case "$target" in
    refs/remotes/origin/?*) name=${target#refs/remotes/origin/} ;;
  esac
  if [ -z "$name" ]; then
    for ref in main master; do
      if git -C "$repo" rev-parse -q --verify "refs/remotes/origin/$ref^{commit}" >/dev/null 2>&1 \
        || git -C "$repo" rev-parse -q --verify "refs/heads/$ref^{commit}" >/dev/null 2>&1; then
        name=$ref
        break
      fi
    done
  fi
  [ -n "$name" ] || return 0
  for ref in "refs/remotes/origin/$name" "refs/heads/$name"; do
    if git -C "$repo" rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1; then
      printf '%s\n' "$ref"
    fi
  done
  return 0
}

# fm_verify_change_set <repo> <upstream> <commit> <out>: write <commit>'s own
# change - the diff from where it forks off <upstream> to it - to <out> in the
# rebase-invariant form of POST-REBASE rule b, and echo that fork point.
#
# Every option that could make two runs of one diff disagree, or hide a change
# from both, is pinned rather than left to git config: no external diff or
# textconv driver, no color, fixed prefixes, no rename detection (a similarity
# heuristic), submodule changes shown as their commit ids and never ignored.
# --binary keeps a changed binary file's content in the comparison instead of
# one "Binary files differ" line that two different changes share. -U0 drops
# context lines, and --inter-hunk-context=0 stops diff.interHunkContext from
# merging nearby hunks and pulling the lines between them back in. Then the only two
# things a rebase alone changes are normalized away: `index <blob>..<blob>`
# lines, and the offsets in `@@ -a,b +c,d @@ <heading>`, which keep only their
# line counts. Neither pattern can match a content line, which always starts
# with '+', '-', or '\', nor a base85 line of a binary patch, which never
# contains a space.
fm_verify_change_set() {  # <repo> <upstream> <commit> <out>
  local repo=$1 upstream=$2 commit=$3 out=$4 base
  base=$(git -C "$repo" merge-base "$upstream" "$commit" 2>/dev/null) || return 1
  fm_verify_sha_valid "$base" || return 1
  git -C "$repo" diff --no-ext-diff --no-textconv --no-color --no-renames \
    --submodule=short --ignore-submodules=none --inter-hunk-context=0 \
    --binary -U0 --src-prefix=a/ --dst-prefix=b/ "$base" "$commit" -- \
    > "$out.raw" 2>/dev/null || return 1
  awk '
    /^index / { next }
    /^@@ / && $4 == "@@" && $2 ~ /^-[0-9]+(,[0-9]+)?$/ && $3 ~ /^[+][0-9]+(,[0-9]+)?$/ {
      oc = (index($2, ",") ? substr($2, index($2, ",") + 1) : 1)
      nc = (index($3, ",") ? substr($3, index($3, ",") + 1) : 1)
      print "@@ -" oc " +" nc " @@"
      next
    }
    { print }
  ' "$out.raw" > "$out" || return 1
  rm -f -- "$out.raw"
  printf '%s' "$base"
}

# fm_verify_change_set_split <set> <dir> <side>: split one normalized change set
# into <dir>/<side>.<n> per file, indexed by "<n>\t<path>" lines in
# <dir>/<side>.index. With renames off a header is always `a/X b/X`, so X is
# recovered exactly; a quoted header is kept whole.
fm_verify_change_set_split() {  # <set> <dir> <side>
  : > "$2/$3.index" || return 1
  awk -v dir="$2" -v side="$3" '
    /^diff --git / {
      if (out != "") close(out)
      n++
      out = dir "/" side "." n
      name = substr($0, 12)
      l = length(name)
      if (substr(name, 1, 2) == "a/" && (l - 5) % 2 == 0) {
        k = (l - 5) / 2
        if (substr(name, 3 + k, 3) == " b/" && substr(name, 3, k) == substr(name, 6 + k)) {
          name = substr(name, 3, k)
        }
      }
      print n "\t" name >> (dir "/" side ".index")
    }
    out != "" { print > (out) }
  ' "$1"
}

# fm_verify_change_set_differences <prior-set> <head-set> <dir>: echo which
# files' changes differ between two normalized change sets, as
# "changed differently: a; only in the head: b; only in the prior: c".
fm_verify_change_set_differences() {  # <prior-set> <head-set> <dir>
  local dir=$3 where np nh path changed='' only_head='' only_prior='' out=''
  fm_verify_change_set_split "$1" "$dir" p || return 1
  fm_verify_change_set_split "$2" "$dir" h || return 1
  awk -F '\t' '
    FILENAME == ARGV[1] { p[$2] = $1; next }
    {
      if ($2 in p) { print "both\t" p[$2] "\t" $1 "\t" $2; seen[$2] = 1 }
      else print "head\t-\t" $1 "\t" $2
    }
    END { for (k in p) if (!(k in seen)) print "prior\t" p[k] "\t-\t" k }
  ' "$dir/p.index" "$dir/h.index" > "$dir/joined" || return 1
  while IFS="$FM_VERIFY_TAB" read -r where np nh path; do
    case "$where" in
      both)
        cmp -s "$dir/p.$np" "$dir/h.$nh" || changed="$changed$path$FM_VERIFY_NL"
        ;;
      head) only_head="$only_head$path$FM_VERIFY_NL" ;;
      prior) only_prior="$only_prior$path$FM_VERIFY_NL" ;;
    esac
  done < "$dir/joined"
  [ -z "$changed" ] || out="changed differently: $(fm_verify_list_join "$changed")"
  [ -z "$only_head" ] || out="${out:+$out; }only in the head: $(fm_verify_list_join "$only_head")"
  [ -z "$only_prior" ] || out="${out:+$out; }only in the prior: $(fm_verify_list_join "$only_prior")"
  printf '%s' "${out:-the files match but their changes do not}"
}

# fm_verify_list_join <newline-list>: the list sorted and joined with ", ".
fm_verify_list_join() {
  printf '%s' "$1" | LC_ALL=C sort | awk 'NF { printf "%s%s", (n++ ? ", " : ""), $0 }'
}

# fm_verify_rebase_equivalent <repo> <prior> <head>: 0 when <head> is a rebase of
# <prior> under POST-REBASE rule b, against any of the project's upstream refs,
# setting FM_VERIFY_REBASE_ONTO to that ref and FM_VERIFY_REBASE_BASE to the
# head's fork point off it. 1 when it is not, with FM_VERIFY_REFUSAL naming the
# files whose change differs. 2 when it cannot be established at all.
FM_VERIFY_REBASE_ONTO=''
FM_VERIFY_REBASE_BASE=''
fm_verify_rebase_equivalent() {  # <repo> <prior> <head>
  local repo=$1 prior=$2 head=$3 refs ref tmp base diffs='' against='' rc=2
  FM_VERIFY_REBASE_ONTO=''
  FM_VERIFY_REBASE_BASE=''
  refs=$(fm_verify_upstream_refs "$repo")
  if [ -z "$refs" ]; then
    FM_VERIFY_REFUSAL="cannot find the project's upstream branch (origin/HEAD, main, or master) in $repo, so whether $head is a rebase of $prior cannot be established"
    return 2
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-verify-rebase.XXXXXX") || {
    FM_VERIFY_REFUSAL="cannot create a temporary directory to compare $head with $prior"
    return 2
  }
  # Ref names cannot contain whitespace or glob characters, so word splitting
  # the newline-separated list is exact.
  # shellcheck disable=SC2086
  for ref in $refs; do
    fm_verify_change_set "$repo" "$ref" "$prior" "$tmp/prior" >/dev/null || continue
    base=$(fm_verify_change_set "$repo" "$ref" "$head" "$tmp/head") || continue
    if cmp -s "$tmp/prior" "$tmp/head"; then
      FM_VERIFY_REBASE_ONTO=$ref
      FM_VERIFY_REBASE_BASE=$base
      rc=0
      break
    fi
    if [ "$rc" -eq 2 ]; then
      diffs='the changes differ'
      if mkdir "$tmp/split"; then
        diffs=$(fm_verify_change_set_differences "$tmp/prior" "$tmp/head" "$tmp/split") \
          || diffs='the changes differ'
      fi
      against=$ref
      rc=1
    fi
  done
  rm -rf -- "$tmp"
  case "$rc" in
    0) return 0 ;;
    1)
      FM_VERIFY_REFUSAL="commit $head is not a rebase of $prior: the branch's own change against ${against#refs/} differs beyond blob ids and hunk offsets ($diffs)"
      return 1
      ;;
  esac
  FM_VERIFY_REFUSAL="cannot diff $prior and $head against the project's upstream branch in $repo, so whether $head is a rebase of $prior cannot be established"
  return 2
}

# fm_verify_rebase_select <repo> <prior> <head> <head-base> <config-file>: apply
# the declared tier to this rebase (POST-REBASE rule c). Sets
# FM_VERIFY_REBASE_SELECTED to ",a,b," - every step the tier re-runs - and
# FM_VERIFY_REBASE_REASONS to one "<step>\t<why>" line per step, in rule order.
# <head-base> is the head's fork point off its upstream, which bounds the
# branch's own files. A path the tier cannot represent (one holding a newline)
# selects every conditional step rather than none.
FM_VERIFY_REBASE_SELECTED=''
FM_VERIFY_REBASE_REASONS=''
fm_verify_rebase_select() {  # <repo> <prior> <head> <head-base> <config-file>
  local repo=$1 prior=$2 head=$3 base=$4 config=$5 rules tmp path changed='' own=''
  local odd=0 line step selector patterns why pat prest
  FM_VERIFY_REBASE_SELECTED=','
  FM_VERIFY_REBASE_REASONS=''
  rules=$(fm_verify_rebase_rules "$config") || return 1
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-verify-select.XXXXXX") || return 1
  if ! git -C "$repo" diff --name-only -z --no-renames --ignore-submodules=none \
    "$prior" "$head" -- > "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi
  while IFS= read -r -d '' path; do
    case "$path" in
      *"$FM_VERIFY_NL"*) odd=1 ;;
      *) changed="$changed$path$FM_VERIFY_NL" ;;
    esac
  done < "$tmp"
  if ! git -C "$repo" diff --name-only -z --no-renames --ignore-submodules=none \
    "$base" "$head" -- > "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi
  while IFS= read -r -d '' path; do
    case "$path" in
      *"$FM_VERIFY_NL"*) odd=1 ;;
      *) own="$own$path$FM_VERIFY_NL" ;;
    esac
  done < "$tmp"
  rm -f -- "$tmp"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    step=${line%%"$FM_VERIFY_TAB"*}
    line=${line#*"$FM_VERIFY_TAB"}
    selector=${line%%"$FM_VERIFY_TAB"*}
    patterns=${line#*"$FM_VERIFY_TAB"}
    case "$FM_VERIFY_REBASE_SELECTED" in
      *",$step,"*) continue ;;
    esac
    why=''
    if [ "$selector" = always ]; then
      why='always re-run after a rebase'
    elif [ "$odd" -eq 1 ]; then
      why='the rebase changed a path this tier cannot represent'
    else
      while IFS= read -r path; do
        [ -n "$path" ] || continue
        if [ "$selector" = if-own-changed ]; then
          case "$FM_VERIFY_NL$own" in
            *"$FM_VERIFY_NL$path$FM_VERIFY_NL"*) ;;
            *) continue ;;
          esac
        fi
        prest="$patterns "
        while [ -n "$prest" ]; do
          pat=${prest%%" "*}
          prest=${prest#*" "}
          [ -n "$pat" ] || continue
          # Unquoted on purpose: the declared pattern is a shell pattern.
          # shellcheck disable=SC2254
          case "$path" in
            $pat)
              if [ "$selector" = if-own-changed ]; then
                why="$path, one of the branch's own files, changed"
              else
                why="$path changed"
              fi
              break 2
              ;;
          esac
        done
      done <<EOF
$changed
EOF
    fi
    [ -n "$why" ] || continue
    FM_VERIFY_REBASE_SELECTED="$FM_VERIFY_REBASE_SELECTED$step,"
    FM_VERIFY_REBASE_REASONS="$FM_VERIFY_REBASE_REASONS$step$FM_VERIFY_TAB$why$FM_VERIFY_NL"
  done <<EOF
$rules
EOF
  return 0
}

# fm_verify_post_rebase_holds <sha> <passed-set> <priors> <required-csv>
# <config-file> <repo>: 0 when every POST-REBASE precondition still holds for
# every prior the post-rebase records bound to <sha> name, so the declared steps
# they did not re-run may be carried. Otherwise 1, with FM_VERIFY_REFUSAL.
# Every named prior must hold, not just one: a prior recorded failed is evidence
# against this head's change, whatever another prior says.
fm_verify_post_rebase_holds() {  # <sha> <passed-set> <priors> <required-csv> <config-file> <repo>
  local sha=$1 passed=$2 priors=$3 required=$4 config=$5 repo=$6
  local always prior line step why
  if [ -z "$config" ] || [ -z "$repo" ]; then
    FM_VERIFY_REFUSAL="a post-rebase run is recorded for commit $sha, but this merge path did not supply the project's declaration and repository needed to check it"
    return 1
  fi
  if ! always=$(fm_verify_rebase_always "$config" 2>/dev/null); then
    FM_VERIFY_REFUSAL="the project's verification declaration cannot be read, so the post-rebase run recorded for commit $sha cannot be checked"
    return 1
  fi
  if [ -z "$always" ]; then
    FM_VERIFY_REFUSAL="a post-rebase run is recorded for commit $sha, but the project declares no post-rebase tier, so nothing can be carried from its prior"
    return 1
  fi
  # Priors are validated 40-hex commit ids, so word splitting is exact.
  # shellcheck disable=SC2086
  for prior in $priors; do
    if ! fm_verify_prior_full "$prior" "$required"; then
      FM_VERIFY_REFUSAL="the post-rebase run recorded for commit $sha relies on commit $prior, but there is no full passing record for $prior ($FM_VERIFY_PRIOR_WHY)"
      return 1
    fi
    fm_verify_rebase_equivalent "$repo" "$prior" "$sha" || return 1
    if ! fm_verify_rebase_select "$repo" "$prior" "$sha" "$FM_VERIFY_REBASE_BASE" "$config"; then
      FM_VERIFY_REFUSAL="cannot apply the post-rebase tier to the rebase from $prior to $sha in $repo"
      return 1
    fi
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      step=${line%%"$FM_VERIFY_TAB"*}
      why=${line#*"$FM_VERIFY_TAB"}
      case "$passed" in
        *",$step,"*) ;;
        *)
          FM_VERIFY_REFUSAL="the post-rebase tier re-runs '$step' after the rebase from $prior ($why), and '$step' has no passing record for commit $sha"
          return 1
          ;;
      esac
    done <<EOF
$FM_VERIFY_REBASE_REASONS
EOF
  done
  return 0
}

# fm_verify_gate <ledger> <sha> <required-csv> [<meta>] [<config-file> <repo>]:
# 0 when the exact commit has genuine, complete, unbypassed local verification
# evidence. 1 otherwise, with FM_VERIFY_REFUSAL explaining which of the four
# rules failed. <meta> is the task's metadata file, the bypass record's second
# home; omitting it consults the ledger alone. <config-file> and <repo> are the
# project's declaration and repository, which a post-rebase record is checked
# against; without them no step is ever carried, so omitting them only refuses.
fm_verify_gate() {  # <ledger> <sha> <required-csv> [<meta>] [<config-file> <repo>]
  local ledger=$1 sha=$2 required=${3:-} meta=${4:-} config=${5:-} repo=${6:-}
  local line what why value rest req passed evidence priors missing='' first_missing=''

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

  fm_verify_ledger_read "$ledger" || return 1
  fm_verify_tally "$sha" || return 1
  passed=$FM_VERIFY_T_PASSED
  evidence=$FM_VERIFY_T_EVIDENCE
  priors=$FM_VERIFY_T_PRIORS

  # Rule 1: some run is bound to this exact commit.
  if [ "$FM_VERIFY_T_FOUND" -eq 0 ]; then
    FM_VERIFY_REFUSAL="no local verification run is recorded for commit $sha (a run on the same branch is not evidence: the branch moves)"
    return 1
  fi

  # Rule 2: nothing recorded for this commit failed. Worst outcome wins, so a
  # later passing re-run of the same commit does not erase an earlier failure.
  if [ -n "$FM_VERIFY_T_FIRST_FAILED" ] || [ "$FM_VERIFY_T_RUN_FAILED" -eq 1 ]; then
    if [ -n "$FM_VERIFY_T_FIRST_FAILED" ]; then
      why="step '$FM_VERIFY_T_FIRST_FAILED' is recorded failed"
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
  # not passed - unless a post-rebase record bound to this commit carries it,
  # and every POST-REBASE precondition still holds now.
  rest=$required
  while [ -n "$rest" ]; do
    req=$(fm_verify_csv_head "$rest")
    rest=$(fm_verify_csv_tail "$rest")
    [ -n "$req" ] || continue
    case "$passed" in
      *",$req,"*) ;;
      *)
        [ -n "$first_missing" ] || first_missing=$req
        missing="${missing:+$missing,}$req"
        ;;
    esac
  done
  if [ -n "$missing" ]; then
    if [ -z "$priors" ]; then
      FM_VERIFY_REFUSAL="required verification step '$first_missing' has no passing record for commit $sha (declared for this project but not run)"
      return 1
    fi
    fm_verify_post_rebase_holds "$sha" "$passed" "$priors" "$required" "$config" "$repo" || return 1
    evidence="$evidence; post-rebase of $priors, carried: $missing"
  fi

  # Rule 4: any recorded bypass survives unless the exact commit has positive
  # evidence for every step it named. Both durable homes are consulted, because
  # this is the one rule the gate cannot check against evidence of its own. The
  # ledger's bypasses were collected by the single read above; neither field can
  # hold a TAB or a newline, because the split rejects a seventh field and `read`
  # ends a record at the newline. A carried step is not evidence for this commit,
  # so it never supersedes a bypass.
  rest=$FM_VERIFY_BYPASSES
  while [ -n "$rest" ]; do
    line=${rest%%"$FM_VERIFY_NL"*}
    rest=${rest#*"$FM_VERIFY_NL"}
    [ -n "$line" ] || continue
    what=${line%%"$FM_VERIFY_TAB"*}
    why=${line#*"$FM_VERIFY_TAB"}
    if fm_verify_bypass_survives "$what" "$why" "$passed" "$sha"; then
      fm_verify_bypass_carried_note "$missing"
      return 1
    fi
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
      if fm_verify_bypass_survives "$what" "$why" "$passed" "$sha"; then
        fm_verify_bypass_carried_note "$missing"
        return 1
      fi
    done < "$meta"
  fi

  # shellcheck disable=SC2034  # Read by the sourcing merge scripts.
  FM_VERIFY_EVIDENCE=$evidence
  return 0
}

# fm_verify_bypass_carried_note <carried-csv>: when a bypass refuses a commit
# that carried steps from a post-rebase prior, say why the carried steps did not
# supersede it, so the refusal does not read as contradicting the prior's pass.
fm_verify_bypass_carried_note() {  # <carried-csv>
  [ -n "${1:-}" ] || return 0
  FM_VERIFY_REFUSAL="$FM_VERIFY_REFUSAL; the steps carried from a post-rebase prior ($1) are not records for this commit, so they never supersede a bypass"
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
# `)` of a command substitution: one apostrophe written into the banner PROSE
# below would break the parse of this whole file on a macOS fleet member. The
# hazard is the literal source text, not the operator's $reason, which arrives
# at runtime and never reaches the parser - so this wording is one edit away
# from the failure at any time. bin/fm-bash-syntax-check.sh's header owns that
# rule and its full rationale, and the ban on the idiom is structural.
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
