# Changelog

## v2.0.0 baseline — 2026-10-05

Initial archived baseline of the current VM updater.

The updater manages:

- Codex
- OpenCode V2
- Hermes
- T3 Code

Current design includes:

- a single update entry point;
- per-tool update selection;
- `--all`;
- read-only `--verify`;
- read-only `--dry-run`;
- mutation locking;
- tool-specific service/process verification;
- regression tests;
- secret redaction;
- explicit handling of interruption/restoration around managed runtimes.

This changelog tracks the updater script itself. It does not represent deployment releases of the managed tools.
