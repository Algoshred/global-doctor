# Auth Module E2E Tests

End-to-end tests for the **global-auth-svc** authentication service.

## Overview

These tests validate authentication operations through the Global Public Gateway, ensuring the auth module functions correctly in a production-like environment.

## Test Coverage

| Category | Tests | Description |
|----------|-------|-------------|
| **Tokens** | 4 | Token validation, refresh, info retrieval |
| **Password** | 3 | Change password, request reset, verify reset |
| **MFA** | 6 | Setup TOTP, enable, verify, disable, backup codes |
| **Sessions** | 4 | List sessions, sign out, revoke all, device management |
| **Account** | 3 | Profile update, deactivation, reactivation |
| **Stability contract** | 3 | MFA method status, paginated sessions, backend auth audit logs |

**Total Tests**: 20+

## Prerequisites

1. **Bootstrap Environment**: Run from doctor root first
   ```bash
   cd ~/products/workspaces/workspaces-doctor
   make bootstrap-env
   ```

2. **Services Running**:
   - global-auth-svc (port 4011)
   - global-public-gateway (port 4000)
   - PostgreSQL (port 5441)
   - Valkey (port 6381)

## Quick Start

```bash
# Run all auth tests
make test

# Run specific test categories
make test-tokens      # Token operations
make test-password    # Password management
make test-mfa         # Multi-factor authentication
make test-sessions    # Session management
make test-account     # Account operations

# Check environment
make check-env

# View logs
make logs
```

## Test Scripts

| Script | Purpose |
|--------|---------|
| `scripts/test-auth.sh` | Main test runner (803 lines) |

### Script Usage

```bash
./scripts/test-auth.sh              # Run all tests
./scripts/test-auth.sh tokens       # Token tests only
./scripts/test-auth.sh password     # Password tests only
./scripts/test-auth.sh mfa          # MFA tests only
./scripts/test-auth.sh sessions     # Session tests only
./scripts/test-auth.sh account      # Account tests only
```

## Environment Variables

Set by `bootstrap-env`:

| Variable | Description |
|----------|-------------|
| `E2E_AUTH_TOKEN` | JWT access token |
| `E2E_REFRESH_TOKEN` | Refresh token |
| `E2E_USER_ID` | Test user ID |
| `E2E_USER_EMAIL` | Test user email |
| `E2E_USER_PASSWORD` | Test user password |
| `GLOBAL_PUBLIC_GATEWAY_URL` | Gateway URL |

## Tested Operations

### Token Operations
- `validateTokens` - Validate JWT token
- `refreshToken` - Refresh access token
- `tokenInfo` - Get token information
- Token expiration handling

### Password Operations
- `changePassword` - Change user password
- `requestPasswordReset` - Request password reset email
- Password strength validation
- Password history enforcement

### MFA Operations
- `setupMFA` - Setup TOTP authenticator
- `enableMFA` - Enable MFA requirement
- `verifyMFA` - Verify TOTP code
- `disableMFA` - Disable MFA
- `generateBackupCodes` - Generate backup codes
- `verifyBackupCode` - Verify backup code

### Session Operations
- `activeSessions` - List active sessions
- `activeSessions(pagination)` - Bounded paginated session list contract
- `signOut` - Sign out current session
- `revokeSession` - Revoke specific session
- `revokeAllSessions` - Revoke all sessions

### Stability Contract Operations
- `currentUserMFAMethods` - Backend-backed MFA method status list
- `authAuditLogs(pagination)` - Backend-backed auth audit event list

### Account Operations
- `updateProfile` - Update user profile
- `deactivateAccount` - Deactivate account
- `reactivateAccount` - Reactivate account

## Logs

Test logs are stored in:
```
~/products/workspaces/workspaces-doctor/logs/e2e-auth-{timestamp}.log
```

View latest log:
```bash
make logs
```

## Troubleshooting

### "Environment not bootstrapped"
```bash
cd ~/products/workspaces/workspaces-doctor
make bootstrap-env
```

### "No auth token"
Token may have expired. Re-bootstrap:
```bash
make bootstrap-env
```

### "Connection refused"
Ensure services are running:
```bash
# Check auth service
curl http://localhost:4011/health/ready

# Check gateway
curl http://localhost:4000/health
```

## Related

- **Service**: `~/products/global/auth/global-auth-svc`
- **State**: `~/products/global/auth/global-auth-state`
- **Specs**: `~/products/global/global-specs/modules/auth`

## Author

Vignesh T.V. (vignesh@burdenoff.com)

## License

Proprietary - Copyright Burdenoff Consultancy Services Pvt. Ltd. 2025
