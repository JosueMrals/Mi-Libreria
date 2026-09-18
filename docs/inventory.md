# Inventory & Stock Core (Fase 4)

## Modelo

```
Product (GLOBAL, Fase 3)
      │
      └── Inventory (por Branch, UNIQUE(product, branch))
              │
              └── InventoryMovement (kardex, append-only)
```

`Product` sigue siendo global (Fase 3, sin cambios). `Inventory` es donde ese producto se
vuelve físico, por sucursal: el mismo producto puede tener una fila de `Inventory` en cada
sucursal donde exista, cada una con su propia `quantity`. No se crearon entidades comerciales
alternativas (`BranchProduct`, `BookInventory`, etc.) — un único par de tablas
(`Inventory`/`InventoryMovement`) sirve para todo el catálogo, cualquiera sea su `ProductType`.

**Unidad de medida**: `Inventory` no tiene su propio campo de unidad — reutiliza siempre
`Product.unitOfMeasure` (Fase 3). `quantity` se almacena siempre en la unidad BASE del
producto, nunca en la unidad de compra/empaque; si existe una `UnitConversion` (ej. `1 BOX = 12
UNIT`), convertir de la unidad de compra a la unidad base es responsabilidad del cliente al
construir la mutation — no se implementaron conversiones automáticas de inventario en esta fase
(YAGNI, sección 20).

**`quantity` como `NUMERIC`, no `Int`**: `UnitOfMeasure.allowsDecimals` (Fase 3) ya anticipaba
productos vendidos por peso/volumen fraccionario. `quantity`/`reservedQuantity`/`minimumStock`/
`maximumStock` usan `numeric(14,3)` (3 decimales — soporta kg/L sin rediseño futuro); productos
de unidad entera simplemente se almacenan como `10.000`.

## Stock por sucursal — fuente de verdad

`Inventory.quantity` es la fuente de verdad del stock actual (sección 7). `InventoryMovement`
es el historial que explica cómo se llegó a ese valor. No existe ninguna mutation
`UpdateInventoryQuantity` de uso arbitrario: toda modificación de `quantity` ocurre únicamente
como efecto de una operación de inventario nombrada (`InitializeInventory`,
`CreateInventoryAdjustment`, `ReceiveInventory`, `ReturnInventoryIn/Out`, `TransferInventory`).

`(productId, branchId)` es la PRIMARY KEY compuesta de `Inventory` (`@table(key:
["product","branch"])`) — un duplicado es rechazado por PostgreSQL, no por lógica de
aplicación. `InitializeInventory` es la única forma de crear la fila; las demás mutations
exigen que ya exista (ver "Precondiciones" más abajo).

## Movimientos (kardex) y tipos de movimiento

`InventoryMovement` es append-only por diseño (sección 6): no existe ninguna mutation
`UpdateInventoryMovement`/`DeleteInventoryMovement`. Una corrección se registra como un nuevo
movimiento (ej. un `ADJUSTMENT_OUT` erróneo se corrige con un `ADJUSTMENT_IN` compensatorio),
nunca editando el original — el kardex conserva trazabilidad completa.

`movementType` es un dominio CERRADO de 8 valores, con signo fijo determinado por el tipo (el
signo nunca es parte del dato `quantity`, que siempre almacena la magnitud positiva):

| Tipo | Efecto | Generado por |
|---|:---:|---|
| `PURCHASE_RECEIPT` | + | `ReceiveInventory` |
| `SALE` | − | (Fase 5, no implementado aún) |
| `ADJUSTMENT_IN` | + | `CreateInventoryAdjustment(direction: "IN")` |
| `ADJUSTMENT_OUT` | − | `CreateInventoryAdjustment(direction: "OUT")` |
| `RETURN_IN` | + | `ReturnInventoryIn` |
| `RETURN_OUT` | − | `ReturnInventoryOut` |
| `TRANSFER_IN` | + | `TransferInventory` (pierna destino) |
| `TRANSFER_OUT` | − | `TransferInventory` (pierna origen) |

**Decisión de arquitectura (sección 5, "seguir la arquitectura existente si hay dominios
data-driven"):** este proyecto ya tiene DOS patrones distintos para dominios de valores:

1. **Catálogo de referencia abierto** (tabla real, ej. `ProductType`, `Category`, `Currency`):
   para dominios que el NEGOCIO extiende insertando filas, sin tocar código.
2. **Varchar + whitelist CEL** (ej. `Product.status`, `ProductPrice.priceType`, Fase 3/3.1):
   para dominios CERRADOS donde cada valor está ligado a lógica de código específica.

`movementType` es inequívocamente el caso 2: sus 8 valores están ligados 1:1 a la lógica de
signo/efecto de cada mutation — agregar un 9no tipo requeriría cambiar código de todas formas,
así que una tabla de referencia no aportaría extensibilidad real, solo una JOIN innecesaria. Se
implementó como `varchar(20)` con el valor fijado por CADA mutation (nunca recibido como string
libre del cliente): el cliente nunca puede enviar un `movementType` arbitrario porque ninguna
mutation expone ese campo como variable — cada mutation nombrada ya implica su tipo.

## Costo promedio ponderado

Implementado únicamente para `ReceiveInventory` (obligatorio) y `ReturnInventoryIn` (opcional,
ver más abajo):

```
newQty = oldQty + receivedQty
newAverageCost = (oldQty * oldAverageCost + receivedQty * receivedUnitCost) / newQty
si oldQty = 0: newAverageCost = receivedUnitCost   (evita division por cero)
```

Calculado en la MISMA sentencia `UPDATE` nativa que cambia `quantity`, leyendo `quantity`/
`average_cost` en su valor previo a esa misma sentencia (semántica estándar de SQL: el `SET`
de un `UPDATE` lee los valores de la fila ANTES de esa sentencia). **`ReturnInventoryIn` con
`unitCost` opcional:** la sección 12 solo especifica la fórmula para "cuando entra inventario"
en el contexto de recepción de compra; una devolución de cliente normalmente no trae un costo
nuevo conocido. Si el cliente envía `unitCost`, se recalcula con la misma fórmula; si no,
`averageCost` no se toca — decisión documentada, no un olvido.

**No implementado en esta fase (explícitamente fuera de alcance, sección 29):** FIFO/LIFO,
lotes, números de serie, costeo avanzado. `averageCost` es y solo es costo promedio ponderado.

**Costo promedio en transferencias:** el destino de una `TransferInventory` NO recalcula su
`averageCost` absorbiendo el del origen — conserva el propio sin cambios. Simplificación
documentada (YAGNI): implementarlo correctamente requeriría leer el `averageCost` del origen
dentro de la misma sentencia atómica de 2 filas (técnicamente posible vía subconsulta, mismo
patrón que el guard de stock), pero no fue pedido explícitamente y añade complejidad a la
sentencia más crítica de la fase sin un caso de negocio confirmado.

## Concurrencia — cómo se evita lost update, stock negativo y transferencias parciales

**Prioridad aplicada exactamente como pide la sección de reglas finales:** PostgreSQL
transactional semantics > atomic SQL update > constraint enforcement > Data Connect
`@transaction` > CEL. Nunca se confía solo en "leer cantidad, calcular en cliente, escribir
cantidad".

### El mecanismo real

Todo cambio de `quantity` se hace con una sentencia `UPDATE` nativa PLANA (sin `WITH`), con la
condición de suficiencia de stock en el propio `WHERE`:

```sql
UPDATE inventory
SET quantity = quantity - $qty
WHERE product_id = $p AND branch_id = $b AND quantity >= $qty
RETURNING quantity
```

Bajo PostgreSQL (MVCC + row-level locking), dos `UPDATE` concurrentes sobre la MISMA fila se
serializan automáticamente: el motor toma un lock de fila para el primero que llega, lo aplica,
libera el lock; el segundo entonces re-evalúa su propio `WHERE` contra el valor YA actualizado
por el primero — si ya no alcanza, su `UPDATE` afecta 0 filas (rechazo silencioso, sin
excepción, mismo patrón que el checksum de ISBN en Fase 3.1). Esto es una garantía del motor de
base de datos, no del código de la aplicación.

**Verificado empíricamente, no asumido** (sección "no inventar capacidades"): se dispararon 2
mutations `CreateInventoryAdjustment` en PARALELO real (`Promise.allSettled`, no secuencial)
contra el mismo `Inventory` con `stock=10`, pidiendo `-7` y `-5` simultáneamente (suma=12 > 10).
Resultado, repetido en 5+ corridas: **exactamente una tuvo efecto real, la otra fue rechazada,
el stock final siempre coincidió exactamente con la que ganó (nunca ambas, nunca stock
negativo, nunca lost update)**. Ver `run_inventory_tests.js`, sección "Concurrency".

### Transferencias: atomicidad de 2 filas en 1 sentencia

`TransferInventory` mueve stock entre 2 filas (`Inventory` de origen y destino) con una única
sentencia `UPDATE` que las afecta a ambas, usando una SUBCONSULTA NO correlacionada como
"compuerta" conjunta:

```sql
UPDATE inventory
SET quantity = CASE WHEN branch_id = $origen THEN quantity - $qty ELSE quantity + $qty END
WHERE product_id = $p AND branch_id IN ($origen, $destino)
  AND (SELECT quantity FROM inventory WHERE product_id = $p AND branch_id = $origen) >= $qty
```

La subconsulta se evalúa UNA vez, contra el valor de la fila origen ANTES de esta sentencia, y
ese resultado booleano se aplica como filtro a AMBAS filas candidatas: si el origen no tiene
stock suficiente, la condición es falsa para las DOS filas y NINGUNA cambia — atomicidad real
de 2 filas en 1 solo `UPDATE`, sin necesitar una transacción distribuida ni un `WITH`.
**Verificado empíricamente:** con origen insuficiente, tanto origen como destino quedan
exactamente sin cambios (probado con lecturas posteriores confirmando ambos valores intactos).

### Idempotencia

`InventoryMovement.idempotencyKey` es `@unique` real de columna (nullable). Un reintento del
cliente con la MISMA `idempotencyKey` (ej. tras un timeout de red) hace que el `INSERT` del
movimiento viole esa restricción `UNIQUE` → PostgreSQL lo rechaza → `@transaction` revierte TODA
la mutation, incluyendo el `UPDATE` de stock que ese mismo intento ya había aplicado antes de
llegar al `INSERT` fallido. Resultado: **el stock nunca queda duplicado por un reintento**, sin
depender de un `if exists(...)` en CEL (que sí sería vulnerable a una carrera entre el chequeo y
la escritura). Verificado con prueba E2E: `ReceiveInventory`/`TransferInventory` con la misma
key dos veces → la segunda es rechazada, y el stock final refleja solo UNA aplicación.

`TransferInventory` genera 2 filas de `InventoryMovement` (`TRANSFER_OUT`/`TRANSFER_IN`) a
partir de UNA sola `idempotencyKey` de cliente; como la columna es `UNIQUE` global (no
compuesta con el tipo de movimiento), se sufija internamente (`":OUT"`/`":IN"`) para poder
insertar ambas filas sin chocar entre sí, preservando que un reintento de la MISMA
`idempotencyKey` de cliente siga siendo rechazado en ambas piernas.

### Límite de plataforma: aislamiento entre campos de una misma mutation

**Hallazgo nuevo de esta fase, verificado empíricamente con `xmin`/`pg_current_xact_id()`:**
dentro de UNA misma mutation `@transaction`, un campo Native SQL NO ve los cambios que otro
campo (anterior, en el mismo mutation) ya escribió — cada campo se evalúa contra un snapshot de
antes de que la mutation empezara a escribir. `@transaction` sigue garantizando que TODOS los
campos se reviertan si CUALQUIERA falla con una excepción real (verificado y explotado
deliberadamente para la idempotencia, arriba), pero no hay visibilidad cruzada de datos NO
confirmados entre campos de la misma mutation.

**Consecuencia práctica:** no es posible hacer que el `INSERT` de `InventoryMovement`/
`AuditLog` sea condicional al resultado REAL del `UPDATE` atómico de stock dentro de la misma
mutation (no se puede "leer" si el `UPDATE` afectó una fila desde un campo separado). Se acepta
la MISMA limitación ya documentada y aceptada en Fase 3.1 para `CreateBookDetails`: si el guard
atómico rechaza la operación (stock insuficiente detectado justo en el instante de escritura,
tras haber pasado el `@check` de pre-validación), el `InventoryMovement`/`AuditLog`
correspondiente igual se registra, con `quantityAfter` "mejor esfuerzo" (leído en vivo dentro
del propio `INSERT ... SELECT`, que sí ve el estado ANTES de la mutation — correcto en el caso
no-concurrente, que es la inmensa mayoría). El `@check` de pre-validación (lectura de
`Inventory.quantity` antes de cualquier escritura) cubre el caso común (solicitud inválida sin
carrera real) con un mensaje de error claro; el residuo de imprecisión queda acotado
ÚNICAMENTE a una carrera genuina entre 2 mutations distintas ocurriendo casi simultáneamente
sobre la MISMA fila — no es un hueco de seguridad ni corrompe `Inventory.quantity` (que sigue
siendo 100% correcto gracias al guard atómico), solo puede dejar un registro histórico
optimista en ese caso extremadamente acotado.

**No se intentó "arreglar" esto con un `WITH` que encadene ambas escrituras en una sola
sentencia** porque Fase 3.1 ya había documentado que un `WITH` anidado dentro del `WITH` que
Data Connect genera automáticamente rompe el protocolo del emulador local — confirmado de nuevo
en esta fase con una prueba aislada (`UPDATE ... RETURNING` encadenado a un `INSERT ... SELECT`
vía CTE): mismo error `unexpected message 'E'; expected ReadyForQuery`.

**Otro hallazgo de plataforma menor:** intentar forzar una constraint `CHECK` real vía
`@col(dataType: "numeric(14,3) CHECK (quantity >= 0)")` NO funciona — Data Connect analiza el
`dataType` y solo conserva el tipo base reconocido (`numeric(14,3)`), descartando en silencio
cualquier sufijo adicional (confirmado inspeccionando el DDL generado en
`dataconnect-debug.log`: la columna se creó sin el `CHECK`). La garantía de no-negativo para
`quantity` descansa, en cambio, enteramente en el guard `WHERE quantity >= $qty` de cada
`UPDATE` — que además es el mecanismo que también resuelve concurrencia (una constraint `CHECK`
sola NO habría resuelto el problema de lost update, solo lo hubiera detectado después del
hecho).

## Precondiciones y validaciones

- `InitializeInventory`: producto y sucursal deben existir (FK real), sin duplicar (PK real),
  `minimumStock`/`maximumStock >= 0`, `maximumStock >= minimumStock` si ambos existen.
- `CreateInventoryAdjustment`/`ReceiveInventory`/`ReturnInventoryIn`/`ReturnInventoryOut`:
  exigen que `Inventory` YA exista (usar `InitializeInventory` primero) — mensaje de error
  explícito si no.
- `TransferInventory`: exige que el `Inventory` de AMBAS sucursales (origen y destino) ya
  exista. El destino NO se auto-crea dentro de la transferencia — decisión mínima documentada
  para evitar lógica adicional de "crear-o-actualizar" dentro de la sentencia atómica de 2
  filas más crítica de esta fase.
- Dinero (`unitCost`/`totalCost`/`averageCost`, sección 13): mismas reglas de Fase 3.1 —
  `numeric(12,2)` real en Postgres, rechazo de negativo y de un tope de negocio
  (`999999.99`) deliberadamente por debajo de la capacidad cruda de la columna, para nunca
  disparar un overflow crudo de Postgres desde el `@check`.

## Estado de producto (sección 24)

| Operación | `INACTIVE` | `DISCONTINUED` |
|---|:---:|:---:|
| `ReceiveInventory` | Permitido | **Bloqueado** |
| `CreateInventoryAdjustment` | Permitido | Permitido |
| `ReturnInventoryIn`/`ReturnInventoryOut` | Permitido | Permitido |
| `TransferInventory` | Permitido | Permitido |

**Decisión explícita:** solo `ReceiveInventory` se bloquea para `DISCONTINUED` (no tiene
sentido comercial comprar más de algo descontinuado permanentemente). `INACTIVE` nunca bloquea
nada (puede ser una pausa temporal con una orden de compra ya en camino). Ajustes/devoluciones/
transferencias se permiten SIEMPRE independientemente del estado — corregir un conteo físico o
mover stock existente debe funcionar incluso para productos fuera de circulación, tal como
advierte la sección 24 ("no asumir que INACTIVE debe bloquear absolutamente toda operación
histórica").

## Branch isolation

Mismo modelo exacto de Fase 2 (`auth.uid → UserProfile ACTIVE → roles → permissions →
UserBranch`), sin ningún atajo `if role == SUPER_ADMIN`. Cada mutation/query de inventario
verifica, además del permiso concreto, que el `UserProfile` del llamador tenga una fila
`UserBranch` para la(s) sucursal(es) involucrada(s):

- Operaciones de una sola sucursal: se exige acceso a esa sucursal.
- `TransferInventory`: se exige acceso a AMBAS sucursales (origen y destino) — decisión
  explícita de la sección 21 ("definir claramente si se requiere autorización sobre origen,
  destino, o ambos"): mover stock hacia o desde una sucursal no autorizada queda denegado en
  cualquier dirección, la más conservadora de las 3 opciones permitidas por el prompt.

**Queries (kardex, sección 17):** todas exigen `$branchId` obligatorio, verificado igual que
las mutations. **Decisión documentada (YAGNI):** no se implementó agregación "todas mis
sucursales en una sola llamada" — un usuario con acceso a varias sucursales llama la query una
vez por sucursal. Filtrar server-side por "todas las sucursales a las que tengo acceso" sin
conocer esa lista de antemano no tiene un patrón `where` seguro y verificado en este proyecto
todavía; inventarlo sin probarlo violaría "no inventar capacidades de la plataforma". Una capa
de reportes/dashboard futura puede agregar client-side (llamando una vez por sucursal) o
diseñar una query dedicada una vez que el patrón se verifique.

## Permisos (sección 15)

Reutiliza el RBAC existente. Nuevos: `inventory.receive`, `inventory.return`,
`inventory.transfer` (`inventory.read`/`inventory.adjust` ya existían como placeholders desde
Fase 2). **`inventory.create` evaluado y NO creado**: la inicialización de inventario
(`InitializeInventory`) reutiliza `inventory.adjust` — crear un permiso separado solo para
"crear la fila en 0" no aporta separación de responsabilidades real (quien puede ajustar stock
ya puede, por definición, llevarlo a cualquier valor incluyendo el inicial) y violaría "no
crear permisos excesivamente granulares sin necesidad". Ver `docs/authorization-matrix.md`
para la matriz completa actualizada.

## Auditoría

Toda mutation genera `AuditLog`: `INVENTORY_INITIALIZED`, `INVENTORY_ADJUSTED`,
`INVENTORY_RECEIVED`, `INVENTORY_RETURNED` (ambos returns comparten el evento — misma
granularidad que otras acciones compuestas del proyecto), `INVENTORY_TRANSFERRED`. El actor
siempre es `auth.uid` (nunca un campo de cliente). Para transferencias, `AuditLog.entityId`
referencia el producto y `branchId` referencia la sucursal ORIGEN — el destino queda
recuperable desde las 2 filas de `InventoryMovement` generadas (`TRANSFER_OUT` en origen,
`TRANSFER_IN` en destino), que sí registran ambas sucursales por separado.

## Restricciones de PostgreSQL verificadas E2E (sección 22)

- `Inventory.productId → Product`, `Inventory.branchId → Branch`: FK reales, huérfano
  rechazado.
- `InventoryMovement.productId → Product`, `.branchId → Branch`, `.inventory → Inventory`
  (FK compuesta hacia `product_id`+`branch_id`, con `@ref(constraintName:)` explícito porque el
  nombre auto-generado excedía el límite de 63 bytes de Postgres — mismo patrón que
  `ProductVariantOptionValue` en Fase 3).
- `UNIQUE(product_id, branch_id)` en `Inventory` (es la PK compuesta).
- `UNIQUE(idempotency_key)` en `InventoryMovement`.

Ningún caso de huérfano/duplicado se rechaza solo por `@check` de CEL sin respaldo real de
PostgreSQL (sección 22: "no asumir que una validación CEL reemplaza una constraint SQL").

## No implementado a propósito (sección 29)

Mobile/Desktop, POS, Sales, Shopping Cart, Customers, Purchase Orders completos, Suppliers UI,
barcode scanner, printing, offline sync completo, Redis, WebSockets, ASP.NET Core, REST API,
FIFO/LIFO, lot tracking, serial tracking, warehouse management avanzado, `ReserveStock`/
`ReleaseStock` (aunque `reservedQuantity` SÍ se mantiene en el modelo, con la restricción
`reservedQuantity <= quantity` documentada — sin mutations que la usen todavía, preparado para
ventas/preventas futuras).

## Decisiones pendientes / riesgos conocidos

- Sin tope de negocio confirmado si el negocio pide costo promedio propagado en transferencias.
- `GetLowStockProducts`/`GetOutOfStockProducts` no se combinan todavía con notificaciones
  (explícitamente fuera de alcance, sección 18).
- Agregación de inventario cross-branch en una sola query: pendiente de un patrón `where`
  verificado (ver "Branch isolation" arriba).
