# Configuring License(s) for Confluent Private Cloud Gateway - Example

This section has a docker setup to bring up Gateway and broker containers with License configuration for Gateway.

## Gateway Configuration Example

Below example has Gateway configuration. Declaring licenses via environment variable `GATEWAY_LICENSES` in `docker-compose.yaml` file, as shown below:

```yaml
GATEWAY_LICENSES: |
  <license-str1>
  <license-str2>
```

Without license configuration, Gateway will start in trial mode. In trial mode, maximum 4 routes can be configured.

## How to Get Started ?
### Prerequisites
- Docker Desktop (or Docker Engine) with Compose v2
- macOS/Linux shell

### What's here
- `docker-compose.yaml`: spins up Kafka and Gateway
- `kafka_server_jaas.conf`: JAAS config for Kafka
- `start.sh`: simple startup helper

### Quick start
1) From this folder, make the script executable (first time only):
```bash
chmod +x ./start.sh
```
2) Start the stack:
```bash
./start.sh
```

This will:
- export paths for a default `GATEWAY_IMAGE` and `KAFKA_SERVER_JAAS_CONF` 
- run `docker compose down -v`, prune stopped containers, then `docker compose up -d` to bring up broker and gateway containers

### Run Console Clients with Gateway

You can download the Kafka clients [here](https://kafka.apache.org/downloads) to get your console clients to work with the Gateway container. Console clients are available within the bin directory once you unzip the Kafka binary.

Create a client config file "client_sasl.properties" with the following details and make them accessible for the console clients. In Identity Passthrough setup, authentication will not be performed by the Gateway. However, the broker performs the authentication. In the current setup, a single node broker is set up with SASL/Plain authentication and the client needs to provide the Plain credentials for successful authentication.

```
# client_sasl.properties
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required \
username="admin" \
password="admin-secret";
```

Since the Passthrough Route is available at Gateway's localhost:19092, we need the clients to connect to localhost:19092 to stream data. 
Following are the commands to create a topic, produce and consume to the passthrough Route using the Gateway. All this traffic will be forwarded by Gateway to broker's internal Kafka listener as per the Gateway setup.

Command to create a topic via the Gateway 
```
 ./kafka-topics --bootstrap-server localhost:19092 --create --topic "test-topic" --command-config client_sasl.properties
```

Command to run the producer
```
./kafka-console-producer --bootstrap-server localhost:19092 --topic test-topic --producer.config client_sasl.properties
```

Command to run the consumer 
``` 
./kafka-console-consumer --bootstrap-server localhost:19092 --topic test-topic --consumer.config client_sasl.properties
```

### Stop / Clean
```bash
docker compose down -v
```

### Notes
- Run commands from this directory so Compose finds `docker-compose.yaml`.
- Ports mapped by the Gateway to the host machine in this example: 19092, 19093, 19094, 9190. These are ports for Gateway Route endpoints.

