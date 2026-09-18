# Matriz de autorización (Fase 2, extendida en Fase 3)

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
| inventory.receive | ✔ | ✔ | ✔ | | ✔ | | |
| inventory.return | ✔ | ✔ | ✔ | | ✔ | | |
| inventory.transfer | ✔ | ✔ | ✔ | | ✔ | | |
| purchases.read | ✔ | ✔ | ✔ | | ✔ | | |
| purchases.create | ✔ | ✔ | ✔ | | ✔ | | |
| purchases.update | ✔ | ✔ | ✔ | | | | |
| purchases.submit | ✔ | ✔ | ✔ | | ✔ | | |
| purchases.approve | ✔ | ✔ | | | | | |
| purchases.cancel | ✔ | ✔ | ✔ | | | | |
| purchases.receive | ✔ | ✔ | ✔ | | ✔ | | |
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
| categories.read | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |
| categories.create | ✔ | ✔ | ✔ | | | | |
| categories.update | ✔ | ✔ | ✔ | | | | |
| categories.delete | ✔ | ✔ | | | | | |
| brands.read | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |
| brands.create | ✔ | ✔ | ✔ | | | | |
| brands.update | ✔ | ✔ | ✔ | | | | |
| brands.delete | ✔ | ✔ | | | | | |
| authors.read | ✔ | ✔ | ✔ | | | ✔ | ✔ |
| authors.create | ✔ | ✔ | | | | | |
| authors.update | ✔ | ✔ | | | | | |
| publishers.read | ✔ | ✔ | ✔ | | | ✔ | ✔ |
| publishers.create | ✔ | ✔ | | | | | |
| publishers.update | ✔ | ✔ | | | | | |
| prices.read | ✔ | ✔ | ✔ | | | | ✔ |
| prices.update | ✔ | ✔ | | | | | |
| book_metadata.read | ✔ | ✔ | ✔ | | | | ✔ |
| book_metadata.create | ✔ | ✔ | ✔ | | | | |
| book_metadata.update | ✔ | ✔ | ✔ | | | | |

`products.*` y `suppliers.*` (filas de arriba) se **reutilizan tal cual de Fase 2** — ya
existían como placeholders para esta fase (sección 47 del prompt de Fase 3 los vuelve a listar
exactamente igual, confirmando que no debían duplicarse).

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
- **[Fase 3] `categories.read`/`brands.read` se dieron a todos los roles operativos**
  (`CASHIER`/`INVENTORY`/`SELLER` incluidos, no solo a quienes ya tenían `products.read`):
  necesitan navegar el catálogo para vender/recibir mercancía, y enumerar nombres de categorías/
  marcas no es sensible.
- **[Fase 3] `prices.update` solo en ADMIN/SUPER_ADMIN**, ni siquiera `MANAGER` lo tiene —
  separación deliberada de `products.update` (sección 31 del prompt de Fase 3): un `MANAGER`
  puede editar el catálogo de su sucursal pero no cambiar precios/costos. Verificado con
  prueba E2E (`MANAGER` con `products.update` intentando `CreateProductPrice` → DENIED).
- **[Fase 3] `book_metadata.*` separado de `products.*`**: catalogar la ficha bibliográfica de
  un libro (título, ISBN, autores) es una operación distinta de editar el producto comercial
  que la contiene, aunque en la práctica los mismos roles (ADMIN/MANAGER) suelen tener ambos.

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

**[Fase 3] Lección de plataforma:** una variable GraphQL opcional que el cliente **omite**
(no la envía, en vez de enviar `null` explícito) no aparece en `vars`, y comparar
`vars.limit == null` directamente **falla la evaluación de CEL** en vez de devolver `false` —
denegando incluso el caso más común (cliente usa el default del schema sin pasar nada). El
patrón correcto es `!has(vars.limit) || vars.limit == null || ...`. Aplica a cualquier check que
referencie una variable opcional, no solo a paginación — ver `docs/catalog.md` y
`docs/security.md`.

## Fase 5: purchases.submit/approve/cancel/receive nuevos — segregación de funciones preparada

`purchases.read`/`create`/`update` ya existían como placeholders de Fase 2. Se agregaron
`purchases.submit`, `purchases.approve`, `purchases.cancel`, `purchases.receive`.

**`purchases.approve` es el único permiso de esta fase otorgado a un subconjunto MÁS
restringido que `purchases.create`**: solo `SUPER_ADMIN`/`ADMIN` — ni siquiera `MANAGER` (que
sí tiene `create`/`submit`/`receive`) puede aprobar. Esto prepara segregación de funciones
(sección 26: "Creator ≠ Approver ≠ Receiver") sin forzarla como política rígida — un `ADMIN`
individual todavía podría crear y aprobar la misma orden si actuara en ambos pasos, pero el
modelo ya permite que el negocio lo restrinja más adelante (ej. quitándole `purchases.create`
a quienes solo deban aprobar) sin ningún cambio de schema ni de mutations. Verificado con
prueba E2E: `MANAGER` intentando aprobar su propia orden → DENIED.

`purchases.submit`/`purchases.receive` se otorgaron al mismo tier que `purchases.create`
(`SUPER_ADMIN`/`ADMIN`/`MANAGER`/`INVENTORY`) — quien puede crear una orden también puede
someterla y recibir su mercancía, consistente con el flujo operativo normal de una sucursal.
`purchases.cancel` se otorgó al mismo tier que `purchases.update` (`SUPER_ADMIN`/`ADMIN`/
`MANAGER`, sin `INVENTORY`).

## Fase 4: inventory.receive/return/transfer nuevos; inventory.create evaluado y descartado

`inventory.read`/`inventory.adjust` ya existían como placeholders de Fase 2 (mismos 4 roles:
SUPER_ADMIN, ADMIN, MANAGER, INVENTORY). Se agregaron `inventory.receive`, `inventory.return`,
`inventory.transfer`, otorgados a los MISMOS 4 roles — ninguna granularidad nueva por rol.
`TransferInventory` exige `inventory.transfer` **más** acceso `UserBranch` a AMBAS sucursales
(origen y destino), no solo una — la separación de responsabilidad de negocio (`transfer` vs
`adjust`/`receive`/`return`) y la separación de scope de sucursal (branch isolation) son
mecanismos independientes que se combinan, igual que en el resto del proyecto.

**`inventory.create` evaluado explícitamente y NO creado** (sección 15 lo pide evaluar): la
inicialización de inventario (`InitializeInventory`) reutiliza `inventory.adjust`. Quien puede
ajustar el stock de un producto/sucursal ya puede, por definición, llevarlo a cualquier valor
incluyendo el inicial (cero) — un permiso `inventory.create` separado no aportaría separación
de responsabilidad real, solo granularidad sin caso de uso, violando "no crear permisos
excesivamente granulares sin necesidad".

## Fase 3.1: sin permisos nuevos, reutilización confirmada

El hardening de Fase 3.1 no introdujo ninguna fila nueva en esta matriz. Las mutations nuevas
(`CreateSupplierProduct`, `CreateProductOption`, `CreateProductOptionValue`,
`CreateProductImage`) se agregaron exclusivamente para poder verificar constraints de
integridad ya existentes en el schema (FK, duplicados por key compuesta), y reutilizan permisos
ya existentes (`suppliers.update`, `products.update`) — no representan una capacidad de negocio
nueva. Se evaluó explícitamente partir `prices.update` en `prices.update` (venta) +
`prices.cost.update` (costo) para que un rol pudiera tocar precio de venta sin ver costo; **no
se implementó** por falta de un caso de negocio confirmado — ver `docs/catalog.md` sección
"COST vs RETAIL/WHOLESALE/PROMOTIONAL". `UpdateProductPrice` (incluyendo su nuevo campo
`status` para desactivar precios) sigue exigiendo únicamente `prices.update`, igual que
`CreateProductPrice`.

## Verificación de hardening (Fase 2.1)

Esta matriz fue puesta a prueba explícitamente con intentos de escalamiento (no solo
inspección de código): `CASHIER`/`SELLER` auto-asignándose `ADMIN`, un usuario sin
`roles.manage`/`permissions.manage` modificando `Role`/`Permission`/`RolePermission`, y
`SUPER_ADMIN` operando **después de que se le quitó en runtime** su fila `RolePermission` de
`roles.manage` (para confirmar que no hay ningún `if role == 'SUPER_ADMIN'` en el código, solo
esta tabla). Los 41 casos de la suite de hardening — incluyendo 9 de escalamiento de permisos y
3 de escalamiento de rol — dieron el resultado esperado. Detalle completo en
`docs/security.md#pruebas-ejecutadas`.
