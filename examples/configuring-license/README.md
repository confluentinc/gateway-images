# Configuring License for CPC-Gateway & Confluent-Gateway-for-Cloud

This example demonstrates how to configure and manage licenses for Confluent Private Cloud Gateway, including the differences between trial mode and licensed mode.

## Overview

CPC-Gateway requires cpc-gateway license while confluent-gateway-for-cloud requires cloud specific license. One can configure one of them.

| Image | License Type |
|-|-|
| cpc-gateway | CPC |
| confluent-gateway-for-cloud | Cloud |

### 🆓 Trial Mode (Default)
- **No license required** - Gateway starts automatically in trial mode
- **Limitation:** Maximum of 4 routes can be configured
- **Purpose:** Evaluation and testing
- **Duration:** No time limit on trial mode

### Enterprise Mode for Non Confluent-Cloud Deployments
- **License required** Requires valid license
- **Limitation:** Allows only non-confluent-cloud streaming domains
- **Purpose:** Gateway forwarding to non-confluent-cloud deployments
- **Duration:** As specified in the claim.

### Enterprise Mode for Confluent-Cloud Deployments
- **License required** Requires valid license
- **Limitation:** Allows only confluent-cloud streaming domains
- **Purpose:** Gateway forwarding to confluent-cloud deployments
- **Duration:** As specified in the claim.

---

## What's Included

- `docker-compose.yaml`: Orchestrates Kafka broker and Gateway containers
- `gateway.yaml`: Standalone Gateway configuration (single route example)
- `kafka_server_jaas.conf`: JAAS configuration for Kafka SASL/PLAIN authentication
- `client_sasl.properties`: Client configuration for connecting to Gateway
- `start.sh`: Helper script for easy startup

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         Gateway                             │
│  ┌────────────────┬────────────────┬────────────────┐       │
│  │ Route 1        │ Route 2        │ Route 3        │ ...   │
│  │ localhost:19092│ localhost:29092│ localhost:39092│       │
│  └───────┬────────┴───────┬────────┴───────┬────────┘       │
│          │                │                │                │
│          └────────────────┼────────────────┘                │
│                           │                                 │
│                  ┌────────▼────────┐                        │
│                  │ sample-domain   │                        │
│                  │ (kafka-cluster) │                        │
│                  └────────┬────────┘                        │
└───────────────────────────┼─────────────────────────────────┘
                            │
                   ┌────────▼────────┐
                   │  Kafka Broker   │
                   │  kafka-1:44444  │
                   │  (SASL/PLAIN)   │
                   └─────────────────┘
```

---

## Prerequisites

- **Docker Desktop** (or Docker Engine) with Compose v2
- **macOS/Linux shell** environment
- **(Optional)** Valid Confluent license token for licensed mode

---

## Quick Start

### 1. Start in Trial Mode (Default)

```bash
# Make the script executable (first time only)
chmod +x ./start.sh

# Start the stack
./start.sh
```

The Gateway will start in trial mode with 4 routes configured.

### 2. Start in Licensed Mode

To use licensed mode, you need to configure the `GATEWAY_LICENSES` environment variable with your valid license token:

**Option A: Set environment variable before starting**
```bash
export GATEWAY_LICENSES="your-license-token-here"
./start.sh
```

**Option B: Edit docker-compose.yaml**
```yaml
gateway:
  environment:
    GATEWAY_LICENSES: |
      your-license-token-here
      # You can add multiple license tokens, one per line
```

> **Note:** Contact Confluent to obtain a valid license token for production use.

---

## Example Configuration

### Route Configuration

This example configures **4 passthrough routes** to demonstrate the trial mode limit:

| Route Name         | Gateway Endpoint | Purpose                          |
|--------------------|------------------|----------------------------------|
| passthrough-route  | localhost:19092  | Primary route (used in examples) |
| passthrough-route-2| localhost:29092  | Additional route #2              |
| passthrough-route-3| localhost:39092  | Additional route #3              |
| passthrough-route-4| localhost:49092  | Additional route #4              |

All routes use:
- **Authentication:** Passthrough (authentication handled by Kafka broker)
- **Broker Identification:** Port-based strategy
- **Streaming Domain:** sample-domain (maps to kafka-1:44444)

### Understanding the 4-Route Configuration

The example intentionally configures 4 routes to demonstrate the trial mode limitation. A 5th route (commented out in `docker-compose.yaml`) would fail in trial mode:

```yaml
# This 5th route will fail in trial mode:
# - name: passthrough-route-5
#   endpoint: "localhost:59092"
#   ...
```

**To test the trial mode limit:**
1. Start Gateway in trial mode (without license)
2. Uncomment the 5th route in `docker-compose.yaml`
3. Restart: Gateway will fail to start with an error about route limits

---

## Using the Gateway

### Download Kafka Clients

Download Kafka binaries from [Apache Kafka Downloads](https://kafka.apache.org/downloads) to get console clients.

### Client Configuration

The included `client_sasl.properties` file contains the necessary authentication configuration:

```properties
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required \
  username="admin" \
  password="admin-secret";
```

> **Note:** In this passthrough setup, authentication is performed by the Kafka broker, not the Gateway. The Gateway forwards authentication credentials to the broker.

### Console Client Examples

All examples use the primary route at `localhost:19092`.

**Create a Topic**
```bash
kafka-topics --bootstrap-server localhost:19092 \
  --create --topic test-topic \
  --command-config client_sasl.properties
```

**Produce Messages**
```bash
kafka-console-producer --bootstrap-server localhost:19092 \
  --topic test-topic \
  --producer.config client_sasl.properties
```

**Consume Messages**
```bash
kafka-console-consumer --bootstrap-server localhost:19092 \
  --topic test-topic \
  --from-beginning \
  --consumer.config client_sasl.properties
```

**Using Alternative Routes**

You can connect to any of the 4 configured routes:
```bash
# Connect via route 2 (port 29092)
kafka-console-producer --bootstrap-server localhost:29092 \
  --topic test-topic \
  --producer.config client_sasl.properties

# Connect via route 3 (port 39092)
kafka-console-consumer --bootstrap-server localhost:39092 \
  --topic test-topic \
  --consumer.config client_sasl.properties
```

---

## Exposed Ports

| Port  | Service                        | Description                                  |
|-------|--------------------------------|----------------------------------------------|
| 19092 | Gateway - passthrough-route    | Primary Gateway route (used in examples)     |
| 29092 | Gateway - passthrough-route-2  | Additional Gateway route #2                  |
| 39092 | Gateway - passthrough-route-3  | Additional Gateway route #3                  |
| 49092 | Gateway - passthrough-route-4  | Additional Gateway route #4                  |
| 9190  | Gateway - Admin/Metrics        | Gateway management and monitoring endpoint   |
| 33333 | Kafka - External Listener      | Kafka broker external access (SASL/PLAIN)    |
| 44444 | Kafka - Internal Listener      | Kafka broker internal access (for Gateway)   |

---

## Monitoring and Verification

### Check Gateway Metrics

The Gateway exposes metrics at the admin endpoint:
```bash
curl http://localhost:9190/metrics
```

### View Gateway Logs

```bash
# View Gateway logs
docker logs gateway

# Follow Gateway logs
docker logs -f gateway
```

### Verify License Status

Check Gateway logs for license information:
```bash
docker logs gateway | grep -i license
```

**Trial Mode Output:**
```
===> Checking Licenses Text...
===> Starting Gateway in trial mode (max 4 routes)
```

**Licensed Mode Output:**
```
===> Checking Licenses Text...
===> Using GATEWAY_LICENSES environment variable
===> Using licenses file at /etc/gateway/licenses.txt
```

---

## Configuration Details

### License Configuration Methods

The Gateway supports multiple ways to provide license configuration:

**1. Environment Variable (Recommended for Docker)**
```yaml
environment:
  GATEWAY_LICENSES: |
    license-token-1
    license-token-2
```

**2. Trial Mode (No Configuration)**
Simply omit the `GATEWAY_LICENSES` variable and any license files.

### Gateway Configuration Options

This example uses inline configuration via the `GATEWAY_CONFIG` environment variable. The Gateway also supports:

- **`GATEWAY_CONFIG`**: Inline YAML configuration (used in this example)
- **`GATEWAY_CONFIG_FILE`**: Path to configuration file
- **`GATEWAY_CONFIG_TEMPLATE`**: Path to template file with variable substitution

---

## Cleanup

```bash
# Stop and remove containers, networks, and volumes
docker compose down -v

# Optional: Remove stopped containers
docker container prune -f
```

---

## Troubleshooting

### Issue: Gateway fails to start with "route limit exceeded"

**Cause:** You're in trial mode and have configured more than 4 routes.

**Solution:**
- Remove excess routes from configuration, OR
- Add a valid license token to `GATEWAY_LICENSES`

### Issue: "Authentication failed" when connecting clients

**Cause:** Incorrect credentials or missing SASL configuration.

**Solution:**
- Verify `client_sasl.properties` contains correct credentials (admin/admin-secret)
- Ensure you're using the `--producer.config` or `--consumer.config` flag

### Issue: "Cannot connect to Gateway at localhost:19092"

**Cause:** Gateway container not running or port not exposed.

**Solution:**
```bash
# Check if Gateway is running
docker ps | grep gateway

# Check Gateway logs for errors
docker logs gateway

# Verify port mapping
docker port gateway
```

### Issue: License token expired

**Cause:** The license token has passed its expiration date.

**Solution:**
- Contact Confluent to obtain a renewed license token
- Update the `GATEWAY_LICENSES` environment variable
- Restart the Gateway: `docker compose restart gateway`

---

## Notes

- Run all commands from this directory so Docker Compose finds `docker-compose.yaml`
- For production deployments, use licensed mode and secure credential management