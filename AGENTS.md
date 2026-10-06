# AGENTS.md

## Repository purpose

This repository exists only to preserve and version the VM updater scripts.

Keep it small.

Do not turn it into a deployment platform, provisioning system, package mirror, daemon manager, CI/CD system, or general-purpose infrastructure repository unless the owner explicitly changes that scope.

## Source of truth

Canonical updater source:

```text
scripts/update.src.sh
```

Regression tests:

```text
scripts/test-update.sh
```

The installed VM executable, normally `~/bin/update`, is a deployed/runtime copy and is not the repository source of truth.

## Managed tools

The updater currently covers:

- Codex
- OpenCode V2
- Hermes
- T3 Code

Do not silently add another managed tool.

## Core contracts that must not regress

1. **One update authority per tool.**
   Do not add competing cron jobs, timers, helper scripts, or other mutation paths.

2. **Use native updaters.**
   The wrapper coordinates interruption, verification, restoration, and cleanup around the tools' supported update commands.

3. **Explicit interruption only.**
   Active work may be interrupted only when the user explicitly invokes an update.

4. **Read-only verification.**
   `update --verify` performs zero mutation.

5. **Read-only dry-run.**
   `update --dry-run ...` performs zero tool-state mutation and must describe the intended plan truthfully.

   Dry-run uses only a best-effort shared observation of an existing lock. It never creates the lock, holder, or logs; its snapshot can become stale if a mutation starts concurrently.

6. **Read-only availability check.**
   `update --check` creates no lock or logs. `CURRENT` requires proof; `UNKNOWN` must continue through the native updater on a normal update.

7. **Force means native update.**
   `--force` bypasses only a proven-current skip. It does not bypass lifecycle proofs, restoration, verification, or locking.

8. **Global mutual exclusion.**
   Mutating updater runs use the single global lock. Preserve exit code 3 for lock contention.

9. **Independent components stay independent.**
   A failure in one selected component must not cause unrelated components to be skipped or falsely marked failed.

10. **Restore only what this run changed.**
   Do not start/restart a service merely because it exists. Restore it only when the updater stopped it or it was active before the relevant update path.

11. **Targeted process handling.**
   Avoid broad `pkill`, `killall`, or signal-by-name patterns. Prefer proven process ownership/identity and targeted PIDs.

12. **Truthful post-update verification.**
    Never report success because an updater command returned 0 alone. Verify the required post-conditions.

13. **No secret leakage.**
    Never commit credentials and do not weaken output/log redaction.

## Tool-specific invariants

### Codex

- Native CLI update is `codex update`.
- Capability detection decides whether `codex app-server daemon update` is applicable.
- The app-server control-socket owner is authoritative; legacy PID files are not required.
- When a maintainer/updater process can recreate the app-server, stop it before the app-server.
- Prove the old app-server/workload is gone before invoking the native updater.
- If a background app-server was running, require a fresh post-update process and current release.
- T3 should only be stopped when T3 actually owns Codex child processes.

### OpenCode V2

- Native update is `opencode upgrade`.
- Background-service PID and start time are authoritative; URL responsiveness alone is not identity.
- Use the official service-stop path first; targeted escalation may be used only for the identified old PID.
- Refuse to run the upgrade if the pre-update process proof fails.
- If the service was running before, restore it and prove a fresh process/current executable afterward.
- Do not start a service that was not running before.
- T3 should only be stopped when T3 actually owns OpenCode child processes.

### Hermes

- Native update is `hermes update --yes --no-backup`.
- Do not reintroduce custom state backups.
- Restore only Hermes units that were active before the update.
- Do not start the PM2/web UI as part of update.

### T3

- Native update is `t3 update --channel nightly --yes`.
- Do not use deprecated `t3 service update` as the normal update mechanism.
- Post-update verification must align CLI, launcher, service-state, systemd ExecStart, MainPID, running serve version, HTTP health, and pending-update state.
- Preserve the bounded post-update health convergence wait; the native updater can return before HTTP becomes ready.
- Before a real restart, report category counts for workloads in the service cgroup. Never terminate those processes independently.

Availability checks must use the native updater's authoritative channel. If that cannot be established safely, return `UNKNOWN` and run the native updater.

## Change discipline

When modifying `scripts/update.src.sh`:

- read the relevant helper/lifecycle functions first;
- make the smallest change that satisfies the request;
- preserve exit-code semantics unless intentionally changing the contract;
- update `scripts/test-update.sh` for behavior changes;
- run the regression suite;
- inspect `git diff`;
- do not mix unrelated host cleanup/configuration changes into an updater change;
- keep source and the installed `~/bin/update` synchronized when working on the VM.

The test suite explicitly checks that repository source and the installed updater are byte-identical on the current host.

## Testing

Run:

```bash
bash scripts/test-update.sh
```

Prefer sandboxed/fixture harnesses for dangerous lifecycle tests. Tests must not kill unrelated real processes, expose secrets, or mutate unrelated host state.

Some tests intentionally inspect the current VM, so the suite is host-aware rather than a portable generic library.

## Repository boundaries

Allowed:

- updater source;
- updater regression tests;
- concise documentation;
- changelog/history notes;
- small non-sensitive test fixtures.

Do not add by default:

- CI/CD pipelines;
- deployment manifests;
- Docker files;
- Terraform/Ansible;
- release bots;
- copied third-party binaries;
- VM backups;
- runtime databases;
- credentials;
- generated logs.

This is an archive/maintenance home for the scripts, not a deployment target.

## Commit style

Prefer small commits with clear intent, for example:

```text
fix: preserve T3 service state during update
test: cover OpenCode service PID rollover
docs: clarify updater repository scope
```

Tags may mark stable updater-script baselines only.
