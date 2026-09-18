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

## Modelo de Product Catalog & Master Data (Fase 3)

Definido en `dataconnect/schema/catalog.gql` (universal) y `catalog_books.gql` (bibliográfico).
Detalle completo de cada tabla y decisiones de diseño en `docs/catalog.md`.

```
Product (GLOBAL, sin branchId — sección 48)
├── ProductIdentifier      (type+value UNIQUE: EAN/UPC/ISBN10/13/GTIN/SUPPLIER_CODE/INTERNAL_CODE)
├── ProductVariant
│      └── ProductVariantOptionValue ── ProductOptionValue ── ProductOption
├── ProductPrice           (permiso propio: prices.read/update, separado de products.*)
├── ProductImage           (COVER/PRODUCT/THUMBNAIL/OTHER; url/storagePath, nunca binarios)
├── SupplierProduct ── Supplier   (prepara Compras, Fase 6)
├── BookDetails            (1:1, PK = product; productType = BOOK forzado por @check desde Fase 3.1)
│      ├── BookAuthor    ── Author
│      ├── BookPublisher ── Publisher
│      ├── BookGenre     ── Genre
│      └── BookSeries    (BookDetails.seriesId, opcional)
├── Category  (jerárquica via parent, ciclos acotados a 3 niveles; sin límite de profundidad al crear — ver docs/catalog.md)
├── Brand     (opcional)
├── ProductType (catálogo abierto: BOOK, SCHOOL, OFFICE, COMPUTER, ...)
├── UnitOfMeasure ── UnitConversion (factor BOX→UNIT, etc.)
├── TaxCategory (opcional, mínima — entidad agregada para el FK de Product)
└── Currency (catálogo, sin conversión automática)
```

Constraints de integridad clave (sección 53): `Product.sku` UNIQUE, `ProductIdentifier`
(`type`,`value`) UNIQUE, `Category.code`/`ProductType.code`/`Publisher.code`/`Supplier.code`
UNIQUE, `Brand.code` UNIQUE cuando existe (nullable), `BookDetails.isbn10`/`isbn13` UNIQUE
(nullable — múltiples libros sin ISBN no chocan), `BookDetails.product` UNIQUE (1:1 real).

## Seeds (Fase 3.1)

`seed_identity_data.gql`/`seed_catalog_data.gql` usan `_upsert` (`ON CONFLICT DO UPDATE`) fila
por fila, no `_insertMany`, para poder re-ejecutarse contra una base ya poblada sin violar
constraints UNIQUE. Ver `docs/catalog.md#seeds-idempotentes` para el detalle y el hallazgo de
plataforma sobre el límite de CTEs encadenados por mutation que motivó dividirlos en mutations
pequeñas ejecutadas por `dataconnect/seed.sh`.

## Reglas futuras

- Usar `NUMERIC/DECIMAL` para dinero (Fase 1, sección 17): aplicado en `ProductPrice.amount` y
  `SupplierProduct.purchasePrice` vía `@col(dataType: "numeric(12,2)")` — Data Connect no
  expone un escalar `Decimal` en GraphQL (solo `Float` para números fraccionarios), pero la
  columna Postgres real es `NUMERIC`, evitando el error de redondeo binario en el
  almacenamiento aunque el transporte GraphQL sea `Float`. Ver `docs/catalog.md`.
- Usar UTC para almacenamiento de timestamps (ya aplicado: todo `Timestamp` usa
  `request.time`/`@default`, nunca un valor de cliente).
- Diseñar transacciones para ventas y cambios de inventario (Fase 4/5).
- Extender `Product`/`ProductVariant` con `branchId`/stock cuando se implemente Inventario
  (Fase 4), reutilizando el mismo mecanismo de `@check` sobre `roles_via_UserRole`/
  `permissions_via_RolePermission` + `UserBranch` para autorizar cada nueva operación.
