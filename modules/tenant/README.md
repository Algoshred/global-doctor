# Tenant Module E2E Tests

Canonical doctor coverage for `global-tenant-svc`.

## Entry points

```bash
# from repo root
make test-global-tenant

# from module directory
make test
make test-tenants
make test-organizations
make test-workspaces
make test-memberships
make test-products
```

## Current execution model

- Global gateway: `http://localhost:4000/global/graphql`
- Workspace gateway (for cross-layer validations when needed): `http://localhost:4003/workspaces/graphql`
- Auth: `Authorization: Bearer <auth-token>`
- Env source: `../../../core/env/e2e-env.sh`

## Coverage focus

- tenant lifecycle and settings
- organization lifecycle
- workspace provisioning and lifecycle
- organization invites and acceptance/rejection flows
- organization + workspace membership flows
- platform product catalog lookups

## Notes

- This is the **canonical service-aligned** suite for the real `~/products/global/tenant` repo
- The sibling `../tenants` suite is retained as a legacy CRUDL compatibility suite
- Prefer namespaced root commands (`make test-global-tenant`) in docs and automation
