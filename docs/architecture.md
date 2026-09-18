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

## Delimitación del alcance

No se crea aún:

- mobile UI
- desktop UI
- React Native
- Tauri
- ASP.NET Core
- REST API propia
- Product/Inventory/Sale/Purchase/Customer/Supplier (Fase 3)
