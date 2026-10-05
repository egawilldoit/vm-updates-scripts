# Repository Scope

## In scope

This repository stores and versions the custom VM update scripts used to maintain a small set of developer tools:

- Codex
- OpenCode V2
- Hermes
- T3 Code

It also stores the tests and documentation needed to understand and safely modify those scripts.

## Out of scope

This repository is not responsible for:

- deploying applications;
- provisioning the VM;
- managing production infrastructure;
- automatically scheduling tool updates;
- mirroring upstream binaries;
- storing credentials;
- backing up the VM;
- managing project repositories that happen to use these tools.

## Operational model

The script is run manually on the VM when an update or verification is wanted.

The GitHub repository is the historical/source archive. It does not need to deploy itself anywhere.

The expected lifecycle is:

```text
modify script
→ test
→ verify
→ commit/push
```

That is intentionally all.
