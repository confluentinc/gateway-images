#!/bin/bash
# Gateway Image Sanity Tests using simple-passthrough-example
# Usage: ./scripts/sanity-test.sh <image_name> [timeout]
#
# This script validates a built gateway image by:
# 1. Starting the simple-passthrough-example docker-compose with the specified image
# 2. Waiting for the gateway health endpoint to respond
# 3. Cleaning up all containers
#
# Exit codes:
#   0 - Success (health endpoint responded)
#   1 - Failure (timeout or error)

set -e

IMAGE=$1
TIMEOUT=${2:-90}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="$REPO_ROOT/examples/simple-passthrough-example"
HEALTH_URL="http://localhost:9190/livez"

if [ -z "$IMAGE" ]; then
    echo "❌ Usage: $0 <image_name> [timeout]"
    echo ""
    echo "Arguments:"
    echo "  image_name  - Docker image to test (e.g., confluentinc/cpc-gateway:dev-master-123)"
    echo "  timeout     - Max seconds to wait for health endpoint (default: 90)"
    echo ""
    echo "Example:"
    echo "  $0 confluentinc/cpc-gateway:dev-master-latest-ubi9"
    exit 1
fi

echo "🧪 Gateway Sanity Test"
echo "======================"
echo "📦 Image: $IMAGE"
echo "📁 Compose: $COMPOSE_DIR"
echo "⏱️  Timeout: ${TIMEOUT}s"
echo ""

cleanup() {
    echo ""
    echo " Cleaning up..."
    cd "$COMPOSE_DIR" 2>/dev/null && docker compose down -v 2>/dev/null || true
}
trap cleanup EXIT

# Verify compose directory exists
if [ ! -d "$COMPOSE_DIR" ]; then
    echo "❌ Compose directory not found: $COMPOSE_DIR"
    exit 1
fi

if [ ! -f "$COMPOSE_DIR/docker-compose.yaml" ]; then
    echo "❌ docker-compose.yaml not found in: $COMPOSE_DIR"
    exit 1
fi

# Navigate to compose directory
cd "$COMPOSE_DIR"

# Start services with the built image
echo " Starting services with GATEWAY_IMAGE=$IMAGE"
export GATEWAY_IMAGE="$IMAGE"
docker compose up -d

# Wait for gateway health endpoint
echo "⏳ Waiting for gateway health endpoint..."
for i in $(seq 1 $TIMEOUT); do
    if curl -sf "$HEALTH_URL" > /dev/null 2>&1; then
        echo ""
        echo "✅ Gateway healthy after ${i}s"
        echo ""
        echo "📋 Health response:"
        curl -s "$HEALTH_URL" | head -20
        echo ""
        echo ""
        echo "✅ Sanity test PASSED for $IMAGE"
        exit 0
    fi
    
    # Show progress every 10 seconds
    if [ $((i % 10)) -eq 0 ]; then
        echo "   ... waiting ${i}s"
    fi
    
    sleep 1
done

# Timeout reached - failure
echo ""
echo "❌ Gateway failed to become healthy within ${TIMEOUT}s"
echo ""
echo "📋 Gateway container logs:"
echo "=========================="
docker compose logs gateway
echo ""
exit 1

