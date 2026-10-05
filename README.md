# VM Updates Scripts

A small archive repository for the updater scripts used on the Ubuntu VM.

This repository is intentionally simple: it exists to **version and preserve the scripts** that keep a few development tools updated. It is not a deployment system, package manager, configuration-management platform, or CI/CD project.

## What is stored here

The important files are:

```text
scripts/
├── update.src.sh
└── test-update.sh
```

- `scripts/update.src.sh` is the canonical source for the custom `update` command.
- `scripts/test-update.sh` is the regression test suite for that script.

On the VM, the installed command normally lives at:

```text
~/bin/update
```

That installed copy is runtime state. This repository stores the source we want to preserve and review.

## Tools we keep updated

The updater currently manages:

- **OpenAI Codex**
- **OpenCode V2**
- **Hermes**
- **T3 Code**

The command supports:

```bash
update --all
update --codex
update --opencode
update --hermes
update --t3
update --verify
update --dry-run --all
```

## Design of the updater

The updater follows a few deliberate rules:

- one update authority per managed tool;
- native tool updaters perform the actual update when available;
- this script owns interruption, verification, restoration, and cleanup around those native updates;
- `--verify` must not mutate the machine;
- `--dry-run` must not mutate the machine;
- one tool failing should not prevent independent selected tools from being attempted;
- active tool workloads may be interrupted only when the user explicitly runs the updater;
- secrets must never be written to this repository or updater logs.

The current updater also performs tool-specific runtime checks, including service/process identity checks where needed.

## This repository is NOT

This repository is deliberately **not**:

- a deployment repository;
- an infrastructure-as-code project;
- a Docker image or VM image;
- a CI/CD release system;
- an automatic scheduler for tool updates;
- a place for credentials, API keys, service passwords, SSH keys, or environment secrets;
- a mirror of Codex, OpenCode, Hermes, or T3 binaries.

GitHub already preserves upstream tool releases. We only preserve **our update logic and its tests**.

## Normal workflow

When the updater needs a change:

```text
edit scripts/update.src.sh
        ↓
update or add regression tests
        ↓
run scripts/test-update.sh
        ↓
verify the updater behavior on the VM
        ↓
commit the script + tests here
```

No deployment pipeline is required.

## Safety

Do not commit:

- `.env` files;
- API keys or tokens;
- OpenCode server passwords;
- T3 connection credentials;
- SSH private keys;
- tool runtime databases/state;
- logs containing sensitive values.

The updater itself uses restrictive defaults and redacts secret-looking values from its own output, but repository hygiene is still required.

## Versioning

Use normal Git history as the primary archive.

Tags may be created for important stable updater milestones, for example:

```text
v2.0.0
v2.0.1
```

A tag represents a known updater-script baseline, not a deployment release.
