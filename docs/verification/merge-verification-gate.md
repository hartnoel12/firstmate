# Verification: the merge verification gate

Active empirical evidence for the guarantee that `bin/fm-pr-merge.sh` and `bin/fm-merge-local.sh` refuse to land a commit Firstmate holds no local verification evidence for.
`bin/fm-verify-lib.sh` owns the contract itself; this record holds the measurements that justify its shape.

## Why the gate does not consult the no-mistakes run record

Date: 2026-07-26.
Subject: no-mistakes run `01KYG4AK1MJJT2939M25AX7FAY`, whose `ci` step was force-approved over three failing checks, and whose `push` step ran with commit hooks disabled.

```
$ sqlite3 ~/.no-mistakes/state.sqlite \
  "select step_name,status,exit_code from step_results where run_id='01KYG4AK1MJJT2939M25AX7FAY'"
intent|completed|0
rebase|completed|0
review|completed|0
test|completed|0
document|completed|0
lint|completed|0
push|completed|0
pr|completed|0
ci|completed|0
```

```
$ sqlite3 -header ~/.no-mistakes/state.sqlite \
  "select sr.step_name, r.round, r.trigger_type, r.selection_source, r.fix_summary
     from step_results sr join step_rounds r on r.step_result_id = sr.id
    where sr.run_id='01KYG4AK1MJJT2939M25AX7FAY' and sr.step_name in ('ci','push','review')"
step_name|round|trigger_type|selection_source|fix_summary
review|1|initial|user|
review|2|auto_fix|user|gate public cache header on viewer-independent restaurant payloads
review|3|auto_fix||align restaurant detail cache headers across miss and hit
push|1|initial||
ci|1|initial||
```

The force-approved `ci` step is byte-identical to a step that genuinely passed: `completed`, exit `0`, one initial round, no selection source, no fix summary.
No column anywhere in the schema (`runs`, `step_results`, `step_rounds`, `agent_invocations`, `run_agent_sessions`) records that an agent approved the step rather than observing it pass.

no-mistakes is a separate installed tool, so this cannot be fixed in Firstmate.
Two consequences the gate is built around:

1. The gate never treats a no-mistakes run as evidence, because that record overstates what was verified, and a record that overstates is worse than no record.
2. Firstmate keeps its own account instead: `bin/fm-verify.sh` executes the verification commands itself and records real exit codes, and an authorized bypass is recorded explicitly so the gate can consult it.

Honest resolution of gate outcomes remains the correct upstream request to no-mistakes (`passed` versus `approved-over-red`, a hook-bypassed push, a skipped step rendered rather than omitted).
The local gate does not wait on it.

## Why the gate is not a CI-rollup check

The obvious gate - refuse unless the forge reports every check green - is unenforceable in this fleet.
Its GitHub Actions budget runs out, checks go dark for that reason, and branch protection is unavailable on the product repository's plan.
A gate that cannot be satisfied exactly when it matters most is a gate agents route around, so forge checks are corroboration here and never the requirement.

## Refusals observed firing

Date: 2026-07-26.
Command: `bash tests/fm-merge-verification.test.sh`.
Each case constructs the failing situation against the real scripts and real git repositories, and asserts that nothing landed - local `main` did not move, or the forge CLI was never asked to merge - rather than asserting on message text.

```
ok - local merge refuses a commit with no verification record
ok - PR merge refuses a PR head with no verification record, without calling the forge
ok - local merge refuses when the record's commit is not the branch tip
ok - PR merge refuses when the record's commit is not the PR head
ok - both merge paths refuse a verification record whose step failed
ok - a project-declared required step that never ran refuses, and running it clears the refusal
ok - a recorded bypass refuses the merge even though the run itself passed
ok - PR merge refuses while a recorded bypass has no passing evidence
ok - an unscoped bypass can never be superseded by later evidence
ok - a scoped bypass is superseded only by a passing record of that step for the exact commit
ok - a genuinely verified commit merges on both paths with no new friction
ok - the override refuses without its acknowledgement or with a thin reason
ok - the override merges, announces loudly on both streams, and records durably
ok - fm-verify.sh refuses to record evidence for a dirty worktree
ok - PR merge refuses when the forge cannot report the head commit to bind evidence to
ok - a returned worktree still resolves the PR head, so evidence is not lost to cleanup
ok - the override's metadata note leaves the task's PR metadata and armed poll intact
ok - an override whose metadata record cannot be written is refused, not taken
ok - a declared step set that exists but is unusable refuses instead of silently requiring nothing
ok - a declared step that reads stdin cannot swallow the steps after it
```

Four of those cases guard the gate's own record-keeping rather than a merge refusal, and each was watched failing against the pre-fix scripts before being encoded.
The override's metadata note is inserted before the `pr=` line, because `bin/fm-pr-lib.sh` treats everything after `pr=` as post-recording injection and an override reason is operator free text.
That rewrite checks every write and then proves the replacement is the original plus exactly the note line before it replaces anything, so a filesystem that fills partway through refuses the override instead of installing a plausible-looking truncation, and its temporary copy of the metadata is removed on signal as well as on every return path.
A declared step set that exists but is unusable - a symlink, a directory - is refused rather than read as "this project declares nothing", which would silently drop the project from its own declared bar back to the floor.
Declared steps are read into memory before any of them runs and each runs with stdin on `/dev/null`, so a step that drains stdin cannot consume the steps after it and leave a partial run recorded as a complete one.

## Scope of the guarantee

The gate covers the two entrypoints Firstmate uses to land work.
It is a capability boundary at the merge point, not a claim that no other tool on the machine can merge: a direct `gh pr merge` or `git merge` still bypasses it, exactly as `bin/fm-gate-refuse-lib.sh` protects its own chokepoints rather than the whole shell.

The gate reads the PR head the forge reports, recorded by `bin/fm-pr-check.sh` as `pr_head=`.
A head the forge cannot report refuses, because evidence bound to an assumed commit is not evidence.
GitLab merge requests record no `pr_head`, and `bin/fm-pr-merge.sh` already addresses only GitHub, so that path is unchanged.
