#!/bin/bash

# Gateway SNI-Based Routing Validation Script
# Domain: gateway.local

set -e

echo "🔍 Validating Gateway SNI-Based Routing setup..."

# Check if services are running
echo "📋 Checking service status..."
if ! docker ps | grep -q kafka-1; then
    echo "❌ Kafka service (kafka-1) is not running"
    echo "💡 Run './start.sh' to start the services"
    exit 1
fi

if ! docker ps | grep -q gateway; then
    echo "❌ Gateway service is not running"
    echo "💡 Run './start.sh' to start the services"
    exit 1
fi

echo "✅ Services are running"

# Check if SSL certificates exist
echo "📜 Checking SSL certificates..."
SSL_DIR="./ssl"
if [ ! -f "$SSL_DIR/gateway.keystore.jks" ] || [ ! -f "$SSL_DIR/client.keystore.jks" ]; then
    echo "❌ SSL certificates not found"
    echo "💡 Run './start.sh' to generate certificates"
    exit 1
fi

echo "✅ SSL certificates found"

# Check hosts file entry
echo "🌐 Checking /etc/hosts entry..."
if ! grep -q "broker1.kafka.gateway.local" /etc/hosts; then
    echo "⚠️ Missing /etc/hosts entry"
    echo "💡 Add this entry to /etc/hosts:"
    echo "127.0.0.1   broker1.kafka.gateway.local"
    echo ""
fi

# Test gateway admin endpoint
echo "🔧 Testing Gateway admin endpoint..."
if curl -s http://localhost:9190/metrics > /dev/null 2>&1; then
    echo "✅ Gateway admin endpoint is accessible"
else
    echo "⚠️ Gateway admin endpoint not accessible (may still be starting up)"
fi

# Create test topic and validate connectivity
echo "📡 Testing Kafka connectivity through Gateway..."
docker exec kafka-1 bash -c '
    # Wait a bit for services to be fully ready
    sleep 5
    
    # Create test topic
    kafka-topics --bootstrap-server broker1.kafka.gateway.local:19092 \
        --command-config /etc/kafka/client.properties \
        --create --topic sni-test --partitions 1 --replication-factor 1 \
        --if-not-exists > /dev/null 2>&1

    # Test producer (send a test message)
    echo "test-message-$(date +%s)" | kafka-console-producer \
        --bootstrap-server broker1.kafka.gateway.local:19092 \
        --topic sni-test \
        --producer.config /etc/kafka/client.properties > /dev/null 2>&1

    # Test consumer (read the message back)
    timeout 10s kafka-console-consumer \
        --bootstrap-server broker1.kafka.gateway.local:19092 \
        --topic sni-test \
        --consumer.config /etc/kafka/client.properties \
        --from-beginning --max-messages 1 > /dev/null 2>&1
'

if [ $? -eq 0 ]; then
    echo "✅ Kafka connectivity through Gateway SNI routing is working!"
else
    echo "❌ Kafka connectivity test failed"
    echo "💡 Check service logs: docker-compose logs gateway"
    exit 1
fi

echo ""
echo "🎉 All validations passed!"
echo ""
echo "🚀 Ready to use SNI-based routing!"
echo "📋 Example usage:"
echo "  Producer: docker exec -it kafka-1 kafka-console-producer --bootstrap-server broker1.kafka.gateway.local:19092 --topic your-topic --producer.config /etc/kafka/client.properties"
echo "  Consumer: docker exec -it kafka-1 kafka-console-consumer --bootstrap-server broker1.kafka.gateway.local:19092 --topic your-topic --consumer.config /etc/kafka/client.properties"
