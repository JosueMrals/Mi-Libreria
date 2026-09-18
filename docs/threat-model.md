# Threat model (Fase 2)

Analiza las 10 amenazas pedidas en la Fase 2, sección 34, sobre el modelo Identity/RBAC/
Branches/Audit implementado en `dataconnect/schema/identity.gql` y
`dataconnect/identity/{queries,mutations}.gql`.

## 1. Usuario manipula `branchId`

**Impacto:** acceder u operar sobre una sucursal a la que no pertenece.
**Mitigación:** ninguna query/mutation de esta fase confía en un `branchId` enviado libremente;
la relación real se valida vía `UserBranch` (`ListMyBranches`) o queda pendiente de cruzarse
contra ella en las futuras mutations de negocio (Fase 3). Verificado con prueba: `NOPERMS` ve 0
sucursales propias mientras `SUPER_ADMIN` ve las 2 sembradas — el listado nunca sale de lo que
la tabla `UserBranch` dice, no de lo que pida el cliente.

## 2. Usuario manipula `userId`

**Impacto:** leer o modificar el perfil de otro usuario haciéndose pasar por él.
**Mitigación:** todas las operaciones de autoservicio (`GetMyProfile`, `UpdateMyProfile`,
`RecordLogin`, `CreateMyProfile`) resuelven el `firebaseUid` exclusivamente desde `auth.uid`
(`firebaseUid_expr: "auth.uid"` / `where: { firebaseUid: { eq_expr: "auth.uid" } }`); ninguna
declara una variable de cliente para ese campo. Probado: el token de `NEWUSER` solo puede leer
y crear el perfil de `NEWUSER`.

## 3. Usuario intenta acceder a otro usuario

**Impacto:** leer datos de otro `UserProfile` sin autorización.
**Mitigación:** `ListUsers`/`GetUserById` (lectura de terceros) exigen `users.read` vía
`@check`; sin ese permiso, la query aborta antes de tocar la tabla. Probado: `NOPERMS` (sin
rol) recibe `Requiere permiso users.read` al intentar `ListUsers`.

## 4. Usuario intenta elevar permisos

**Impacto:** un usuario sin `roles.manage`/`permissions.manage` se asigna a sí mismo (o a otro)
un rol/permiso mayor.
**Mitigación:** `AssignRole`, `RemoveRole`, `AssignPermissionToRole`, `RemovePermissionFromRole`
exigen `roles.manage`/`permissions.manage` respectivamente, verificados contra las tablas
reales (`roles_via_UserRole`/`permissions_via_RolePermission`), no contra un claim enviado por
el cliente. Probado: `NOPERMS` intentando `AssignRole(SUPER_ADMIN)` sobre el perfil de `ADMIN`
es rechazado y la transacción se revierte (sin fila `UserRole` ni `AuditLog` insertados).
**Nota de diseño:** `permissions.manage`/`roles.manage` solo están en `SUPER_ADMIN` — ni
siquiera `ADMIN` puede auto-otorgarse esos dos permisos (ver `authorization-matrix.md`).

## 5. Usuario intenta modificar role

**Impacto:** cambiar el `name` de un `Role` ya usado por los checks de autorización y por el
seed, rompiendo la matriz vigente o creando confusión entre roles.
**Mitigación:** `UpdateRoleDescription` solo permite editar `description`; el schema no expone
ninguna mutation que permita renombrar un `Role` existente. Renombrar un rol en caliente queda
fuera de alcance de esta fase (ver `Riesgos pendientes`).

## 6. Usuario intenta acceder a `AuditLog`

**Impacto:** un usuario sin `audit.read` lee el historial de auditoría (incluyendo eventos de
seguridad de otros usuarios).
**Mitigación:** `ListAuditLogs` exige `audit.read` vía `@check`; ni siquiera `ADMIN` lo tiene
por defecto en el seed (solo `SUPER_ADMIN` y `AUDITOR`). Probado: `NOPERMS` rechazado, `AUDITOR`
puede leer. Adicionalmente, `AuditLog` es append-only por **omisión de operación**: no existe
ninguna mutation `_update`/`_delete` publicada para esa tabla en ningún connector, así que el
SDK generado no puede ofrecerla aunque alguien lo intente.

## 7. Usuario deshabilitado intenta operar

**Impacto:** un usuario `INACTIVE`/`SUSPENDED` sigue operando porque su sesión de Firebase
Authentication sigue siendo válida.
**Mitigación:** todo `@check` (administrativo **y de autoservicio**) exige
`status == 'ACTIVE'`; el estado se lee de PostgreSQL en cada llamada, no se cachea en el token.
Probado end-to-end: se suspendió a `ADMIN` (rol y permisos intactos) y `ListUsers` con su token
pasó de ALLOWED a DENIED inmediatamente después, solo por el cambio de `status`.
**[Fase 2.1 — CERRADO]** El hueco de autoservicio detectado al cierre de la Fase 2
(`GetMyProfile`, `UpdateMyProfile`, `RecordLogin`, `ListMyRoles`, `ListMyPermissions`,
`ListMyBranches` no verificaban `status`) se corrigió: las 6 operaciones ahora exigen
`this.exists(u, u.status == 'ACTIVE')` antes de ejecutar nada. Probado: `SUSPENDED`/`INACTIVE`
→ DENIED en las 6; `ACTIVE` → ALLOWED. `CreateMyProfile` queda exento a propósito (bootstrap,
sin `UserProfile` previo que consultar).

## 8. Usuario intenta acceder sin autenticación

**Impacto:** ejecutar cualquier operación protegida sin haber iniciado sesión.
**Mitigación:** toda operación (salvo que se agregue una explícitamente `PUBLIC` en el futuro)
usa `@auth(level: USER)` o `USER_EMAIL_VERIFIED`. Probado: una llamada anónima
(`impersonate: { unauthenticated: true }`) a `GetMyProfile` es rechazada con
`unauthenticated: this operation requires a signed-in user`.

## 9. Usuario intenta enviar datos inválidos

**Impacto:** valores fuera de rango o mal formados (`status` arbitrario, UUID inválido,
duplicados) corrompen el modelo.
**Mitigación:** `status` de `UserProfile`/`Branch` nunca se recibe como texto libre del
cliente: cada transición usa una mutation con literal fijo
(`SuspendUser`→`"SUSPENDED"`, `ActivateBranch`→`"ACTIVE"`, etc.), evitando el problema por
diseño en vez de validarlo en cada request. Las claves únicas (`firebaseUid`, `Role.name`,
`Permission.name`, `Branch.code`, las PK compuestas de `UserRole`/`RolePermission`/
`UserBranch`) están declaradas como `@unique`/`@table(key:...)` en el schema, así que Postgres
rechaza duplicados aunque el cliente los reintente — probado con el registro doble de
`CreateMyProfile`.

## 10. Cliente comprometido intenta ejecutar operaciones no autorizadas

**Impacto:** un cliente Mobile/Desktop modificado intenta invocar operaciones fuera de lo
previsto (SQL arbitrario, mutation genérica, bypass de `@auth`).
**Mitigación:** no existe ningún endpoint SQL arbitrario ni operaciones genéricas
(`createAnything`/`updateAnything`); el cliente solo puede invocar los nombres de operación
publicados en `dataconnect/identity/*.gql` y `dataconnect/example/*.gql`, cada uno con su
propio `@auth`/`@check` evaluado **en servidor** por el emulador/Data Connect — un cliente
modificado no puede saltarse ese chequeo porque no corre en el cliente.

## Amenazas adicionales verificadas en Fase 2.1 (fuera de la lista original de 10)

## 11. "Usuario ghost": autenticado en Firebase, sin `UserProfile` en PostgreSQL

**Impacto:** ¿qué pasa si alguien tiene un token de Firebase válido pero, por lo que sea
(usuario huérfano tipo B, ver `docs/security.md#consistencia-firebase-auth--postgresql`), no
tiene fila en `UserProfile`? Riesgo de excepción no controlada tratada como "allow" por
defecto, o de un `NullPointerException`-equivalente que exponga detalles internos.
**Mitigación:** `this.exists(u, ...)` sobre una lista vacía evalúa a `false` de forma segura en
CEL — ningún caso especial que tratar. Probado: `GetMyProfile`, `ListUsers` y `AssignRole` con
un `auth.uid` sin `UserProfile` correspondiente devuelven DENIED, no error 500 ni acceso.

## 12. Registro masivo de perfiles falsos (`CreateUserProfileForUser` sin permiso)

**Impacto:** un cliente sin `users.create` intenta invocar `CreateUserProfileForUser` con un
`firebaseUid` inventado o ajeno, para poblar la tabla con perfiles falsos o pre-vincularse a la
identidad de otra persona antes de que esa persona se registre.
**Mitigación:** exige `users.create` vía `@check`, igual que cualquier otra mutation
administrativa. Probado: `NOPERMS` intentando esto es rechazado con `Requiere permiso
users.create`.

## Riesgos pendientes (no bloqueantes para cerrar la fase)

- `AUTH_LOGIN_FAILED`/`SECURITY_ACCESS_DENIED` (sección 24 del prompt) **no** tienen una
  mutation cliente-invocable: un intento de login fallido no tiene sesión autenticada válida
  con la que escribir en `AuditLog` de forma no forjable. Registrar estos eventos requiere
  Cloud Functions/Admin SDK sobre los logs de Firebase Authentication, fuera del alcance de
  Data Connect — pendiente para una fase posterior.
- `ipAddress`/`userAgent` en `AuditLog` quedan `nullable` y sin exponer en ninguna mutation:
  **confirmado contra la referencia oficial de CEL** (Fase 2.1) que Data Connect no expone hoy
  un equivalente a `request.ip`/`request.userAgent`. No es una limitación de implementación,
  es una limitación real de la plataforma en su versión actual — requeriría una capa adicional
  (Cloud Function/gateway) delante de Data Connect. `correlationId` es distinto: no es un dato
  de identidad, así que sí podría aceptarse como variable de cliente sin riesgo de seguridad el
  día que alguna mutation lo necesite; hoy ninguna lo expone todavía.
- Renombrar un `Role` existente no está soportado (ver amenaza 5) — decisión consciente, no bug.
- La reconciliación Firebase Auth ↔ PostgreSQL (escenarios A/B/C) está documentada como
  estrategia (retry con idempotency key + job de reconciliación periódico) pero **no
  implementada**: no existe todavía el job de reconciliación ni el panel administrativo que
  dispararía el flujo completo de alta. Ver `docs/security.md` para el detalle.
