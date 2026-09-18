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
- **[Fase 3.1] Imprecisión conocida en `CreateBookDetails`:** por una limitación del emulador
  local (`WITH` anidado rompe el protocolo — ver `docs/catalog.md#hallazgos-de-plataforma`), el
  `AuditLog` de esta mutation se inserta como campo separado del `INSERT` nativo condicionado
  por checksum, así que se registra `BOOK_METADATA_UPDATED` aunque el checksum de ISBN sea
  inválido y no se haya creado ningún `BookDetails`. `performedByUid` sigue siendo el
  `auth.uid` real y la acción describe la intención real de la llamada — no es una vía de log
  forgery, solo una imprecisión de "se intentó" vs. "se completó".
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

### Fase 3 (Product Catalog) — 33/33, más regresión completa de Fase 2/2.1

Mismo mecanismo de pruebas, ahora contra `dataconnect/catalog/*.gql` (connector `catalog`).
Categorías: Setup 4/4, Authentication 1/1, User status 2/2, Authorization 21/21, Permission
escalation 3/3, Audit security 2/2.

Casos representativos:

- **Reutiliza el patrón de Fase 2/2.1 sin cambios estructurales**: anónimo/`INACTIVE`/
  `SUSPENDED` denegados en `GetProduct`, usuario sin `products.read`/`products.create`
  denegado, usuario con el permiso correcto permitido.
- **Separación de precios (sección 31) verificada en runtime**: `MANAGER` (tiene
  `products.update`, no `prices.update`) intentando `CreateProductPrice` → DENIED; `ADMIN`
  (tiene `prices.update`) → ALLOWED.
- **Otro recurso sin permiso**: `SELLER` sin `categories.update` intentando `UpdateCategory` →
  DENIED.
- **Duplicados rechazados por constraint, no por lógica de aplicación**: SKU duplicado y
  ISBN13 duplicado → `violates SQL unique constraint`, ninguna fila corrupta.
- **Integridad referencial**: `categoryId`/`productTypeId` inexistentes en `CreateProduct`,
  `productId` inexistente en `CreateBookDetails`/`CreateProductVariant` (huérfanos) →
  rechazados por `FOREIGN KEY constraint`, no por una validación manual que pudiera olvidarse.
- **Ciclos de categoría**: auto-referencia (`parentId == newCategoryId`) y ciclo de 2 niveles
  (mover una categoría bajo su propia nieta) → ambos DENIED; una reorganización normal sin
  ciclo sigue permitida.
- **Paginación**: `limit=500` → DENIED (excede el tope de 200); `limit=50` y `limit` omitido
  (usa el default del schema) → ambos ALLOWED.
- **Auditoría**: `PRODUCT_CREATED`, `PRICE_CREATED`, `PRODUCT_DEACTIVATED`, `CATEGORY_CREATED`,
  `BOOK_METADATA_UPDATED` aparecen correctamente en `ListAuditLogs` (connector `identity`,
  confirmando que ambos connectors comparten la misma tabla `AuditLog`); `NOPERMS` sigue sin
  poder leerlos.

**Regresión:** Fase 2 y Fase 2.1 se re-ejecutaron completas después de todos los cambios de
Fase 3, contra la misma base de datos ya poblada con datos de catálogo — sin cambios de
comportamiento. El resultado 14/15 observado en corridas repetidas contra una base persistente
fue investigado a fondo en Fase 3.1 (ver sección siguiente) y clasificado como fixture de
prueba no idempotente, no como regresión de seguridad — corregido en la raíz.

### Fase 3.1 (Data Integrity Hardening) — investigación del 14/15 y endurecimiento

**Investigación del 14/15 de Fase 2 (clasificación pedida explícitamente: fixture no
idempotente vs. regresión real vs. prueba incorrecta):** el caso 9 (`CreateMyProfile` de
`NEWUSER`) usaba un `firebaseUid`/`email` fijos (`TEST_FIREBASE_UID_NEWUSER`,
`newuser@test.local`) en el script de pruebas. Al re-ejecutar el script contra la misma base
persistente sin reiniciar el emulador, el segundo intento de auto-registro chocaba con el
`UNIQUE` de `firebaseUid` de una corrida *anterior* del propio script — no del sistema bajo
prueba. **Clasificación: (A) fixture de prueba no idempotente.** No es (B) una regresión real
(la lógica de anti-duplicación de `CreateMyProfile` siempre funcionó correctamente — de hecho
el caso 10, que prueba exactamente esa protección, seguía en PASS) ni (C) una prueba
incorrecta (la aserción es correcta; solo los datos de entrada no eran únicos por corrida).
**Corrección en la raíz:** se sufijó `UID.NEWUSER`/`EMAIL.NEWUSER` con un `RUN_ID` aleatorio
generado una vez por ejecución del script. Reconfirmado 15/15 en múltiples corridas
consecutivas contra la misma base sin reiniciar el emulador.

**Seeds no idempotentes:** ver `docs/catalog.md#seeds-idempotentes` — causa raíz real
independiente de lo anterior, corregida convirtiendo `_insertMany` a `_upsert` fila por fila.

**Endurecimiento aplicado en Fase 3.1** (detalle técnico completo en `docs/catalog.md`):
checksum matemático real de ISBN-10 (mod-11 + dígito `X`)/ISBN-13 (mod-10, pesos 1/3) vía
Native SQL; validación de `amount`/`priceType` en `CreateProductPrice`/`UpdateProductPrice`
(negativo, tope de negocio 999999.99, whitelist de `priceType`); `status` de `UpdateProductPrice`
ahora se aplica de verdad (antes se declaraba y no se usaba); `CreateBookDetails` ahora exige
`productType = BOOK`; se agregaron `CreateSupplierProduct`/`CreateProductOption`/
`CreateProductOptionValue`/`CreateProductImage` (no existían) específicamente para poder
verificar sus constraints de integridad (FK, duplicados por key compuesta) de punta a punta.

**Total final (Fase 2 + Fase 2.1 + Catálogo F3+F3.1): 15 + 41 + 63 = 119/119.** Ningún caso
oculto ni convertido en warning para forzar un PASS — el detalle de cada categoría está en
`docs/catalog.md#resultado-de-pruebas-fase-31-checkpoint`.

### Fase 4 (Inventory & Stock Core) — 73/73

Mismo mecanismo de pruebas, ahora contra `dataconnect/inventory/*.gql` (connector `inventory`).
Categorías: Setup 2/2, Inventory 8/8, Adjustments 8/8, Receiving 10/10, Returns 3/3, Transfers
14/14, **Concurrency 3/3**, Branch isolation 4/4, Authorization 8/8, Product status 2/2,
Kardex 9/9, Audit 2/2.

**Concurrencia (sección crítica de la fase) verificada con paralelismo REAL, no secuencial:**
dos `CreateInventoryAdjustment` disparados con `Promise.allSettled` (no `await` secuencial)
contra el mismo `Inventory` (`stock=10`, pidiendo `-7` y `-5` simultáneamente — suma 12 > 10).
Resultado reproducido en múltiples corridas: exactamente una tuvo efecto, la otra fue
rechazada, el stock final siempre coincidió exactamente con la ganadora (nunca ambas, nunca
negativo, nunca lost update). Detalle completo del mecanismo (UPDATE guardado por `WHERE`,
serialización por row-lock de PostgreSQL) en `docs/inventory.md#concurrencia`.

**Transferencias atómicas de 2 filas** verificadas explícitamente: con stock de origen
insuficiente, tanto origen como destino quedan sin cambios (nunca "origen descontado, destino
sin acreditar").

**Idempotencia** verificada con reintento de la misma `idempotencyKey` en `ReceiveInventory` y
`TransferInventory`: la segunda llamada es rechazada por `UNIQUE`, y el stock final refleja
solo una aplicación (no depende de un `if exists(...)` vulnerable a carreras).

**Branch isolation extendida a un caso nuevo:** `TransferInventory` exige acceso a AMBAS
sucursales (origen y destino), no solo una — decisión explícita, ver `docs/inventory.md`.

**Regresión:** Fase 2 (15/15), Fase 2.1 (41/41) y Catálogo F3+F3.1 (63/63) se re-ejecutaron
completas en la MISMA corrida de emulador que Fase 4, sin reiniciar entre suites — sin cambios
de comportamiento.

**Total combinado: 15 + 41 + 63 + 73 = 192/192.**

**Hallazgo de plataforma nuevo (aislamiento entre campos de una mutation):** un campo Native
SQL no ve los cambios que otro campo de la MISMA mutation ya escribió, aunque `@transaction`
sigue revirtiendo todo ante una excepción real. Documentado en detalle, con la verificación
empírica exacta (xmin/pg_current_xact_id), en `docs/inventory.md#límite-de-plataforma-aislamiento-entre-campos-de-una-misma-mutation`.

### Fase 5 (Purchasing & Procurement Core) — 60/60

Mismo mecanismo de pruebas, contra `dataconnect/purchasing/*.gql` (connector `purchasing`).
Categorías: PurchaseOrder 18/18, PurchaseOrderItem 5/5, Receiving 11/11, Receiving atomicity
3/3, **Concurrency 3/3**, **Idempotency 1/1**, Branch isolation 3/3, Authorization 8/8,
Queries 6/6, Audit 2/2.

**Over-receiving bajo concurrencia real verificado**: PO item `ordered=10, alreadyReceived=7`,
dos requests de `3` disparados con `Promise.all` (no secuencial) — exactamente uno tuvo éxito,
`received` final fue exactamente `10`, nunca `13`. **Idempotencia bajo concurrencia real**: 3
llamadas idénticas (misma `idempotencyKey`) vía `Promise.all` — exactamente un efecto lógico,
stock incrementado una sola vez. **Atomicidad de recepción multi-item**: con 1 de 2 productos
excediendo su remanente, ninguno de los 2 se aplicó (ni el válido).

**Segregación de funciones verificada**: `MANAGER` (creador/submitter de una orden, con
`purchases.create`/`purchases.submit` pero SIN `purchases.approve`) no puede auto-aprobar su
propia orden — probado explícitamente.

**Regresión:** Fase 2 (15/15), Fase 2.1 (41/41), Catálogo F3+F3.1 (63/63) y Fase 4 (73/73) se
re-ejecutaron completas en la MISMA corrida de emulador que Fase 5, sin reiniciar entre suites.

**Total combinado: 15 + 41 + 63 + 73 + 60 = 252/252.**

**Hallazgos de plataforma nuevos** (detalle completo en `docs/purchasing.md`): (1) un campo de
recálculo de totales/estado no puede leer `SUM(...)` de filas que otro campo de la misma
mutation acaba de escribir (generalización del hallazgo de aislamiento de Fase 4 a agregaciones);
(2) encadenar dos o más campos `_execute` **sin** `RETURNING` en la misma mutation rompe el
protocolo del emulador, mitigado usando `_executeReturningFirst` con `RETURNING` explícito en
todo campo de escritura Native SQL del connector `purchasing`.

### Lección de plataforma (Fase 3): variables opcionales omitidas en CEL

Se descubrió, corrigió y verificó un patrón de bug real: cualquier `@check`/`@auth(expr:...)`
que compare `vars.<campoOpcional> == null` falla la evaluación de CEL (no devuelve `false`)
cuando el cliente **omite** esa variable en vez de enviarla como `null` explícito — que es el
comportamiento normal de la mayoría de clientes GraphQL al usar un default del schema. Esto
afectaba: los checks de paginación (`vars.limit`) de todas las queries de listado del
connector `catalog`, y los checks de auto-referencia de categoría (`vars.parentId`). Corregido
en ambos archivos (`catalog/queries.gql`, `catalog/mutations.gql`) reemplazando el patrón por
`!has(vars.X) || vars.X == null || ...`. Verificado con una prueba explícita
(`ListProducts` sin pasar `$limit` en absoluto). **Recomendación para fases futuras:** aplicar
siempre este patrón `has()` cuando un `@check`/`@auth(expr:...)` referencie una variable
GraphQL opcional.
