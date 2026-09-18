# Matriz de autorización (Fase 2)

Matriz inicial `Role | Permission`, cargada en `dataconnect/seed_identity_data.gql` (solo
emulador/pruebas). SUPER_ADMIN no tiene ningún atajo de código: su autoridad total viene
exclusivamente de tener asignados **todos** los `RolePermission`, igual que cualquier otro rol.
La matriz puede modificarse después con `AssignPermissionToRole`/`RemovePermissionFromRole`
(ambas requieren el permiso `permissions.manage`).

| Permission | SUPER_ADMIN | ADMIN | MANAGER | CASHIER | INVENTORY | SELLER | AUDITOR |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| products.read | ✔ | ✔ | ✔ | | ✔ | ✔ | |
| products.create | ✔ | ✔ | ✔ | | | | |
| products.update | ✔ | ✔ | ✔ | | | | |
| products.delete | ✔ | ✔ | | | | | |
| sales.read | ✔ | ✔ | ✔ | ✔ | | ✔ | |
| sales.create | ✔ | ✔ | ✔ | ✔ | | ✔ | |
| sales.cancel | ✔ | ✔ | ✔ | | | | |
| inventory.read | ✔ | ✔ | ✔ | | ✔ | | |
| inventory.adjust | ✔ | ✔ | ✔ | | ✔ | | |
| purchases.read | ✔ | ✔ | ✔ | | ✔ | | |
| purchases.create | ✔ | ✔ | ✔ | | ✔ | | |
| purchases.update | ✔ | ✔ | ✔ | | | | |
| customers.read | ✔ | ✔ | ✔ | ✔ | | ✔ | |
| customers.create | ✔ | ✔ | ✔ | | | ✔ | |
| customers.update | ✔ | ✔ | ✔ | | | | |
| suppliers.read | ✔ | ✔ | ✔ | | ✔ | | |
| suppliers.create | ✔ | ✔ | | | | | |
| suppliers.update | ✔ | ✔ | | | | | |
| reports.read | ✔ | ✔ | ✔ | | | | ✔ |
| users.read | ✔ | ✔ | ✔ | | | | ✔ |
| users.create | ✔ | ✔ | | | | | |
| users.update | ✔ | ✔ | | | | | |
| users.disable | ✔ | ✔ | | | | | |
| branches.read | ✔ | ✔ | ✔ | | | | ✔ |
| branches.create | ✔ | ✔ | | | | | |
| branches.update | ✔ | ✔ | | | | | |
| cash.read | ✔ | ✔ | ✔ | ✔ | | | |
| cash.open | ✔ | ✔ | ✔ | ✔ | | | |
| cash.close | ✔ | ✔ | ✔ | ✔ | | | |
| audit.read | ✔ | | | | | | ✔ |
| permissions.manage | ✔ | | | | | | |
| roles.manage | ✔ | | | | | | |

## Decisiones de diseño

- **`permissions.manage`/`roles.manage` solo en SUPER_ADMIN.** ADMIN administra usuarios,
  sucursales y negocio, pero no puede modificar el catálogo de roles/permisos ni auto-otorgarse
  privilegios nuevos. Evita escalamiento horizontal entre administradores.
- **`roles.read`/`permissions.read` no existen** como permisos separados: `ListRoles` y
  `ListPermissions` solo exigen sesión autenticada (`@auth(level: USER)`), sin permiso
  adicional, porque enumerar nombres de catálogo no expone datos de negocio ni de otros
  usuarios (data minimization sin sacrificar usabilidad de UI).
- **Scope de sucursal** se resuelve por separado vía `UserBranch` (tabla `Branch`), no por esta
  matriz de permisos: un permiso de negocio (p. ej. `sales.create`) autoriza la operación en
  general, pero la sucursal concreta debe validarse contra `UserBranch` en servidor (Fase 2,
  sección 13). Ningún query/mutation de esta fase confía en un `branchId` enviado por el
  cliente sin cruzarlo contra esa tabla.

## Cómo se aplica en Data Connect

Cada operación administrativa incluye, antes de tocar datos, un bloque `@check` sobre el
propio `UserProfile` del llamador (resuelto por `auth.uid`, nunca por un id enviado por el
cliente):

```graphql
this.size() > 0 && this[0].status == 'ACTIVE' &&
this[0].roles_via_UserRole.exists(r, r.permissions_via_RolePermission.exists(p, p.name == '<permiso>'))
```

Si el check falla, toda la mutation aborta (transacción revertida) — confirmado con pruebas
end-to-end contra el emulador (`docs/security.md#pruebas-ejecutadas`).

## Verificación de hardening (Fase 2.1)

Esta matriz fue puesta a prueba explícitamente con intentos de escalamiento (no solo
inspección de código): `CASHIER`/`SELLER` auto-asignándose `ADMIN`, un usuario sin
`roles.manage`/`permissions.manage` modificando `Role`/`Permission`/`RolePermission`, y
`SUPER_ADMIN` operando **después de que se le quitó en runtime** su fila `RolePermission` de
`roles.manage` (para confirmar que no hay ningún `if role == 'SUPER_ADMIN'` en el código, solo
esta tabla). Los 41 casos de la suite de hardening — incluyendo 9 de escalamiento de permisos y
3 de escalamiento de rol — dieron el resultado esperado. Detalle completo en
`docs/security.md#pruebas-ejecutadas`.
