#!/bin/bash
# Register schemas in Schema Registry for the governance demo.
#
# Usage: ./scripts/register-schemas.sh

set -euo pipefail

SR_URL="${SR_URL:-http://localhost:8081}"

echo "==> Waiting for Schema Registry to be ready..."
until curl -s "${SR_URL}/subjects" > /dev/null 2>&1; do
  sleep 2
done
echo "    Schema Registry is ready."

echo ""
echo "==> Registering 'orders-value' schema (Avro)..."
curl -s -X POST "${SR_URL}/subjects/orders-value/versions" \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d '{
    "schemaType": "AVRO",
    "schema": "{\"type\":\"record\",\"name\":\"Order\",\"namespace\":\"io.confluent.demo\",\"fields\":[{\"name\":\"order_id\",\"type\":\"string\"},{\"name\":\"product\",\"type\":\"string\"},{\"name\":\"quantity\",\"type\":\"int\"},{\"name\":\"price\",\"type\":\"double\"}]}"
  }' | python3 -m json.tool
echo ""

echo "==> Listing registered subjects:"
curl -s "${SR_URL}/subjects" | python3 -m json.tool
echo ""
echo "Done. Schema registered successfully."
