# Passthrough to Confluent Cloud

This example demonstrates how to configure CPC Gateway to act as a passthrough proxy to a Confluent Cloud cluster. 

## Overview

In this configuration:
- **Gateway** acts as a passthrough proxy - it forwards authentication requests to Confluent Cloud without performing authentication itself
- **Confluent Cloud** performs the actual authentication using your API credentials
- **SSL/TLS** certificates are downloaded from Confluent Cloud and configured in the Gateway's streaming domain


When clients connect:
1. Client connects to Gateway at `localhost:19092` using `SASL_PLAINTEXT`
2. Gateway forwards auth request to Confluent Cloud using `SASL_SSL`
3. Confluent Cloud authenticates the client's API key/secret
4. Data flows through Gateway to/from Confluent Cloud


## Setup Instructions

### Step 1: Download SSL Certificates from Confluent Cloud

The Gateway needs to trust the SSL certificates from your Confluent Cloud cluster. Use the provided script to download and create a truststore:

```bash
chmod +x ./download-cc-certs.sh
./download-cc-certs.sh <your-cc-bootstrap-server>
```

**Example:**
```bash
./download-cc-certs.sh pkc-xxxxx.us-west2.gcp.confluent.cloud:9092
```

This script will:
1. ✅ Download the certificate chain from your Confluent Cloud cluster
2. ✅ Create certificates in `ssl/<your-cc-domain>/` directory
3. ✅ Create a PKCS12 truststore at `ssl/<your-cc-domain>/truststore.p12`
4. ✅ Create a password file at `ssl/<your-cc-domain>/truststore.password`
5. ✅ Verify the truststore was created successfully

**Certificate Storage:**

The script creates a domain-specific directory based on your Confluent Cloud cluster:
```
ssl/
  └── pkc-xxxxx.us-west2.gcp.confluent.cloud/
      ├── truststore.p12
      └── truststore.password
```

This directory structure is mounted to `/etc/gateway/ssl/` in the Gateway container via `docker-compose.yaml`, making the certificates available at:
- `/etc/gateway/ssl/pkc-xxxxx.us-west2.gcp.confluent.cloud/truststore.p12`
- `/etc/gateway/ssl/pkc-xxxxx.us-west2.gcp.confluent.cloud/truststore.password`

The certificates are configured in the Gateway's `streamingDomains` section under `ssl.truststore`.

### Step 2: Update Gateway Configuration

Edit `gateway.yaml` and update two things:

1. **Bootstrap server endpoint** - Replace with your Confluent Cloud cluster endpoint
2. **SSL certificate paths** - Update the paths to match the directory created by the download script


**Note:** The paths in `gateway.yaml` reference `/etc/gateway/ssl/<your-cc-domain>/` because the `docker-compose.yaml` mounts `./ssl` to `/etc/gateway/ssl` in the container.

### Step 3: Update Client Configuration

Edit `client.properties` and add your Confluent Cloud API credentials:

```properties
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required \
  username="YOUR_API_KEY" \
  password="YOUR_API_SECRET";
```

**Where to get API credentials:**
1. Log in to [Confluent Cloud Console](https://confluent.cloud)
2. Navigate to your cluster
3. Go to "API Keys" section
4. Create a new API key or use an existing one

### Step 4: Start the Gateway

Make the startup script executable and run it:

```bash
chmod +x ./start.sh
./start.sh
```

This will start the Gateway container with the appropriate configuration.

## Testing the Connection

Once the Gateway is running, you can test it using Kafka command-line tools:

### List Topics

```bash
kafka-topics --bootstrap-server localhost:19092 --list --command-config client.properties
```

### Create a Topic

```bash
kafka-topics --bootstrap-server localhost:19092 --create --topic test-gateway-topic --command-config client.properties
```

### Produce Messages

```bash
kafka-console-producer --bootstrap-server localhost:19092 --topic test-gateway-topic --producer.config client.properties
```

### Consume Messages

```bash
kafka-console-consumer --bootstrap-server localhost:19092 --topic test-gateway-topic --from-beginning --consumer.config client.properties
```

## Stopping the Gateway

```bash
docker compose down -v
```