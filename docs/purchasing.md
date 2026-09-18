# Purchasing & Procurement Core (Fase 5)

## Modelo y principio central

```
Supplier (Fase 3, reutilizado sin cambios)
    ↓
PurchaseOrder → PurchaseOrderItem   (documento/intención comercial)
    ↓
PurchaseReceipt → PurchaseReceiptItem   (recepción física real)
    ↓
InventoryMovement(PURCHASE_RECEIPT) → Inventory.quantity   (Fase 4, reutilizado)
```

**`PurchaseOrder ≠ Inventory`, `PurchaseOrderItem ≠ InventoryMovement`** (sección 1): una orden
de compra es una intención comercial que nunca toca el stock por sí misma. Solo una
`PurchaseReceipt` (recepción física confirmada) genera `InventoryMovement` y actualiza
`Inventory.quantity`. No existe ninguna mutation que module `Inventory` directamente desde
`PurchaseOrder` — el único camino es `PurchaseOrder → aprobada → PurchaseReceipt →
InventoryMovement(PURCHASE_RECEIPT) → Inventory.quantity`.

`Supplier`/`SupplierProduct` (Fase 3) se reutilizan sin cambios de schema, permisos ni
auditoría — ver "SupplierProduct" más abajo para la única decisión de diseño nueva sobre cómo
se referencian desde `PurchaseOrderItem`.

## PurchaseOrder — ciclo de vida

```
DRAFT → SUBMITTED → APPROVED → PARTIALLY_RECEIVED → RECEIVED
  ↓         ↓            ↓
CANCELLED CANCELLED  CANCELLED
```

Transiciones respaldadas por el propio `WHERE` de la sentencia `UPDATE` (no solo `@check`), para
que dos transiciones concurrentes conflictivas (ej. `Approve`+`Cancel` simultáneos sobre la
misma orden) se serialicen correctamente vía row-locking de PostgreSQL — nunca ambas tienen
efecto, igual que los guards de stock de Fase 4.

- **No se permiten saltos arbitrarios** (`DRAFT → RECEIVED` directo): cada mutation exige el
  estado de origen exacto en su `WHERE` (`SubmitPurchaseOrder` exige `DRAFT`, `ApprovePurchaseOrder`
  exige `SUBMITTED`, etc.).
- **Nunca se permite cancelar `PARTIALLY_RECEIVED` ni `RECEIVED`** (sección 34): `CancelPurchaseOrder`
  solo acepta `DRAFT`/`SUBMITTED`/`APPROVED`. No se implementó una política de reversión
  automática de lo ya recibido — decisión pendiente, documentada como *future feature*.
- **El estado se deriva del progreso real**, nunca se acepta como campo de cliente: `status`
  nunca es una variable de ninguna mutation de recepción — `CreatePurchaseReceipt` lo calcula
  comparando `SUM(orderedQuantity)` contra `SUM(receivedQuantity) + cantidad de esta recepción`
  (ver "Recepción → Inventario" más abajo para el detalle técnico de por qué se calcula así y
  no con una simple lectura posterior).

## `orderNumber`: único por sucursal, no global

**Decisión de sección 40** ("no asumir global si el negocio numera por sucursal"): cada
sucursal numera sus propias órdenes independientemente. **Hallazgo de plataforma:** Data
Connect no expone un `UNIQUE` compuesto secundario sobre `(branch, orderNumber)` fuera de la
key primaria de la tabla — el mismo límite ya documentado en Fase 3/4 para relaciones FK
compuestas. Forzar `(branch, orderNumber)` como PRIMARY KEY (como se hizo con `Inventory` en
Fase 4) habría complicado innecesariamente cada FK de `PurchaseOrderItem`/`PurchaseReceipt`
hacia `PurchaseOrder` (tendrían que cargar branch+orderNumber en vez de un solo `id`).

**Solución adoptada:** `PurchaseOrder.id` sigue siendo un `UUID` simple como PRIMARY KEY (patrón
estándar del proyecto), y la unicidad de `orderNumber` por sucursal se respalda con un `INSERT`
nativo guardado por `WHERE NOT EXISTS (SELECT 1 FROM purchase_order WHERE branch_id=... AND
order_number=...)` — atómico a nivel de PostgreSQL, sin el hueco de carrera que tendría un
`@check` de solo lectura previo al `INSERT` (dos creaciones concurrentes con el mismo número
en la misma sucursal: la segunda encuentra la fila de la primera ya comprometida y su propio
`INSERT` no inserta nada, silenciosamente, igual que el patrón de guard de Fase 4).

## `SupplierProduct`: sin FK propia en `PurchaseOrderItem`

**Hallazgo de plataforma (sección 7):** `SupplierProduct` no tiene columna `id` propia — su
identidad ES la key compuesta `(supplier, product)` (Fase 3). Intentar `supplierProduct:
SupplierProduct @ref(constraintName: ...)` en `PurchaseOrderItem` fue rechazado por Data Connect
("Reference another reference field SupplierProduct.supplier") porque, a diferencia de
`InventoryMovement.inventory` (Fase 4, que sí funcionó), `PurchaseOrderItem` no tenía un campo
local `supplier` propio con el que emparejar esa mitad de la key compuesta.

**Solución adoptada:** en vez de añadir un campo `supplier` redundante solo para habilitar la
FK, se observó que el `SupplierProduct` relevante para un item de compra es **siempre derivable
sin ambigüedad** como `(PurchaseOrder.supplier, item.product)` — no existe otra combinación
válida posible en este modelo (un item de una orden de un supplier dado solo puede
"catalogarse" contra el `SupplierProduct` de ESE MISMO supplier). `PurchaseOrderItem.usesSupplierProduct:
Boolean` expresa únicamente la INTENCIÓN del cliente ("valida este item contra un
SupplierProduct catalogado"); la validación real ocurre en Native SQL al escribir el item,
uniendo contra `supplier_product` filtrado por el supplier de la ORDEN (nunca un valor
enviado por el cliente aparte). Esto hace **estructuralmente imposible** el ejemplo de cruce
inválido de la sección 7 (`SupplierProduct(A, Product X)` usado en una orden de `Supplier B`):
no existe ningún campo por el que el cliente pueda siquiera intentar enviar un supplier
distinto al de la orden.

## Cálculo de totales — nunca confiados del cliente

`PurchaseOrder.subtotal/discountAmount/taxAmount/totalAmount` se recalculan enteramente en
`UpdatePurchaseOrderDraft` a partir de los items enviados, nunca aceptados como valores del
cliente (sección 10). `UpdatePurchaseOrderDraft` reemplaza la lista COMPLETA de items en cada
llamada (el cliente envía el estado actual completo, no un delta) — decisión mínima que evita
necesitar mutations separadas de `AddItem`/`RemoveItem`/`UpdateItem`, consistente con que los
items solo son mutables mientras `status = DRAFT` (sección 35: una vez `SUBMITTED` en adelante,
el guard de la propia sentencia congela los items frente a esta mutation).

**Hallazgo de plataforma importante:** los totales se calculan **aritméticamente desde los
arrays de entrada** (vía `UNNEST`), nunca desde un `SUM(...)` leído contra la tabla real
`purchase_order_item`. La primera versión SÍ intentó leer `SUM(ordered_quantity * unit_cost)
FROM purchase_order_item` dentro del mismo `UpdatePurchaseOrderDraft` que acababa de insertar
esos mismos items en un campo separado (`insertItems`) — y **siempre calculó 0**, porque ese
campo de recálculo de totales, al ser una sentencia SEPARADA en la misma mutation, no ve las
filas que `insertItems` acaba de escribir (el mismo hallazgo de "aislamiento entre campos" de
Fase 4/5, ver más abajo). La corrección fue calcular `SUM` directamente sobre los arrays de
entrada (`SELECT SUM(t.qty*t.cost) FROM UNNEST($quantities, $unitCosts) AS t(qty,cost)`), que
no depende de leer ninguna escritura ajena.

## Recepción → Inventario: atomicidad de N items en una sola mutation

**El reto central de esta fase:** `CreatePurchaseReceipt` debe aplicar un número **arbitrario**
de items (`PurchaseReceiptItem` + `InventoryMovement` + actualización de `Inventory.quantity` +
actualización de `PurchaseOrderItem.receivedQuantity` + recálculo del `status` de la orden) de
forma completamente atómica — o todo tiene efecto, o nada (secciones 14/19). Data Connect no
permite que una mutation llame a otra (sección 15: "no llamar una mutation desde otra si la
plataforma no lo soporta" — confirmado que no lo soporta), así que **no se pudo reutilizar
literalmente la mutation `ReceiveInventory` de Fase 4** dentro de esta. En su lugar,
`CreatePurchaseReceipt` reimplementa inline exactamente la misma fórmula de costo promedio
ponderado y el mismo patrón de guard atómico que `ReceiveInventory`, generalizado a N items.

### El patrón: variables de tipo lista + `UNNEST` + compuerta agregada

Verificado empíricamente con un probe dedicado antes de escribir la mutation real:

1. **Variables GraphQL de tipo lista** (`$productIds: [UUID!]!`, `$quantities: [Float!]!`, etc.)
   — confirmadas soportadas como parámetros de Native SQL.
2. **`UNNEST($1::uuid[], $2::numeric[], ...)`** expande esas listas en un conjunto de filas
   dentro de UNA sola sentencia SQL plana (sin `WITH`, que sigue roto desde Fase 3.1/4).
3. **Una "compuerta" agregada no correlacionada**: `(SELECT COUNT(*) FROM UNNEST(...) v JOIN
   purchase_order_item poi ON ... WHERE v.qty > 0 AND poi.received_quantity + v.qty <=
   poi.ordered_quantity) = array_length(...)`. Si CUALQUIER item de la lista falla su condición
   individual (sobre-recepción, producto/orden no coincide, inventario no inicializado), la
   cuenta agregada no alcanza el total esperado y la compuerta es `false` para **todas** las
   filas de **todas** las sentencias — ninguna se modifica. Esto generaliza el patrón de 2 filas
   de `TransferInventory` (Fase 4, una compuerta booleana simple) a un número arbitrario de
   filas con condiciones individuales.

Verificado con un probe aislado (`UNNEST` + `JOIN` + subconsulta correlacionada de una tabla
distinta, replicando exactamente la forma real) antes de escribir la mutation completa: con 3
items donde 1 excedía su límite individual, **ninguno** de los 3 se aplicó; con los 3 válidos,
los 3 se aplicaron correctamente.

### Hallazgo de plataforma: `_execute` sin `RETURNING` rompe el protocolo al encadenarse

**El bug más difícil de diagnosticar de esta fase.** El diseño original usaba `_execute` (sin
cláusula `RETURNING`, ya que no se necesitaba leer el resultado) para los pasos intermedios
(`DELETE`, `UPDATE`s de aplicación). Cada sentencia individual, probada AISLADA (como su propia
mutation de un solo campo), funcionaba perfectamente — incluyendo la sentencia `INSERT`
completa con su compuerta agregada de 6 columnas. Pero al **combinar dos o más campos `_execute`
en la misma mutation** (por ejemplo `deleteOldItems` seguido de `insertItems`), el protocolo de
PGlite se rompía con el mismo error genérico ya documentado en fases anteriores
(`unexpected message 'E'; expected ReadyForQuery`).

**Diagnóstico:** aislado mediante mutations de depuración sucesivas (probar la compuerta sola →
funciona; probar el `INSERT` solo → funciona; combinar `DELETE` + `INSERT`, ambos como
`_execute` → falla; los mismos dos campos como `_executeReturningFirst` con `RETURNING id`
explícito en ambos → funciona). **Causa raíz:** el mecanismo de Data Connect que empaqueta todos
los campos de una mutation en un único `WITH "cte_0" AS (...)` gigante parece requerir que cada
CTE individual tenga una cláusula `RETURNING` (necesaria de todas formas para construir el
`jsonb_build_object(...)` de cada campo); con múltiples campos `_execute` sin `RETURNING`
encadenados, esa construcción se rompe en el emulador local.

**Solución adoptada en todo el archivo:** **todo** campo Native SQL de escritura en
`purchasing/mutations.gql` usa `_executeReturningFirst` con una cláusula `RETURNING id` (o
equivalente) explícita, incluso cuando el resultado no se necesita para nada más que confirmar
éxito/fracaso — nunca `_execute` liso cuando hay más de un campo Native SQL de escritura en la
misma mutation. Documentado aquí para que futuras fases no repitan el mismo ciclo de
diagnóstico.

### `PurchaseOrder.status` tras la recepción: mismo hallazgo de aislamiento, misma solución

El campo que recalcula `status` (`RECEIVED` vs `PARTIALLY_RECEIVED`) tampoco puede leer el
`SUM(received_quantity)` YA actualizado por el campo `poItemUpdate` de la misma mutation (mismo
aislamiento entre campos). Se resuelve leyendo el `SUM(received_quantity)` **anterior** a esta
recepción (que sí es correcto de leer, porque nada lo ha tocado desde la perspectiva de este
campo) y sumándole aritméticamente `SUM(quantities recibidas ahora)` calculado directamente
desde el array de entrada — igual que el recálculo de totales de `UpdatePurchaseOrderDraft`.

## Concurrencia

**Prioridad aplicada exactamente como pide la regla final de la fase:** transactional integrity
> inventory correctness > idempotency > authorization > auditability > financial consistency >
performance > convenience.

### Over-receiving bajo concurrencia (secciones 31/32)

Caso de la sección 31 verificado con paralelismo real (`Promise.all`, no secuencial): PO item
`ordered=10`, `alreadyReceived=7`; dos requests simultáneos piden `3` cada uno. **Nunca** ambas
tienen éxito (lo que daría `received=13`, superando lo ordenado): exactamente una gana, la otra
es rechazada silenciosamente por la compuerta agregada (mismo mecanismo de la sección anterior),
`received` termina en exactamente `10`. El mecanismo NO es `SELECT remaining; calcular en
cliente; UPDATE` — es la compuerta agregada evaluada dentro de la misma sentencia `UPDATE`, que
PostgreSQL serializa vía row-locking real sobre la fila de `purchase_order_item` contendida.

### Idempotencia + concurrencia (sección 33)

`PurchaseReceipt.idempotencyKey` es `UNIQUE` real de columna (igual que `InventoryMovement` en
Fase 4). Verificado con `Promise.all` de 3 llamadas **idénticas** (misma `idempotencyKey`, mismo
receipt): exactamente una tiene efecto lógico real (`receipt` no-null), las otras 2 son
rechazadas (violación de `UNIQUE` → `@transaction` revierte esa llamada completa, incluyendo
cualquier escritura parcial de inventario que hubiera alcanzado a aplicar en ese intento) — el
stock final refleja una sola aplicación, nunca 3.

### Recepción parcial atómica (sección 19)

Con un receipt de múltiples productos donde uno de ellos excede su remanente: verificado que
**ninguno** de los productos (ni siquiera los válidos) cambia — la compuerta agregada es una
condición ÚNICA aplicada uniformemente a todas las filas de todas las sentencias de la
recepción, así que un solo item inválido bloquea el conjunto entero. No existe un estado
intermedio donde algunos productos del receipt se hayan aplicado y otros no.

## Estado de producto/proveedor (secciones 36/37)

- **`Product.isPurchasable = false`**: bloquea agregar ese producto como item de una
  `PurchaseOrder` nueva (`UpdatePurchaseOrderDraft` lo valida en la misma compuerta agregada de
  validación de items). Las órdenes históricas que ya contenían ese producto siguen siendo
  consultables sin restricción — el campo no se re-valida en la recepción (recibir mercancía ya
  ordenada legítimamente debe funcionar aunque el producto se haya marcado no-comprable
  después).
- **`Supplier.status = INACTIVE`**: bloquea crear una `PurchaseOrder` nueva con ese proveedor
  (`CreatePurchaseOrder` lo valida). Las órdenes históricas de un proveedor ya desactivado
  siguen siendo consultables — nunca se borra un `Supplier` con historial. Se agregó
  `DeactivateSupplier` (reutilizando `suppliers.update`) ya que Fase 3 no lo había implementado
  todavía.

## Autorización

Permisos nuevos (sección 25): `purchases.submit`, `purchases.approve`, `purchases.cancel`,
`purchases.receive` (`purchases.read`/`create`/`update` ya existían desde Fase 2).
**Segregación de funciones preparada, no forzada** (sección 26): `purchases.approve` se otorgó
ÚNICAMENTE a `SUPER_ADMIN`/`ADMIN` — ni siquiera `MANAGER` (que sí tiene `purchases.create`/
`submit`/`receive`) puede aprobar sus propias órdenes. Esto NO es una política rígida de "4
ojos" (`ADMIN` sí podría crear y aprobar la misma orden si actuara en ambos roles), pero hace
posible que el negocio la adopte más adelante sin cambios de modelo. `approvedBy`/`approvedAt`
se registran siempre desde `auth.uid`/`request.time`, nunca aceptados como variables de cliente.

Ver `docs/authorization-matrix.md` para la matriz completa actualizada.

## Auditoría

Eventos generados: `PURCHASE_ORDER_CREATED`, `PURCHASE_ORDER_UPDATED`, `PURCHASE_ORDER_SUBMITTED`,
`PURCHASE_ORDER_APPROVED`, `PURCHASE_ORDER_CANCELLED`, `PURCHASE_RECEIPT_CREATED`,
`PURCHASE_RECEIPT_APPLIED` (ambos eventos de recepción se generan juntos, en la misma
mutation, ya que no existe un estado intermedio "creada pero no aplicada" — sección 23). Actor
siempre `auth.uid`.

## Trazabilidad (secciones 29/30)

```
InventoryMovement.referenceType = "PURCHASE_RECEIPT"
InventoryMovement.referenceId   = PurchaseReceipt.id
```

permite navegar `InventoryMovement → PurchaseReceipt → PurchaseOrder → Supplier` sin
ambigüedad, sin duplicar datos del proveedor/orden en el propio movimiento. Preguntas
respondibles con las queries de `docs/purchasing.md`/`purchasing/queries.gql`: cuánto se
ordenó/recibió/falta (`GetPurchaseOrderItems.orderedQuantity/receivedQuantity`), cuándo se
recibió y con qué costo (`GetPurchaseReceiptItems`), qué usuario la recibió
(`PurchaseReceipt.createdBy`), qué movimiento de inventario produjo (join por `referenceId`).

## Constraints de PostgreSQL verificados E2E (sección 40)

`PurchaseOrder.branchId→Branch`, `.supplierId→Supplier`; `PurchaseOrderItem.purchaseOrderId→
PurchaseOrder`, `.productId→Product`; `PurchaseReceipt.purchaseOrderId→PurchaseOrder`,
`.branchId→Branch`, `.supplierId→Supplier`; `PurchaseReceiptItem.purchaseReceiptId→
PurchaseReceipt`, `.purchaseOrderItemId→PurchaseOrderItem`, `.productId→Product` — todos FK
reales, huérfano rechazado. `PurchaseReceipt.idempotencyKey` `UNIQUE` real. `orderNumber` único
por sucursal vía `INSERT ... WHERE NOT EXISTS` atómico (ver arriba, no un `UNIQUE` de schema).

## No implementado a propósito (sección 42/43)

Pagos a proveedor, cuentas por pagar, facturas, conciliación bancaria, contabilidad — la
compra termina en `PurchaseReceipt → Inventory` en esta fase. Tampoco POS, carrito, ventas,
crédito de cliente — fases futuras.

## Limitaciones

- **Platform limitation**: aislamiento entre campos de una mutation (Fase 4, reconfirmado aquí
  con un caso nuevo: recálculo de totales/status debe usar aritmética de arrays, nunca `SUM(...)`
  contra la tabla que otro campo de la misma mutation acaba de escribir); `_execute` sin
  `RETURNING` rompe el protocolo al encadenarse con otro campo de escritura (nuevo hallazgo de
  esta fase, mitigado usando `_executeReturningFirst` con `RETURNING` en todo el archivo).
- **Business decision pending**: política de reversión para `PARTIALLY_RECEIVED` cancelado;
  corrección retroactiva de una recepción ya aplicada (sección 17: requeriría una operación de
  corrección explícita, no implementada todavía).
- **Future feature**: pagos/cuentas por pagar/facturas (explícitamente fuera de alcance).
- **Technical debt**: ninguna identificada como deuda real — las simplificaciones están
  documentadas como decisiones deliberadas.
