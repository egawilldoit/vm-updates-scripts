# VM Updates Scripts

A small archive repository for the updater scripts used on the Ubuntu VM.

This repository is intentionally simple: it exists to **version and preserve the scripts** that keep a few development tools updated. It is not a deployment system, package manager, configuration-management platform, or CI/CD project.

## What is stored here

```text
scripts/
├── update.src.sh
└── test-update.sh
```

- `scripts/update.src.sh` is the canonical source for the custom `update` command.
- `scripts/test-update.sh` is the regression suite for that script.

On the VM, the installed runtime copy normally lives at:

```text
~/bin/update
```

The repository is the source/archive. The installed file is runtime state.

## Managed tools

The updater currently manages:

- **OpenAI Codex**
- **OpenCode V2**
- **Hermes**
- **T3 Code**

The full update order is:

```text
Codex → OpenCode V2 → Hermes → T3
```

T3 is intentionally last because its updater reconciles and restarts the T3 background service and can interrupt active T3 work.

## Native update commands

The wrapper coordinates the safe lifecycle around the tools' own native updaters:

```text
Codex      codex update
OpenCode   opencode upgrade
Hermes     hermes update --yes --no-backup
T3         t3 update --channel nightly --yes
```

Codex may also run `codex app-server daemon update` when capability detection proves that daemon-package lifecycle is supported on the installed Codex build.

## User commands

```bash
update --all
update --codex
update --opencode
update --hermes
update --t3
update --verify
update --check
update --dry-run --all
update --force --all
```

Individual component updates also support `--dry-run`.

## Important updater contracts

The `v2.1.0` updater enforces these rules:

- one update authority per managed tool;
- native tool updaters perform the actual version change;
- a single global mutation lock prevents concurrent updater runs;
- `--verify` performs zero mutation;
- `--dry-run` performs zero mutation;
- `--check` reports `CURRENT`, `UPDATE_AVAILABLE`, `UNKNOWN`, or `NOT_CONFIGURED` without creating locks or logs;
- normal updates skip disruption only when `CURRENT` is proven; `UNKNOWN` runs the existing native updater;
- `--force` bypasses only the current-version optimization and preserves all lifecycle safety checks;
- updater logs retain the newest 20 updater-owned log files;
- failures in independent components do not incorrectly gate each other;
- process/service state is restored only when this updater actually changed it;
- broad process killing is avoided in favor of identified/owned PIDs;
- an update is not reported successful until its post-update state is verified;
- secret-looking values are redacted from updater output/logging.

## Tool-specific safety checks

### Codex

The updater does more than check `codex --version`.

It tracks the app-server by the control-socket owner, stops the maintainer/updater before the app-server when required, proves the old process is gone before updating, and requires a fresh post-update instance when a background app-server was running.

A missing legacy `daemon.pid` is not treated as proof that Codex is unmanaged.

### OpenCode V2

The OpenCode path treats the background-service PID and process start time as authoritative. A responding URL alone is not considered proof of process identity.

Before upgrading it proves the old targeted process is gone. If the background service existed before the update, the updater restores it and verifies that the restored process is fresh and belongs to the current installation.

T3 is stopped only when T3 actually owns OpenCode child processes.

### Hermes

Hermes uses its native updater with `--no-backup`. The wrapper records relevant service state and restores only services that were active before the update.

The PM2/web UI is informational and is not started by this updater.

### T3

The T3 update path verifies convergence across multiple surfaces:

- CLI version;
- launcher target;
- T3 service-state version;
- systemd `ExecStart` version;
- running main-process version;
- running `t3 serve` version;
- service active state;
- HTTP health on `127.0.0.1:3773`;
- no pending/failed update marker.

The update is only reported successful when those surfaces align.

## Exit codes

```text
0  success
1  at least one selected component failed
2  usage error
3  global lock contention
4  preflight refusal; nothing mutated
5  interrupted; state may be mid-flight
```

## Tests

Run:

```bash
bash scripts/test-update.sh
```

The current suite covers syntax, CLI/exit-code contracts, lock behavior, read-only verification/dry-run, legacy-authority retirement, truthful logging/reporting, Codex lifecycle handling, OpenCode PID/freshness handling, T3 ownership rules, and protection against broad process kills.

The suite is intentionally host-aware. Some tests inspect the current VM's systemd/process layout and installed `~/bin/update`, so it is not intended to be a portable generic test framework.

`--check` currently has authoritative latest data only for OpenCode, using the npm registry package that `opencode upgrade` manages. Codex, Hermes, and T3 report `UNKNOWN` until a safe read-only lookup on their native update channel can be proven. T3 latest-state uncertainty never suppresses reconciliation.

`--dry-run` never creates an update lock, holder file, or log. It makes an observational plan that may become stale if a mutating updater starts concurrently.

## This repository is NOT

This repository is deliberately **not**:

- a deployment repository;
- an infrastructure-as-code project;
- a Docker/VM image;
- a CI/CD release system;
- an automatic scheduler for tool updates;
- a package mirror;
- a host backup;
- a place for credentials, API keys, service passwords, SSH keys, or environment secrets.

GitHub/upstream projects already preserve the tool releases themselves. This repository preserves **our update logic and tests**.

## Normal workflow

```text
edit scripts/update.src.sh
        ↓
update/add regression tests
        ↓
run scripts/test-update.sh
        ↓
verify behavior on the VM
        ↓
commit and push
```

No deployment pipeline is required.

## Versioning

Git history is the main archive. Tags may mark important stable updater-script baselines such as `v2.0.0`.

A repository tag represents a version of **our updater script**, not a release of Codex, OpenCode, Hermes, or T3.
