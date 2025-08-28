#!/bin/bash

# Gateway SNI-Based Routing Validation Script
# Domain: gateway.local

set -e

echo "🔍 Validating Gateway SNI-Based Routing setup..."

# Check if services are running
echo "📋 Checking service status..."
if ! docker ps --filter name=kafka-1 --format '{{.Names}}' | grep -xq kafka-1; then
    echo "❌ Kafka service (kafka-1) is not running"
    echo "💡 Run './start.sh' to start the services"
    exit 1
fi

if ! docker ps --filter name=gateway --format '{{.Names}}' | grep -xq gateway; then
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
else
    echo "✅ /etc/hosts entry found"
fi

if ! grep -q "kafka.gateway.local" /etc/hosts; then
    echo "⚠️ Missing /etc/hosts entry for kafka.gateway.local"
    echo "💡 Add this entry to /etc/hosts:"
    echo "127.0.0.1   kafka.gateway.local"
    echo ""
else
    echo "✅ kafka.gateway.local /etc/hosts entry found"
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
echo "🔄 Using bootstrap server: kafka.gateway.local:19092"

# Test connectivity with explicit error handling
set +e  # Disable exit on error for better error reporting

echo "🔍 Running connectivity test..."
DOCKER_EXEC_OUTPUT=$(docker exec kafka-1 bash -c '
    set -e
    
    echo "DEBUG: Starting connectivity test inside container"
    echo "DEBUG: Waiting 5 seconds for services to be ready..."
    sleep 5

    echo "DEBUG: Cleaning up any existing test topic..."
    kafka-topics --bootstrap-server kafka.gateway.local:19092 \
        --command-config /etc/kafka/client.properties \
        --delete --topic sni-test-topic 2>/dev/null || echo "DEBUG: No existing topic to clean"
    
    echo "DEBUG: Creating test topic..."
    kafka-topics --bootstrap-server kafka.gateway.local:19092 \
        --command-config /etc/kafka/client.properties \
        --create --topic sni-test-topic --partitions 1 --replication-factor 1 \
        --if-not-exists || {
            echo "ERROR: Failed to create topic"
            exit 1
        }
    echo "DEBUG: Test topic created successfully"

    echo "DEBUG: Producing test message..."
    TEST_MESSAGE="test-message-$(date +%s)"
    echo "$TEST_MESSAGE" | kafka-console-producer \
        --bootstrap-server kafka.gateway.local:19092 \
        --topic sni-test-topic \
        --producer.config /etc/kafka/client.properties 2>&1 || {
            echo "ERROR: Failed to produce message"
            exit 1
        }
    echo "DEBUG: Message produced successfully"

    echo "DEBUG: Consuming test message..."
    CONSUMED_MESSAGE=$(timeout 15s kafka-console-consumer \
        --bootstrap-server kafka.gateway.local:19092 \
        --topic sni-test-topic \
        --consumer.config /etc/kafka/client.properties \
        --from-beginning --max-messages 1 2>/dev/null) || {
            echo "ERROR: Failed to consume message or timeout reached"
            exit 1
        }
    
    echo "DEBUG: Consumed message: $CONSUMED_MESSAGE"
    echo "SUCCESS: Connectivity test completed successfully"
    
' 2>&1)

DOCKER_EXIT_CODE=$?

# Output the results from docker exec
echo "$DOCKER_EXEC_OUTPUT"

# Re-enable exit on error
set -e

if [ $DOCKER_EXIT_CODE -eq 0 ]; then
    echo ""
    echo "✅ Kafka connectivity through Gateway SNI routing is working!"
else
    echo ""
    echo "❌ Kafka connectivity test failed (exit code: $DOCKER_EXIT_CODE)"
    echo "💡 Debug steps:"
    echo "  1. Check service logs: docker-compose logs gateway"
    echo "  2. Check service logs: docker-compose logs kafka-1"
    echo "  3. Verify /etc/hosts entries are correct"
    echo "  4. Test direct connection: docker exec -it kafka-1 kafka-topics --bootstrap-server kafka.gateway.local:19092 --command-config /etc/kafka/client.properties --list"
    exit 1
fi

echo ""
echo "🎉 All validations passed!"
echo ""
echo "🚀 Ready to use SNI-based routing!"
echo "📋 Example usage:"
echo "  Producer: docker exec -it kafka-1 kafka-console-producer --bootstrap-server kafka.gateway.local:19092 --topic your-topic --producer.config /etc/kafka/client.properties"
echo "  Consumer: docker exec -it kafka-1 kafka-console-consumer --bootstrap-server kafka.gateway.local:19092 --topic your-topic --consumer.config /etc/kafka/client.properties"
