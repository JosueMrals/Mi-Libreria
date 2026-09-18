# Catálogo Maestro de Productos (Fase 3 + Fase 3.1 — Data Integrity Hardening)

## Principio central

`Product` es la entidad comercial universal (sección 2 del prompt). Un libro y un mouse son
ambos `Product`; un libro además cuelga `BookDetails` con la metadata bibliográfica. El resto
de productos (escolares, oficina, informática, decoración, regalos, arte, manualidades,
juguetes...) solo usan los atributos generales de `Product` + su `ProductType`.

```
Product
name = "Harry Potter y la Piedra Filosofal"   productType = BOOK   → tiene BookDetails
Product
name = "Mouse Logitech M185"                  productType = COMPUTER
Product
name = "Cuaderno Norma"                       productType = SCHOOL
```

## Separación de responsabilidades

Esta fase responde **"¿qué es este producto?"**. No implementa:

- **Inventario** ("¿cuántas unidades tengo?") — Fase 4.
- **Ventas** ("¿cuánto vendí?") — Fase 5.
- **Compras** ("¿a quién se lo compré?") — Fase 6 (`SupplierProduct` solo prepara el terreno).
- **Caja** ("¿cómo fue pagado?") — Fase 5.

## Product

Campos y decisiones NOT NULL (sección 4):

| Campo | Nullable | Razón |
|---|---|---|
| `sku` | NO, `@unique` | Identificador comercial interno; toda operación de negocio lo necesita desde el día uno. |
| `name` | NO | Un producto sin nombre no es utilizable. |
| `productType` | NO | Núcleo del principio "Product = entidad universal" (sección 2): sin tipo, no se sabe qué es. |
| `category` | **SÍ** | Un producto puede darse de alta antes de terminar de clasificarlo comercialmente (flujo de importación de libros, sección 37). |
| `brand` | **SÍ** (sección 10) | No todos los productos tienen marca. |
| `unitOfMeasure` | NO | Necesaria para cualquier cálculo futuro de inventario/venta. |
| `taxCategory` | **SÍ** | Modelo de impuestos completo fuera de esta fase (ver más abajo). |
| `status` | NO | `ACTIVE` \| `INACTIVE` \| `DISCONTINUED`. Nunca eliminación física (sección 45). |
| `createdBy`/`updatedBy` | **SÍ** | Ver "Decisión: createdBy/updatedBy nullable" más abajo. |

### SKU vs ProductIdentifier

`Product.sku` es la columna directa, autoritativa y de lookup rápido (una sola por producto).
`ProductIdentifier` es la tabla de identificadores auxiliares de cardinalidad variable (EAN,
UPC, ISBN10/13, GTIN, códigos de proveedor/internos — sección 13/15): un producto puede tener
cero, uno o varios. No se depende de ISBN como identificador primario en ningún caso (sección
13/14): un producto sin ISBN funciona exactamente igual.

### `TaxCategory`: entidad agregada, no pedida explícitamente

El prompt (sección 4) pide un campo `taxCategoryId` en `Product` pero no describe la entidad
`TaxCategory`. Se creó una versión mínima (`code`, `name`, `ratePercent`, `status`) para que el
FK tenga un destino real; el modelo de impuestos completo (reglas por región, exenciones
compuestas, etc.) queda fuera de esta fase. Es nullable a propósito.

### Decisión: `createdBy`/`updatedBy` nullable

Firebase Data Connect evalúa `@default(expr: "auth.uid")` **siempre**, incluso si el cliente
intenta pasar un literal explícito para ese campo, y falla si no hay un usuario impersonado
(por ejemplo, al sembrar datos vía `firebase dataconnect:execute`, que corre en contexto admin
puro sin `auth.uid`). Declarar estos campos `NOT NULL` habría hecho imposible sembrar o migrar
datos históricos/importados sin actor conocido. Se dejaron `String` nullable con
`@default(expr: "auth.uid")`: se completan automáticamente en cualquier mutation real (nunca
aceptan un valor de cliente, sección 46), y quedan `null` únicamente para datos de sistema/
importación masiva fuera del flujo normal de mutations.

## ProductType

Catálogo abierto (`code` único): `BOOK`, `SCHOOL`, `OFFICE`, `COMPUTER`, `TECH_ACCESSORY`,
`DECORATION`, `GIFT`, `ART`, `CRAFT`, `TOY`, `OTHER`. Se puede extender sin migrar código —
solo se inserta una fila nueva. **No usar permisos `productTypes.*`**: es catálogo de
referencia sin dato sensible, igual que `Role`/`Permission` en Fase 2 (`ListProductTypes` solo
exige sesión `ACTIVE`).

## Category vs ProductType

No son lo mismo (sección 9): `ProductType` es la naturaleza técnica del producto (¿qué clase de
cosa es?); `Category` es la clasificación comercial jerárquica (¿dónde vive en el catálogo de
la tienda?). Un Mouse Logitech es `ProductType = COMPUTER`, `Category = Informática →
Periféricos → Mouse`.

### Jerarquía y prevención de ciclos

`Category.parent` es una auto-relación nullable. Prevención de ciclos (sección 8):

1. **Auto-referencia** (`A → A`): se rechaza comparando `parentId` contra el propio id, sin
   consulta a la base (`CreateCategory`/`UpdateCategory`).
2. **Ciclo con ancestros** (`A → B → C → A`): `UpdateCategory` consulta hasta 3 niveles de
   ancestros del nuevo padre propuesto (`parent.parent.parent`) y rechaza el cambio si la
   categoría que se mueve aparece entre ellos.

**Límite documentado (`ponytail`):** la detección de ciclos está acotada a 3 niveles de
ancestros, no es una detección de grafo arbitraria — CEL no soporta recursión. Una jerarquía
que intente cerrar un ciclo más allá de ese rango no sería detectada por este mecanismo. Si se
necesita una garantía sin límite de profundidad, la vía correcta es un CTE recursivo de
PostgreSQL ejecutado en una capa de validación adicional (p. ej. una Cloud Function delante de
la mutation), o ampliar manualmente los niveles siguiendo el mismo patrón si la jerarquía real
lo justifica.

### Profundidad de categorías (hallazgo de Fase 3.1)

Fase 3.1 pidió verificar "profundidad máxima 3 niveles permitida, 4to nivel rechazado". Al
investigar, lo que existe en `CreateCategory`/`UpdateCategory` **no es eso**: es prevención de
CICLOS al reparentar (`UpdateCategory`, mirando hasta 3 generaciones de ancestros hacia atrás),
no un contador de profundidad al crear. `CreateCategory` no cuenta niveles en absoluto — una
cadena lineal `L1 → L2 → L3 → L4 → ...` sin ciclo se acepta hoy sin límite, verificado con
prueba E2E (`run_catalog_tests.js`, "Category depth: nivel 4"). Se documenta esta diferencia en
vez de: (a) ocultarla, o (b) inventar un cap nuevo de "máximo 3 niveles" no solicitado
explícitamente como cambio de negocio — ese es un límite de UX/negocio distinto de integridad
referencial, y agregarlo sin confirmación de producto sería alcance no pedido. Si el negocio
confirma que sí quiere un tope duro de profundidad, se implementa contando ancestros igual que
la detección de ciclo (mismo patrón, un nivel más de anidamiento en el `@check`).

## Brand

Opcional en `Product` (sección 10). `code` es único **cuando existe** (nullable + `@unique`:
Postgres permite múltiples `NULL` bajo una restricción `UNIQUE`, así que las marcas sin código
formal no chocan entre sí).

## UnitOfMeasure / UnitConversion

Catálogo abierto igual que `ProductType`. `UnitConversion` (sección 12) solo almacena el factor
(`BOX → UNIT, factor 12`); no hay lógica de conversión de inventario todavía — eso es Fase 4.
Sin permisos propios (catálogo de referencia).

## ProductIdentifier

`type` (`SKU`\|`EAN`\|`UPC`\|`ISBN10`\|`ISBN13`\|`GTIN`\|`SUPPLIER_CODE`\|`INTERNAL_CODE`) +
`value`, con `@table(key: ["type","value"])`: un mismo código no puede registrarse dos veces
para tipos que deban ser globalmente únicos (sección 39). Gatea igual que el propio producto
(`products.update`): no tiene permiso propio en la sección 47.

## Variantes (`ProductOption`/`ProductOptionValue`/`ProductVariant`)

Modelo mínimo de e-commerce (sección 27, explícitamente pedido "no excesivamente complejo"):
`ProductOption` ("Color"), `ProductOptionValue` ("Rojo"), `ProductVariant` (pertenece a un
`Product` real — FK, sin variantes huérfanas, sección 55), y `ProductVariantOptionValue` como
tabla puente para representar "esta variante = Color:Rojo + Talla:M". Sin inventario/precio por
variante todavía (sección 26); eso se conecta en fases posteriores reutilizando `ProductPrice`/
`Inventory` con `productVariantId` cuando corresponda.

**Fase 3.1 (sección 24):** `ProductOption`/`ProductOptionValue` tenían schema pero ninguna
mutation para crearlos, así que no se podía verificar la regla "sin duplicados dentro de una
Option" end-to-end. Se agregaron `CreateProductOption`/`CreateProductOptionValue` (permiso
`products.update`, mismo patrón que el resto del catálogo) exclusivamente para poder ejercer y
confirmar la protección — la key compuesta `@table(key: ["productOption","value"])` ya existente
rechaza un `(option, value)` repetido a nivel de PostgreSQL, no de lógica de aplicación.
Verificado con prueba E2E ("Duplicate ProductOptionValue... -> DENY").

## Pricing (`ProductPrice`) — permisos separados de `products.*`

`ProductPrice` es una tabla independiente (sección 30), nunca campos sueltos en `Product`.
**Separación deliberada de permisos (sección 31):** `products.update` NO otorga capacidad de
tocar precios/costos. `CreateProductPrice`/`UpdateProductPrice` exigen `prices.update`
exclusivamente. Un `MANAGER` puede editar el nombre/categoría de un producto sin poder
cambiarle el precio; solo `ADMIN`/`SUPER_ADMIN` tienen `prices.update` en la matriz inicial
(ver `docs/authorization-matrix.md`). Verificado con prueba E2E.

`priceType`: `COST` \| `RETAIL` \| `WHOLESALE` \| `PROMOTIONAL`, con whitelist explícita en el
`@check` de `CreateProductPrice` (`vars.priceType in ['COST','RETAIL','WHOLESALE',
'PROMOTIONAL']`, Fase 3.1) — un valor arbitrario ("HACKED") es rechazado antes de tocar la base.
`Currency` es una entidad propia (sección 32) — sin conversión automática entre monedas todavía.

**Dinero como `NUMERIC`, no `float` (Fase 1, sección 17 — reconfirmado en Fase 3.1):** Data
Connect no expone un escalar `Decimal`/`Numeric` en su GraphQL (solo
`String`/`Int`/`Float`/`Boolean`/`UUID`/`Int64`/`Date`/`Timestamp`/`Vector`/`Any`).
`ProductPrice.amount` y `SupplierProduct.purchasePrice` declaran `Float` en el schema GraphQL
pero fuerzan `@col(dataType: "numeric(12,2)")`: la columna real en PostgreSQL es `NUMERIC`,
exacta, evitando el error de redondeo binario en el almacenamiento aun cuando el transporte
GraphQL sea `Float`. Fase 3.1 reconfirmó que este es el único mecanismo disponible en la versión
actual del emulador/SDK — no apareció ningún escalar Decimal nuevo que lo reemplace.

**Validación de entrada de dinero (Fase 3.1, secciones 5/6/7):** `CreateProductPrice`/
`UpdateProductPrice` rechazan en el `@check` (antes de tocar Postgres):
- `amount < 0` (negativo).
- `amount > 999999.99` (tope de negocio — ver "Hallazgo de plataforma: overflow numérico" más
  abajo para por qué este tope es deliberadamente mucho menor que la capacidad cruda de la
  columna).
- `priceType` fuera de la whitelist.

CEL no puede rechazar `NaN`/`Infinity` con una comparación directa (`NaN >= 0` es `false` en
IEEE754, así que en la práctica ya cae en el rechazo por rango), y GraphQL en sí no acepta
literales `NaN`/`Infinity` en un campo `Float` de la request — quedan cubiertos por la
combinación de ambas capas, no por una regla explícita "es NaN".

**Redondeo/escala:** `numeric(12,2)` fuerza escala 2 a nivel de columna (PostgreSQL trunca/
redondea automáticamente cualquier valor con más de 2 decimales al insertar). Política: el
cliente debe enviar montos ya redondeados a 2 decimales; el servidor no re-redondea ni avisa si
llega con más precisión — es responsabilidad del cliente/SDK, igual que la normalización de
ISBN.

**COST vs RETAIL/WHOLESALE/PROMOTIONAL siguen siendo el mismo permiso (`prices.update`):** Fase
3.1 evaluó separar un permiso `prices.cost.update` distinto de `prices.update` para que un
`MANAGER` pudiera tocar precios de venta sin ver/editar costos. **No se implementó**: no hay
pedido de negocio explícito para esa separación todavía, y añadirla ahora sería una
abstracción especulativa (una tabla `RolePermission` adicional, una migración de permisos, y un
`@check` más complejo) sin un caso de uso real que la justifique hoy. Se documenta como
decisión consciente, no como omisión: si el negocio pide "un vendedor no debe ver el costo de
compra", ese es el momento de partir el permiso.

## ProductImage

`type`: `COVER` \| `PRODUCT` \| `THUMBNAIL` \| `OTHER`. Nunca se guardan binarios en
PostgreSQL (sección 34): solo `url`/`storagePath` (Firebase Storage/Cloud Storage se conectará
en una fase posterior; no hay UI de upload todavía). Para portadas externas de libros
(sección 59) se documenta `source`/`sourceUrl` en la misma tabla — una portada es, en este
modelo, simplemente una `ProductImage` con `type = COVER` y procedencia registrada; no
amerita una entidad separada.

**`isPrimary` (Fase 3.1, sección 26): mismo patrón que `ProductIdentifier.isPrimary`, no
mutuamente excluyente.** Se agregó `CreateProductImage` (permiso `products.update`) para poder
verificar el comportamiento con FK real (huérfanos rechazados, verificado con prueba E2E). Se
revisó explícitamente si debía forzarse "a lo sumo una imagen primaria por producto" y **se
decidió no implementarlo todavía**: el schema no tiene un índice `UNIQUE` parcial
(`WHERE isPrimary`) que lo garantice, y agregarlo ahora requeriría esa migración más lógica de
"desmarcar la anterior" en la mutation — trabajo real pero no solicitado explícitamente como
regla de negocio confirmada. Hoy, crear dos `ProductImage` con `isPrimary = true` para el mismo
producto se acepta; el consumidor (UI) debe decidir cuál mostrar (p. ej. la más reciente por
`displayOrder`) hasta que se confirme la regla y se implemente el índice parcial.

## BookDetails y su universo bibliográfico

`BookDetails` cuelga 1:1 de `Product` (la propia relación `product` es la primary key de la
tabla, no un `id` independiente, así que no puede haber huérfanos ni duplicados por producto).

**Restringido a `productType = BOOK` (Fase 3.1, sección 18):** hasta Fase 3.1, el schema no
forzaba esto — cualquier `Product` (un mouse, un cuaderno) podía recibir `BookDetails` sin que
nada lo impidiera, porque es una regla de negocio, no una integridad referencial de FK.
`CreateBookDetails` ahora resuelve el `Product` objetivo en el `query @redact` y exige
`this[0].productType.code == 'BOOK'` en el `@check`; verificado con prueba E2E ("CreateBookDetails
sobre Product no-BOOK (P2, mouse) -> DENY").

### Título ≠ Edición ≠ Producto físico (sección 25)

**No se creó una entidad `Edition` separada.** En este modelo, cada `Product` + `BookDetails`
representa ya una edición/publicación concreta — un ISBN distinto es, por definición, otro
`Product` con su propio `BookDetails`. "El mismo libro" en otra edición (otro año, otra
editorial, otro formato) es simplemente otro `Product`, opcionalmente conectado al mismo
`BookSeries`/mismo conjunto de `Author` vía `BookAuthor`. Esto evita duplicar información
(sección 25 pide explícitamente no hacerlo) sin añadir una capa conceptual que el negocio no
pidió.

### ISBN: formato (CEL) + checksum matemático real (Native SQL) — endurecido en Fase 3.1

`isbn10`/`isbn13` se validan en dos capas dentro de `CreateBookDetails`:

1. **Formato** vía regex CEL en el `@check` (`^[0-9]{9}[0-9X]$` / `^[0-9]{13}$}`) — rechaza
   longitud y caracteres inválidos antes de llegar a la base.
2. **Checksum matemático real** (Fase 3.1, secciones 3/4 — explícitamente pedido "no solo
   regex"): mod-11 con soporte de dígito final `X` para ISBN-10, mod-10 con pesos 1/3 para
   ISBN-13. CEL no tiene funciones de extracción de caracteres individuales de un string (sin
   `substring`/índice), así que el checksum se calcula en **Native SQL** (`_executeReturningFirst`,
   soportado oficialmente por Data Connect) dentro de la misma mutation, usando
   `generate_series`/`substring(... from i for 1)` sobre el valor ya normalizado.

Ambos son `@unique` a nivel de columna (nullable: múltiples libros sin ISBN no chocan, pero dos
libros no pueden compartir el mismo ISBN13 — sección 54).

**Diseño del rechazo por checksum inválido:** si el checksum no cuadra, el `INSERT` (filtrado
por una condición booleana en su propio `WHERE`) no produce ninguna fila — la mutation devuelve
`bookDetails: null` sin lanzar excepción. El cliente debe tratar un resultado `null` como "ISBN
rechazado por checksum". Ver "Hallazgos de plataforma" más abajo para el porqué de este diseño
específico (no es la primera forma que se intentó).

**Normalización:** el servidor exige el valor ya normalizado (solo dígitos, sin guiones/
espacios) — quitar los separadores de entrada del usuario (`978-84-123456-7-8` →
`9788412345678`, sección 41) sigue siendo responsabilidad del cliente/SDK antes de enviar la
mutation, no del servidor. Esta es la única fuente de verdad para comparación/almacenamiento/
búsqueda: `GetProductByISBN` y el `@unique` de columna operan siempre sobre el valor
normalizado, nunca sobre una variante con guiones.

### Hallazgos de plataforma (Fase 3.1)

Implementar el checksum real vía Native SQL expuso cuatro límites del emulador local
(`dataconnect-emulator` + PGlite) no documentados previamente en este proyecto. Se registran
aquí porque afectan cómo se debe escribir Native SQL en mutations futuras, no solo esta:

1. **Renumeración textual de `$N`:** Data Connect renumera cada aparición TEXTUAL de `$N` en el
   string SQL secuencialmente, sin deduplicar referencias repetidas a la misma variable GraphQL.
   Si el SQL usa `$9` dos veces, hay que repetir la variable correspondiente dos veces en
   `params:`, en el mismo orden en que aparecen los tokens `$N` en el texto — no basta con
   pasarla una vez.
2. **Límite de encadenado de CTEs por mutation:** una sola `mutation` con ~250+ `_upsert`
   encadenados en un solo statement SQL (una CTE por upsert) rompe el protocolo del emulador
   (`"unexpected message 'E'; expected ReadyForQuery"`). Es un límite real del emulador local,
   no un error de datos. Mitigación: dividir en mutations de ≤15-20 filas cada una (ver
   `seed_identity_data.gql`/`seed_catalog_data.gql`/`seed.sh` más abajo).
3. **`CASE` con cast de tipos mixtos rompe el emulador:** cualquier intento de forzar un error
   en tiempo de ejecución vía `CASE WHEN ... THEN $x ELSE ('X' || $y)::int::text END` (incluso
   con literales constantes) deja la conexión de PGlite en un estado inválido para el resto del
   proceso. Mitigación adoptada: nunca usar ese patrón; poner la condición booleana directamente
   en el `WHERE` del `INSERT` y dejar que produzca 0 filas en vez de lanzar una excepción.
4. **`WITH` anidado dentro de otro `WITH` rompe el emulador:** Data Connect envuelve cada
   `_executeReturningFirst` en su propio `WITH "cte_0" AS (...)`; si el SQL del usuario ya
   empieza con `WITH ... SELECT ...`, el resultado es un `WITH` dentro de otro `WITH`, que
   también rompe el protocolo. Por esto `CreateBookDetails` NO encadena el `INSERT` de
   `book_details` con el `INSERT` de `audit_log` en un solo statement nativo — usa dos campos
   GraphQL separados (`bookDetails: _executeReturningFirst(...)` + `auditLog_insert(...)`
   estándar). **Limitación conocida y aceptada:** como consecuencia, si el checksum es
   inválido, el `AuditLog` "BOOK_METADATA_UPDATED" se registra igual aunque no se haya creado
   ningún `BookDetails`. No es un hueco de seguridad (el actor sigue siendo `auth.uid`, la
   acción describe la intención real de la llamada), pero es una imprecisión de auditoría
   conocida — ver también `docs/security.md`.
5. **Overflow numérico durante el bind de parámetros, antes del `@check`:** enviar un `amount`
   que excede la capacidad cruda de `numeric(12,2)` (`9999999999.99`, 10 dígitos enteros) hace
   que PostgreSQL lance un error de overflow AL RECIBIR el parámetro, antes de que el `@check`
   de CEL tenga oportunidad de rechazarlo por regla de negocio — y ese error crudo de Postgres
   deja al emulador en el mismo estado degradado que los hallazgos 3/4. Mitigación: el tope de
   negocio en el `@check` (`999999.99`) se fijó deliberadamente muy por debajo de la capacidad
   cruda de la columna, para que cualquier valor que falle la regla de negocio nunca llegue a
   tocar el límite real de Postgres.

### Author / BookAuthor

`Author` es una entidad propia (sección 19): nunca se guarda `author = "J.K. Rowling"` como
string suelto. `BookAuthor` (`bookDetails`, `author`, `authorRole`) permite múltiples autores
por libro y múltiples libros por autor, con `authorRole`
(`AUTHOR`\|`TRANSLATOR`\|`EDITOR`\|`ILLUSTRATOR`\|`COMPILER`\|`INTRODUCTION`\|`OTHER`) y
`displayOrder`.

### Publisher / BookPublisher

Igual patrón: `Publisher` es una entidad real, `BookPublisher` permite una o varias relaciones
editoriales por libro (`isPrimary` marca la principal).

### BookSeries y Genre

`BookSeries` + `BookDetails.volumeNumber` representan colecciones ("Harry Potter", volumen 1,
2, 3...). `Genre` + `BookGenre` son clasificación **bibliográfica**, independiente de
`Category` (clasificación **comercial** — sección 24): un mismo libro puede vivir en
`Category = Libros → Literatura → Fantasía` y tener `Genre = Fantasy`, y son conceptos que
pueden divergir sin que uno dependa del otro.

## Supplier / SupplierProduct

`Supplier` (entidad comercial) es explícitamente distinto de `Publisher` (información
bibliográfica, sección 28): una editorial no es un proveedor. `SupplierProduct` conecta ambos
mundos preparando Compras (Fase 6) sin implementarla — solo almacena `supplierSku`,
`supplierBarcode`, `purchasePrice`, `minimumOrderQuantity`, `leadTimeDays`, `isPreferred`.

## Metadata externa (secciones 35–38, 56–59)

No se implementó integración con un proveedor externo real (OpenLibrary/Google Books) en esta
fase — el prompt lo permite explícitamente ("no implementar integración externa completa
todavía salvo que sea necesaria para validar la arquitectura", sección 56), y no era necesaria
para validar el modelo de datos. Se preparó, en su lugar:

- **`metadataSource`/`metadataSourceId`/`metadataFetchedAt`** en `BookDetails` (sección 57):
  permiten saber de dónde vino un dato sin implementar todavía la sincronización.
- **Regla de "no sobrescribir cambios manuales" (sección 58):** documentada, no implementada.
  El modelo actual no distingue automáticamente "este campo lo editó un humano" de "esto vino
  de una sincronización externa" — cuando se implemente el proveedor real, la estrategia
  recomendada es agregar una columna `manualOverride: Boolean` por campo sensible (o una tabla
  de override generica) y que la sincronización externa consulte ese flag antes de sobrescribir.
- **Abstracción `BookMetadataProvider` (sección 56):** no se creó como código (no hay ningún
  proveedor real conectado todavía, así que una interfaz sin implementaciones sería
  abstracción especulativa — YAGNI). Cuando se conecte el primer proveedor real, la interfaz
  debe extraerse de esa implementación concreta, no diseñarse en el vacío antes.
- **Derechos de imagen (sección 59):** documentado como advertencia en el comentario de
  `ProductImage`; no hay lógica de licencias implementada (fuera de alcance de esta fase).

## Autorización (reutiliza el modelo de Fase 2 sin cambios estructurales)

Mismo patrón exacto que `dataconnect/identity/`: cada operación administrativa resuelve el
`UserProfile` del llamador por `auth.uid`, exige `status == 'ACTIVE'` y el permiso concreto vía
`@check` sobre `roles_via_UserRole.exists(r, r.permissions_via_RolePermission.exists(...))`.
Nunca se confía en `userId`/`role`/`permissions` enviados por el cliente (sección 46).

**Permisos nuevos** (sección 47, ver `docs/authorization-matrix.md` para la matriz completa):
`categories.*`, `brands.*`, `authors.{read,create,update}`, `publishers.{read,create,update}`,
`prices.{read,update}`, `book_metadata.{read,create,update}`. `products.*` y `suppliers.*` **se
reutilizan tal cual de Fase 2** (ya existían como placeholders para esta fase).

## Branch scope

`Product` es **GLOBAL** (sección 48): no se duplica por sucursal. Ninguna tabla de esta fase
tiene `branchId`. El inventario (Fase 4) será el que sea específico por sucursal.

## Paginación

Toda query de listado/búsqueda tiene `limit` con default y un tope máximo de 200, forzado por
`@check` (`vars.limit <= 200`, con `has()` para tolerar que el cliente omita la variable y use
el default del schema — ver "Lección de plataforma" en `docs/security.md`). No existe ninguna
query que devuelva el catálogo completo sin límite (sección 43).

## Seeds idempotentes (Fase 3.1, secciones 1/2)

`seed_identity_data.gql` y `seed_catalog_data.gql` originalmente usaban `_insertMany`, sin
semántica de upsert: volver a correr el seed contra una base ya poblada lanzaba
`violates SQL unique constraint` y abortaba toda la transacción en cascada. Esto era la causa
raíz real de que Fase 2 reportara 14/15 en una corrida — no una regresión de seguridad ni una
prueba incorrecta en su lógica, sino un fixture de prueba (`TEST_FIREBASE_UID_NEWUSER` fijo)
que colisionaba con estado de una corrida anterior; se corrigió sufijando el UID/email con un
`RUN_ID` aleatorio por corrida en el script de pruebas.

El seed en sí se reescribió para ser realmente idempotente: cada fila pasó de
`{...}` dentro de un `_insertMany` a `aliasN: tabla_upsert(data: {...})` individual (`_upsert`
usa `ON CONFLICT (key) DO UPDATE SET`). Además, una sola `mutation` con más de ~20 upserts
encadenados rompe el emulador (ver hallazgo de plataforma #2 arriba), así que ambos archivos se
dividieron en mutations nombradas de ≤15 filas cada una, ejecutadas en orden por
`dataconnect/seed.sh` (nuevo script, ver su cabecera para el detalle). Verificado corriendo
`seed.sh` dos veces seguidas contra la misma base: cero errores en ambas corridas.

## Resultado de pruebas (Fase 3.1, checkpoint)

```
Fase 2:            15/15
Fase 2.1:           41/41
Catálogo (F3+F3.1): 63/63
TOTAL:             119/119
```

## Mutations que NO existen a propósito

- `DeactivateAuthor`/`DeactivatePublisher`: la sección 44 solo pide `Create`/`Update` para
  `Author`/`Publisher`. No se inventó una baja lógica no solicitada.
- Endpoint de actualización de `Category.name`/renombrado: `UpdateCategory` no permite cambiar
  el nombre del `code` (clave lógica); solo `name`/`description`/`parent`.
- No hay `UpdateAnything`/`DeleteAnything` genéricos (sección 44): cada mutation es explícita y
  nombrada, con su propio permiso.
