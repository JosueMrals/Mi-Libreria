# Arquitectura

## Objetivo de la fase

Preparar la infraestructura base del sistema de librerías con Firebase SQL Connect y Cloud SQL para PostgreSQL.

## Arquitectura inicial

Mobile
↓
Firebase Authentication
↓
Firebase SQL Connect
↓
Cloud SQL PostgreSQL

Desktop
↓
Firebase Authentication
↓
Firebase SQL Connect
↓
Cloud SQL PostgreSQL

## Principios

- Los clientes no se conectan directamente a PostgreSQL.
- Las operaciones de lectura y escritura se exponen mediante queries y mutations de SQL Connect.
- La autorización se valida en el backend mediante Directives de SQL Connect y Firebase Auth.
- No se implementan todavía productos, ventas, compras ni inventario funcional.

## Modelo de prueba

Se utiliza una entidad temporal llamada `TestEntity` para validar el ciclo completo de infraestructura:

- schema
- query
- mutation
- auth
- authorization
- emulator
- generated SDK

## Fase 2 — Identity, RBAC, Branches, Audit

Sobre la base de la Fase 1 se implementó el primer modelo real de negocio:

```
Identity                Application Identity      Authorization         Organization        Auditing
Firebase Authentication → UserProfile        →     Role → Permission    Branch → UserBranch  AuditLog
```

- `UserProfile` separa identidad (Firebase) de perfil de aplicación (PostgreSQL), vinculados
  por `firebaseUid`, siempre resuelto desde `auth.uid` en servidor.
- Autorización por permisos concretos (`@check` sobre `RolePermission`/`UserRole`), nunca por
  atajos de rol en código — ver `docs/security.md` y `docs/authorization-matrix.md`.
- Branch scope real vía `UserBranch`: ninguna operación confía en un `branchId` de cliente.
- `AuditLog` append-only, escrito solo como efecto secundario de las mutations de negocio (no
  hay endpoint genérico de auditoría).

Detalle completo del modelo de datos en `docs/database.md`, amenazas analizadas en
`docs/threat-model.md`.

## Fase 3 / 3.1 — Product Catalog & Data Integrity Hardening

`Product` como entidad comercial universal, global (sin `branchId`), con `BookDetails` para el
caso bibliográfico. Endurecido en Fase 3.1 con checksum matemático real de ISBN, validación de
dinero, seeds idempotentes. Detalle completo en `docs/catalog.md`.

## Fase 4 — Inventory & Stock Core

Sobre `Product` (global, Fase 3) se construyó el inventario físico por sucursal:

```
Product (global) → Inventory (por Branch) → InventoryMovement (kardex append-only)
```

Objetivo central de la fase: correctness bajo concurrencia (nunca lost update, nunca stock
negativo, transferencias atómicas de 2 filas, idempotencia real vía `UNIQUE`), priorizada
explícitamente por encima de performance/conveniencia. Verificado con pruebas de paralelismo
real (`Promise.allSettled`), no solo secuencial. Reutiliza el mismo modelo de seguridad de Fase
2 (`auth.uid → UserProfile ACTIVE → roles → permissions → UserBranch`) sin ningún atajo de rol
en código. Detalle completo del modelo, la estrategia de concurrencia y los hallazgos de
plataforma en `docs/inventory.md`.

## Fase 5 — Purchasing & Procurement Core

Sobre `Supplier`/`SupplierProduct` (Fase 3) e `Inventory`/`InventoryMovement` (Fase 4) se
construyó el núcleo de compras:

```
Supplier → PurchaseOrder → PurchaseOrderItem → PurchaseReceipt → PurchaseReceiptItem
                                                       ↓
                                    InventoryMovement(PURCHASE_RECEIPT) → Inventory.quantity
```

`PurchaseOrder` es un documento/intención comercial que nunca toca `Inventory` directamente;
solo `PurchaseReceipt` (recepción física confirmada) genera el movimiento. Reto técnico central:
Data Connect no permite componer mutations, así que aplicar un número arbitrario de items de
una recepción de forma atómica requirió generalizar el patrón de guard de Fase 4 usando
variables GraphQL de tipo lista + `UNNEST` + una compuerta agregada — verificado con
concurrencia real antes de construir la mutation completa. Detalle completo, incluyendo el
hallazgo de plataforma sobre `_execute` sin `RETURNING`, en `docs/purchasing.md`.

## Delimitación del alcance

No se crea aún:

- mobile UI
- desktop UI
- React Native
- Tauri
- ASP.NET Core
- REST API propia
- Sales/Customer/pagos/cuentas por pagar/contabilidad (Fase 6+)
- FIFO/LIFO, lotes, números de serie, warehouse management avanzado
