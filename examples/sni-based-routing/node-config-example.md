# Node-Level Configuration Example

This example demonstrates how to configure node-specific settings using the `$(gatewayNodeId)`
placeholder in your gateway configuration.

## Overview

The gateway now supports node-level configuration through the `GATEWAY_NODE_ID` environment
variable. When set, the `$(gatewayNodeId)` placeholder in your configuration files will be replaced
with the actual node ID value.

## Minimal Configuration Example

### Base Configuration (gateway.yaml)

```yaml
gateway:
  admin:
    endpoints:
      metrics: true
  streamingDomains:
    - name: sample-domain
      type: kafka
      kafkaCluster:
        name: kafka-cluster-1
        bootstrapServers:
          - id: localkafka
            endpoint: "kafka-1:44444"
  routes:
    - name: sni-route
      endpoint: "kafka.gateway.local:19092"
      brokerIdentificationStrategy:
        type: host
        pattern: "broker$(nodeId).$(gatewayNodeId).kafka.gateway.local"
      streamingDomain:
        name: sample-domain
        bootstrapServerId: localkafka
```

### Usage

Set the `GATEWAY_NODE_ID` environment variable when starting the gateway:

```bash
export GATEWAY_NODE_ID="pod0"
./start.sh
```

### Result

The configuration will be processed and `$(gatewayNodeId)` will be replaced with `pod0`:

```yaml
# Generated node-specific configuration
gateway:
  routes:
    - name: sni-route
      endpoint: "kafka.gateway.local:19092"
      brokerIdentificationStrategy:
        type: host
        pattern: "broker$(nodeId).pod0.kafka.gateway.local"
      streamingDomain:
        name: sample-domain
        bootstrapServerId: localkafka
```

## Benefits

1. **Single Configuration Template**: Use one configuration file for multiple nodes (specially in
   kubernetes environments)
2. **Dynamic Node Identification**: Each node gets its unique identifier in hostnames
3. **NLB Cost Reduction**: This allows kafka client to communicate directly through the gateway
   nodes, reducing the traffic bytes going through the NLB, thus reducing costs. It requires
   kafka >= 3.8. Read
   more - [KIP-899](https://cwiki.apache.org/confluence/display/KAFKA/KIP-899%3A+Allow+producer+and+consumer+clients+to+rebootstrap)

## TLS Certificate Configuration

When using node-specific hostnames with SNI-based routing, TLS certificates must be configured to match the hostname patterns used by clients. There are two main approaches:

### Approach 1: Wildcard Certificates (Recommended for Simplicity)

Use wildcard certificates that cover all possible node-specific hostnames:

**Certificate Subject Alternative Names (SANs):**
```
DNS:*.kafka.gateway.local
DNS:*.pod*.kafka.gateway.local
DNS:kafka.gateway.local
DNS:gateway.local
DNS:localhost
IP:127.0.0.1
```

**Benefits:**
- Single certificate works for all nodes
- Simpler certificate management
- No need to regenerate certificates when adding nodes

**Trade-offs:**
- Less granular security isolation
- Broader certificate scope

### Approach 2: Node-Specific Certificates (Enhanced Security)

Generate individual certificates for each gateway node with specific SANs:

**For Node pod0:**
```
DNS:broker0.pod0.kafka.gateway.local
DNS:broker1.pod0.kafka.gateway.local
DNS:broker2.pod0.kafka.gateway.local
DNS:kafka.gateway.local
DNS:gateway.local
```

**For Node pod1:**
```
DNS:broker0.pod1.kafka.gateway.local
DNS:broker1.pod1.kafka.gateway.local
DNS:broker2.pod1.kafka.gateway.local
DNS:kafka.gateway.local
DNS:gateway.local
```

**Benefits:**
- Better security isolation per node
- Principle of least privilege
- Easier certificate rotation per node

**Trade-offs:**
- More complex certificate management
- Need to generate certificates for each node

### Certificate Generation Commands

**For Wildcard Approach:**
```bash
# Set environment variable for wildcard support
export CERT_APPROACH=wildcard
./generate-ssl.sh
```

**For Node-Specific Approach:**
```bash
# Set environment variables for node-specific certificates
export CERT_APPROACH=node-specific
export GATEWAY_NODE_ID=pod0
export MAX_KAFKA_BROKERS=3  # Number of Kafka brokers this gateway will route to
./generate-ssl.sh
```

### Security Considerations

1. **mTLS Authentication**: All approaches support mutual TLS (mTLS) for client authentication
2. **Certificate Rotation**: Plan for regular certificate rotation (current certificates valid for 365 days)
3. **CA Security**: Protect the Certificate Authority (CA) private key (`ca.key`)
4. **Password Management**: Use secure methods to store keystore/truststore passwords in production

## DNS Configuration

If using DNS, ensure that the DNS records are set up to resolve the node-specific hostnames
correctly.

```
kafka.gateway.local -> <GATEWAY_LB_ADDRESS>
*.pod0.kafka.gateway.local -> <POD0_IP_ADDRESS>
*.pod1.kafka.gateway.local -> <POD1_IP_ADDRESS>
*.pod2.kafka.gateway.local -> <POD2_IP_ADDRESS>
```

### Host Configuration in Local Setup

Update `/etc/hosts` to include node-specific entries:

```
127.0.0.1   broker0.pod0.kafka.gateway.local broker1.pod0.kafka.gateway.local kafka.gateway.local
```