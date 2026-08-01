# Verification: Bash 3.2 empty-array expansion

Active empirical evidence for the guarantee that Firstmate's `bin/` scripts survive an empty array under `set -u` on the stock macOS Bash.
`tests/fm-bash32-empty-array.test.sh` owns the regression guard; this record holds the measurements that justify its shape.
`bin/fm-bash-syntax-check.sh` owns the separate Bash 3.2 *parse* hazard (a heredoc inside a command substitution) and is not repeated here.

## What Bash 3.2 actually does

Date: 2026-08-01.
Interpreter: GNU bash 3.2.57, built from the GNU release tarball, matching the `3.2.57` that ships as `/bin/bash` on macOS.

```
$ bash-3.2.57/bash --version | head -1
GNU bash, version 3.2.57(2)-release (x86_64-unknown-linux-gnu)
```

Each row is one `bash -c` invocation under `set -u` against an array declared with `a=()`.

```
$ bash-3.2.57/bash -c 'set -u; a=(); printf "[%s]" "${a[@]}"; echo OK'
bash: a[@]: unbound variable

$ bash-3.2.57/bash -c 'set -u; a=(); echo "[${a[*]}] OK"'
bash: a[*]: unbound variable

$ bash-3.2.57/bash -c 'set -u; a=(); for x in "${a[@]}"; do :; done; echo OK'
bash: a[@]: unbound variable

$ bash-3.2.57/bash -c 'set -u; a=(); printf "[%s]" "${a[@]+"${a[@]}"}"; echo OK'
[]OK

$ bash-3.2.57/bash -c 'set -u; a=(one); printf "[%s]" "${a[@]+"${a[@]}"}"; echo OK'
[one]OK

$ bash-3.2.57/bash -c 'set -u; a=(); echo "${#a[@]}"; echo OK'
0
OK

$ bash-3.2.57/bash -c 'set -u; a=(); b=("${a[@]:1}"); echo "OK ${#b[@]}"'
OK 0
```

Every one of those is silent and successful under Bash 5.2.21, which is what every Linux CI lane runs.

Three consequences the guard is built around:

1. The hazard is the bare `"${a[@]}"` and `"${a[*]}"` on an array that can be empty, not slicing: `${a[@]:1}` is fine on an empty array even on 3.2.
2. `${a[@]+"${a[@]}"}` is correct on 3.2 for both the empty and the populated case, so it is the idiom the repo uses.
3. `${#a[@]}` is safe, so an explicit count test before expanding is equally correct and is what most of `bin/` already does.

## The crash this reproduces

Issue #173: `fm-spawn.sh` batch dispatch assembles the flags shared across every `id=repo` pair into `shared_args`, which is empty when the caller passes none.
Reverting the `+` guard on `bin/fm-spawn.sh`'s two batch re-exec lines and running the same command under each interpreter:

```
$ bash-3.2.57/bash bin/fm-spawn.sh a=projects/none-a b=projects/none-b
bin/fm-spawn.sh: line 372: shared_args[@]: unbound variable

$ bash bin/fm-spawn.sh a=projects/none-a b=projects/none-b
batch: FAILED to spawn a (projects/none-a)
batch: FAILED to spawn b (projects/none-b)
```

Bash 5 does not fail, so nothing in CI saw it: the Linux lanes all run Bash 5, and the macOS lane only parse-checks.
`tests/fm-bash32-empty-array.test.sh` closes that by running the batch dispatch through a real 3.2 with zero, one, and several shared flags, and by refusing to pass vacuously when no 3.2 interpreter is present.

## Guard observed failing

Date: 2026-08-01.
With the `+` guard reverted on `bin/fm-spawn.sh`, both halves of the guard report it:

```
$ FM_BASH32=bash-3.2.57/bash bash tests/fm-bash32-empty-array.test.sh
ok - Bash 3.2 rejects the unguarded empty-array expansion and accepts the guarded one
not ok - batch-no-shared-flags: batch dispatch hit an unbound variable under Bash 3.2

$ bash tests/fm-bash32-empty-array.test.sh
skip: no Bash 3.2 interpreter (set FM_BASH32 to one); runtime half not run
not ok - unguarded empty-array expansions in bin/:
fm-spawn.sh: ${shared_args[@]} is expanded without the ${shared_args[@]+...} guard and without a ${#shared_args[@]} test
```

The second run is the important one: the static half reports the hazard on a Bash 5 lane, where the crash itself is invisible.

With the guard restored, both halves pass:

```
$ FM_BASH32=bash-3.2.57/bash bash tests/fm-bash32-empty-array.test.sh
ok - Bash 3.2 rejects the unguarded empty-array expansion and accepts the guarded one
ok - fm-spawn batch dispatch runs under Bash 3.2 with zero, one, and several shared flags
ok - no bin/ accumulator array is expanded without a guard or a count test
ok - the static rule reports a planted unguarded expansion and accepts the guarded one
```
