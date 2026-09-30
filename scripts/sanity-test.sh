#!/bin/bash
# Gateway Image Sanity Tests
# Usage: ./scripts/sanity-test.sh <image_name> [timeout]
#
# Validates a built gateway Docker image in two phases:
# 1. Structure checks — verifies required files, binaries, permissions, and
#    script wiring exist in the image (fast, no services needed)
# 2. Health check — starts docker-compose and waits for /livez
#
# Exit codes:
#   0 - All checks passed
#   1 - One or more checks failed

set -e

IMAGE=$1
TIMEOUT=${2:-90}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="$REPO_ROOT/examples/simple-passthrough-example"
HEALTH_URL="http://localhost:9190/livez"

if [ -z "$IMAGE" ]; then
    echo "Usage: $0 <image_name> [timeout]"
    echo ""
    echo "Arguments:"
    echo "  image_name  - Docker image to test (e.g., confluentinc/cpc-gateway:dev-master-123)"
    echo "  timeout     - Max seconds to wait for health endpoint (default: 90)"
    echo ""
    echo "Example:"
    echo "  $0 confluentinc/cpc-gateway:dev-master-latest-ubi9"
    exit 1
fi

echo "Gateway Sanity Test"
echo "==================="
echo "Image: $IMAGE"
echo "Timeout: ${TIMEOUT}s"
echo ""

# ── Phase 1: Image structure checks ──────────────────────────────────────────

STRUCT_FAIL=0

check() {
    local description="$1"
    local cmd="$2"
    if docker run --rm --entrypoint="" "$IMAGE" sh -c "$cmd" > /dev/null 2>&1; then
        echo "  PASS  $description"
    else
        echo "  FAIL  $description"
        STRUCT_FAIL=$((STRUCT_FAIL + 1))
    fi
}

check_output() {
    local description="$1"
    local cmd="$2"
    local expected="$3"
    actual=$(docker run --rm --entrypoint="" "$IMAGE" sh -c "$cmd" 2>/dev/null || true)
    if echo "$actual" | grep -qF "$expected"; then
        echo "  PASS  $description"
    else
        echo "  FAIL  $description (expected '$expected', got '$actual')"
        STRUCT_FAIL=$((STRUCT_FAIL + 1))
    fi
}

echo "Image structure checks:"

check "bash-config exists"              "test -f /etc/confluent/docker/bash-config"
check "configure exists and executable" "test -x /etc/confluent/docker/configure"
check "run exists and executable"       "test -x /etc/confluent/docker/run"
check "configure sources bash-config"   "grep -q '. /etc/confluent/docker/bash-config' /etc/confluent/docker/configure"
check "run invokes configure"           "grep -q '/etc/confluent/docker/configure' /etc/confluent/docker/run"
check "run invokes gateway-start"       "grep -q '/usr/bin/gateway-start' /etc/confluent/docker/run"

check "/usr/bin/ub exists"              "test -x /usr/bin/ub"
check "/usr/bin/gateway-start exists"   "test -x /usr/bin/gateway-start"
check "java is available"               "java -version"

check_output "runs as UID 1000"         "id -u" "1000"
check_output "COMPONENT=gateway"        "printenv COMPONENT" "gateway"

cmd=$(docker inspect --format='{{join .Config.Cmd " "}}' "$IMAGE" 2>/dev/null || true)
if [ "$cmd" = "/etc/confluent/docker/run" ]; then
    echo "  PASS  CMD is /etc/confluent/docker/run"
else
    echo "  FAIL  CMD (expected '/etc/confluent/docker/run', got '$cmd')"
    STRUCT_FAIL=$((STRUCT_FAIL + 1))
fi

echo ""

if [ "$STRUCT_FAIL" -gt 0 ]; then
    echo "FAILED — $STRUCT_FAIL structure check(s) did not pass"
    exit 1
fi

echo "All structure checks passed."
echo ""

# ── Phase 2: Health check via docker-compose ─────────────────────────────────

cleanup() {
    echo ""
    echo "Cleaning up..."
    cd "$COMPOSE_DIR" 2>/dev/null && docker compose down -v 2>/dev/null || true
}
trap cleanup EXIT

if [ ! -d "$COMPOSE_DIR" ] || [ ! -f "$COMPOSE_DIR/docker-compose.yaml" ]; then
    echo "docker-compose.yaml not found in: $COMPOSE_DIR"
    exit 1
fi

cd "$COMPOSE_DIR"

echo "Starting services with GATEWAY_IMAGE=$IMAGE"
export GATEWAY_IMAGE="$IMAGE"
docker compose up -d

echo "Waiting for gateway health endpoint..."
for i in $(seq 1 $TIMEOUT); do
    if curl -sf "$HEALTH_URL" > /dev/null 2>&1; then
        echo ""
        echo "Gateway healthy after ${i}s"
        echo ""
        echo "Sanity test PASSED for $IMAGE"
        exit 0
    fi

    if [ $((i % 10)) -eq 0 ]; then
        echo "   ... waiting ${i}s"
    fi

    sleep 1
done

echo ""
echo "Gateway failed to become healthy within ${TIMEOUT}s"
echo ""
echo "Gateway container logs:"
echo "=========================="
docker compose logs gateway
echo ""
exit 1

