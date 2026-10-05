# Changelog

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

The regression suite covers 40 named sections, including syntax/CLI contracts, lock behavior, read-only verification/dry-run, logging, Codex lifecycle, OpenCode lifecycle, T3 ownership semantics, signal restoration, source/runtime identity, and protection against broad process kills.

### Known baseline limitation

A pre-existing issue remains documented in the test suite: `update --all --dry-run` may leave the global lock FD inherited by child processes for a few seconds after the command exits.

This changelog tracks the updater script itself. It is not a deployment/release log for the managed tools.
