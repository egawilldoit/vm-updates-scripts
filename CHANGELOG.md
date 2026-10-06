# Changelog

## v2.1.0 — 2026-10-06

### Fixed

- OpenCode official commands preserve the requested service subcommand and classify command success by exit status; lifecycle proofs remain authoritative.
- OpenCode service and native updater children close lock fd 9.
- Dry-run no longer creates/acquires the mutation lock, holder file, or logs; it uses only a best-effort read-only observation of an existing lock.
- Removed the documented dry-run lock-FD limitation after reproducing the prior inheritance and adding direct regression coverage.

### Added

- Conservative per-tool `CURRENT` / `UPDATE_AVAILABLE` / `UNKNOWN` / `NOT_CONFIGURED` availability reporting and `update --check`.
- `--force` to bypass only a proven-current optimization.
- T3 pre-restart workload category counts and bounded updater-log retention (20 logs).
- Read-only availability is authoritative only for OpenCode's npm package channel at present; unresolved sources stay `UNKNOWN` and do not skip native updates.

## v2.0.0 baseline — 2026-10-05

Initial archived baseline of the current VM updater.

Managed tools:

- Codex
- OpenCode V2
- Hermes
- T3 Code

### Core behavior

- single update entry point;
- per-tool updates plus `--all`;
- update order: Codex → OpenCode V2 → Hermes → T3;
- global mutation lock;
- read-only `--verify`;
- read-only `--dry-run`;
- independent component failure handling;
- secret redaction;
- explicit restore semantics;
- targeted process handling rather than broad kill patterns.

### Codex lifecycle hardening

- native `codex update`;
- control-socket ownership used as the authoritative app-server identity;
- legacy PID files not required for ownership;
- maintainer/updater stopped before the app-server when required;
- pre-update proof that the old workload is gone;
- optional daemon-package update only when capability detection says it is supported;
- fresh post-update app-server proof;
- restoration of previously-running background state;
- restored daemons must not inherit the updater's global lock FD.

### OpenCode V2 lifecycle hardening

- native `opencode upgrade`;
- service PID/start-time identity instead of URL-only inference;
- official service stop with targeted escalation for the identified PID only;
- pre-update stop proof gates the native upgrade;
- fresh-process proof even when the version number does not change;
- no automatic start when the service was not running before;
- T3 stopped only when it actually owns OpenCode children.

### Hermes

- native `hermes update --yes --no-backup`;
- no custom state backup;
- only previously-active service units are restored;
- PM2/web UI is informational and not started by the updater.

### T3

- native `t3 update --channel nightly --yes`;
- deprecated `t3 service update` is not the normal update path;
- full alignment verification across CLI, launcher, service-state, ExecStart, MainPID, running serve version, HTTP health, and pending-update state.

### Tests

The regression suite covers the original 40 named sections plus new OpenCode argv/fd/classification, dry-run locking, availability/force contracts, T3 workload warning, and log retention checks.

### Known limitation at the v2.0.0 baseline

At v2.0.0, `update --all --dry-run` could leave the global lock fd inherited by children briefly. This limitation is fixed in v2.1.0 as described above.

This changelog tracks the updater script itself. It is not a deployment/release log for the managed tools.
