# Centralised Governance Policy Enforcement with CPC Gateway

This example demonstrates **centralised data governance enforcement** with CPC Gateway. The Gateway validates that records produced to Kafka conform to schemas registered in Confluent Schema Registry — enforced centrally at the Gateway, with **zero client changes**. Records that violate the configured policy are rejected before they reach the broker.

The example shows the **four validation levels** (`NONE`, `ID`, `SCHEMA`, `SCHEMA_RULES`) side by side, each applied to a different topic on the same route.

## How It Works

```
┌──────────┐        ┌───────────────────┐        ┌───────────────┐
│ Producer │───────▶│    CPC Gateway    │───────▶│  Confluent    │
│          │        │     :6969         │        │  Server       │
│ Consumer │◀────── │                   │◀────── │  :29092       │
└──────────┘        └────────┬──────────┘        └───────────────┘
                             │
                   schema / ID lookup
                             │
                    ┌────────▼──────────┐
                    │  Schema Registry  │
                    │     :8081         │
                    └───────────────────┘
```

- **Producers** connect to the Gateway (port 6969) instead of the broker directly.
- The **Gateway** inspects each record's value against the validation level configured for that topic.
- Conforming records pass through; violations are rejected with `INVALID_RECORD`.

## Prerequisites

- Docker and Docker Compose
- Access to the CPC Gateway Docker image
- A valid **Confluent license JWT** — all three components (Confluent Server, Schema Registry, CPC Gateway) require a license to run. The `SCHEMA_RULES` / encryption scenarios additionally require the **CSFLE add-on** on the license.

## Quick Start

### 1. Set your license and Gateway image

The compose file reads two variables: `CONFLUENT_LICENSE` (the license JWT) and `GATEWAY_IMAGE` (the CPC Gateway image tag or digest to run). Either export them in your shell:

```bash
export CONFLUENT_LICENSE='<your-license-jwt>'
export GATEWAY_IMAGE='<cpc-gateway-image:tag>'
```

…or create a `.env` file in this directory (auto-read by Docker Compose, and gitignored):

```bash
echo "CONFLUENT_LICENSE=<your-license-jwt>" > .env
echo "GATEWAY_IMAGE=<cpc-gateway-image:tag>" >> .env
```

### 2. Start the stack

```bash
docker compose up -d
```

This starts three containers:
- `kafka` — Confluent Server (KRaft mode, single node), SASL/PLAIN auth
- `schema-registry` — Confluent Schema Registry
- `gateway` — CPC Gateway with schema governance enabled

### 3. Register the schemas

```bash
./scripts/register-schemas.sh
```

## What Gets Created

### Schemas and subjects

The registration script creates these schemas:

| Schema ID | Schema | Fields | Registered under subjects |
|---|---|---|---|
| **1** | `Order` | `order_id, product, quantity, price` | `orders-value`, `gov-id-value`, `gov-schema-value` |
| **2** | `Event` | `event_id, kind` | `events-value` |
| **3** | `Payment` | `payment_id, card_number (PII), amount` | `gov-encrypt-field-value` |
| **4** | `Transaction` | `txn_id, account, amount` | `gov-encrypt-payload-value` |

The `Payment` schema tags `card_number` with `confluent:tags: ["PII"]` and carries a data-contract **`ENCRYPT` rule** targeting that tag — see [Field-Level Encryption](#field-level-encryption-schema_rules) below. The `Transaction` schema carries an **`ENCRYPT_PAYLOAD` rule** that encrypts the whole record — see [Full-Payload Encryption](#full-payload-encryption-schema_rules) below.

### Topics and their validation levels

Topics are auto-created on first produce. Each is pinned to a validation level via per-topic overrides in `gateway.yaml`:

| Topic | Validation level | Expected value subject | Conforming schema |
|---|---|---|---|
| `gov-none`         | `NONE`         | — | anything (no checks) |
| `gov-id`           | `ID`           | `gov-id-value`           | `Order` (id 1) |
| `gov-schema`       | `SCHEMA`       | `gov-schema-value`       | `Order` (id 1) |
| `gov-encrypt-field`| `SCHEMA_RULES` | `gov-encrypt-field-value`| `Payment` (id 3) — `card_number` encrypted at the Gateway |
| `gov-encrypt-payload`| `SCHEMA_RULES` | `gov-encrypt-payload-value`| `Transaction` (id 4) — whole record encrypted at the Gateway |

### What each validation level enforces

| Level | Enforces |
|---|---|
| `NONE` | Nothing — all records accepted. |
| `ID` | Value must carry a valid wire-format schema ID **and** that ID must be registered under the topic's subject. Does **not** inspect payload content. |
| `SCHEMA` | Everything `ID` checks **plus** the payload must successfully deserialize against the schema. |
| `SCHEMA_RULES` | `SCHEMA` + Schema Registry rules (encryption, data quality) executed |

> **Tip:** keys and values are governed independently. This example sets `keyValidationLevel: NONE` (keys ungoverned) and overrides `valueValidationLevel` per topic. To govern keys, register a `<topic>-key` subject and raise `keyValidationLevel`.

## Running the Tests

The `kafka` container has the plain console tools (`kafka-console-producer/consumer`); the `schema-registry` container has the Avro tools (`kafka-avro-console-producer/consumer`). The SASL JAAS string is reused below as `$JAAS`:

```bash
JAAS='org.apache.kafka.common.security.plain.PlainLoginModule required username="admin" password="admin-secret";'
```

### Test 1 — Valid record with a Confluent serializer (accepted)

```bash
echo '{"order_id":"O1","product":"widget","quantity":2,"price":9.99}' | \
docker exec -i schema-registry kafka-avro-console-producer \
  --bootstrap-server gateway:6969 --topic gov-schema \
  --property schema.registry.url=http://schema-registry:8081 \
  --property value.schema.id=1 \
  --producer-property security.protocol=SASL_PLAINTEXT \
  --producer-property sasl.mechanism=PLAIN \
  --producer-property sasl.jaas.config="$JAAS"
```
**Accepted** — id 1 is registered under `gov-schema-value` and the payload conforms to `Order`.

### Test 2 — Non-Confluent client, plain text with no schema ID (rejected)

```bash
echo "plain-text-no-schema-id" | \
docker exec -i kafka kafka-console-producer \
  --bootstrap-server gateway:6969 --topic gov-id \
  --producer-property security.protocol=SASL_PLAINTEXT \
  --producer-property sasl.mechanism=PLAIN \
  --producer-property sasl.jaas.config="$JAAS"
```
**Rejected** at `ID` — `InvalidRecordException: Error deserializing schema ID` (no wire-format prefix). The same record sent to `gov-none` is **accepted** (no checks).

### Test 3 — Confluent serializer, wrong subject (rejected)

Produce an `Event` record (id 2, registered only under `events-value`) to a topic governed for `Order`. `auto.register.schemas=false` keeps the client from registering; the Gateway judges the subject:

```bash
echo '{"event_id":"E1","kind":"click"}' | \
docker exec -i schema-registry kafka-avro-console-producer \
  --bootstrap-server gateway:6969 --topic gov-schema \
  --property schema.registry.url=http://schema-registry:8081 \
  --property auto.register.schemas=false --property use.schema.id=2 --property value.schema.id=2 \
  --producer-property security.protocol=SASL_PLAINTEXT \
  --producer-property sasl.mechanism=PLAIN \
  --producer-property sasl.jaas.config="$JAAS"
```
**Rejected** — `Failed to get schema for topic=gov-schema ... schemaId=id=2`. The ID exists globally but not under `gov-schema-value`. (Rejected at `ID` too — the subject check happens at `ID` and above.)

### Test 4 — Valid schema ID, malformed payload (the ID vs SCHEMA difference)

The same bytes — a valid id=1 prefix followed by non-Avro garbage — behave differently per level:

```bash
# At ID level: ACCEPTED (payload not inspected)
docker exec -i kafka bash -c "printf '\x00\x00\x00\x00\x01GARBAGE' | \
  kafka-console-producer --bootstrap-server gateway:6969 --topic gov-id \
  --producer-property security.protocol=SASL_PLAINTEXT \
  --producer-property sasl.mechanism=PLAIN \
  --producer-property sasl.jaas.config='$JAAS'"

# At SCHEMA level: REJECTED — "Error deserializing Avro message ... id=1"
docker exec -i kafka bash -c "printf '\x00\x00\x00\x00\x01GARBAGE' | \
  kafka-console-producer --bootstrap-server gateway:6969 --topic gov-schema \
  --producer-property security.protocol=SASL_PLAINTEXT \
  --producer-property sasl.mechanism=PLAIN \
  --producer-property sasl.jaas.config='$JAAS'"
```
This is the one test that distinguishes `ID` from `SCHEMA`: `ID` only checks the schema ID resolves; `SCHEMA` also deserializes the payload.

### Field-Level Encryption (SCHEMA_RULES)

At `SCHEMA_RULES` level the Gateway runs the schema's data-contract rules. The `Payment` schema (id 3) on `gov-encrypt-field` carries an `ENCRYPT` rule for its PII-tagged `card_number` field, so the **Gateway encrypts that field** before it reaches the broker — the producer sends plaintext and holds no key. This is *offloaded* encryption: the KMS secret lives only in the Gateway (`gateway.yaml` → `schemaRegistryConfigs`), not in any client.

Because the client must send **plaintext** (the Gateway does the encrypting), the producer disables client-side rule execution with `rule.executors._default_.disabled=true`.

> **Schema Registry setup:** storing data-contract rules and the data encryption keys requires SR to load two resource extensions (already set in `docker-compose.yaml`): `RuleSetResourceExtension` (persists the `ruleSet`) and `DekRegistryResourceExtension` (the DEK registry). Without the first, SR silently drops the `ruleSet` and no encryption happens.

**Produce a `Payment` (client sends plaintext; Gateway encrypts `card_number`):**
```bash
echo '{"payment_id":"P1","card_number":"4111-2222-3333-4444","amount":42.5}' | \
docker exec -i schema-registry kafka-avro-console-producer \
  --bootstrap-server gateway:6969 --topic gov-encrypt-field \
  --property schema.registry.url=http://schema-registry:8081 \
  --property value.schema.id=3 --property auto.register.schemas=false \
  --property rule.executors._default_.disabled=true \
  --producer-property security.protocol=SASL_PLAINTEXT \
  --producer-property sasl.mechanism=PLAIN \
  --producer-property sasl.jaas.config="$JAAS"
```

**(a) Read the raw bytes straight from the broker (bypassing the Gateway) — `card_number` is ciphertext, `payment_id` stays plaintext:**
```bash
docker exec kafka kafka-console-consumer \
  --bootstrap-server kafka:29092 --topic gov-encrypt-field --from-beginning --timeout-ms 6000 \
  --consumer-property security.protocol=SASL_PLAINTEXT \
  --consumer-property sasl.mechanism=PLAIN \
  --consumer-property sasl.jaas.config="$JAAS"
# e.g. ...P1<binary>Ln9rEaAQDjSwUtT6sEmQwgQw2XogpK8ADckjogUJhkIz...=  (card_number encrypted)
```

**(b) Read back through the Gateway — `card_number` is decrypted:**
```bash
docker exec schema-registry kafka-avro-console-consumer \
  --bootstrap-server gateway:6969 --topic gov-encrypt-field --from-beginning \
  --property schema.registry.url=http://schema-registry:8081 \
  --property rule.executors._default_.disabled=true \
  --consumer-property security.protocol=SASL_PLAINTEXT \
  --consumer-property sasl.mechanism=PLAIN \
  --consumer-property sasl.jaas.config="$JAAS"
# {"payment_id":"P1","card_number":"4111-2222-3333-4444","amount":42.5}
```

Only `card_number` is encrypted (it's the only PII-tagged field); `payment_id` and `amount` stay in the clear.

### Full-Payload Encryption (SCHEMA_RULES)

Field-level encryption protects tagged fields. **Full-payload encryption** protects the *entire* record: the `Transaction` schema (id 4) on `gov-encrypt-payload` carries an `ENCRYPT_PAYLOAD` rule (an *encoding* rule, not a field rule), so the **Gateway encrypts the whole serialized value** before it reaches the broker. As with field-level encryption this is *offloaded* — the producer sends plaintext (`rule.executors._default_.disabled=true`) and holds no key.

**Produce a `Transaction` (client sends plaintext; Gateway encrypts the whole record):**
```bash
echo '{"txn_id":"T1","account":"ACME-001","amount":9999.0}' | \
docker exec -i schema-registry kafka-avro-console-producer \
  --bootstrap-server gateway:6969 --topic gov-encrypt-payload \
  --property schema.registry.url=http://schema-registry:8081 \
  --property value.schema.id=4 --property auto.register.schemas=false \
  --property rule.executors._default_.disabled=true \
  --producer-property security.protocol=SASL_PLAINTEXT \
  --producer-property sasl.mechanism=PLAIN \
  --producer-property sasl.jaas.config="$JAAS"
```

**(a) Read the raw bytes straight from the broker (bypassing the Gateway) — the whole value is ciphertext (no field is readable):**
```bash
docker exec kafka kafka-console-consumer \
  --bootstrap-server kafka:29092 --topic gov-encrypt-payload --from-beginning --timeout-ms 6000 \
  --consumer-property security.protocol=SASL_PLAINTEXT \
  --consumer-property sasl.mechanism=PLAIN \
  --consumer-property sasl.jaas.config="$JAAS"
# e.g. <schema-id prefix><binary ciphertext> — neither "T1" nor "ACME-001" appears
```

**(b) Read back through the Gateway — the record is decrypted:**
```bash
docker exec schema-registry kafka-avro-console-consumer \
  --bootstrap-server gateway:6969 --topic gov-encrypt-payload --from-beginning \
  --property schema.registry.url=http://schema-registry:8081 \
  --property rule.executors._default_.disabled=true \
  --consumer-property security.protocol=SASL_PLAINTEXT \
  --consumer-property sasl.mechanism=PLAIN \
  --consumer-property sasl.jaas.config="$JAAS"
# {"txn_id":"T1","account":"ACME-001","amount":9999.0}
```

Unlike field-level encryption, **no field stays in the clear** — `txn_id`, `account`, and `amount` are all inside the encrypted payload.

> **Field vs full-payload:** field-level (`ENCRYPT`) targets tagged fields and leaves the rest readable — good for selective PII protection while keeping the record partially queryable. Full-payload (`ENCRYPT_PAYLOAD`) encrypts everything — good when the whole record is sensitive.

### Verify — consume to confirm what landed

```bash
docker exec kafka kafka-console-consumer \
  --bootstrap-server gateway:6969 --topic gov-none --from-beginning \
  --consumer-property security.protocol=SASL_PLAINTEXT \
  --consumer-property sasl.mechanism=PLAIN \
  --consumer-property sasl.jaas.config="$JAAS"
```
Only accepted records appear — rejected records never reached the broker.

## Results Summary

| Test | Topic (level) | Payload | Result |
|---|---|---|---|
| 1 | `gov-schema` (SCHEMA) | `Order` id=1, conforming | accepted |
| 2 | `gov-id` (ID) | plain text, no prefix | rejected (`Error deserializing schema ID`) |
| 2 | `gov-none` (NONE) | plain text, no prefix | accepted |
| 3 | `gov-schema` (SCHEMA) | `Event` id=2 (wrong subject) | rejected (`Failed to get schema ... id=2`) |
| 4 | `gov-id` (ID) | id=1 prefix + garbage | accepted |
| 4 | `gov-schema` (SCHEMA) | id=1 prefix + garbage | rejected (`Error deserializing Avro message`) |
| 5 | `gov-encrypt-field` (SCHEMA_RULES) | `Payment` id=3 plaintext | accepted; `card_number` encrypted at rest, decrypted on read-back |
| 6 | `gov-encrypt-payload` (SCHEMA_RULES) | `Transaction` id=4 plaintext | accepted; whole record encrypted at rest, decrypted on read-back |

## Gateway Configuration

```yaml
gateway:
  schemaValidation:
    schemaRegistryUrls:
      - "http://schema-registry:8081"
    keyValidationLevel: NONE
    valueValidationLevel: ID          # default for any topic not listed below
    valueSubjectNameStrategy: TOPIC   # subject = {topic}-value
    # Local KMS secret so the Gateway can run encryption rules centrally
    # (demo secret only — use a real KMS in production).
    schemaRegistryConfigs:
      rule.executors: "encryptField,encryptPayload"
      rule.executors.encryptField.class: "io.confluent.kafka.schemaregistry.encryption.FieldEncryptionExecutor"
      rule.executors.encryptField.param.secret: "<base64-local-kms-secret>"
      rule.executors.encryptPayload.class: "io.confluent.kafka.schemaregistry.encryption.EncryptionExecutor"
      rule.executors.encryptPayload.param.secret: "<base64-local-kms-secret>"
    topics:
      - name: gov-none
        valueValidationLevel: NONE
      - name: gov-id
        valueValidationLevel: ID
      - name: gov-schema
        valueValidationLevel: SCHEMA
      - name: gov-encrypt-field
        valueValidationLevel: SCHEMA_RULES
      - name: gov-encrypt-payload
        valueValidationLevel: SCHEMA_RULES
```

| Setting | Value | Description |
|---|---|---|
| `valueValidationLevel` | `ID` | Default level for topics without an override |
| `keyValidationLevel` | `NONE` | No validation on record keys |
| `valueSubjectNameStrategy` | `TOPIC` | Value subject is `{topic}-value` |
| `topics[]` | per-topic | Override key/value validation level for a specific topic |

## Cleanup

```bash
docker compose down -v
```
