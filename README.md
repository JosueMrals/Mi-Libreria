# LibreriaSystem

Sistema de inventario y ventas para librerías. Fase 1 (infraestructura base) y Fase 2
(Identity, RBAC, Branches, Audit) completadas.

## Estado actual

- Estructura de Firebase SQL Connect (Data Connect) creada y validada contra el emulador.
- Modelo real de Identity/RBAC/Branches/Audit implementado (`UserProfile`, `Role`,
  `Permission`, `RolePermission`, `UserRole`, `Branch`, `UserBranch`, `AuditLog`).
- Autorización por permisos vía `@check` (nunca por rol hardcodeado); branch scope real vía
  `UserBranch`; auditoría append-only escrita como efecto secundario de cada mutation.
- Suite de pruebas end-to-end (15 casos) contra el emulador: autenticación, permisos, estado
  de usuario, aislamiento de sucursal y auditoría — ver `docs/security.md#pruebas-ejecutadas`.
- Documentación de arquitectura, seguridad, matriz de autorización y modelo de amenazas.
- No se ejecutan operaciones de Git.
- No se despliega a producción automáticamente.

## Estructura principal

- `dataconnect/schema/` - esquema GraphQL: `schema.gql` (ejemplo), `test_entity.gql`
  (validación Fase 1), `identity.gql` (Identity/RBAC/Branches/Audit, Fase 2).
- `dataconnect/example/` - connector de ejemplo (movies) + operaciones de `TestEntity`.
- `dataconnect/identity/` - connector con las queries/mutations reales de Fase 2.
- `dataconnect/seed_identity_data.gql` - datos de prueba (roles, permisos, sucursales, usuarios).
- `docs/` - arquitectura, seguridad, matriz de autorización, modelo de amenazas, desarrollo.
- `.env.example` - variables ficticias de entorno.
- `firebase.json` - configuración de los emuladores (Auth + Data Connect).
- `dataconnect/dataconnect.yaml` - configuración del servicio y los connectors.

## Requisitos oficiales

Se mantiene el stack indicado en la fase 1:

- Firebase
- Firebase Authentication
- Firebase SQL Connect
- Cloud SQL for PostgreSQL
- PostgreSQL
- GraphQL por SQL Connect
- Firebase CLI
- TypeScript para SDKs y utilidades

## Modelo de prueba inicial (Fase 1)

Se define una entidad mínima llamada `TestEntity` con `id`, `name`, `createdAt`, usada para
validar esquema, query, mutation, autenticación, autorización, SDK y emulador.

## Modelo de identidad y RBAC (Fase 2)

Ver `docs/database.md` (modelo de datos), `docs/authorization-matrix.md` (matriz Role↔Permission)
y `docs/threat-model.md` (amenazas analizadas). No se implementan aún Product/Inventory/Sale/
Purchase/Customer/Supplier — eso es Fase 3.

## Comandos de desarrollo local

```bash
cd LibreriaSystem
firebase emulators:start --only auth,dataconnect --project demo-libreriasystem
```

Ver `docs/development.md` para cargar datos de prueba y probar `@auth`/`@check` con usuarios reales.

## Despliegue

El despliegue de SQL Connect se prepara con las herramientas oficiales de Firebase y se ejecutará solo con autorización explícita del propietario del proyecto:

```bash
firebase deploy --only dataconnect
```

## Importante

Este proyecto aún está en la etapa de infraestructura base. No se crean apps móviles ni desktop ni lógica de negocio del dominio.
