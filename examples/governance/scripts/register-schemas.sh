#!/bin/bash
# Register schemas in Schema Registry for the governance demo.
#
# Usage: ./scripts/register-schemas.sh
#
# Registers:
#   orders-value       Order  (Avro)  -> used by the default ID-level route
#   events-value       Event  (Avro)  -> a *different* schema, used to demo
#                                          wrong-subject rejection at SCHEMA level
#   gov-id-value       Order          -> positive case for the ID-level topic
#   gov-schema-value   Order          -> positive case for the SCHEMA-level topic

set -euo pipefail

SR_URL="${SR_URL:-http://localhost:8081}"

ORDER_SCHEMA='{"type":"record","name":"Order","namespace":"io.confluent.demo","fields":[{"name":"order_id","type":"string"},{"name":"product","type":"string"},{"name":"quantity","type":"int"},{"name":"price","type":"double"}]}'
EVENT_SCHEMA='{"type":"record","name":"Event","namespace":"io.confluent.demo","fields":[{"name":"event_id","type":"string"},{"name":"kind","type":"string"}]}'

register() {
  local subject="$1" schema="$2"
  echo "==> Registering '${subject}'..."
  curl -s -X POST "${SR_URL}/subjects/${subject}/versions" \
    -H "Content-Type: application/vnd.schemaregistry.v1+json" \
    -d "{\"schemaType\":\"AVRO\",\"schema\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$schema")}" \
    | python3 -m json.tool
  echo ""
}

echo "==> Waiting for Schema Registry to be ready..."
until curl -s "${SR_URL}/subjects" > /dev/null 2>&1; do sleep 2; done
echo "    Schema Registry is ready."
echo ""

register "orders-value"     "$ORDER_SCHEMA"
register "events-value"     "$EVENT_SCHEMA"
register "gov-id-value"     "$ORDER_SCHEMA"
register "gov-schema-value" "$ORDER_SCHEMA"

echo "==> Registered subjects:"
curl -s "${SR_URL}/subjects" | python3 -m json.tool
echo ""
echo "Done."
