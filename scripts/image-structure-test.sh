#!/bin/bash
# Gateway Docker Image Structure Tests
# Usage: ./scripts/image-structure-test.sh <image_name>
#
# Validates the internal structure of a built gateway Docker image without
# starting any services. Catches regressions like missing files, wrong
# permissions, or absent binaries that the sanity test (health-check) cannot.
#
# Exit codes:
#   0 - All checks passed
#   1 - One or more checks failed

set -euo pipefail

IMAGE=$1

if [ -z "$IMAGE" ]; then
    echo "Usage: $0 <image_name>"
    echo ""
    echo "Example:"
    echo "  $0 confluentinc/cpc-gateway:dev-master-latest-ubi9"
    exit 1
fi

PASS=0
FAIL=0

check() {
    local description="$1"
    local cmd="$2"

    if docker run --rm --entrypoint="" "$IMAGE" sh -c "$cmd" > /dev/null 2>&1; then
        echo "  PASS  $description"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $description"
        FAIL=$((FAIL + 1))
    fi
}

check_output() {
    local description="$1"
    local cmd="$2"
    local expected="$3"

    actual=$(docker run --rm --entrypoint="" "$IMAGE" sh -c "$cmd" 2>/dev/null || true)
    if echo "$actual" | grep -qF "$expected"; then
        echo "  PASS  $description"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $description (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

echo "Gateway Image Structure Test"
echo "============================="
echo "Image: $IMAGE"
echo ""

# --- Required files in /etc/confluent/docker/ ---
echo "Required files:"
check "/etc/confluent/docker/bash-config exists"   "test -f /etc/confluent/docker/bash-config"
check "/etc/confluent/docker/configure exists"      "test -f /etc/confluent/docker/configure"
check "/etc/confluent/docker/run exists"            "test -f /etc/confluent/docker/run"
check "/etc/confluent/docker/README.md exists"      "test -f /etc/confluent/docker/README.md"
check "/etc/confluent/docker/single-route-plaintext-passthrough.yaml.template exists" \
      "test -f /etc/confluent/docker/single-route-plaintext-passthrough.yaml.template"
echo ""

# --- File permissions ---
echo "File permissions:"
check "/etc/confluent/docker/run is executable"       "test -x /etc/confluent/docker/run"
check "/etc/confluent/docker/configure is executable"  "test -x /etc/confluent/docker/configure"
echo ""

# --- Required binaries ---
echo "Required binaries:"
check "/usr/bin/ub exists"            "test -x /usr/bin/ub"
check "/usr/bin/gateway-start exists" "test -x /usr/bin/gateway-start"
check "java is available"             "java -version"
echo ""

# --- User and permissions ---
echo "User configuration:"
check_output "runs as UID 1000" "id -u" "1000"
check_output "runs as GID 1000" "id -g" "1000"
echo ""

# --- Required directories ---
echo "Required directories:"
check "/var/lib/gateway/data exists"    "test -d /var/lib/gateway/data"
check "/etc/gateway/secrets exists"     "test -d /etc/gateway/secrets"
check "/usr/logs exists"                "test -d /usr/logs"
check "/etc/confluent/docker exists"    "test -d /etc/confluent/docker"
echo ""

# --- Writable directories ---
echo "Writable directories:"
check "/var/lib/gateway/data is writable"  "test -w /var/lib/gateway/data"
check "/etc/gateway/secrets is writable"   "test -w /etc/gateway/secrets"
check "/usr/logs is writable"              "test -w /usr/logs"
echo ""

# --- Environment variables ---
echo "Environment variables:"
check_output "COMPONENT=gateway"  "printenv COMPONENT"  "gateway"
check_output "LANG=C.UTF-8"      "printenv LANG"        "C.UTF-8"
echo ""

# --- License file ---
echo "License:"
check "/licenses/license.txt exists" "test -f /licenses/license.txt"
echo ""

# --- Labels ---
echo "Labels:"
io_confluent_docker=$(docker inspect --format='{{index .Config.Labels "io.confluent.docker"}}' "$IMAGE" 2>/dev/null || true)
if [ "$io_confluent_docker" = "true" ]; then
    echo "  PASS  io.confluent.docker=true"
    PASS=$((PASS + 1))
else
    echo "  FAIL  io.confluent.docker label (expected 'true', got '$io_confluent_docker')"
    FAIL=$((FAIL + 1))
fi

git_repo=$(docker inspect --format='{{index .Config.Labels "io.confluent.docker.git.repo"}}' "$IMAGE" 2>/dev/null || true)
if [ "$git_repo" = "confluentinc/gateway-images" ]; then
    echo "  PASS  io.confluent.docker.git.repo=confluentinc/gateway-images"
    PASS=$((PASS + 1))
else
    echo "  FAIL  io.confluent.docker.git.repo label (expected 'confluentinc/gateway-images', got '$git_repo')"
    FAIL=$((FAIL + 1))
fi
echo ""

# --- configure sources bash-config (the actual regression that prompted this ticket) ---
echo "Script integrity:"
check "configure sources bash-config" "grep -q '. /etc/confluent/docker/bash-config' /etc/confluent/docker/configure"
check "run invokes configure"         "grep -q '/etc/confluent/docker/configure' /etc/confluent/docker/run"
check "run invokes gateway-start"     "grep -q '/usr/bin/gateway-start' /etc/confluent/docker/run"
echo ""

# --- CMD ---
echo "Entrypoint:"
cmd=$(docker inspect --format='{{join .Config.Cmd " "}}' "$IMAGE" 2>/dev/null || true)
if [ "$cmd" = "/etc/confluent/docker/run" ]; then
    echo "  PASS  CMD is /etc/confluent/docker/run"
    PASS=$((PASS + 1))
else
    echo "  FAIL  CMD (expected '/etc/confluent/docker/run', got '$cmd')"
    FAIL=$((FAIL + 1))
fi
echo ""

# --- Summary ---
TOTAL=$((PASS + FAIL))
echo "============================="
echo "Results: $PASS/$TOTAL passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "FAILED - $FAIL check(s) did not pass"
    exit 1
fi

echo ""
echo "All structure checks passed for $IMAGE"
exit 0
