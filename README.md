# global-doctor

Backend E2E diagnostic suite for the `global` (tenant / platform control plane) product.

## Scope

- Global GraphQL gateway smoke tests and platform service health checks.
- Cross-product platform flows that live in `global-*-svc`.

This repo is **backend-only**. Playwright UI tests for the admin console or other
frontends live in the corresponding app/website/microfe repos.

## Quick start

```bash
cd ~/products/global/global-doctor
make test              # run backend E2E tests when defined
```

## Status

Backend shell-test scaffold. Add per-service bash test scripts under this repo
and wire them into the `Makefile`.
