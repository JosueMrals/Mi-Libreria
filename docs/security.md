# Seguridad

## Identidad

- **Firebase Authentication** es la única autoridad de identidad: emite `uid`, `email` y el
  estado de sesión. No se implementa login/JWT/hashing propio (Fase 2, sección 2).
- **`UserProfile`** (PostgreSQL) es el perfil de aplicación, separado de la identidad. Se
  vincula exclusivamente por `firebaseUid` (`@unique`), resuelto siempre desde `auth.uid` en
  servidor — nunca aceptado como valor libre del cliente.
- El registro propio (`CreateMyProfile`) usa **insert, no upsert**: si el `firebaseUid` ya tiene
  perfil, la restricción `UNIQUE` lo rechaza. Evita que un usuario `SUSPENDED`/`INACTIVE` se
  "reactive" a sí mismo repitiendo el alta. Confirmado con prueba end-to-end.

## Roles, permisos y sucursales (RBAC)

- Modelo: `UserProfile —UserRole— Role —RolePermission— Permission`, y `UserProfile —UserBranch—
  Branch` para scope de sucursal. Ver `docs/database.md` para el detalle de columnas y
  `docs/authorization-matrix.md` para la matriz Role↔Permission inicial.
- **`SUPER_ADMIN` no tiene ningún atajo de código** (`if role == SUPER_ADMIN then allow`, Fase
  2 sección 10). Su autoridad total es 100% datos: tiene asignados todos los `RolePermission`,
  igual que cualquier otro rol, y pasa por el mismo `@check` que todos.
  **[Fase 2.1] Verificado en runtime, no solo por inspección de código:** se le quitó a
  `SUPER_ADMIN` la fila `RolePermission` de `roles.manage` (usando su propio
  `permissions.manage`), y `AssignRole` pasó inmediatamente a DENIED para ese mismo usuario —
  si existiera un atajo `if role == 'SUPER_ADMIN'`, habría seguido permitiendo la operación. Se
  restauró el permiso al terminar la prueba (fixture limpio).
- Cada operación administrativa exige el permiso concreto con un bloque `@check` (mecanismo
  oficial de Firebase Data Connect/SQL Connect, no un sistema paralelo) que resuelve el
  `UserProfile` del llamador por `auth.uid` y evalúa:

  ```
  this.size() > 0 && this[0].status == 'ACTIVE' &&
  this[0].roles_via_UserRole.exists(r, r.permissions_via_RolePermission.exists(p, p.name == '<permiso>'))
  ```

  Si falla, la mutation entera aborta (`@transaction`, fail closed): no queda fila insertada ni
  entrada de auditoría. Confirmado con prueba: `NOPERMS` intentando `AssignRole` no deja rastro.
- **Branch scope real:** nunca se confía en un `branchId` enviado por el cliente. `UserBranch`
  es la única fuente de verdad sobre a qué sucursales tiene acceso un usuario
  (`ListMyBranches`); las mutations de negocio de fases futuras deben cruzar el `branchId`
  solicitado contra esta tabla, no aceptarlo tal cual.
- **Custom Claims:** no se usan como fuente de permisos de negocio (pueden cambiar, ser
  numerosos y requieren sincronización manual — Fase 2, sección 16). Toda la matriz
  Role/Permission vive en PostgreSQL y se evalúa en cada request via `@check`.

## Estado de usuario (`status`)

- Valores: `ACTIVE` | `INACTIVE` | `SUSPENDED`. Nunca se reciben como texto libre: cada
  transición usa una mutation con literal fijo (`SuspendUser`, `DeactivateUser`,
  `ReactivateUser`, `ActivateBranch`, `DeactivateBranch`) en vez de un `UpdateStatus(status:
  String)` genérico — evita el problema de validación de enum por diseño y de paso cumple la
  sección 14 (operaciones explícitas, no genéricas).
- Todo `@check` administrativo exige `status == 'ACTIVE'` además del permiso. Confirmado con
  prueba: se suspendió a `ADMIN` (rol/permisos intactos) y `ListUsers` pasó de ALLOWED a DENIED
  inmediatamente, solo por el cambio de `status`.
- **Eliminación física de usuarios: no implementada, a propósito.** Solo `INACTIVE`/
  `SUSPENDED`, para conservar el histórico (una venta futura de `userId=123` debe seguir
  mostrando ese usuario aunque se desactive).
- **[Fase 2.1 — hardening] Cerrado:** `GetMyProfile`, `UpdateMyProfile`, `RecordLogin`,
  `ListMyRoles`, `ListMyPermissions` y `ListMyBranches` ahora exigen `status == 'ACTIVE'` del
  propio `UserProfile` (resuelto por `auth.uid`) antes de ejecutar nada. Antes de este fix, un
  usuario `SUSPENDED`/`INACTIVE` con un token de Firebase todavía válido podía seguir leyendo y
  actualizando su perfil, y "iniciar sesión" (escribiendo `lastLoginAt` + `AuditLog`) sin que
  PostgreSQL lo bloqueara — el `status` solo se validaba en operaciones *administrativas*, no en
  las de autoservicio. Confirmado con pruebas: `SUSPENDED`/`INACTIVE` → DENIED en las 6
  operaciones; `ACTIVE` → ALLOWED sin cambios. `CreateMyProfile` queda sin este check a
  propósito: es la operación de bootstrap, no existe todavía un `UserProfile` que consultar.
- El patrón `this.exists(u, u.status == 'ACTIVE')` también deniega correctamente el caso de un
  usuario autenticado en Firebase que **todavía no tiene `UserProfile`** (lista vacía →
  `exists` = `false`): fail closed, no hay excepción no controlada ni acceso implícito.
  Confirmado con prueba usando un `auth.uid` sin fila correspondiente en `UserProfile`.

## Auditoría

- `AuditLog` es append-only **por omisión de operación**: ningún archivo `.gql` de ningún
  connector define una mutation `_update`/`_delete` para esa tabla, así que el SDK generado no
  puede ofrecerla al cliente aunque lo intente.
- `performedByUid` se resuelve por `@default(expr: "auth.uid")` — ninguna mutation declara una
  variable de cliente para ese campo, así que no puede forjarse.
- **No existe un endpoint genérico `CreateAuditLog`.** Cada mutation que cambia estado de
  negocio (`AssignRole`, `SuspendUser`, `CreateBranch`, etc.) inserta su propia fila de
  `AuditLog` en la misma transacción, con `action`/`entityType`/`entityId` derivados de esa
  misma operación. Esto evita que un cliente pueda escribir entradas de auditoría con
  contenido arbitrario ("log forgery") a través de un endpoint separado.
- Solo `audit.read` puede leer `ListAuditLogs` — ni siquiera `ADMIN` por defecto (ver matriz).
- `AUTH_LOGIN_FAILED`/`SECURITY_ACCESS_DENIED` no tienen mutation cliente-invocable: un intento
  fallido no tiene sesión con la que escribir de forma no forjable. Requieren Cloud
  Functions/Admin SDK sobre logs de Firebase Authentication en una fase posterior.
- **[Fase 2.1] Verificado con pruebas de escalamiento:** ningún usuario sin el permiso
  correspondiente puede insertar/actualizar `UserRole`, `RolePermission`, `UserBranch`, `Role`,
  `Permission` ni cambiar `status` de un `UserProfile` — 9 intentos de escalamiento distintos
  (auto-asignarse `ADMIN`, modificar el rol/permiso de otro, modificar `UserRole`/`UserBranch`
  ajenos, cambiar su propio `status` o el de otro, modificar el `UserProfile` de otro usuario,
  leer datos de otros sin `users.read`, y registrar un `UserProfile` con un `firebaseUid`
  inventado) — todos DENIED, sin excepción. Detalle en la tabla de pruebas más abajo.

### Metadata de auditoría: qué es realmente obtenible (`ipAddress`, `userAgent`, `correlationId`)

**[Fase 2.1]** Se revisó la referencia oficial de CEL para SQL Connect/Data Connect
(`auth.*`, `request.*`) para determinar si estos campos pueden derivarse en servidor, igual
que `auth.uid` o `request.time`:

| Campo | ¿Obtenible hoy vía CEL/Data Connect? | Decisión |
|---|---|---|
| IP del cliente | **No.** La referencia CEL solo expone `request.operationName`, `request.variables` y `request.auth` (con `auth.uid`/`auth.token.*`); no hay `request.ip` ni equivalente documentado. | `AuditLog.ipAddress` queda `nullable`, sin ninguna mutation que lo exponga como variable — nadie (ni cliente ni servidor) lo puede escribir todavía. No se inventa un valor falso. |
| User-Agent | **No**, mismo motivo. | `AuditLog.userAgent` igual: `nullable`, no expuesto en ninguna mutation. |
| `correlationId` | **No hay un CEL que lo genere**, pero a diferencia de IP/User-Agent, no es un dato de identidad/red que deba verificarse en servidor — es solo una etiqueta de trazabilidad opaca (sección 37 de la Fase 1). Un cliente que "falsifica" su propio `correlationId` únicamente arruina su propia trazabilidad, no obtiene ningún privilegio. | Queda `nullable` y sin exponer todavía por simplicidad (ninguna mutation actual lo necesita), pero a diferencia de IP/User-Agent **sí sería seguro aceptarlo como variable de cliente** el día que una mutation lo necesite — no es una decisión de autorización. |

**Cómo se podría obtener en el futuro:** requiere una capa que sí tenga acceso a la request
HTTP cruda antes de llegar a Data Connect — típicamente una Cloud Function/API Gateway en
frente de Data Connect, o lo que Firebase exponga en versiones futuras del CEL de SQL Connect
(la propia Fase 1 advierte que esta tecnología "evoluciona rápidamente"). Hasta entonces, estos
tres campos no deben tratarse como evidencia forense confiable.

## Consistencia Firebase Auth / PostgreSQL

Firebase Authentication y Cloud SQL/PostgreSQL son **dos sistemas distintos sin transacción
distribuida entre ellos** — ninguna de las dos partes puede hacer rollback de la otra. No se
simula una transacción de dos fases que no existe; en su lugar se documenta cómo detectar y
reparar la inconsistencia cuando ocurre.

Flujo: `Firebase Auth User (Admin SDK) → UserProfile (Data Connect, CreateUserProfileForUser)`.

| Escenario | Estado resultante | Detección | Reparación |
|---|---|---|---|
| **A.** Firebase = SUCCESS, PostgreSQL = SUCCESS | Consistente. | — | — |
| **B.** Firebase = SUCCESS, PostgreSQL = FAILURE (red, `CreateUserProfileForUser` cae, permiso revocado a mitad de operación) | Usuario Firebase **huérfano**: puede autenticarse pero no tiene `UserProfile`, así que cualquier operación protegida lo deniega (`this.exists(u, ...)` sobre lista vacía → `false`, fail closed — confirmado con la prueba de usuario "ghost"). No es un agujero de seguridad, es una cuenta inutilizable hasta reconciliar. | Ya no requiere infraestructura extra: el propio `GetMyProfile`/cualquier operación falla de forma visible y consistente para ese usuario. Para detección proactiva (antes de que el usuario se queje), se puede comparar periódicamente la lista de usuarios de Firebase Auth (Admin SDK `listUsers`) contra `SELECT firebaseUid FROM user_profile` — el conjunto en Firebase y no en PostgreSQL son los huérfanos tipo B. | **Reintento con idempotencia:** reintentar `CreateUserProfileForUser` con el mismo `$newUserProfileId` (generado una sola vez, no en cada intento) es seguro — si la fila ya existe por un intento anterior parcialmente exitoso, la restricción `UNIQUE` de `firebaseUid` lo detecta como duplicado en vez de crear un segundo perfil. Si el reintento admin no es posible de inmediato, el propio usuario puede autoprovisionarse via `CreateMyProfile` en su próximo login (mitigación ya disponible hoy). |
| **C.** Firebase = FAILURE, PostgreSQL = SUCCESS | No debería poder ocurrir con el flujo actual: `CreateUserProfileForUser` exige `$firebaseUid` como parámetro y no lo genera, así que si el paso de Firebase (Admin SDK) falla, el llamador (proceso administrativo) simplemente no debería invocar el segundo paso. Si se invoca de todas formas con un `firebaseUid` que no corresponde a ningún usuario real de Firebase, queda un `UserProfile` **inalcanzable** (nadie podrá autenticarse con ese `auth.uid` para usarlo). | Comparar `user_profile.firebaseUid` contra la lista de Firebase Auth (Admin SDK `getUser`) — los que no existen en Firebase son huérfanos tipo C. | **Cleanup administrativo, no automático:** dado que `UserProfile` no tiene eliminación física (ver "Estado de usuario"), la reparación es desactivarlo (`DeactivateUser`) y, si se confirma que fue un error de proceso, documentarlo — no se auto-elimina para no perder trazabilidad si el `id` ya fue referenciado en algún `AuditLog`. |

**Estrategia recomendada para Fase 3** (cuando se construya el panel administrativo real de
alta de usuarios, sección 18 de la Fase 2): envolver ambos pasos en un *saga* explícito con
**idempotency key** = el `$newUserProfileId` generado una sola vez por el cliente/admin antes
de llamar a Firebase, en este orden: 1) crear en Firebase Auth, 2) llamar
`CreateUserProfileForUser` con ese mismo id, 3) si el paso 2 falla, reintentar con el *mismo*
id (seguro por el `UNIQUE`) en vez de generar uno nuevo; 4) un job de reconciliación periódico
(fuera de Data Connect, p. ej. Cloud Function programada) que compare ambos sistemas y marque/
notifique discrepancias tipo B o C para revisión humana, en vez de repararlas automáticamente
sin supervisión.

## Passwords, tokens y sesiones

- La aplicación **nunca almacena passwords**; Firebase Authentication gestiona hashing,
  verificación y reset.
- No se registran passwords, access tokens ni refresh tokens en `AuditLog` ni en logs.
- Sesiones/tokens: preparado para access token + refresh + revocación + logout vía Firebase
  Authentication estándar. Almacenamiento seguro en Mobile (Android Keystore / iOS Keychain, no
  `AsyncStorage`) queda documentado para cuando se implemente la app (Fase 2, sección 22); no
  se crea la app en esta fase.

## Rate limiting / abuso

- Brute force de autenticación lo gestiona Firebase Authentication. No se implementa rate
  limiting artificial dentro de cada query/mutation de Data Connect (sección 28).

## Integridad de datos

- Constraints declaradas en `dataconnect/schema/identity.gql`: `firebaseUid` UNIQUE, `Role.name`
  UNIQUE, `Permission.name` UNIQUE, `Branch.code` UNIQUE, y las PK compuestas de `UserRole`
  (`userProfile`,`role`), `RolePermission` (`role`,`permission`) y `UserBranch`
  (`userProfile`,`branch`) — evitan duplicados sin lógica adicional en las mutations.

## Secretos

- No hay secretos en el repositorio. `.env.example` solo contiene variables ficticias.
- No hay credenciales administrativas de Firebase en ningún archivo de Mobile/Desktop/
  JavaScript/TypeScript (no existen esas apps todavía).

## Pruebas ejecutadas

Suite end-to-end contra el emulador local (Auth + Data Connect, Firebase CLI 15.30.1), usando
impersonación admin (`DataConnectApiClient.executeQuery/executeMutation` con
`impersonate.authClaims`) para simular distintos usuarios reales del seed
(`dataconnect/seed_identity_data.gql`) llamando a las operaciones **reales** de
`dataconnect/identity/*.gql`. Script y evidencia completa en el registro de esta sesión (no
versionado en el repo: usa tokens/UUIDs de prueba y no aporta valor productivo).

### Fase 2 (funcional) — 15/15

| # | Caso | Resultado |
|---|---|---|
| 1 | Anónimo → `GetMyProfile` | DENIED ✅ |
| 2 | Usuario sin permisos → `GetMyProfile` (self) | ALLOWED ✅ |
| 3 | Usuario sin `users.read` → `ListUsers` | DENIED ✅ |
| 4 | `ADMIN` (tiene `users.read`) → `ListUsers` | ALLOWED ✅ |
| 5 | Usuario sin `audit.read` → `ListAuditLogs` | DENIED ✅ |
| 6 | `AUDITOR` (tiene `audit.read`) → `ListAuditLogs` | ALLOWED ✅ |
| 7 | Usuario sin `roles.manage` → `AssignRole` (auto-elevación) | DENIED, sin escritura ✅ |
| 8 | Self → `RecordLogin` actualiza `lastLoginAt` + `AuditLog` | ALLOWED ✅ |
| 9 | Self-registro (`CreateMyProfile`) toma `firebaseUid`/`email` del token | ALLOWED, valores correctos ✅ |
| 10 | Segundo `CreateMyProfile` para el mismo usuario | DENIED por `UNIQUE` ✅ |
| 11 | `SUPER_ADMIN` → `SuspendUser(ADMIN)` | ALLOWED, status cambia ✅ |
| 12 | `ADMIN` recién suspendido → `ListUsers` | DENIED aunque el rol sigue asignado ✅ |
| 13 | `AUDITOR` → `ListAuditLogs` contiene `USER_SUSPENDED` con `performedByUid` correcto | ALLOWED ✅ |
| 14 | `SUPER_ADMIN` → `ReactivateUser(ADMIN)` | ALLOWED (fixture restaurado) ✅ |
| 15 | `ListMyBranches`: `SUPER_ADMIN` ve 2 sucursales, usuario sin asignación ve 0 | ALLOWED, aislamiento correcto ✅ |

### Fase 2.1 (hardening) — 41/41, por categoría

| Categoría | Passed/Total |
|---|---|
| Authentication | 5/5 |
| User status | 9/9 |
| Authorization | 10/10 |
| Role escalation | 3/3 |
| Permission escalation | 9/9 |
| Branch isolation | 3/3 |
| Audit security | 2/2 |
| **TOTAL** | **41/41** |

Casos representativos por categoría:

- **Authentication:** anónimo denegado; usuario autenticado en Firebase pero **sin
  `UserProfile`** ("ghost") denegado en `GetMyProfile`, `ListUsers` y `AssignRole` (fail closed,
  sin excepción no controlada).
- **User status (fix de esta fase):** `SUSPENDED`/`INACTIVE` → DENIED en `GetMyProfile`,
  `UpdateMyProfile`, `ListMyRoles`, `ListMyBranches`, `RecordLogin`; `ACTIVE` → ALLOWED en
  todas.
- **Permission/Role escalation:** `CASHIER`/`SELLER` intentando auto-asignarse `ADMIN` →
  DENIED; usuario sin permiso intentando modificar `Role`, `Permission`, `UserRole`/
  `UserBranch` ajenos, su propio `status` o el de otro, el `UserProfile` de otro usuario, leer
  `ListUsers` sin `users.read`, o registrar un `UserProfile` con `firebaseUid` inventado →
  DENIED en los 9 casos, sin excepción.
- **Branch isolation:** usuario con acceso solo a `BR-NORTE` no ve `BR-CENTRAL`; usuario sin
  `users.update` no puede asignar/quitar sucursales de nadie (ni de sí mismo ni de otros),
  independientemente de qué `branchId`/`userId` envíe.
- **Audit security:** `RecordLogin` escribe `AuditLog` con `action` fijo (`"AUTH_LOGIN"`,
  ninguna variable expone ese campo al cliente) y `performedByUid` igual al `auth.uid` real del
  llamador; usuario sin `audit.read` no puede leer `ListAuditLogs`.
- **Fail closed / input tampering:** `AssignRole` con un `roleId` que no existe → rechazado por
  el `FOREIGN KEY` de PostgreSQL (`user_role_role_id_fkey`), no crea una fila corrupta ni un
  "rol fantasma"; ningún caso de los 41 resultó en `ALLOW` por defecto ante una condición
  inesperada.
- **`SUPER_ADMIN` sin bypass:** verificado en runtime (ver sección RBAC arriba), no solo por
  inspección de código.

**Nota de transparencia (no es una vulnerabilidad):** en el caso "USER intenta modificar
`UserBranch` de otro usuario", el mensaje de error combinó un aviso de `@check` fallido con uno
de restricción `UNIQUE` de PostgreSQL (la fila ya existía en el seed). Ambos confirman DENIED —
no se persistió ningún dato nuevo — pero indica que, bajo `@transaction`, Data Connect puede
reportar el error de una sentencia posterior aunque el `@check` ya haya fallado; el resultado
final (rollback completo) es correcto en ambos casos.

Validación adicional: `firebase emulators:start --only dataconnect` compila sin errores el
schema completo (`schema.gql`, `identity.gql`, `test_entity.gql`) y ambos connectors
(`example`, `identity`) — detectó y permitió corregir un bug heredado de la Fase 1
(`schema/test_entity.gql` mezclaba `query`/`mutation` dentro de `schema/`, donde solo se
permiten definiciones de tipo).
