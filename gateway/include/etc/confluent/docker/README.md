# Confluent Gateway Docker Setup

This directory contains the Docker configuration files for the Confluent Gateway.

**Environment Variables:** Set one of the following environment variables to configure the gateway:
- `GATEWAY_CONFIG`: YAML configuration content (takes precedence)
- `GATEWAY_CONFIG_TEMPLATE`: Path to configuration template file (e.g `/etc/confluent/docker/single-route-plaintext-passthrough.yaml.template`)
- `GATEWAY_CONFIG_FILE`: Path to the final configuration file (defaults to `/etc/${COMPONENT}/gateway-config.yaml`)

**Default Configuration:**
- `GATEWAY_CONFIG_FILE`: `/etc/gateway/gateway-config.yaml`

### minimal config for `single-route-plaintext-passthrough.yaml.template`
```yaml
environment:
  GATEWAY_CONFIG_TEMPLATE: /etc/confluent/docker/single-route-plaintext-passthrough.yaml.template
  GATEWAY_KAFKA_BOOTSTRAP_SERVER: "localhost:9092"
  # Kafka node ID range
  GATEWAY_KAFKA_NODE_ID_RANGE_NAME: "default-range"
  GATEWAY_KAFKA_NODE_ID_RANGE_START: "0"
  GATEWAY_KAFKA_NODE_ID_RANGE_END: "2"
  # Route configuration
  GATEWAY_ROUTE_ENDPOINT: "localhost:9192"
   # Logging configuration
  GATEWAY_LOG_LEVEL: "INFO"
  GATEWAY_ROOT_LOG_LEVEL: "INFO"
```