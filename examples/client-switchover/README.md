# Setting up Client Switchover from one Kafka Cluster to other using CPC Gateway

- Client Switchover feature of CPC Gateway helps to enable migrations from a source cluster to destination cluster. For example, once on-premise clients are onboarded to CPC Gateway, you can migrate them to Confluent Cloud without client side changes. Gateway can take care of authentication translation as per destination cluster with auth swapping feature.

- Client Switchover can also be used to enable Disastor Recovery Switch from unhealthy cluster to a healthy cluster. It helps in significantly reducing the RTO by avoiding client side changes during a DR scenario. 

- Client Switchover can also easies the on-premise broker upgrades by enabling Blue-Green upgrade strategies.

- Data replication has to be setup outside of CPC Gateway as per your requirements using tools like Cluster Linking.


## Gateway Configuration Example
- Below is a set of configs to bring up a gateway container that acts as a proxy for the kafka-1 and kafka-2 brokers.  
- kafka-1 is onboarded with the Gateway with streaming domain kafka1-domain on internal-kafka1-listener.
- kafka-2 is onboarded with the Gateway with streaming domain kafka2-domain on internal-kafka2-listener.
- When passthrough authentication is enabled at Gateway, Gateway will forward the requests to the brokers and will not perform any authentication. Broker will perform authentication. 
- Switchover route on Gateway is created to connect to the kafka-1 broker on Gateway port 19092. Name of the route is switchover-route. This means, all the traffic addressed to switchover-route will be forwarded to the kafka-1 broker.
- To switchover the clients to kafka-2, we need to change the switchover-route to point to kafka-2. This is done by updating the streaming domain and corresponding bootstrap server id in the switchover-route.
- For simplicity of local development experience, we are using port based routing, disabled encryption and ensured the client has same credentials for both the clusters. 


```yaml
gateway:
    image: "${GATEWAY_IMAGE}"
    container_name: gateway
    external_links:
      - kafka-1
      - kafka-2
    environment:
      GATEWAY_CONFIG: | 
        gateway:
          admin:
            endpoints:
              metrics: true
          streamingDomains:
            - name: kafka1-domain  
              type: kafka
              kafkaCluster:
                name: kafka-cluster-1 
                nodeIdRanges:
                  - name: d
                    start: 1 
                    end: 5
                bootstrapServers:
                  - id: internal-kafka1-listener  
                    endpoint: "kafka-1:44444" 
            - name: kafka2-domain  
              type: kafka
              kafkaCluster:
                name: kafka-cluster-2 
                nodeIdRanges:
                  - name: d
                    start: 1 
                    end: 5
                bootstrapServers:
                  - id: internal-kafka2-listener  
                    endpoint: "kafka-2:22222" 
          routes:
            - name: switchover-route
              endpoint: "host.docker.internal:19092" 
              brokerIdentificationStrategy:
                type: port 
              streamingDomain:
                name: kafka1-domain
                bootstrapServerId: internal-kafka1-listener 
              security:
                auth: passthrough 
``` 

## How to Get Started ?
### Prerequisites
- Docker Desktop (or Docker Engine) with Compose v2
- macOS/Linux shell

### What's here
- `kafka-compose.yaml`: spins up two single-node Kafka clusters (kafka-1 and kafka-2)
- `gateway-compose.yaml`: spins up Gateway container configured to proxy both Kafka clusters
- `kafka_server_jaas.conf`: JAAS config for Kafka authentication
- `start-kafka.sh`: script to start Kafka clusters
- `start-gateway.sh`: script to start Gateway

### Quick start
1) From this folder, make the script executable (first time only):
```bash
chmod +x ./start-kafka.sh ./start-gateway.sh
```
2) Bring up 2 Kafka clusters:
```bash
sh ./start-kafka.sh
```
3) Bring up the Gateway 
```bash
sh ./start-gateway.sh
```

These scripts will help:
- export paths for a default `GATEWAY_IMAGE` and `KAFKA_SERVER_JAAS_CONF` 
- run `docker compose down -v`, then `docker compose up -d` to bring up broker and gateway containers

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

Since the Switchover Route is available at Gateway's localhost:19092, we need the clients to connect to localhost:19092 to stream data. 
Following are the commands to create a topic, produce and consume to the passthrough Route using the Gateway. All this traffic will be forwarded by Gateway to broker's internal Kafka listener as per the Gateway setup.


**Create a topic via the Gateway** 
```
 ./kafka-topics --bootstrap-server localhost:19092 --create --topic "test-topic" --command-config client_sasl.properties
```
To experience client traffic switching to second cluster without client side changes, start the producer in a loop to continously stream to the Gateway


**Run the producer**
```
while true; do
  echo "Test message at $(date '+%H:%M:%S')"
  sleep 2
done | ./kafka-console-producer --bootstrap-server localhost:19092 --topic test-topic --producer.config client_sasl.properties
```

**Run the consumer** 
``` 
./kafka-console-consumer --bootstrap-server localhost:19092 --topic test-topic --consumer.config client_sasl.properties
```

### Switchover Clients to a Different Cluster

1) **Update the switchover-route** in gateway-compose to connect to kafka2-domain by changing the associated streaming domain of the route.

```
 - name: switchover-route
              endpoint: "host.docker.internal:19092" 
              brokerIdentificationStrategy:
                type: port 
              streamingDomain:
                name: kafka2-domain
                bootstrapServerId: internal-kafka2-listener 
              security:
                auth: passthrough 
```

2) **Restart the Gateway**

```
sh start-gateway.sh
```
With the above restart, client traffic will be switched to second streaming domain i.e Kafka2-domain. Hence the clients will start streaming from the second cluster. You will see your console clients continue working.

3) Verify by directly consuming from the second Kafka cluster

```
./kafka-console-consumer --bootstrap-server localhost:11111 --topic test-topic --from-beginning --consumer.config client_sasl.properties
```

### Stop / Clean
```bash
docker compose down -v

### Notes
- Run commands from this directory so Compose finds `docker-compose.yaml`.
- Ports mapped by the Gateway to the host machine in this example: 19092, 19093, 19094, 9190. These are ports for Gateway Route endpoints.

