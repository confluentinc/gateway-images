#!/bin/bash

# SSL Certificate Generation Script for Gateway SNI-Based Routing
# This script runs inside the Docker container to generate SSL certificates
# Supports both wildcard and node-specific certificate generation approaches

set -euo pipefail

SSL_DIR="/ssl"
STOREPASS="${STOREPASS:-confluent}"
KEYPASS="${KEYPASS:-confluent}"

# Certificate generation approach: global-wildcard, node-wildcard, or broker-specific
CERT_APPROACH="${CERT_APPROACH:-global-wildcard}"
GATEWAY_NODE_ID="${GATEWAY_NODE_ID:-pod0}"
# Maximum number of Kafka brokers this gateway node will route to
MAX_KAFKA_BROKERS="${MAX_KAFKA_BROKERS:-3}"

cd "$SSL_DIR"

echo "🏛️ Creating Certificate Authority for gateway.local domain..."
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 365 \
    -subj "/C=US/ST=CA/L=San Francisco/O=Gateway Demo/OU=Engineering/CN=Gateway Local CA" \
    -out ca.crt

gen_identity() {
  local name="$1" alias="$2" sans="$3"
  echo "🔐 Generating identity for ${name} (${alias})..."
  
  # Generate private key
  openssl genrsa -out "${name}.key" 2048
  
  # Create certificate signing request
  openssl req -new -key "${name}.key" \
      -subj "/C=US/ST=CA/L=San Francisco/O=Gateway Demo/OU=Engineering/CN=${alias}" \
      -out "${name}.csr"
  
  # Create extension file with SAN
  printf "subjectAltName=%s\n" "${sans}" > "${name}.ext"
  
  # Sign certificate with CA
  openssl x509 -req -in "${name}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out "${name}.crt" -days 365 -sha256 -extfile "${name}.ext"
  
  # Create PKCS12 keystore
  openssl pkcs12 -export -name "${alias}" -in "${name}.crt" -inkey "${name}.key" \
    -out "${name}.p12" -passout pass:"$STOREPASS"
  
  # Convert to JKS keystore
  keytool -importkeystore \
    -deststorepass "$STOREPASS" -destkeypass "$KEYPASS" -destkeystore "${name}.keystore.jks" \
    -srckeystore "${name}.p12" -srcstoretype PKCS12 -srcstorepass "$STOREPASS" -alias "${alias}"
  
  # Create truststore with CA certificate
  keytool -import -trustcacerts -noprompt -alias gateway-local-ca -file ca.crt \
    -keystore "${name}.truststore.jks" -storepass "$STOREPASS"
}

# Function to generate gateway SANs based on approach
generate_gateway_sans() {
    local base_sans="DNS:gateway.local,DNS:kafka.gateway.local,DNS:host.docker.internal,DNS:localhost,IP:127.0.0.1"

    case "$CERT_APPROACH" in
        "global-wildcard")
            echo "🌍 Using global wildcard certificate approach"
            echo "${base_sans},DNS:*.kafka.gateway.local"
            ;;
        "node-wildcard")
            echo "🏷️ Using per-node wildcard certificate approach for node: ${GATEWAY_NODE_ID}"
            echo "${base_sans},DNS:*.${GATEWAY_NODE_ID}.kafka.gateway.local,DNS:kafka.gateway.local"
            ;;
        "broker-specific")
            echo "🎯 Using broker-specific certificate approach for node: ${GATEWAY_NODE_ID}"
            local broker_sans=""
            for ((i=0; i<MAX_KAFKA_BROKERS; i++)); do
                if [[ -n "$broker_sans" ]]; then
                    broker_sans="${broker_sans},"
                fi
                broker_sans="${broker_sans}DNS:b${i}.${GATEWAY_NODE_ID}.kafka.gateway.local"
            done
            echo "${base_sans},${broker_sans}"
            ;;
        *)
            echo "❌ Invalid CERT_APPROACH: ${CERT_APPROACH}"
            echo "Valid options: 'global-wildcard', 'node-wildcard', 'broker-specific'"
            exit 1
            ;;
    esac
}

# Generate gateway identity with appropriate SANs
gateway_sans=$(generate_gateway_sans)
echo "📋 Gateway certificate will include SANs: ${gateway_sans}"

case "$CERT_APPROACH" in
    "global-wildcard")
        # Generate standard gateway identity for global wildcard approach
        gen_identity "gateway" "gateway.local" "${gateway_sans}"
        ;;
    "node-wildcard"|"broker-specific")
        # Generate node-specific certificate files
        echo "🔐 Generating node-specific identity for ${GATEWAY_NODE_ID}..."
        gen_identity "${GATEWAY_NODE_ID}" "gateway.local" "${gateway_sans}"

        # Create symlinks for backward compatibility with generic names
        ln -sf "${GATEWAY_NODE_ID}.keystore.jks" gateway.keystore.jks
        ln -sf "${GATEWAY_NODE_ID}.truststore.jks" gateway.truststore.jks

        # Create node-specific password files
        printf "%s" "$STOREPASS" > "${GATEWAY_NODE_ID}.keystore.pwd"
        printf "%s" "$KEYPASS" > "${GATEWAY_NODE_ID}.key.pwd"
        printf "%s" "$STOREPASS" > "${GATEWAY_NODE_ID}.truststore.pwd"
        ;;
esac

# Generate client identity
gen_identity "client" "client.gateway.local" \
    "DNS:client.gateway.local,DNS:client,DNS:localhost"

if [[ "$CERT_APPROACH" == "global-wildcard" ]]; then
    echo "📝 Creating password files..."
    printf "%s" "$STOREPASS" > gateway.keystore.pwd
    printf "%s" "$KEYPASS" > gateway.key.pwd
    printf "%s" "$STOREPASS" > gateway.truststore.pwd
fi

echo "🔒 Setting secure permissions..."
chmod 600 \
  *.keystore.jks *.truststore.jks client.keystore.jks client.truststore.jks \
  *.keystore.pwd *.key.pwd *.truststore.pwd ca.key *.key 2>/dev/null || true

chmod 644 ca.crt *.crt 2>/dev/null || true

echo "✅ TLS artifacts generated successfully!"
echo "🔧 Certificate approach: ${CERT_APPROACH}"
case "$CERT_APPROACH" in
    "global-wildcard")
        echo "🌍 Global wildcard certificate covers: *.kafka.gateway.local"
        ;;
    "node-wildcard")
        echo "🏷️  Node ID: ${GATEWAY_NODE_ID}"
        echo "🎯 Node wildcard certificate covers: *.${GATEWAY_NODE_ID}.kafka.gateway.local"
        echo "📁 Node-specific files created with prefix: ${GATEWAY_NODE_ID}"
        ;;
    "broker-specific")
        echo "🏷️  Node ID: ${GATEWAY_NODE_ID}"
        echo "🔢 Max Kafka brokers: ${MAX_KAFKA_BROKERS}"
        echo "🎯 Broker-specific certificates cover: b0.${GATEWAY_NODE_ID}.kafka.gateway.local, b1.${GATEWAY_NODE_ID}.kafka.gateway.local, ..."
        echo "📁 Node-specific files created with prefix: ${GATEWAY_NODE_ID}"
        ;;
esac
echo ""
echo "📂 Generated files:"
ls -la *.jks *.pwd *.crt *.key 2>/dev/null || true
