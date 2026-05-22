# CPC Gateway — Schema Usage Enforcement

This example demonstrates **schema ID enforcement** with CPC Gateway. The Gateway validates that all records produced to Kafka use a schema registered in Confluent Schema Registry. Records without a valid schema ID are rejected before reaching the broker.

Platform operators configure enforcement once at the Gateway — all producer traffic is validated automatically with zero client changes.

## How It Works

```
┌──────────┐        ┌───────────────────┐        ┌───────────────┐
│ Producer │───────>│    CPC Gateway    │───────>│  Confluent    │
│          │        │     :6969         │        │  Server       │
│ Consumer │<───── │                   │<───── │  :29092       │
└──────────┘        └────────┬──────────┘        └───────────────┘
                             │
                   schema ID lookup
                             │
                    ┌────────▼──────────┐
                    │  Schema Registry  │
                    │     :8081         │
                    └───────────────────┘
```

- **Producers** connect to the Gateway (port 6969) instead of the broker directly
- **Gateway** checks that the schema ID in each record is registered in Schema Registry
- Records with a valid schema ID pass through; records without one are rejected with `INVALID_RECORD`

## Prerequisites

- Docker and Docker Compose
- [kcat](https://github.com/edenhill/kcat) (for negative test)
- Access to the CPC Gateway Docker image (internal ECR)
- A valid **Confluent Private Cloud license** — all three components (Confluent Server, Schema Registry, and CPC Gateway) require a CPC license to run

## Quick Start

### 1. Set your license

```bash
export CONFLUENT_LICENSE='<your-enterprise-license-jwt>'
```

### 2. Start the stack

```bash
docker compose up -d
```

This starts three containers:
- `kafka` — Confluent Server (KRaft mode, single node)
- `schema-registry` — Confluent Schema Registry
- `gateway` — CPC Gateway with schema ID enforcement enabled

### 3. Register a schema

```bash
./scripts/register-schemas.sh
```

This registers an Avro schema for `Order` records under the subject `orders-value`.

### 4. Run the demo

#### Positive test — produce with a valid schema ID (accepted)

```bash
docker exec -it schema-registry kafka-avro-console-producer \
  --broker-list gateway:6969 \
  --topic orders \
  --property schema.registry.url=http://schema-registry:8081 \
  --property value.schema.id=1 \
  --producer-property security.protocol=SASL_PLAINTEXT \
  --producer-property sasl.mechanism=PLAIN \
  --producer-property sasl.jaas.config='org.apache.kafka.common.security.plain.PlainLoginModule required username="admin" password="admin-secret";'
```

Type the following and press Enter:
```json
{"order_id":"ORD-001","product":"laptop","quantity":1,"price":999.99}
```

The record is accepted — Gateway validated that schema ID 1 is registered under `orders-value`.

#### Negative test — produce without a valid schema ID (rejected)

```bash
printf '\x00\x00\x00\x03\xe7hello' | kcat -b localhost:6969 -t orders -P \
  -X security.protocol=SASL_PLAINTEXT \
  -X sasl.mechanism=PLAIN \
  -X sasl.username=admin \
  -X sasl.password=admin-secret
```

This sends a record with schema ID 999 (unregistered). Gateway rejects it — the schema ID is not found in Schema Registry.

#### Non-Confluent client — plain JSON without wire format (rejected)

Gateway enforcement is byte-level, not library-level. A client that doesn't use the Confluent serializer can still be rejected if it omits the wire-format prefix:

```bash
printf '{"order_id":"ORD-999","product":"plain-json","quantity":1,"price":1.0}' \
  | kcat -b localhost:6969 -t orders -P \
    -X security.protocol=SASL_PLAINTEXT \
    -X sasl.mechanism=PLAIN \
    -X sasl.username=admin \
    -X sasl.password=admin-secret
```

Gateway rejects: the first byte is not `0x00`, so there is no schema ID to validate.

#### Non-Confluent client — wire format with a valid schema ID but bogus payload (rejected)

The `orders` topic is configured with `valueValidationLevel: SCHEMA` (see Gateway Configuration below), so the gateway deserializes each record against the registered schema. A non-Confluent client can fake the wire format prefix with a registered schema ID, but if the payload bytes don't decode as valid Avro for that schema the record is rejected:

```bash
printf '\x00\x00\x00\x00\x01bogus-payload-not-real-avro' \
  | kcat -b localhost:6969 -t orders -P \
    -X security.protocol=SASL_PLAINTEXT \
    -X sasl.mechanism=PLAIN \
    -X sasl.username=admin \
    -X sasl.password=admin-secret
```

Gateway rejects: `KafkaAvroDeserializer` fails to decode the payload against the `Order` schema. Under `valueValidationLevel: ID` this same record would have been accepted — `SCHEMA` mode adds payload validation on top of the schema ID check.

#### Verify — consume to see only the valid record

```bash
docker exec schema-registry kafka-avro-console-consumer \
  --bootstrap-server gateway:6969 \
  --topic orders \
  --from-beginning \
  --property schema.registry.url=http://schema-registry:8081 \
  --consumer-property security.protocol=SASL_PLAINTEXT \
  --consumer-property sasl.mechanism=PLAIN \
  --consumer-property sasl.jaas.config='org.apache.kafka.common.security.plain.PlainLoginModule required username="admin" password="admin-secret";'
```

Only the valid order record appears — the rejected record never reached the broker.

## Gateway Configuration

```yaml
gateway:
  schemaValidation:
    schemaRegistryUrls:
      - "http://schema-registry:8081"
    keyValidationLevel: NONE
    valueValidationLevel: ID            # default for all topics
    valueSubjectNameStrategy: TOPIC
    topics:
      - name: orders
        valueValidationLevel: SCHEMA    # stricter for orders only
```

| Setting | Value | Description |
|---|---|---|
| `valueValidationLevel` (default) | `ID` | Validate that the schema ID in each record is registered in Schema Registry |
| `valueValidationLevel` (orders) | `SCHEMA` | `ID` + deserialize the payload against the schema |
| `keyValidationLevel` | `NONE` | No validation on record keys |
| `valueSubjectNameStrategy` | `TOPIC` | Schema subject is `{topic}-value` |

### Validation levels

| Level | What it checks |
|---|---|
| `NONE` | Nothing |
| `ID` | Schema ID exists in Schema Registry under the correct subject |
| `SCHEMA` | `ID` + payload deserializes against the schema |
| `DATA_CONTRACT` | `SCHEMA` + Schema Registry rules (encryption, data quality) executed |

## Cleanup

```bash
docker compose down -v
```
