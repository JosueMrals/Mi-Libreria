# Desarrollo local

## Requisitos

- Firebase CLI instalado
- Accesso a Firebase cuando se conecte el proyecto real
- SQL Connect VS Code extension habilitada si se desea la experiencia guiada

## Comandos base

```bash
cd LibreriaSystem
firebase emulators:start --only dataconnect
# Con Authentication Emulator (necesario para probar @auth con usuarios reales):
firebase emulators:start --only auth,dataconnect --project demo-libreriasystem
```

Usar siempre un project id `demo-*` para desarrollo local: el propio Firebase CLI lo trata
como proyecto seguro para emulador (evita llamadas accidentales a servicios reales).

## Cargar datos de prueba

```bash
export FIREBASE_DATA_CONNECT_EMULATOR_HOST=127.0.0.1:9399
firebase dataconnect:execute dataconnect/seed_data.gql --project demo-libreriasystem
firebase dataconnect:execute dataconnect/seed_identity_data.gql --project demo-libreriasystem
firebase dataconnect:execute dataconnect/seed_catalog_data.gql --project demo-libreriasystem
```

`dataconnect:execute` corre en contexto admin (bypassa `@auth`), igual que el Admin SDK en
servidor — apropiado solo para seed/pruebas, nunca para operaciones de cliente reales.

**Cuidado con columnas `@default(expr: "auth.uid")` en datos sembrados:** ese default se
evalúa siempre, incluso si el insert intenta pasar un literal, y falla en contexto admin puro
(no hay ningún usuario impersonado). Por eso `seed_catalog_data.gql` **no** siembra `Product`/
`BookDetails`/`ProductPrice` (tienen `createdBy`/`updatedBy` con ese default): esas filas se
crean con las mutations reales (`CreateProduct`, etc.) impersonando un usuario, no por seed
directo. Ver `docs/catalog.md`.

## Flujo recomendado

1. Definir schema en `dataconnect/schema/` (solo definiciones de tipo — `query`/`mutation` van
   en un connector, no aquí; mezclarlos rompe la carga del schema).
2. Crear queries y mutations en el connector correspondiente (`dataconnect/example/`,
   `dataconnect/identity/`, `dataconnect/catalog/`, o uno nuevo) y declararlo en
   `dataconnect/dataconnect.yaml` → `connectorDirs`.
3. Probar con el emulador local: `firebase emulators:start --only dataconnect` debe arrancar
   sin errores en `dataconnect-debug.log` (`Connector "<nombre>" has errors: ...` indica un
   problema de sintaxis GraphQL/CEL a corregir antes de seguir). Gotchas ya encontrados y
   documentados: nombres de campo plural cuando el tipo ya termina en "s" (`BookSeries` →
   `bookSeriess`, no `bookSeries`; ver `docs/database.md`), y variables opcionales omitidas en
   `@check`/`@auth(expr:...)` (usar `!has(vars.x) || vars.x == null || ...`, nunca solo
   `vars.x == null` — ver `docs/security.md`).
4. Para validar `@auth`/`@check` con usuarios reales, usar el Auth Emulator + impersonación
   (`impersonate: { authClaims: { sub, email } }` con el Admin SDK, o un ID token real firmado
   por el Auth Emulator) — ver `docs/security.md#pruebas-ejecutadas` para el patrón usado en
   la Fase 2.
5. Generar SDK y validar tipos.
6. Preparar el deployment con `firebase deploy --only dataconnect` solo cuando esté autorizado.

## Restricciones

- No se ejecutará `git init`, `git add`, `git commit`, `git push` ni ninguna otra acción Git.
- No se crean aplicaciones móviles ni desktop en esta fase.
