# Repository Scope

## In scope

This repository stores and versions the custom VM update scripts used to maintain:

- Codex
- OpenCode V2
- Hermes
- T3 Code

It also stores the regression tests and concise documentation needed to understand and safely modify those scripts.

The updater may perform read-only availability checks for each native update channel. An unproven latest source is reported as `UNKNOWN` and never used to suppress an update. T3 restart warnings may report bounded workload category counts from its service cgroup.

## Out of scope

This repository is not responsible for:

- deploying applications;
- provisioning the VM;
- managing production infrastructure;
- automatically scheduling tool updates;
- mirroring upstream binaries;
- storing credentials;
- backing up the VM;
- managing project repositories that use these tools;
- acting as a package registry or release service.

## Operational model

The updater is run manually on the VM when an update or verification is wanted.

The GitHub repository is the source/history archive. It does not deploy itself anywhere.

Expected lifecycle:

```text
modify script
→ update tests
→ run regression suite
→ verify on the VM
→ commit/push
```

Some regression checks are deliberately host-aware and inspect the current VM's systemd/process/runtime layout. That is acceptable because this repository preserves the updater for this host; it is not intended to be a portable updater framework.

Keep the repository boring and small.
