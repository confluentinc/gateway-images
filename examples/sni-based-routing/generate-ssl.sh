#!/bin/bash

# SSL Certificate Generation Script for Gateway SNI-Based Routing
# This script runs inside the Docker container to generate SSL certificates

set -euo pipefail

SSL_DIR="/ssl"
STOREPASS="${STOREPASS:-confluent}"
KEYPASS="${KEYPASS:-confluent}"

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
    "DNS:gateway.local,DNS:broker1.kafka.gateway.local,DNS:kafka.gateway.local,DNS:host.docker.internal,DNS:localhost,IP:127.0.0.1"

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
