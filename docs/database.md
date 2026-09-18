# Base de datos

## Base de datos principal

Se utiliza Cloud SQL for PostgreSQL como capa persistente.

## Principio

Los clientes no acceden directamente a PostgreSQL. Toda operación pasa por Firebase SQL Connect.

## Modelo base para validación (Fase 1)

Se preparó una entidad mínima de prueba para validar que el flujo completo funciona:

- `TestEntity` (`id`, `name`, `createdAt`) — definida en `dataconnect/schema/test_entity.gql`,
  con sus operaciones en el connector `example/` (no puede vivir dentro de `schema/`: esa
  carpeta solo admite definiciones de tipo, no `query`/`mutation`).

## Modelo de Identity/RBAC/Branches/Audit (Fase 2)

Definido en `dataconnect/schema/identity.gql`.

| Tabla | Campos clave | Notas |
|---|---|---|
| `UserProfile` | `id` (PK), `firebaseUid` (UNIQUE), `email`, `firstName`, `lastName`, `displayName`, `phone`, `status`, `createdAt`, `updatedAt`, `lastLoginAt` | Perfil de aplicación separado de la identidad Firebase. `status`: `ACTIVE`\|`INACTIVE`\|`SUSPENDED`. |
| `Role` | `id` (PK), `name` (UNIQUE), `description` | Catálogo abierto: se pueden agregar roles sin tocar código. |
| `Permission` | `id` (PK), `name` (UNIQUE), `description` | Catálogo de permisos (`products.read`, `sales.create`, ...). |
| `RolePermission` | PK compuesta (`role`, `permission`) | Relación N:N Role↔Permission. |
| `UserRole` | PK compuesta (`userProfile`, `role`) | Relación N:N UserProfile↔Role. |
| `Branch` | `id` (PK), `name`, `code` (UNIQUE), `address`, `phone`, `status`, `createdAt`, `updatedAt` | `status`: `ACTIVE`\|`INACTIVE`. |
| `UserBranch` | PK compuesta (`userProfile`, `branch`) | Scope real de sucursales por usuario. |
| `AuditLog` | `id` (PK), `performedByUid`, `branch` (FK opcional), `action`, `entityType`, `entityId` (UUID), `timestamp`, `correlationId`, `ipAddress`, `userAgent`, `metadata` | Append-only: no existe ninguna mutation `_update`/`_delete` publicada para esta tabla. |

Relaciones inversas generadas por Data Connect (confirmadas contra el emulador, Firebase CLI
15.30.1): `userRoles_on_userProfile`, `userBranches_on_userProfile`, `rolePermissions_on_role`,
y los atajos N:N `roles_via_UserRole` (en `UserProfile`) y `permissions_via_RolePermission`
(en `Role`), usados en las expresiones `@check` de autorización (ver `docs/security.md`).

Diagrama de relaciones:

```
UserProfile ──< UserRole >── Role ──< RolePermission >── Permission
     │
     └──< UserBranch >── Branch ──< AuditLog (branch opcional)
```

`entityId` en `AuditLog` es `UUID` (no `String`): todas las entidades de dominio referenciadas
(`UserProfile`, `Role`, `Permission`, `Branch`) usan UUID como identificador.

## Reglas futuras

- Usar `NUMERIC/DECIMAL` para dinero.
- Usar UTC para almacenamiento de timestamps.
- Diseñar transacciones para ventas y cambios de inventario.
- Extender `UserProfile`/`Branch`/`AuditLog` cuando se implementen Fase 3 (Product, Inventory,
  Sale, etc.), reutilizando el mismo mecanismo de `@check` sobre `roles_via_UserRole` /
  `permissions_via_RolePermission` para autorizar cada nueva operación.
