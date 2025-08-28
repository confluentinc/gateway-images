#!/bin/bash

# Gateway SNI-Based Routing Cleanup Script
# Domain: gateway.local

set -e

echo "🧹 Cleaning up Gateway SNI-Based Routing setup..."

# Stop and remove containers
echo "🛑 Stopping services..."
docker-compose down -v --remove-orphans 2>/dev/null || true

# Remove SSL certificates
echo "🗑️ Removing SSL certificates..."
rm -rf ssl/

# Remove any leftover containers
echo "🐳 Cleaning up containers..."
docker container rm -f kafka-1 gateway 2>/dev/null || true

# Clean up Docker networks
echo "🌐 Cleaning up networks..."
docker network rm sni-based-routing_confluent-local-network 2>/dev/null || true

echo ""
echo "✅ Cleanup completed!"
echo ""
echo "💡 To remove /etc/hosts entry manually run:"
echo "sudo sed -i '' '/broker1.kafka.gateway.local/d' /etc/hosts"
echo "sudo sed -i '' '/kafka.gateway.local/d' /etc/hosts"
echo ""
echo "🚀 Run './start.sh' to set up again"
