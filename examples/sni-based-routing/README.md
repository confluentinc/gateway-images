# SNI-Based Routing Example

This example demonstrates SNI-based routing with automatic certificate generation for Gateway and Kafka client mutual TLS authentication.

## Prerequisites

- Docker and Docker Compose installed
- Write access to `/etc/hosts` file

## Setup Instructions

### 1. Update /etc/hosts

Add the following entry to your `/etc/hosts` file:

```bash
sudo vi /etc/hosts
```
```
127.0.0.1   broker1.host.docker.internal
```

### 2. Start the Services

Run the start script which will:
- Clean up any existing certificates
- Generate fresh CA, Gateway, and client certificates with mutual trust
- Start the Kafka and Gateway services

```bash
./start.sh
```

### 3. Test Producer/Consumer

#### Access the Kafka container:
```bash
docker exec -it kafka-1 /bin/bash
```

#### Test Producer:
From inside the kafka-1 container, run:
```bash
kafka-console-producer \
     --bootstrap-server host.docker.internal:19092 \
     --topic test \
     --producer.config /etc/kafka/client.properties
```

Type some messages and press Enter after each one. Press Ctrl+C to exit.

#### Test Consumer:
In another terminal, access the kafka-1 container again:
```bash
docker exec -it kafka-1 /bin/bash
```

Then run:
```bash
kafka-console-consumer \
     --bootstrap-server host.docker.internal:19092 \
     --topic test \
     --consumer.config /etc/kafka/client.properties
```

You should see the messages you produced earlier.

## What's Happening

1. **Certificate Generation**: The `start.sh` script generates:
   - A local Certificate Authority (CA)
   - Gateway certificate signed by the CA (with SANs for various hostnames)
   - Client certificate signed by the same CA
   - Truststores containing the CA for mutual authentication

2. **SNI Routing**: The Gateway uses Server Name Indication (SNI) to route traffic based on the hostname in the TLS handshake.

3. **Mutual TLS**: Both Gateway and Kafka client trust each other's certificates through the shared CA.

## Generated Files

The `./ssl/` directory will contain:
- `gateway.keystore.jks` - Gateway's private key and certificate
- `gateway.truststore.jks` - Gateway's trusted CA certificates
- `client.keystore.jks` - Client's private key and certificate  
- `client.truststore.jks` - Client's trusted CA certificates
- `gateway.*.pwd` - Password files for Gateway keystores
- Various intermediate files (`.key`, `.crt`, `.p12`, etc.)

## Cleanup

To stop the services:
```bash
docker-compose down
```

To clean up certificates and start fresh, just run `./start.sh` again - it automatically cleans up existing certificates before generating new ones.

## Troubleshooting

- **Connection refused**: Ensure the `/etc/hosts` entry is correct and services are running
- **Certificate errors**: Run `./start.sh` again to regenerate certificates
- **Permission errors**: Ensure the `start.sh` script is executable (`chmod +x start.sh`)
