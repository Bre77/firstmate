# Per-crew memory cap (systemd --user transient scope)

This document records the empirical verification behind the memory cap `bin/fm-spawn.sh` wraps around every ship/scout AGENT launch.

## Why this exists

An `hq` firstmate host hit a real OOM incident: a repo-wide pylint run inside one crewmate ballooned to roughly 18GB of resident memory, and because that crewmate's process tree shared the host's default cgroup with everything else, it threatened to take the whole host down rather than just itself.

The fix is deliberately simple and scoped to that one failure mode: bound a single runaway crew to its own cgroup so it can never exhaust host memory.
This is **not** an aggregate cap across every crew on the host - the incident was one crew going crazy, not many crews together exceeding a shared budget, so there is no slice-wide memory limit here, no host or ansible config, and no attempt to also bound CPU or other resources.

## Mechanism

`bin/fm-spawn.sh` prefixes every ship/scout launch command with:

```
systemd-run --user --scope --slice=firstmate-crew.slice \
  -p MemoryHigh=<high> -p MemoryMax=<max> -p MemorySwapMax=<swap> \
  -- bash -c '<original launch command>'
```

A transient scope creates its cgroup on the fly - there is no pre-defined slice unit to install or maintain, and `--slice=firstmate-crew.slice` only groups every crew's scope together for `systemctl --user status`/`systemd-cgls` visibility, not for any aggregate limit.
The original launch command (env-var prefixes, `$(cat ...)` substitutions, quoting - the harness template as already assembled by `launch_template()`) is itself a shell command line the pane's shell is expected to interpret, so it is re-quoted whole and handed to `bash -c` inside the scope rather than to `systemd-run`'s own `--` argv (which execs directly, with no shell).
Because a transient `--scope` inherits the invoking shell's environment (verified below), the existing `export GOTMPDIR=...` sent to the pane immediately before the launch line still reaches the harness process unchanged.

Defaults: `MemoryHigh=8G`, `MemoryMax=12G`, `MemorySwapMax=2G`, overridable per spawn via `FM_CREW_MEMORY_HIGH` / `FM_CREW_MEMORY_MAX` / `FM_CREW_MEMORY_SWAP`.
`MemoryHigh` is a soft throttle: reclaim pressure inside the cgroup slows the crew down without killing it.
`MemoryMax` is the hard ceiling: exceeding it gets a process **inside that cgroup** OOM-killed by the kernel, scoped to the crew, never the host's own OOM killer picking an arbitrary victim process elsewhere.
`MemorySwapMax` stops a runaway crew from thrashing the host into swap instead of just dying cleanly.

Applies to `KIND=ship` and `KIND=scout` launches only.
A `--secondmate` AGENT (the persistent supervisor process itself) is not wrapped, but every crewmate *it* spawns goes through this same `fm-spawn.sh` path and is capped identically.

**Graceful fallback.** `crew_memory_cap_available()` probes with a real trial scope (`systemd-run --user --scope --quiet -- true`), not just `command -v`, so a `systemd-run` binary that is present but unusable (no reachable user systemd instance/D-Bus session) is caught the same way a missing binary is.
When the probe fails, the spawn proceeds with the launch unwrapped and a `warning: systemd-run --user is unavailable on this host...` line on stderr - the cap must never block a spawn.

## Verification environment

- Host: Debian, `Linux 6.1.0-50-amd64`, cgroup v2 unified hierarchy.
- `systemd-run --version`: `systemd 252 (252.39-1~deb12u2)`.
- `systemctl --user status` confirmed a live user instance (`State: running`) and `cat /sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/cgroup.subtree_control` reported `cpu memory pids` - the memory controller is delegated to the user manager, so `MemoryHigh`/`MemoryMax`/`MemorySwapMax` are actually enforced, not silently accepted and ignored.
- Verification date: 2026-07-08.

One naming fact worth recording: systemd treats dashes in a slice unit's name as a hierarchy separator, so `--slice=firstmate-crew.slice` is created *nested inside* an auto-created `firstmate.slice`, not as a top-level sibling of `user@<uid>.service`.
The real cgroup path observed throughout this verification was:

```
/user.slice/user-1000.slice/user@1000.service/firstmate.slice/firstmate-crew.slice/<scope>.scope
```

This is expected systemd behavior, not a bug; anyone inspecting the tree with `systemd-cgls`/`systemctl --user status` should look one level deeper than `firstmate-crew.slice` alone would suggest.

## (a) Normal launch runs inside the scope, under the limits

Ran the real, modified `bin/fm-spawn.sh` end to end (isolated tmux server + throwaway `FM_HOME`, so no live fleet state was touched) with a raw launch command standing in for a harness:

```
$ FM_ROOT_OVERRIDE='' FM_HOME=<throwaway> FM_STATE_OVERRIDE=... FM_DATA_OVERRIDE=... \
  FM_PROJECTS_OVERRIDE=... FM_CONFIG_OVERRIDE=... FM_SPAWN_NO_GUARD=1 \
  bin/fm-spawn.sh memcaplive1 <throwaway-project> "sleep 60"
spawned memcaplive1 harness=sleep kind=ship mode=no-mistakes yolo=off window=memcap-verify:fm-memcaplive1 worktree=<wt>
```

The pane's actual captured content showed fm-spawn.sh sent exactly:

```
systemd-run --user --scope --slice=firstmate-crew.slice -p MemoryHigh=8G -p MemoryMax=12G -p MemorySwapMax=2G -- bash -c 'sleep 60'
Running scope as unit: run-rc91c6643ea884dec9919c4d0cbcd53ca.scope
```

`systemctl --user status run-rc91c6643ea884dec9919c4d0cbcd53ca.scope`:

```
● run-rc91c6643ea884dec9919c4d0cbcd53ca.scope - /usr/bin/bash -c sleep 60
     Loaded: loaded (/run/user/1000/systemd/transient/run-rc91c6643ea884dec9919c4d0cbcd53ca.scope; transient)
  Transient: yes
     Active: active (running) since Wed 2026-07-08 12:35:50 AEST; 12s ago
      Tasks: 1 (limit: 37499)
     Memory: 172.0K (high: 8.0G max: 12.0G swap max: 2.0G available: 7.9G)
        CPU: 1ms
     CGroup: /user.slice/user-1000.slice/user@1000.service/firstmate.slice/firstmate-crew.slice/run-rc91c6643ea884dec9919c4d0cbcd53ca.scope
             └─2175935 sleep 60
```

This confirms the exact production defaults (8G/12G/2G) are the ones actually applied to the real process tree, visible via both `systemctl --user status` and `systemd-cgls`.

Separately, a raw `MemoryHigh` throttle was verified directly (outside the fm-spawn.sh wrapper, same underlying `systemd-run` invocation): a memory hog capped at `MemoryHigh=100M`/`MemoryMax=300M`/`MemorySwapMax=0` stalled at ~110MB resident for over three minutes without dying, and `memory.events` for that scope's cgroup showed a climbing `high` counter (`high 15749`) with `max 0`/`oom 0` - i.e., repeatedly throttled, never killed, exactly the "slows, does not die" contract `MemoryHigh` is supposed to provide.

Environment propagation was also verified directly, since the existing `export GOTMPDIR=...` line depends on it:

```
$ export FM_TEST_ENV_PROPAGATION=hello123
$ systemd-run --user --scope --quiet -- bash -c 'echo $FM_TEST_ENV_PROPAGATION'
hello123
```

A transient `--scope` inherits the invoking shell's environment, so `GOTMPDIR` (and any harness-specific env prefix already inside the launch string) still reaches the agent process unchanged.

## (b) A memory hog is OOM-killed WITHIN its own cgroup, host stays healthy

Ran a second real spawn through the same `bin/fm-spawn.sh`, with `FM_CREW_MEMORY_HIGH=infinity FM_CREW_MEMORY_MAX=150M FM_CREW_MEMORY_SWAP=0` (a reduced cap so the test is fast and safe rather than actually consuming 12GB), launching a small Python script that allocates and touches 20MB chunks every 100ms and never frees them:

```
$ free -h   # before
               total        used        free      shared  buff/cache   available
Mem:            30Gi       6.6Gi        14Gi        15Mi        10Gi        24Gi

$ FM_CREW_MEMORY_HIGH=infinity FM_CREW_MEMORY_MAX=150M FM_CREW_MEMORY_SWAP=0 \
  FM_ROOT_OVERRIDE='' FM_HOME=<throwaway> ... FM_SPAWN_NO_GUARD=1 \
  bin/fm-spawn.sh memcaplive2 <throwaway-project> "python3 -u memhog.py"
spawned memcaplive2 harness=python3 kind=ship mode=no-mistakes yolo=off window=memcap-verify:fm-memcaplive2 worktree=<wt>
```

Pane content:

```
systemd-run --user --scope --slice=firstmate-crew.slice -p MemoryHigh=infinity -p MemoryMax=150M -p MemorySwapMax=0 -- bash -c 'python3 -u memhog.py'
Running scope as unit: run-rb32c6063360741f2b2f0454f84aa100b.scope
allocated 20 MB
allocated 40 MB
allocated 60 MB
allocated 80 MB
allocated 100 MB
allocated 120 MB
allocated 140 MB
Killed
```

`journalctl --user -u run-rb32c6063360741f2b2f0454f84aa100b.scope`:

```
Jul 08 12:36:15 hq systemd[844]: Started run-rb32c6063360741f2b2f0454f84aa100b.scope - /usr/bin/bash -c python3 -u memhog.py.
Jul 08 12:36:16 hq systemd[844]: run-rb32c6063360741f2b2f0454f84aa100b.scope: A process of this unit has been killed by the OOM killer.
Jul 08 12:36:16 hq systemd[844]: run-rb32c6063360741f2b2f0454f84aa100b.scope: Failed with result 'oom-kill'.
```

The kill is scoped to that one unit - the journal message names the specific `run-....scope`, not the whole host or an unrelated process.
Confirming containment: the sibling crew spawned moments earlier (`memcaplive1`, running `sleep 60` in its own scope) was still running, untouched, in its own tmux window and its own scope throughout; `free -h` immediately after the kill was effectively unchanged from before (`6.6Gi` used, both before and after); and no other process on the host was affected.

An equivalent direct (non-fm-spawn) run against the production-scale default `MemoryMax=150M` variant was also captured via `journalctl --user -g oom`, additionally showing systemd's containment reporting one level up the hierarchy:

```
Jul 08 12:14:38 hq systemd[844]: fm-crew-memcap-oom-test-2.scope: A process of this unit has been killed by the OOM killer.
Jul 08 12:14:38 hq systemd[844]: fm-crew-memcap-oom-test-2.scope: Failed with result 'oom-kill'.
Jul 08 12:14:38 hq systemd[844]: firstmate-crew.slice: A process of this unit has been killed by the OOM killer.
Jul 08 12:14:38 hq systemd[844]: firstmate.slice: A process of this unit has been killed by the OOM killer.
```

## Conclusion

Both `systemd-run --user --scope` mechanics and the actual `bin/fm-spawn.sh` wrapping were verified live on this host, end to end, including the failure path (OOM-kill contained to one crew's cgroup) and the fallback path (unavailable systemd-run still lets the spawn proceed, unwrapped, with a warning - covered by `tests/fm-crew-memory-cap.test.sh` using a stubbed `systemd-run`).
The feature is safe to ship as implemented, with no further host or ansible configuration required.
