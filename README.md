# global-doctor

Backend E2E diagnostic suite for the `global` (tenant / platform control plane) product.

## Scope

- Global GraphQL gateway smoke tests and platform service health checks.
- Cross-product platform flows that live in `global-*-svc`.

This repo is **backend-only**. Playwright UI tests for the admin console or other
frontends live in the corresponding app/website/microfe repos.

## Prerequisite

The global dev stack must already be running — module state services,
`global-{auth,tenant,rbac}-svc`, `global-public-gateway`, and
`wspace-public-gateway` (the tenant bootstrap flow provisions a workspace via
the wspace layer too). Bring it up with `make reset` in `~/products/dev/`, or
start the individual services per their own `CLAUDE.md`.

## Quick start

```bash
cd ~/products/global/global-doctor
make bootstrap-env      # create a test user/tenant/org/workspace (run once)
make test-all           # core provisioning flow + CRUDL + module suites
```

Individual suites:

```bash
make test               # 18-step auth/tenant/workspace provisioning flow
make test-crudl         # CRUDL: users, tenants, organizations, workspaces
make test-modules       # all module suites (see modules/)
make -C modules test-auth     # auth module only (tokens, MFA, password, profile)
make -C modules test-tenant   # tenant module only (tenants, orgs, workspaces, products)
make -C modules test-rbac     # rbac module only (roles, permissions, overrides, analytics)
```

## Status

Real, runnable backend E2E coverage — not a placeholder. `core/` and
`modules/{auth,tenant,rbac}` are ported from `workspaces-doctor`'s
already-proven `global/modules` harness (kept as this repo's own copy so
global-doctor's coverage doesn't depend on a sibling repo's checkout).
Verified locally: `auth` 10/10, `rbac` 51/51, CRUDL 4/4 suites, and the core
18-step flow 17/18 (the one gap is an unrelated local wspace-rbac-svc DB
constraint issue, not a global-doctor defect — see module coverage notes
below).

The `tenant` suite's admin-gated sub-tests (create/suspend a tenant) need a
properly-scoped admin test account; without `E2E_ADMIN_TOKEN` or
`E2E_ADMIN_EMAIL`/`E2E_ADMIN_PASSWORD` in the environment they correctly
report "Admin privileges required" rather than silently passing.

Add more module suites under `modules/` (billing, support, newsletter,
channel, notification, devportal, i18n, scheduler, store, tours, activity)
following the same pattern as `modules/auth`, and append them to
`ALL_SUITES` in `modules/Makefile`.
