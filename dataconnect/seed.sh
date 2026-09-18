#!/usr/bin/env bash
# Ejecuta todas las mutations de seed (identity + catalog) en orden, en lotes pequenos.
#
# Por que en lotes: el emulador de SQL Connect (PGlite) compila cada "mutation" en UN solo
# statement SQL con una CTE encadenada por cada upsert. Con ~50+ upserts en una sola mutation
# el protocolo de PGlite falla con "unexpected message 'E'; expected ReadyForQuery" (limite
# real del emulador, no un error de datos) — por eso seed_identity_data.gql/
# seed_catalog_data.gql estan divididos en mutations de <=15 filas cada una. Ver
# docs/security.md y docs/catalog.md para el detalle.
#
# Uso:
#   export FIREBASE_DATA_CONNECT_EMULATOR_HOST=127.0.0.1:9399
#   ./dataconnect/seed.sh [--project demo-libreriasystem]

set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="${1:-demo-libreriasystem}"
[ "$PROJECT" = "--project" ] && PROJECT="${2:-demo-libreriasystem}"

IDENTITY_OPS=(
  SeedRole SeedPermission1 SeedPermission2 SeedPermission3 SeedPermission4
  SeedBranch SeedUserProfile SeedUserRole SeedUserBranch
  SeedRolePermission1 SeedRolePermission2 SeedRolePermission3 SeedRolePermission4
  SeedRolePermission5 SeedRolePermission6 SeedRolePermission7 SeedRolePermission8
  SeedRolePermission9 SeedRolePermission10 SeedRolePermission11 SeedRolePermission12
  SeedRolePermission13
)
CATALOG_OPS=(
  SeedProductType SeedUnitOfMeasure SeedUnitConversion SeedCurrency SeedTaxCategory
  SeedCategory SeedBrand SeedPublisher SeedAuthor SeedGenre SeedBookSeries
)

run() {
  local file="$1"; shift
  for op in "$@"; do
    echo "-> $op"
    firebase dataconnect:execute "$file" "$op" --project "$PROJECT" > /tmp/seed_step.json 2>&1
    if ! grep -q '"errors": \[\]' /tmp/seed_step.json; then
      echo "FALLO en $op (ver /tmp/seed_step.json):"
      tail -c 2000 /tmp/seed_step.json
      exit 1
    fi
  done
}

echo "=== Identity seed ==="
run dataconnect/seed_identity_data.gql "${IDENTITY_OPS[@]}"
echo "=== Catalog seed ==="
run dataconnect/seed_catalog_data.gql "${CATALOG_OPS[@]}"
echo "=== Inventory seed ==="
echo "(sin mutations: Inventory.createdBy/updatedBy exigen auth.uid real, ver seed_inventory_data.gql)"
echo "=== Purchasing seed ==="
echo "(sin mutations: PurchaseOrder/PurchaseReceipt.createdBy exigen auth.uid real, ver seed_purchasing_data.gql)"
echo "OK: seed completo (idempotente, se puede volver a correr)."
