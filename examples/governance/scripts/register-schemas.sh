#!/bin/bash
# Register schemas in Schema Registry for the governance demo.
#
# Usage: ./scripts/register-schemas.sh
#
# Registers:
#   orders-value       Order  (Avro)  -> used by the default ID-level route
#   events-value       Event  (Avro)  -> a *different* schema, used to demo
#                                          wrong-subject rejection at SCHEMA level
#   gov-id-value              Order        -> positive case for the ID-level topic
#   gov-schema-value          Order        -> positive case for the SCHEMA-level topic
#   gov-encrypt-field-value   Payment      -> SCHEMA_RULES: field-level encryption (PII tag)
#   gov-encrypt-payload-value Transaction  -> SCHEMA_RULES: full-payload encryption

set -euo pipefail

SR_URL="${SR_URL:-http://localhost:8081}"

ORDER_SCHEMA='{"type":"record","name":"Order","namespace":"io.confluent.demo","fields":[{"name":"order_id","type":"string"},{"name":"product","type":"string"},{"name":"quantity","type":"int"},{"name":"price","type":"double"}]}'
EVENT_SCHEMA='{"type":"record","name":"Event","namespace":"io.confluent.demo","fields":[{"name":"event_id","type":"string"},{"name":"kind","type":"string"}]}'
# Payment: the card_number field is tagged PII so the encryption rule targets only that field.
PAYMENT_SCHEMA='{"type":"record","name":"Payment","namespace":"io.confluent.demo","fields":[{"name":"payment_id","type":"string"},{"name":"card_number","type":"string","confluent:tags":["PII"]},{"name":"amount","type":"double"}]}'
# Transaction: no tags — full-payload encryption encrypts the whole record, not individual fields.
TRANSACTION_SCHEMA='{"type":"record","name":"Transaction","namespace":"io.confluent.demo","fields":[{"name":"txn_id","type":"string"},{"name":"account","type":"string"},{"name":"amount","type":"double"}]}'

# Encryption KMS params for the field-encryption rule (local KMS for the demo; no cloud KMS needed).
ENCRYPT_PARAMS='"encrypt.kek.name":"demo-kek","encrypt.kms.type":"local-kms","encrypt.kms.key.id":"demo-key"'
# Full-payload encryption uses its own KEK so the two scenarios stay independent.
ENCRYPT_PAYLOAD_PARAMS='"encrypt.kek.name":"demo-kek-payload","encrypt.kms.type":"local-kms","encrypt.kms.key.id":"demo-key"'

register() {
  local subject="$1" schema="$2"
  echo "==> Registering '${subject}'..."
  curl -s -X POST "${SR_URL}/subjects/${subject}/versions" \
    -H "Content-Type: application/vnd.schemaregistry.v1+json" \
    -d "{\"schemaType\":\"AVRO\",\"schema\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$schema")}" \
    | python3 -m json.tool
  echo ""
}

# Register a schema together with a field-level encryption ruleSet.
# The ENCRYPT rule targets fields carrying the given tag (e.g. PII).
#   $1 subject  $2 schema  $3 rule name  $4 tag (e.g. PII)
register_field_encrypted() {
  local subject="$1" schema="$2" rule="$3" tag="$4"
  echo "==> Registering '${subject}' with field-encryption rule (tag: ${tag})..."
  local schema_json; schema_json=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$schema")
  curl -s -X POST "${SR_URL}/subjects/${subject}/versions" \
    -H "Content-Type: application/vnd.schemaregistry.v1+json" \
    -d "{
      \"schemaType\":\"AVRO\",
      \"schema\":${schema_json},
      \"ruleSet\":{\"domainRules\":[{
        \"name\":\"${rule}\",\"kind\":\"TRANSFORM\",\"type\":\"ENCRYPT\",\"mode\":\"WRITEREAD\",
        \"tags\":[\"${tag}\"],
        \"params\":{${ENCRYPT_PARAMS}}
      }]}
    }" | python3 -m json.tool
  echo ""
}

# Register a schema together with a full-payload encryption ruleSet.
# The ENCRYPT_PAYLOAD rule is an *encoding* rule: it encrypts the whole serialized
# record (every field), so no field tags are needed.
#   $1 subject  $2 schema  $3 rule name
register_payload_encrypted() {
  local subject="$1" schema="$2" rule="$3"
  echo "==> Registering '${subject}' with full-payload encryption rule..."
  local schema_json; schema_json=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$schema")
  curl -s -X POST "${SR_URL}/subjects/${subject}/versions" \
    -H "Content-Type: application/vnd.schemaregistry.v1+json" \
    -d "{
      \"schemaType\":\"AVRO\",
      \"schema\":${schema_json},
      \"ruleSet\":{\"encodingRules\":[{
        \"name\":\"${rule}\",\"kind\":\"TRANSFORM\",\"type\":\"ENCRYPT_PAYLOAD\",\"mode\":\"WRITEREAD\",
        \"params\":{${ENCRYPT_PAYLOAD_PARAMS}}
      }]}
    }" | python3 -m json.tool
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

# Field-level encryption: only the PII-tagged field (card_number) is encrypted.
register_field_encrypted "gov-encrypt-field-value" "$PAYMENT_SCHEMA" "encryptPII" "PII"

# Full-payload encryption: the entire Transaction record is encrypted.
register_payload_encrypted "gov-encrypt-payload-value" "$TRANSACTION_SCHEMA" "encryptPayload"

echo "==> Registered subjects:"
curl -s "${SR_URL}/subjects" | python3 -m json.tool
echo ""
echo "Done."
