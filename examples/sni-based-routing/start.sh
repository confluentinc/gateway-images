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
patterns=( "*.jks" "*.pwd" "*.key" "*.crt" "*.csr" "*.p12" "*.ext" "*.srl" )
for pattern in "${patterns[@]}"; do
  rm -f "${SSL_DIR}/${pattern}"
done

# Make sure the SSL generation script is executable
chmod +x "${SCRIPT_DIR}/generate-ssl.sh"

echo "📜 Generating TLS artifacts under ${SSL_DIR}..."
docker run --rm -u 1000:1000 \
  -v "${SSL_DIR}:/ssl" \
  -v "${SCRIPT_DIR}/generate-ssl.sh:/usr/local/bin/generate-ssl.sh" \
  -e STOREPASS="${STOREPASS}" \
  -e KEYPASS="${KEYPASS}" \
  confluentinc/cp-server:latest \
  bash -c "chmod +x /usr/local/bin/generate-ssl.sh && /usr/local/bin/generate-ssl.sh"

cd "${SCRIPT_DIR}"

echo "🐳 Starting Kafka and Gateway services..."
docker-compose up --no-recreate -d kafka-1 gateway

echo ""
echo "🎉 SNI-Based Routing setup completed successfully!"
echo ""
echo "📋 Next steps:"
echo "1. Add to /etc/hosts: 127.0.0.1 broker1.kafka.gateway.local kafka.gateway.local"
echo "2. Wait for services to start (~30-60 seconds)"
echo "3. Validate setup: ./validate.sh"
echo "4. Test with: docker exec -it kafka-1 kafka-console-producer --bootstrap-server kafka.gateway.local:19092 --topic test --producer.config /etc/kafka/client.properties"
echo ""
echo "🔐 Authentication details:"
echo "  SASL Username: admin"
echo "  SASL Password: admin-secret"
echo "  SSL: Mutual TLS enabled"
echo ""
echo "🌐 Connection details:"
echo "  Gateway Bootstrap Server: kafka.gateway.local:19092"
echo "  Gateway SNI Endpoint: broker1.kafka.gateway.local:19092"
echo "  Kafka Internal: kafka-1:44444"
echo "  Gateway Admin: localhost:9190/metrics"
echo ""
echo "📁 Generated certificates in: ${SSL_DIR}/"
echo "🔧 Use client.properties for SSL/SASL configuration"
