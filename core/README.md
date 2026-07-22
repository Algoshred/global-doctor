# Shared E2E core

Cross-product end-to-end helpers and shell harness used by every `{product}-doctor` repo.

| Path | Purpose |
|---|---|
| `scripts/*.sh` | Bash workflow scripts (CRUDL tests, env bootstrap, teardown). |
| `env/e2e-env.sh` | Shared env variables sourced by every doctor invocation. |
| `Makefile` | Convenience entry points. |

## Why this lives outside the doctor repos

So every doctor inherits the same bootstrap, CRUDL, and teardown behavior. Updating one file rolls the behavior across the fleet on the next CI run — no per-product copy-paste drift.
