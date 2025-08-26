#!/bin/bash

# Gateway SNI-Based Routing Example Setup
# Domain: gateway.local

set -euo pipefail

echo "🚀 Setting up Gateway SNI-Based Routing with TLS mutual authentication..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSL_DIR="${SCRIPT_DIR}/ssl"
STOREPASS="confluent"
KEYPASS="confluent"

# Create SSL directory
mkdir -p "${SSL_DIR}"

# Clean up existing certificates
echo "🧹 Cleaning up existing certificates..."
rm -f "${SSL_DIR}"/*.jks "${SSL_DIR}"/*.pwd "${SSL_DIR}"/*.key "${SSL_DIR}"/*.crt "${SSL_DIR}"/*.csr "${SSL_DIR}"/*.p12 "${SSL_DIR}"/*.ext "${SSL_DIR}"/*.srl

echo "📜 Generating TLS artifacts under ${SSL_DIR}..."
docker run --rm -u 0:0 -v "${SSL_DIR}:/ssl" confluentinc/cp-server:latest bash -lc '
    set -euo pipefail
    SSL_DIR="/ssl"
    STOREPASS="'"${STOREPASS}"'"
    KEYPASS="'"${KEYPASS}"'"
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

    # Generate gateway identity with meaningful SNI domains
    # SANs must match how clients connect for SNI-based routing
    gen_identity "gateway" "gateway.local" \
        "DNS:gateway.local,DNS:broker1.kafka.gateway.local,DNS:host.docker.internal,DNS:localhost,IP:127.0.0.1"
    
    # Generate client identity
    gen_identity "client" "client.gateway.local" \
        "DNS:client.gateway.local,DNS:client,DNS:localhost"

    echo "📝 Creating password files..."
    printf "%s" "$STOREPASS" > gateway.keystore.pwd
    printf "%s" "$KEYPASS" > gateway.key.pwd
    printf "%s" "$STOREPASS" > gateway.truststore.pwd

    echo "🔒 Setting secure permissions..."
    chmod 600 \
      gateway.keystore.jks gateway.truststore.jks client.keystore.jks client.truststore.jks \
      gateway.keystore.pwd gateway.key.pwd gateway.truststore.pwd ca.key *.key || true
    
    chmod 644 ca.crt *.crt || true

    echo "✅ TLS artifacts generated successfully!"
  '

cd "${SCRIPT_DIR}"

echo "🐳 Starting Kafka and Gateway services..."
docker-compose up --no-recreate -d kafka-1 gateway

echo ""
echo "🎉 SNI-Based Routing setup completed successfully!"
echo ""
echo "📋 Next steps:"
echo "1. Add to /etc/hosts: 127.0.0.1 broker1.kafka.gateway.local"
echo "2. Wait for services to start (~30-60 seconds)"
echo "3. Test with: docker exec -it kafka-1 kafka-console-producer --bootstrap-server broker1.kafka.gateway.local:19092 --topic test --producer.config /etc/kafka/client.properties"
echo ""
echo "🔐 Authentication details:"
echo "  SASL Username: admin"
echo "  SASL Password: admin-secret"
echo "  SSL: Mutual TLS enabled"
echo ""
echo "🌐 Connection details:"
echo "  Gateway SNI Endpoint: broker1.kafka.gateway.local:19092"
echo "  Kafka Internal: kafka-1:44444"
echo "  Gateway Admin: localhost:9190/metrics"
echo ""
echo "📁 Generated certificates in: ${SSL_DIR}/"
echo "🔧 Use client.properties for SSL/SASL configuration"