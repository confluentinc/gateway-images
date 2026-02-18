#!/bin/bash
# librdkafka-version-compatibility.sh
# Tests confluent-kafka-python (librdkafka) client versions against Kafka server versions
# through the Confluent Gateway.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GATEWAY_METRICS="http://localhost:9190/metrics"
RESULTS_DIR="$PARENT_DIR/compatibility-results/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

# All 14 minor versions of confluent-kafka-python (latest patch each)
CLIENTS=("2.0.2" "2.1.1" "2.2.0" "2.3.0" "2.4.0" "2.5.3" "2.6.2" "2.7.0" "2.8.2" "2.9.0" "2.10.1" "2.11.1" "2.12.2" "2.13.0")
SERVERS=("7.4.0" "7.5.0" "7.6.0" "7.7.0" "7.8.0" "7.9.0" "8.0.0")

version_ge() {  # $1 >= $2 ?
    [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

# =============================================================================
# SSL CERTIFICATE GENERATION (reuse from parent directory)
# =============================================================================

ensure_ssl_certificates() {
    if [ ! -d "$PARENT_DIR/ssl" ] || [ ! -f "$PARENT_DIR/ssl/kafka.keystore.jks" ]; then
        echo "Generating SSL certificates..."
        mkdir -p "$PARENT_DIR/ssl"
        cd "$PARENT_DIR/ssl"

        KEYSTORE_PASSWORD="confluent"
        TRUSTSTORE_PASSWORD="confluent"
        KEY_PASSWORD="confluent"
        VALIDITY_DAYS=365

        echo "$KEYSTORE_PASSWORD" > keystore_creds
        echo "$TRUSTSTORE_PASSWORD" > truststore_creds
        echo "$KEY_PASSWORD" > key_creds

        openssl req -new -x509 -keyout ca-key -out ca-cert -days $VALIDITY_DAYS \
            -subj "/CN=kafka-ca" -passout pass:$KEY_PASSWORD

        keytool -keystore kafka.truststore.jks -alias CARoot -import -file ca-cert \
            -storepass $TRUSTSTORE_PASSWORD -noprompt

        keytool -keystore kafka.keystore.jks -alias kafka-server -validity $VALIDITY_DAYS \
            -genkey -keyalg RSA -keysize 2048 -storepass $KEYSTORE_PASSWORD \
            -keypass $KEY_PASSWORD -dname "CN=kafka-server,OU=Test,O=Confluent,L=CA,S=CA,C=US"

        keytool -keystore kafka.keystore.jks -alias kafka-server -certreq -file cert-file \
            -storepass $KEYSTORE_PASSWORD

        openssl x509 -req -CA ca-cert -CAkey ca-key -in cert-file -out cert-signed \
            -days $VALIDITY_DAYS -CAcreateserial -passin pass:$KEY_PASSWORD

        keytool -keystore kafka.keystore.jks -alias CARoot -import -file ca-cert \
            -storepass $KEYSTORE_PASSWORD -noprompt

        keytool -keystore kafka.keystore.jks -alias kafka-server -import -file cert-signed \
            -storepass $KEYSTORE_PASSWORD -noprompt

        cd "$SCRIPT_DIR"
        echo "SSL certificates generated in $PARENT_DIR/ssl/"
    fi
}

# =============================================================================
# PYTHON ENVIRONMENT SETUP (for metrics parsing)
# =============================================================================

setup_python_env() {
    echo "Setting up Python environment for metrics parsing..."
    if ! command -v python3 &> /dev/null; then
        echo "Python 3 is required but not installed"
        exit 1
    fi
    if [ ! -d "$PARENT_DIR/venv" ]; then
        python3 -m venv "$PARENT_DIR/venv"
    fi
    source "$PARENT_DIR/venv/bin/activate"
    pip install --upgrade pip
    if [ -f "$PARENT_DIR/requirements.txt" ]; then
        pip install -r "$PARENT_DIR/requirements.txt"
    fi
    echo "Python environment ready"
}

# =============================================================================
# RUN SINGLE COMPATIBILITY TEST
# =============================================================================

run_compatibility_test() {
    local client_ver=$1
    local server_ver=$2
    local test_id="librdkafka${client_ver}_server${server_ver}"

    echo ""
    echo "============================================"
    echo "Testing: librdkafka ${client_ver} with Kafka Server ${server_ver}"
    echo "Test ID: $test_id"
    echo "============================================"

    ensure_ssl_certificates

    export LIBRDKAFKA_CLIENT_VERSION="$client_ver"
    export KAFKA_SERVER_VERSION="$server_ver"

    # Set up result directories
    mkdir -p "$RESULTS_DIR/${test_id}_junit"
    mkdir -p "$RESULTS_DIR/${test_id}_html"

    JUNIT_RESULTS_DIR="$RESULTS_DIR/${test_id}_junit"
    HTML_RESULTS_DIR="$RESULTS_DIR/${test_id}_html"

    # Choose compose file based on server version
    if version_ge "$server_ver" "8.0.0"; then
        echo "Starting Kafka in KRaft mode..."
        COMPOSE_FILE="docker-compose-librdkafka-kraft.yml"
    else
        COMPOSE_FILE="docker-compose-librdkafka.yml"
    fi

    if ! docker-compose -f "$COMPOSE_FILE" up -d --build; then
        echo "SETUP_FAILED: Docker compose failed to start services" > "$RESULTS_DIR/${test_id}_status.txt"
        echo "FAILURE_TYPE: DOCKER_COMPOSE_FAILED" >> "$RESULTS_DIR/${test_id}_status.txt"
        echo "TIMESTAMP: $(date -Iseconds)" >> "$RESULTS_DIR/${test_id}_status.txt"
        return 1
    fi

    # Verify gateway is up
    echo "Verifying gateway connectivity..."
    if ! curl -s "$GATEWAY_METRICS" > /dev/null; then
        echo "SETUP_FAILED: Gateway not responding" > "$RESULTS_DIR/${test_id}_status.txt"
        echo "FAILURE_TYPE: GATEWAY_NOT_RESPONDING" >> "$RESULTS_DIR/${test_id}_status.txt"
        echo "TIMESTAMP: $(date -Iseconds)" >> "$RESULTS_DIR/${test_id}_status.txt"
        docker-compose -f "$COMPOSE_FILE" down -v
        return 1
    fi

    echo "Running test suite..."

    OVERALL_EXIT_CODE=0

    # Disable errexit so we can capture exit codes from each test run
    set +e

    # Test 1: PLAINTEXT
    echo "--- PLAINTEXT (gateway:19092) ---"
    docker exec librdkafka-client-test bash -c "
        cd /tests &&
        BOOTSTRAP_SERVERS=gateway:19092 \
        pytest test_librdkafka_compatibility.py \
            --junitxml=/junit-results/plaintext/results.xml \
            --html=/html-results/plaintext/report.html --self-contained-html \
            --timeout=90 \
            -v
    "
    PLAINTEXT_EXIT_CODE=$?

    # Test 2: SASL_PLAINTEXT
    echo "--- SASL_PLAINTEXT (gateway:19095) ---"
    docker exec librdkafka-client-test bash -c "
        cd /tests &&
        BOOTSTRAP_SERVERS=gateway:19095 \
        KAFKA_SASL_ENABLED=true \
        KAFKA_SASL_USERNAME=admin \
        KAFKA_SASL_PASSWORD=admin-secret \
        pytest test_librdkafka_compatibility.py \
            --junitxml=/junit-results/sasl-admin/results.xml \
            --html=/html-results/sasl-admin/report.html --self-contained-html \
            --timeout=90 \
            -v
    "
    SASL_ADMIN_EXIT_CODE=$?

    # Test 3: SSL
    echo "--- SSL (gateway:19098) ---"
    docker exec librdkafka-client-test bash -c "
        cd /tests &&
        BOOTSTRAP_SERVERS=gateway:19098 \
        KAFKA_SSL_ENABLED=true \
        pytest test_librdkafka_compatibility.py \
            --junitxml=/junit-results/ssl/results.xml \
            --html=/html-results/ssl/report.html --self-contained-html \
            --timeout=90 \
            -v
    "
    SSL_EXIT_CODE=$?

    # Re-enable errexit
    set -e

    # Evaluate results
    if [ $PLAINTEXT_EXIT_CODE -ne 0 ]; then
        OVERALL_EXIT_CODE=1
        echo "PLAINTEXT tests failed"
    else
        echo "PLAINTEXT tests passed"
    fi

    if [ $SASL_ADMIN_EXIT_CODE -ne 0 ]; then
        OVERALL_EXIT_CODE=1
        echo "SASL tests failed"
    else
        echo "SASL tests passed"
    fi

    if [ $SSL_EXIT_CODE -ne 0 ]; then
        OVERALL_EXIT_CODE=1
        echo "SSL tests failed"
    else
        echo "SSL tests passed"
    fi

    # Copy results from container
    docker cp librdkafka-client-test:/junit-results/plaintext/ "$JUNIT_RESULTS_DIR/" 2>/dev/null || true
    docker cp librdkafka-client-test:/junit-results/sasl-admin/ "$JUNIT_RESULTS_DIR/" 2>/dev/null || true
    docker cp librdkafka-client-test:/junit-results/ssl/ "$JUNIT_RESULTS_DIR/" 2>/dev/null || true
    docker cp librdkafka-client-test:/html-results/ "$HTML_RESULTS_DIR/" 2>/dev/null || true

    # Scrape gateway metrics
    sleep 5
    curl -s "$GATEWAY_METRICS" > "$RESULTS_DIR/${test_id}_metrics.txt"

    # Cleanup
    docker-compose -f "$COMPOSE_FILE" down -v

    if [ $OVERALL_EXIT_CODE -ne 0 ]; then
        echo "FAILED: One or more auth modes failed" > "$RESULTS_DIR/${test_id}_status.txt"
        echo "PLAINTEXT_EXIT=$PLAINTEXT_EXIT_CODE" >> "$RESULTS_DIR/${test_id}_status.txt"
        echo "SASL_EXIT=$SASL_ADMIN_EXIT_CODE" >> "$RESULTS_DIR/${test_id}_status.txt"
        echo "SSL_EXIT=$SSL_EXIT_CODE" >> "$RESULTS_DIR/${test_id}_status.txt"
        echo "TIMESTAMP: $(date -Iseconds)" >> "$RESULTS_DIR/${test_id}_status.txt"
        return 1
    fi

    echo "Completed: $test_id - ALL PASSED"
}

# =============================================================================
# REPORT GENERATION
# =============================================================================

generate_final_report() {
    echo "Generating compatibility summary..."

    if [ -d "$PARENT_DIR/venv" ] && [ -f "$PARENT_DIR/enhanced_metrics_parser.py" ]; then
        source "$PARENT_DIR/venv/bin/activate"
        python3 "$PARENT_DIR/enhanced_metrics_parser.py" "$RESULTS_DIR"
        deactivate
    fi

    echo ""
    echo "librdkafka compatibility testing completed!"
    echo "Results directory: $RESULTS_DIR"
    echo ""

    if [ -f "$RESULTS_DIR/compatibility_summary.txt" ]; then
        echo "COMPATIBILITY SUMMARY:"
        echo "========================"
        cat "$RESULTS_DIR/compatibility_summary.txt"
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    local client_count=${#CLIENTS[@]}
    local server_count=${#SERVERS[@]}
    local total_combinations=$((client_count * server_count))

    echo "LIBRDKAFKA CLIENT COMPATIBILITY TESTING"
    echo "Matrix: $client_count librdkafka client versions x $server_count server versions = $total_combinations combinations"
    echo "Results: $RESULTS_DIR"
    echo ""

    local test_count=0
    CURRENT_TIME=$(date +%s)

    for client_ver in "${CLIENTS[@]}"; do
        for server_ver in "${SERVERS[@]}"; do
            test_count=$((test_count + 1))
            echo "[$test_count/$total_combinations] Testing combination..."
            run_compatibility_test "$client_ver" "$server_ver" || true
            sleep 3
        done
    done

    END_TIME=$(date +%s)
    ELAPSED_TIME=$((END_TIME - CURRENT_TIME))
    echo ""
    echo "Total testing time: $ELAPSED_TIME seconds"

    generate_final_report
}

# Usage
case "${1:-}" in
    "--run")
        setup_python_env
        cd "$SCRIPT_DIR"
        main
        ;;
    "--single")
        if [ $# -ne 3 ]; then
            echo "Usage: $0 --single <librdkafka_client_version> <server_version>"
            exit 1
        fi
        setup_python_env
        cd "$SCRIPT_DIR"
        run_compatibility_test "$2" "$3"
        source "$PARENT_DIR/venv/bin/activate"
        if [ -f "$PARENT_DIR/enhanced_metrics_parser.py" ]; then
            python3 "$PARENT_DIR/enhanced_metrics_parser.py" "$RESULTS_DIR"
        fi
        deactivate
        ;;
    "--parse")
        if [ $# -ne 2 ]; then
            echo "Usage: $0 --parse <results_directory>"
            exit 1
        fi
        setup_python_env
        source "$PARENT_DIR/venv/bin/activate"
        if [ -f "$PARENT_DIR/enhanced_metrics_parser.py" ]; then
            python3 "$PARENT_DIR/enhanced_metrics_parser.py" "$2"
        fi
        deactivate
        ;;
    "--setup-env")
        setup_python_env
        ;;
    *)
        echo "Usage:"
        echo "  $0 --run                           # Run all ${#CLIENTS[@]}x${#SERVERS[@]} test combinations"
        echo "  $0 --single 2.6.2 7.8.0            # Test single combination"
        echo "  $0 --parse results_dir              # Parse existing results"
        echo "  $0 --setup-env                      # Set up Python environment only"
        ;;
esac
