# AGENTS.md

## Purpose of this repository

This repository exists only to preserve and version the VM updater scripts.

Keep the project small.

Do not turn it into a deployment platform, provisioning system, package mirror, daemon manager, or general-purpose infrastructure repository unless the owner explicitly changes that scope.

## Source of truth

The canonical updater source is:

```text
scripts/update.src.sh
```

Its regression tests are:

```text
scripts/test-update.sh
```

The VM-installed executable such as `~/bin/update` is a deployed copy and is not the repository source of truth.

## Managed tools

The updater currently covers:

- Codex
- OpenCode V2
- Hermes
- T3 Code

Do not silently add more managed tools.

A new tool requires an explicit owner request and should include corresponding verification and tests.

## Core contracts that must not regress

Preserve these behaviors unless the owner explicitly requests a change:

1. **One update authority per tool.**
   Do not add competing cron jobs, timers, background scripts, or helper updaters that mutate the same managed tool.

2. **Prefer native updaters.**
   The wrapper should coordinate interruption, verification, restoration, and cleanup instead of reimplementing a tool's own updater.

3. **Explicit interruption only.**
   Active work may be interrupted when the user explicitly invokes an update. Do not introduce surprise background mutation.

4. **Read-only verification.**
   `update --verify` must perform zero mutation.

5. **Read-only dry-run.**
   `update --dry-run ...` must perform zero mutation and should describe the intended actions.

6. **Independent components stay independent.**
   A failure in one selected tool must not incorrectly report another independent tool as failed.

7. **Truthful verification.**
   Never report an update or restore as successful unless the post-condition was actually proven.

8. **No secret leakage.**
   Never commit credentials or weaken redaction behavior.

## Change discipline

When changing `scripts/update.src.sh`:

- read the relevant existing helper functions first;
- make the smallest change needed;
- preserve existing exit-code semantics unless intentionally changing the contract;
- update `scripts/test-update.sh` for behavior changes;
- run the test suite;
- inspect `git diff` before committing;
- do not mix unrelated host cleanup or configuration changes into a script change.

## Testing

The regression suite is part of the updater, not optional documentation.

Run:

```bash
bash scripts/test-update.sh
```

If a behavior change cannot be tested safely against the real host, prefer a fixture/harness that simulates the process or service state.

Tests must not kill unrelated real processes, expose credentials, or mutate unrelated host state.

## Repository boundaries

Allowed here:

- updater source;
- updater tests;
- concise documentation;
- changelog/history notes;
- small non-sensitive fixtures needed by tests.

Do not add by default:

- CI/CD pipelines;
- deployment manifests;
- Docker files;
- Terraform/Ansible;
- automatic release bots;
- copied third-party binaries;
- VM backups;
- runtime databases;
- service credentials;
- generated logs.

This repository is an archive and maintenance home for the scripts, not an application deployment target.

## Commit style

Prefer small commits with clear intent, for example:

```text
fix: preserve T3 service state during update
test: cover OpenCode service PID rollover
docs: clarify updater repository scope
```

For a stable updater baseline, a Git tag is acceptable. Tags describe script versions only.
