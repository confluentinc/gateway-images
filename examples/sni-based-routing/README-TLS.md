# TLS Configuration Guide for SNI-Based Routing

This document provides comprehensive guidance on TLS certificate configuration for multi-node gateway deployments with SNI-based routing.

## Architecture Overview

```
[Clients] → [Gateway Node pod0] ↘
                                   [Kafka Cluster: broker0, broker1, broker2...]
[Clients] → [Gateway Node pod1] ↗
```

**Key Components:**
- **Gateway Nodes**: Multiple gateway instances (pod0, pod1, pod2...) that provide SNI-based routing
- **Kafka Brokers**: Backend Kafka cluster brokers (broker0, broker1, broker2...)
- **Certificate Strategy**: Each gateway node needs certificates that cover the broker hostnames it will advertise to clients

**Hostname Pattern**: `broker$(kafkaBrokerId).$(gatewayNodeId).kafka.gateway.local`
- Example: `broker0.pod0.kafka.gateway.local`, `broker1.pod0.kafka.gateway.local`
- Each gateway node advertises all Kafka brokers with its own node ID in the hostname

## Quick Start

### Approach 1: Global Wildcard (Simplest)
```bash
# Single certificate covers ALL gateway nodes: *.kafka.gateway.local
export CERT_APPROACH=global-wildcard
./generate-ssl.sh
# Use with gateway-wildcard.yaml (pattern: broker$(nodeId).kafka.gateway.local)
```

### Approach 2: Per-Node Wildcard (Balanced)
```bash
# Each gateway node gets its own wildcard certificate: *.gw-0.kafka.gateway.local
export CERT_APPROACH=node-wildcard
export GATEWAY_NODE_ID=gw-0
./generate-ssl.sh

# Generate for additional nodes
export GATEWAY_NODE_ID=gw-1
./generate-ssl.sh
# Use with gateway-node-wildcard.yaml (pattern: broker$(nodeId).$(gatewayNodeId).kafka.gateway.local)
```

### Approach 3: Broker-Specific (Most Secure)
```bash
# Each broker on each gateway node gets explicit certificate entry
export CERT_APPROACH=broker-specific
export GATEWAY_NODE_ID=gw-0
export MAX_KAFKA_BROKERS=3  # Number of Kafka brokers this gateway will route to
./generate-ssl.sh

# Generate for additional nodes
export GATEWAY_NODE_ID=gw-1
export MAX_KAFKA_BROKERS=3
./generate-ssl.sh
# Use with gateway-node-specific.yaml (pattern: b$(nodeId).$(gatewayNodeId).kafka.gateway.local)
```

## Certificate Approaches Comparison

| Aspect | Global Wildcard | Per-Node Wildcard | Broker-Specific |
|--------|----------------|-------------------|-----------------|
| **Certificate Scope** | `*.kafka.gateway.local` | `*.gw-0.kafka.gateway.local` | `b0.gw-0.kafka.gateway.local, b1.gw-0.kafka.gateway.local` |
| **Management** | Simplest - one cert for all | Moderate - one cert per node | Complex - explicit entries |
| **Security** | Broadest scope | Node-level isolation | Maximum granularity |
| **Scalability** | Easiest to add nodes/brokers | Easy to add nodes, automatic for brokers | Need cert regeneration for new brokers |
| **Hostname Pattern** | `broker$(nodeId).kafka.gateway.local` | `broker$(nodeId).$(gatewayNodeId).kafka.gateway.local` | `b$(nodeId).$(gatewayNodeId).kafka.gateway.local` |
| **Use Case** | Simple deployments, testing | Production multi-node | High-security, compliance requirements |
| **Certificate Rotation** | Single rotation affects everything | Per-node rotation | Per-node rotation |

## Environment Variables

| Variable | Description | Default | Example |
|----------|-------------|---------|---------|
| `CERT_APPROACH` | Certificate generation approach | `global-wildcard` | `global-wildcard`, `node-wildcard`, `broker-specific` |
| `GATEWAY_NODE_ID` | Unique identifier for gateway node | `pod0` | `pod0`, `pod1`, `node-a` |
| `MAX_KAFKA_BROKERS` | Maximum number of Kafka brokers this gateway node will route to | `3` | `1`, `5`, `10` |
| `STOREPASS` | Keystore/truststore password | `confluent` | Custom password |
| `KEYPASS` | Private key password | `confluent` | Custom password |

## Configuration Files

- `gateway.yaml` - Basic single-node configuration
- `gateway-wildcard.yaml` - Global wildcard certificate approach
- `gateway-node-wildcard.yaml` - Per-node wildcard certificate approach
- `gateway-node-specific.yaml` - Broker-specific certificate approach
- `docker-compose-multi-node.yml` - Multi-node Docker Compose example

## Certificate Files Generated

| File | Description | Approach |
|------|-------------|----------|
| `ca.crt` | Certificate Authority certificate | All |
| `ca.key` | Certificate Authority private key | All |
| `gateway.crt` / `$(GATEWAY_NODE_ID).crt` | Gateway certificate | Global-wildcard / Node-wildcard, Broker-specific |
| `gateway.key` / `$(GATEWAY_NODE_ID).key` | Gateway private key | Global-wildcard / Node-wildcard, Broker-specific |
| `gateway.keystore.jks` / `$(GATEWAY_NODE_ID).keystore.jks` | Java keystore for gateway | Global-wildcard / Node-wildcard, Broker-specific |
| `gateway.truststore.jks` / `$(GATEWAY_NODE_ID).truststore.jks` | Java truststore for gateway | Global-wildcard / Node-wildcard, Broker-specific |
| `client.keystore.jks` | Java keystore for clients | All |
| `client.truststore.jks` | Java truststore for clients | All |
| `*.pwd` | Password files (gateway.*.pwd or $(GATEWAY_NODE_ID).*.pwd) | All |

## Hostname Patterns & Certificate SANs

### Global Wildcard Certificate SANs
```
*.kafka.gateway.local
kafka.gateway.local
gateway.local
```
**Supported hostnames**: `broker0.kafka.gateway.local`, `broker1.kafka.gateway.local`, etc.

### Per-Node Wildcard Certificate SANs (for gw-0)
```
*.gw-0.kafka.gateway.local
kafka.gateway.local
gateway.local
```
**Supported hostnames**: `broker0.gw-0.kafka.gateway.local`, `broker1.gw-0.kafka.gateway.local`, etc.

### Broker-Specific Certificate SANs (for gw-0 with 3 brokers)
```
b0.gw-0.kafka.gateway.local
b1.gw-0.kafka.gateway.local
b2.gw-0.kafka.gateway.local
kafka.gateway.local
gateway.local
```
**Supported hostnames**: Only the explicitly listed broker hostnames

## Testing Certificate Generation

```bash
# Test global wildcard approach
export CERT_APPROACH=global-wildcard
./generate-ssl.sh
openssl x509 -in ssl/gateway.crt -text -noout | grep -A1 "Subject Alternative Name"

# Test per-node wildcard approach
export CERT_APPROACH=node-wildcard
export GATEWAY_NODE_ID=gw-0
./generate-ssl.sh
openssl x509 -in ssl/gw-0.crt -text -noout | grep -A1 "Subject Alternative Name"

# Test broker-specific approach
export CERT_APPROACH=broker-specific
export GATEWAY_NODE_ID=gw-0
export MAX_KAFKA_BROKERS=2
./generate-ssl.sh
openssl x509 -in ssl/gw-0.crt -text -noout | grep -A1 "Subject Alternative Name"
```

## Production Considerations

### Security Best Practices
1. **Rotate certificates regularly** (current validity: 365 days)
2. **Protect CA private key** (`ca.key`) with restricted access
3. **Use strong passwords** for keystores in production
4. **Monitor certificate expiration** dates
5. **Implement automated certificate rotation**

### Scalability Considerations
1. **Wildcard certificates** scale better for dynamic environments
2. **Node-specific certificates** provide better security isolation
3. **Consider certificate management tools** for large deployments
4. **Plan for certificate distribution** in orchestrated environments

### Kubernetes Integration
```yaml
# Example ConfigMap for certificates
apiVersion: v1
kind: ConfigMap
metadata:
  name: gateway-certs
data:
  gateway.keystore.jks: |
    <base64-encoded-keystore>
  gateway.truststore.jks: |
    <base64-encoded-truststore>
---
# Example Secret for passwords
apiVersion: v1
kind: Secret
metadata:
  name: gateway-cert-passwords
type: Opaque
data:
  keystore.pwd: Y29uZmx1ZW50  # base64 encoded password
  truststore.pwd: Y29uZmx1ZW50
```

## Troubleshooting

### Common Issues

1. **Certificate doesn't match hostname**
   - Verify SAN entries in certificate match client connection hostnames
   - Check `GATEWAY_NODE_ID` matches the pattern used in client connections

2. **SSL handshake failures**
   - Ensure client has correct truststore with CA certificate
   - Verify keystore passwords are correctly configured

3. **Multi-node routing issues**
   - Check DNS resolution for node-specific hostnames
   - Verify broker identification pattern matches certificate SANs

### Debug Commands
```bash
# Check certificate details
openssl x509 -in ssl/gateway.crt -text -noout

# Test SSL connection
openssl s_client -connect kafka.gateway.local:19092 -servername broker1.pod0.kafka.gateway.local

# List keystore contents
keytool -list -v -keystore ssl/gateway.keystore.jks -storepass confluent
```

## Migration Guide

### From Single-Node to Multi-Node
1. Back up existing certificates
2. Choose certificate approach (wildcard vs node-specific)
3. Regenerate certificates with new approach
4. Update gateway configuration files
5. Test with new hostname patterns

### Certificate Rotation
1. Generate new certificates with same SANs
2. Update keystores/truststores
3. Restart gateway nodes (rolling restart for availability)
4. Update client truststores if CA changed