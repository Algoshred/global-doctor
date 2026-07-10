# global-doctor

End-to-end diagnostic suite for the `global` (tenant / platform control plane) product.

## Scope

- Admin console (`admin.burdenoff.com`) critical paths: login, tenant list, billing, notifications.
- Global GraphQL gateway smoke tests.
- Cross-product platform flows that live in `global-*-svc`.

## Quick start

```bash
cd ~/products/global/global-doctor
bun install
bun run setup          # install Playwright browsers
bun run test           # run the suite against alpha
```

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `ADMIN_URL` | `https://admin.burdenoff.com` | Base URL of the admin app shell |
| `GRAPHQL_URL` | `https://alphagraphql.burdenoff.com/global/graphql` | Global GraphQL gateway |
| `SERVE_LOCAL` | unset | Set to `1` to start the local `admin-app` dev server |

## Status

Scaffold created. Full tenant bootstrap, billing signup, and admin console flows are TODO.
