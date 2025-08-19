# Setting up Network Isolation and Custom Domains for a private Kafka Cluster using CPC Gateway


## Gateway Configuration Example

 Below is a set of configs to bring up a gateway container that acts as a proxy for kafka brokers. Please go through docker-compose file for more details.

 - kafka-1 is onboarded with the Gateway with streaming domain sample-domain. When a Route is associated with this sample streaming domain, Gateway forwards to this Kafka-1 cluster using external-listener-endpoint as the bootstrap server endpoint.
 - partner-access-route route on Gateway is created for external clients to connect to the kafka-1 broker via the Gateway. Name of the route is partner-access-route. 
 - partner-access-route is associated with sample-domain. All the traffic addressed by partner-access-route will be forwarded to the sample-domain by the Gateway.
 - Passthrough authentication is enabled at Gateway for partner-access-route. When passthrough authentication is enabled at Gateway, Gateway will forward the requests to the brokers and will not perform any authentication. Brokers will perform authentication. 
 - Two seperate networks are defined for kafka and gateway in the local docker network. Kafka brokers are isolated in a private docker network. 
 - partner-access-route route is created with a custom domain name "my-custom-domain-name" and port 19092. This route is used by external clients to connect to the kafka-1 broker via the Gateway. For example, clients use "my-custom-domain-name:19092" as the bootstrap server address.
 - Setting this custom domain name rather than using localhost requires setting up the host resolution in /etc/hosts file.
 - Port based routing is used for this partner-access-route is configured for simplicity of local experience. 


```yaml
gateway:
    image: "${GATEWAY_IMAGE}"
    container_name: gateway
    networks:
      - gateway-net
    depends_on:
      - kafka-1
    environment:
      GATEWAY_CONFIG: |
        gateway:
          admin:
            endpoints:
              metrics: true
          streamingDomains:
            - name: sample-domain
              type: kafka
              kafkaCluster:
                name: kafka-cluster-1
                nodeIdRanges:
                  - name: d
                    start: 1 # 19093, 1
                    end: 5
                bootstrapServers:
                  - id: external-listener-endpoint 
                    endpoint: "host.docker.internal:33333"  
          routes:
            - name: partner-access-route
              endpoint: "my-custom-domain-name:19092"
              brokerIdentificationStrategy:
                type: port 
              streamingDomain:
                name: sample-domain
                bootstrapServerId: external-listener-endpoint
              security:
                auth: passthrough
``` 

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

## Host Resolution for Custom Domains defined at CPC Gateway 

This example exposes a custom domain **my-custom-domain-name** for your Kafka listeners using Gateway Route endpoint. So, In your local /etc/hosts file, you need to create an entry for resolving **my-custom-domain-name** to your localhost

```
127.0.0.1       my-custom-domain-name
``` 

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

Since the partner-access-route Route is available at Gateway's my-custom-domain-name:19092, we need the clients to connect to my-custom-domain-name:19092 to stream data. 

Following are the commands to create a topic, produce and consume to the passthrough Route using the Gateway. All this traffic will be forwarded by Gateway to broker's internal Kafka listener as per the Gateway setup.

Command to create a topic via the Gateway 
```
 ./kafka-topics --bootstrap-server my-custom-domain-name:19092 --create --topic "test-topic" --command-config client_sasl.properties
```

Command to run the producer
```
./kafka-console-producer --bootstrap-server my-custom-domain-name:19092 --topic test-topic --consumer.config client_sasl.properties
```

Command to run the consumer 
``` 
./kafka-console-consumer --bootstrap-server my-custom-domain-name:19092 --topic test-topic --consumer.config client_sasl.properties
```

### Stop / Clean

```bash
docker compose down -v
```

### Notes
- Run commands from this directory so Compose finds `docker-compose.yaml`.
- Ports mapped by the Gateway to the host machine in this example: 19092, 19093, 19094, 9190. These are ports for Gateway Route endpoints.

