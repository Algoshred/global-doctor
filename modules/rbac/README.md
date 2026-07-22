# RBAC Module E2E Tests

End-to-end tests for the Global RBAC (Role-Based Access Control) module.

## Overview

This test suite covers:
- **Permission Management**: CRUD operations, assignment to roles/actors
- **Role Management**: CRUD operations, hierarchy, permission assignment
- **Actor Management**: User and agent actors, role assignment, delegation
- **Resource Management**: Resource types and instances, permissions
- **Permission Checking**: Single/multiple permission checks, scoped checks

## Prerequisites

1. **Bootstrap the test environment** from doctor root:
   ```bash
   cd ~/products/workspaces/workspaces-doctor
   make bootstrap-env
   ```

2. **Ensure global-rbac-svc is running**:
   ```bash
   cd ~/products/global/rbac/global-rbac-state
   docker compose up -d

   cd ~/products/global/rbac/global-rbac-svc
   bun run dev
   ```

## Running Tests

### All Tests
```bash
make test
```

### Individual Test Suites

```bash
# Permission CRUD and assignment
make test-permissions

# Role CRUD and hierarchy
make test-roles

# Actor management (users, agents)
make test-actors

# Resource types and instances
make test-resources

# Permission checking operations
make test-checks
```

## Test Coverage

### Permissions
- `createPermission` - Create new permission
- `updatePermission` - Update permission details
- `deletePermission` - Delete permission
- `getPermissions` - List all permissions
- `getPermission` - Get single permission
- `assignPermissionToRole` - Assign permission to role
- `assignPermissionToActor` - Assign permission to actor
- `removePermissionFromRole` - Remove permission from role
- `removePermissionFromActor` - Remove permission from actor

### Roles
- `createRole` - Create new role
- `updateRole` - Update role details
- `deleteRole` - Delete role
- `getRoles` - List all roles
- `getRole` - Get single role
- `getWorkspaceRoles` - Get roles for workspace
- `assignRoleToActor` - Assign role to actor
- `removeRoleFromActor` - Remove role from actor
- `roleHierarchy` - Get role hierarchy

### Actors
- `createActor` - Create actor (user or agent)
- `updateActor` - Update actor details
- `deleteActor` - Delete actor
- `getActors` - List all actors
- `getActor` - Get single actor
- `createRbacAgent` - Create RBAC agent
- `delegatePermissionToAgent` - Delegate permission to agent
- `delegateRoleToAgent` - Delegate role to agent
- `revokeDelegatedPermission` - Revoke delegated permission
- `revokeDelegatedRole` - Revoke delegated role

### Resources
- `createRBACResourceType` - Create resource type
- `updateRBACResourceType` - Update resource type
- `deleteRBACResourceType` - Delete resource type
- `getRBACResourceTypes` - List resource types
- `createRBACResource` - Create resource instance
- `updateRBACResource` - Update resource
- `deleteRBACResource` - Delete resource
- `getRBACResources` - List resources
- `resourceHierarchy` - Get resource hierarchy

### Permission Checks
- `checkPermission` - Check single permission
- `checkMultiplePermissions` - Check multiple permissions
- `checkActorPermission` - Check actor permission
- `checkScopedCreatePermission` - Check scoped create permission
- `getEffectivePermissions` - Get effective permissions
- `evaluatePermission` - Detailed permission evaluation

## Log Files

Test logs are stored in:
```
~/products/workspaces/workspaces-doctor/logs/e2e-rbac-*.log
```

View latest log:
```bash
make logs
```

## Service Info

| Property | Value |
|----------|-------|
| **Service** | global-rbac-svc |
| **Port** | 4022 |
| **GraphQL** | http://localhost:4022/graphql |
| **State** | PostgreSQL (5822), Valkey (6822), NATS (4224) |
| **Layer** | global |

## Related

- **Service**: `~/products/global/rbac/global-rbac-svc/`
- **State**: `~/products/global/rbac/global-rbac-state/`
- **Specs**: `~/products/global/global-specs/modules/rbac/`
- **Docs**: `~/products/global/rbac/global-rbac-svc/src/modules/rbac/docs/`

## Author

Vignesh T.V. (vignesh@burdenoff.com)

## License

Proprietary - Burdenoff Consultancy Services Pvt. Ltd.
