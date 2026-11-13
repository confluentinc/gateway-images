#!/bin/bash
# Gateway version compatibility tests, Java clients:
#   standard  every client x server version, through PLAINTEXT, SASL and SSL routes
#             (docker-compose.yml, or docker-compose-kraft.yml for 8.0.0+ servers)
#   tbm       topic-based routing: one dynamic route over two clusters (docker-compose-tbm.yml),
#             every client version x TBM_SERVER_PAIRS

GATEWAY_METRICS="http://localhost:9190/metrics"

# Wait for the gateway admin endpoint to respond. The ubi9-micro gateway image
# ships without curl, so readiness is polled from the host (which has curl)
# instead of via an in-container Docker healthcheck.
wait_for_gateway() {
    for _ in $(seq 1 30); do
        curl -sf "$GATEWAY_METRICS" > /dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}
RESULTS_DIR="compatibility-results/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

# Java clients only
CLIENTS=("7.4.0" "7.5.0" "7.6.0" "7.7.0" "7.8.0" "7.9.0" "8.0.0" "8.1.0" "8.2.0" "8.3.0" "8.4.0")
SERVERS=("7.4.0" "7.5.0" "7.6.0" "7.7.0" "7.8.0" "7.9.0" "8.0.0" "8.1.0" "8.2.0" "8.3.0" "8.4.0")
# TBM: "<cluster A> <cluster B>" server versions (A is the coordination cluster). Same-version
# pairs, plus oldest/newest mixes: the router advertises only the API versions both support.
TBM_SERVER_PAIRS=("7.4.0 7.4.0" "8.0.0 8.0.0" "8.4.0 8.4.0" "7.4.0 8.4.0" "8.4.0 7.4.0")

# =============================================================================
# SSL CERTIFICATE GENERATION
# =============================================================================

generate_ssl_certificates() {
    echo "🔒 Generating SSL certificates for SASL_SSL listener..."
    
    # Create ssl directory
    mkdir -p ssl
    cd ssl
    
    # Certificate configuration
    KEYSTORE_PASSWORD="confluent"
    TRUSTSTORE_PASSWORD="confluent"
    KEY_PASSWORD="confluent"
    VALIDITY_DAYS=365
    
    # Create credential files
    echo "$KEYSTORE_PASSWORD" > keystore_creds
    echo "$TRUSTSTORE_PASSWORD" > truststore_creds
    echo "$KEY_PASSWORD" > key_creds
    
    # Generate CA
    echo "Generating Certificate Authority (CA)..."
    openssl req -new -x509 -keyout ca-key -out ca-cert -days $VALIDITY_DAYS \
        -subj "/CN=kafka-ca" -passout pass:$KEY_PASSWORD
    
    # Create truststore and import CA
    echo "Creating truststore..."
    keytool -keystore kafka.truststore.jks -alias CARoot -import -file ca-cert \
        -storepass $TRUSTSTORE_PASSWORD -noprompt
    
    # Generate server keystore
    echo "Generating server keystore..."
    keytool -keystore kafka.keystore.jks -alias kafka-server -validity $VALIDITY_DAYS \
        -genkey -keyalg RSA -keysize 2048 -storepass $KEYSTORE_PASSWORD \
        -keypass $KEY_PASSWORD -dname "CN=kafka-server,OU=Test,O=Confluent,L=CA,S=CA,C=US"
    
    # Generate certificate signing request
    echo "Generating certificate signing request..."
    keytool -keystore kafka.keystore.jks -alias kafka-server -certreq -file cert-file \
        -storepass $KEYSTORE_PASSWORD
    
    # Sign the certificate with CA
    echo "Signing certificate with CA..."
    openssl x509 -req -CA ca-cert -CAkey ca-key -in cert-file -out cert-signed \
        -days $VALIDITY_DAYS -CAcreateserial -passin pass:$KEY_PASSWORD
    
    # Import CA certificate into keystore
    echo "Importing CA certificate into keystore..."
    keytool -keystore kafka.keystore.jks -alias CARoot -import -file ca-cert \
        -storepass $KEYSTORE_PASSWORD -noprompt
    
    # Import signed certificate into keystore
    echo "Importing signed certificate into keystore..."
    keytool -keystore kafka.keystore.jks -alias kafka-server -import -file cert-signed \
        -storepass $KEYSTORE_PASSWORD -noprompt
    
    cd ..
    echo "✅ SSL certificates generated successfully in ssl/ directory"
}

# =============================================================================
# PYTHON ENVIRONMENT SETUP
# =============================================================================

setup_python_env() {
    echo "Setting up Python environment for metrics parsing..."
    
    # Check if Python 3 is available
    if ! command -v python3 &> /dev/null; then
        echo "❌ Python 3 is required but not installed"
        exit 1
    fi
    
    # Create virtual environment if it doesn't exist
    if [ ! -d "venv" ]; then
        echo "Creating Python virtual environment..."
        python3 -m venv venv
    fi
    
    # Activate virtual environment
    source venv/bin/activate
    
    # Upgrade pip
    pip install --upgrade pip
    
    # Install required packages from requirements.txt
    echo "Installing required Python packages..."
    if [ -f "requirements.txt" ]; then
        pip install -r requirements.txt
    else
        # Fallback to manual installation
        pip install requests
    fi
    
    echo "✅ Python environment ready"
}

version_ge() {  # $1 >= $2 ?
    [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}
# Java application is required for all tests

# Function to run test and capture metrics
run_compatibility_test() {
    local client_ver=$1
    local server_ver=$2
    local test_id="java${client_ver}_server${server_ver}"
    
    echo "Testing: Java Client ${client_ver} with Kafka Server ${server_ver}"
    echo "Test ID: $test_id"
    echo "----------------------------------------"

    # Generate SSL certificates if they don't exist
    if [ ! -d "ssl" ] || [ ! -f "ssl/kafka.keystore.jks" ]; then
        generate_ssl_certificates
    fi

    # print images being used
    export KAFKA_CLIENT_VERSION="$client_ver"
    export KAFKA_SERVER_VERSION="$server_ver"
    echo "Using Kafka Client Image: $KAFKA_CLIENT_VERSION"
    echo "Using Kafka Server Image: $KAFKA_SERVER_VERSION"
    
    # Set up directories for test results
    mkdir -p "$RESULTS_DIR/${test_id}_junit"
    mkdir -p "$RESULTS_DIR/${test_id}_html" 
    mkdir -p "$RESULTS_DIR/${test_id}_m2"
    
    JUNIT_RESULTS_DIR="$RESULTS_DIR/${test_id}_junit"
    HTML_RESULTS_DIR="$RESULTS_DIR/${test_id}_html"
    MAVEN_REPO_DIR="$RESULTS_DIR/${test_id}_m2"
    
    echo "JUnit results will be saved to: $JUNIT_RESULTS_DIR"
    echo "HTML reports will be saved to: $HTML_RESULTS_DIR"
    # Start environment
    # if kafka_server_version starts after 8.0.0, use KRaft mode: docker-compose-kraft.yml
    if version_ge $server_ver "8.0.0"; then
            echo "Starting Kafka in KRaft mode..."
            COMPOSE_FILE="docker-compose-kraft.yml"
        if ! docker-compose -f $COMPOSE_FILE up -d; then
            echo "❌ Failed to start services in KRaft mode"
            echo "SETUP_FAILED: Docker compose failed to start services (KRaft mode)" > "$RESULTS_DIR/${test_id}_status.txt"
            echo "FAILURE_TYPE: DOCKER_COMPOSE_FAILED" >> "$RESULTS_DIR/${test_id}_status.txt"
            echo "TIMESTAMP: $(date -Iseconds)" >> "$RESULTS_DIR/${test_id}_status.txt"
            return 1
        fi
    else
            COMPOSE_FILE="docker-compose.yml"
        if ! docker-compose -f $COMPOSE_FILE up -d; then
            echo "❌ Failed to start services"
            echo "SETUP_FAILED: Docker compose failed to start services" > "$RESULTS_DIR/${test_id}_status.txt"
            echo "FAILURE_TYPE: DOCKER_COMPOSE_FAILED" >> "$RESULTS_DIR/${test_id}_status.txt"
            echo "TIMESTAMP: $(date -Iseconds)" >> "$RESULTS_DIR/${test_id}_status.txt"
            return 1
        fi
    fi
    
    # The ubi9-micro gateway image has no in-container curl, so gateway readiness
    # is polled from the host instead of via a Docker healthcheck.
    echo "Waiting for gateway to become ready..."
    if ! wait_for_gateway; then
        echo "❌ Gateway not responding. Exiting test."
        echo "--- Container logs ---"
        docker-compose -f $COMPOSE_FILE logs --no-color --tail=50
        echo "SETUP_FAILED: Gateway not responding" > "$RESULTS_DIR/${test_id}_status.txt"
        echo "FAILURE_TYPE: GATEWAY_NOT_RESPONDING" >> "$RESULTS_DIR/${test_id}_status.txt"
        echo "TIMESTAMP: $(date -Iseconds)" >> "$RESULTS_DIR/${test_id}_status.txt"
        docker-compose -f $COMPOSE_FILE down
        return 1
    fi

    # if kafka is not up, exit — run inside kafka-server (correct JVM) not client
    KAFKA_READINESS_OUT=$(docker-compose -f $COMPOSE_FILE exec -T kafka-server kafka-topics --bootstrap-server localhost:9092 --list 2>&1)
    if [[ $? -ne 0 ]]; then
        echo "❌ Kafka server not responding. Output:"
        echo "$KAFKA_READINESS_OUT"
        echo "--- Container logs ---"
        docker-compose -f $COMPOSE_FILE logs --no-color --tail=50
        echo "SETUP_FAILED: Kafka server not responding" > "$RESULTS_DIR/${test_id}_status.txt"
        echo "FAILURE_TYPE: KAFKA_NOT_RESPONDING" >> "$RESULTS_DIR/${test_id}_status.txt"
        echo "TIMESTAMP: $(date -Iseconds)" >> "$RESULTS_DIR/${test_id}_status.txt"
        docker-compose -f $COMPOSE_FILE down
        return 1
    fi

    echo "Running comprehensive API compatibility tests..."
    
    # Copy Maven project files to container for Maven-based execution
    echo "📦 Copying Maven project files to test container..."
    docker cp pom.xml kafka-client-test:/tmp/
    docker cp src/ kafka-client-test:/tmp/
    
    # Check if Maven project was copied successfully
    if ! docker exec kafka-client-test test -f /tmp/pom.xml; then
        echo "❌ Failed to copy Maven project files to container"
        return 1
    fi
    
    if ! docker exec kafka-client-test test -d /tmp/src; then
        echo "❌ Failed to copy source files to container"
        return 1
    fi
    
    echo "✅ Maven project files copied successfully"
    
    # Determine Java version and Maven settings based on Kafka client version
    java_settings=""
    if version_ge "$client_ver" "8.0.0"; then
        # Dockerfile sets JAVA_HOME=/usr/lib/jvm/java-11-openjdk (Red Hat OpenJDK);
        # don't override it — the Zulu path no longer exists in this image.
        maven_java_args="-Dmaven.compiler.source=11 -Dmaven.compiler.target=11"
        echo "🔧 Using Java 11 for Kafka client $client_ver (required for 8.0.0+)"
    else
        maven_java_args="-Dmaven.compiler.source=8 -Dmaven.compiler.target=8"
        echo "🔧 Using Java 8 for Kafka client $client_ver"
    fi

    # Run comprehensive compatibility test suite  
    echo "=== Running Comprehensive Kafka Test Suite ==="
    
    # Test 1: PLAINTEXT authentication
    echo "🔓 Testing PLAINTEXT authentication (gateway:19092)..."
    docker exec kafka-client-test bash -c "
        ${java_settings}cd /tmp && 
        mvn test \
            -DclientVersion=$client_ver \
            -DserverVersion=$server_ver \
            -Dkafka.version=$client_ver \
            -Dbootstrap.servers=gateway:19092 \
            -Dtest=AdvancedKafkaTest \
            -Dmaven.test.failure.ignore=false \
            -Dmaven.surefire.reports.directory=/junit-results/plaintext \
            -Dsurefire.failIfNoSpecifiedTests=false \
            $maven_java_args \
            -q
    "
    PLAINTEXT_EXIT_CODE=$?
    
    # Test 2: SASL_PLAINTEXT authentication with admin user
    echo "🔐 Testing SASL_PLAINTEXT authentication with admin user (gateway:19095)..."
    docker exec kafka-client-test bash -c "
        ${java_settings}cd /tmp && 
        KAFKA_SASL_ENABLED=true \
        KAFKA_SASL_USERNAME=admin \
        KAFKA_SASL_PASSWORD=admin-secret \
        mvn test \
            -DclientVersion=$client_ver \
            -DserverVersion=$server_ver \
            -Dkafka.version=$client_ver \
            -Dbootstrap.servers=gateway:19095 \
            -Dtest=AdvancedKafkaTest \
            -Dmaven.test.failure.ignore=false \
            -Dmaven.surefire.reports.directory=/junit-results/sasl-admin \
            -Dsurefire.failIfNoSpecifiedTests=false \
            $maven_java_args \
            -q
    "
    SASL_ADMIN_EXIT_CODE=$?
    
    # Test 3: SSL authentication (no SASL)
    echo "🔒 Testing SSL authentication (gateway:19098)..."
    docker exec kafka-client-test bash -c "
        ${java_settings}cd /tmp && 
        KAFKA_SSL_ENABLED=true \
        mvn test \
            -DclientVersion=$client_ver \
            -DserverVersion=$server_ver \
            -Dkafka.version=$client_ver \
            -Dbootstrap.servers=gateway:19098 \
            -Dtest=AdvancedKafkaTest \
            -Dmaven.test.failure.ignore=false \
            -Dmaven.surefire.reports.directory=/junit-results/ssl \
            -Dsurefire.failIfNoSpecifiedTests=false \
            $maven_java_args \
            -q
    "
    SSL_EXIT_CODE=$?
    
    # Overall test result evaluation
    OVERALL_EXIT_CODE=0
    if [ $PLAINTEXT_EXIT_CODE -ne 0 ]; then
        OVERALL_EXIT_CODE=1
        echo "❌ PLAINTEXT authentication tests failed"
    else
        echo "✅ PLAINTEXT authentication tests passed"
    fi
    
    if [ $SASL_ADMIN_EXIT_CODE -ne 0 ]; then
        OVERALL_EXIT_CODE=1
        echo "❌ SASL authentication tests failed"
    else
        echo "✅ SASL authentication tests passed"
    fi
    
    if [ $SSL_EXIT_CODE -ne 0 ]; then
        OVERALL_EXIT_CODE=1
        echo "❌ SSL authentication tests failed"
    else
        echo "✅ SSL authentication tests passed"
    fi
    
    JUNIT_EXIT_CODE=$OVERALL_EXIT_CODE
    
    # Check JUnit test results
    if [ $JUNIT_EXIT_CODE -eq 0 ]; then
        echo "✅ JUnit tests passed for client $client_ver with server $server_ver"
        
        # Generate HTML reports from all authentication test results
        docker exec kafka-client-test bash -c "
            ${java_settings}cd /tmp && 
            # Copy JUnit XML reports from all authentication modes to Surefire location
            mkdir -p target/surefire-reports && \
            cp /junit-results/plaintext/*.xml target/surefire-reports/ 2>/dev/null && \
            cp /junit-results/sasl-admin/*.xml target/surefire-reports/ 2>/dev/null && \
            cp /junit-results/ssl/*.xml target/surefire-reports/ 2>/dev/null && \
            mvn surefire-report:report-only \
                -Dkafka.version=$client_ver \
                $maven_java_args \
                -q && \
            if [ -f target/site/surefire-report.html ]; then \
                mkdir -p /html-results && \
                cp -r target/site/* /html-results/; \
                echo '📊 HTML report generated successfully with PLAINTEXT, SASL, and SSL authentication test details'; \
            else \
                echo '⚠️ HTML report not found'; \
            fi
        " 2>/dev/null || echo "⚠️ HTML report generation failed (non-critical)"
    else
        echo "❌ JUnit tests failed for client $client_ver with server $server_ver"
        echo "   Check JUnit XML reports at: $JUNIT_RESULTS_DIR"
        echo "--- Container logs ---"
        docker-compose -f $COMPOSE_FILE logs --no-color --tail=50
        echo "FAILED: JUnit tests failed" > "$RESULTS_DIR/${test_id}_status.txt"
        echo "FAILURE_TYPE: JUNIT_FAILED" >> "$RESULTS_DIR/${test_id}_status.txt"
        echo "TIMESTAMP: $(date -Iseconds)" >> "$RESULTS_DIR/${test_id}_status.txt"
        docker-compose -f $COMPOSE_FILE down
        return 1
    fi
    
    # Copy JUnit results from container to host
    echo "📋 Copying JUnit test results from container..."
    docker cp kafka-client-test:/junit-results/plaintext/ "$JUNIT_RESULTS_DIR/" 2>/dev/null || echo "⚠️ Could not copy PLAINTEXT JUnit results"
    docker cp kafka-client-test:/junit-results/sasl-admin/ "$JUNIT_RESULTS_DIR/" 2>/dev/null || echo "⚠️ Could not copy SASL JUnit results"
    docker cp kafka-client-test:/junit-results/ssl/ "$JUNIT_RESULTS_DIR/" 2>/dev/null || echo "⚠️ Could not copy SSL JUnit results"
    
    # Copy HTML results from container to host
    echo "📊 Copying HTML test results from container..."
    docker cp kafka-client-test:/html-results/ "$HTML_RESULTS_DIR/" 2>/dev/null || echo "⚠️ Could not copy HTML results"
    
    # Scrape metrics
    sleep 5
    curl -s "$GATEWAY_METRICS" > "$RESULTS_DIR/${test_id}_metrics.txt"
    
    # Cleanup
    docker-compose -f $COMPOSE_FILE down

    echo "Completed: $test_id"
}

# mark_setup_failed <test_id> <type> <message>
mark_setup_failed() {
    {
        echo "SETUP_FAILED: $3"
        echo "FAILURE_TYPE: $2"
        echo "TIMESTAMP: $(date -Iseconds)"
    } > "$RESULTS_DIR/${1}_status.txt"
}

# run_tbm_test <client> <cluster A server> <cluster B server>: DynamicRoutingTest through one
# dynamic route over two clusters (docker-compose-tbm.yml). Results as run_compatibility_test's,
# with the JUnit reports under <test_id>_junit/tbm-ssl.
run_tbm_test() {
    local client_ver=$1 server_a=$2 server_b=$3
    local test_id="java${client_ver}_server${server_a}+${server_b}"
    local compose="docker-compose-tbm.yml"

    echo "Testing TBM: Java Client ${client_ver} with Kafka clusters ${server_a} (A) and ${server_b} (B)"
    echo "Test ID: $test_id"
    echo "----------------------------------------"
    if [ ! -d "ssl" ] || [ ! -f "ssl/kafka.keystore.jks" ]; then
        generate_ssl_certificates
    fi
    export KAFKA_CLIENT_VERSION="$client_ver" KAFKA_SERVER_VERSION="$server_a" KAFKA_SERVER_B_VERSION="$server_b"
    mkdir -p "$RESULTS_DIR/${test_id}_junit"

    if ! docker-compose -f $compose up -d; then
        echo "❌ Failed to start the TBM services"
        mark_setup_failed "$test_id" DOCKER_COMPOSE_FAILED "Docker compose failed to start services (TBM)"
        docker-compose -f $compose down
        return 1
    fi
    if ! wait_for_gateway; then
        echo "❌ Gateway not responding. Exiting test."
        docker-compose -f $compose logs --no-color --tail=50
        mark_setup_failed "$test_id" GATEWAY_NOT_RESPONDING "Gateway not responding"
        docker-compose -f $compose down
        return 1
    fi

    docker cp pom.xml kafka-client-test:/tmp/
    docker cp src/ kafka-client-test:/tmp/
    local maven_java_args="-Dmaven.compiler.source=8 -Dmaven.compiler.target=8"
    if version_ge "$client_ver" "8.0.0"; then
        maven_java_args="-Dmaven.compiler.source=11 -Dmaven.compiler.target=11"
    fi

    echo "🔀 Testing topic-based routing over SSL (gateway.tbm.test:19400)..."
    local rc=0
    docker exec kafka-client-test bash -c "
        cd /tmp &&
        mvn test \
            -Dtest=DynamicRoutingTest \
            -Dkafka.version=$client_ver \
            -Dbootstrap.servers=gateway.tbm.test:19400 \
            -Dtbm.cluster.a.bootstrap=kafka-server:9092 \
            -Dtbm.cluster.b.bootstrap=kafka-server-b:9092 \
            -Dmaven.test.failure.ignore=false \
            -Dmaven.surefire.reports.directory=/junit-results/tbm-ssl \
            -Dsurefire.failIfNoSpecifiedTests=false \
            $maven_java_args \
            -q
    " || rc=1
    docker cp kafka-client-test:/junit-results/tbm-ssl/ "$RESULTS_DIR/${test_id}_junit/" 2>/dev/null \
        || echo "⚠️ Could not copy TBM JUnit results"

    if [ $rc -ne 0 ]; then
        echo "❌ TBM tests failed for client $client_ver with clusters $server_a + $server_b"
        docker-compose -f $compose logs --no-color --tail=50
        {
            echo "FAILED: JUnit tests failed"
            echo "FAILURE_TYPE: JUNIT_FAILED"
            echo "TIMESTAMP: $(date -Iseconds)"
        } > "$RESULTS_DIR/${test_id}_status.txt"
        docker-compose -f $compose down
        return 1
    fi
    echo "✅ TBM tests passed for client $client_ver with clusters $server_a + $server_b"
    sleep 5
    curl -s "$GATEWAY_METRICS" > "$RESULTS_DIR/${test_id}_metrics.txt"
    docker-compose -f $compose down
    echo "Completed: $test_id"
}

# Function to generate final compatibility report using enhanced Python parser
generate_final_report() {
    echo "Generating compatibility summary..."
    
    # Ensure Python environment is ready
    if [ ! -d "venv" ] || [ ! -f "enhanced_metrics_parser.py" ]; then
        setup_python_env
    fi
    
    # Activate virtual environment
    source venv/bin/activate
    
    # Use the enhanced Python parser instead of the bash parsing
    echo "Running enhanced metrics parser..."
    python3 enhanced_metrics_parser.py "$RESULTS_DIR"
    
    # Deactivate virtual environment
    deactivate
    
    echo ""
    echo "🎉 Compatibility testing completed!"
    echo "📁 Results directory: $RESULTS_DIR"
    echo ""
    
    # Show summary if it exists
    if [ -f "$RESULTS_DIR/compatibility_summary.txt" ]; then
        echo "📊 COMPATIBILITY SUMMARY:"
        echo "========================"
        cat "$RESULTS_DIR/compatibility_summary.txt"
    fi
    
    echo ""
    echo "📋 Available reports:"
    ls -la "$RESULTS_DIR"/*.txt "$RESULTS_DIR"/*.csv "$RESULTS_DIR"/*.json 2>/dev/null || echo "No reports generated"
}

# =============================================================================
# JAVA APPLICATION BUILD AND TEST
# =============================================================================


# Main execution. With SHARD=<i>/<n> (1-based), runs only every n-th combination starting at
# the i-th, so n parallel jobs split the matrix.
main() {
    client_count=${#CLIENTS[@]}
    server_count=${#SERVERS[@]}
    total_combinations=$((client_count * server_count))
    local shard_index=1 shard_count=1
    if [[ -n "${SHARD:-}" ]]; then
        shard_index=${SHARD%/*} shard_count=${SHARD#*/}
    fi
    echo "KAFKA CLIENT COMPATIBILITY TESTING"
    echo "Matrix: $client_count Java client versions × $server_count server versions = $total_combinations combinations (shard $shard_index/$shard_count)"
    echo "Results: $RESULTS_DIR"
    echo ""
    echo "ℹ️  Tests will be compiled and run via Maven inside the test container"
    echo ""
    
    local test_count=0 combo=0
    local total_tests=$(( (total_combinations - shard_index) / shard_count + 1 ))
    local overall_failed=0

    # start timer
    CURRENT_TIME=$(date +%s)

    # Run all combinations
    for client_ver in "${CLIENTS[@]}"; do
        for server_ver in "${SERVERS[@]}"; do
            combo=$((combo + 1))
            (( (combo - shard_index) % shard_count == 0 )) || continue
            test_count=$((test_count + 1))
            echo "[$test_count/$total_tests] Testing combination..."
            run_compatibility_test $client_ver $server_ver || overall_failed=1

            # Brief pause between tests
            sleep 3
        done
    done

    # end timer
    END_TIME=$(date +%s)
    ELAPSED_TIME=$((END_TIME - CURRENT_TIME))
    echo ""
    echo "Total testing time: $ELAPSED_TIME seconds"

    # Generate final reports
    generate_final_report
    return $overall_failed
}

# TBM: every client version x TBM_SERVER_PAIRS.
main_tbm() {
    local total=$(( ${#CLIENTS[@]} * ${#TBM_SERVER_PAIRS[@]} )) count=0 failed=0 pair
    echo "TOPIC-BASED ROUTING (TBM) COMPATIBILITY TESTING"
    echo "Matrix: ${#CLIENTS[@]} Java client versions × ${#TBM_SERVER_PAIRS[@]} cluster pairs = $total combinations"
    echo "Results: $RESULTS_DIR"
    local start=$(date +%s)
    for client_ver in "${CLIENTS[@]}"; do
        for pair in "${TBM_SERVER_PAIRS[@]}"; do
            count=$((count + 1))
            echo "[$count/$total] Testing combination..."
            # shellcheck disable=SC2086 # the pair is two words
            run_tbm_test "$client_ver" $pair || failed=1
            sleep 3
        done
    done
    echo ""
    echo "Total testing time: $(( $(date +%s) - start )) seconds"
    generate_final_report
    return $failed
}

# Usage
case "$1" in
    "--run")
        setup_python_env  # Set up Python environment before running tests
        main
        ;;
    "--tbm-run")
        setup_python_env
        main_tbm
        ;;
    "--tbm-single")
        if [ $# -ne 4 ]; then
            echo "Usage: $0 --tbm-single <client_version> <cluster_a_version> <cluster_b_version>"
            exit 1
        fi
        setup_python_env
        run_tbm_test "$2" "$3" "$4"
        SINGLE_RC=$?
        source venv/bin/activate
        python3 enhanced_metrics_parser.py "$RESULTS_DIR"
        deactivate
        exit $SINGLE_RC
        ;;
    "--single")
        if [ $# -ne 3 ]; then
            echo "Usage: $0 --single <client_version> <server_version>"
            exit 1
        fi
        setup_python_env  # Set up Python environment before running tests
        run_compatibility_test $2 $3
        SINGLE_RC=$?
        # Generate report for single test
        source venv/bin/activate
        python3 enhanced_metrics_parser.py "$RESULTS_DIR"
        deactivate
        exit $SINGLE_RC
        ;;
    "--parse")
        if [ $# -ne 2 ]; then
            echo "Usage: $0 --parse <results_directory>"
            exit 1
        fi
        setup_python_env  # Set up Python environment
        source venv/bin/activate
        python3 enhanced_metrics_parser.py "$2"
        deactivate
        ;;
    "--setup-env")
        # New option to just set up the environment
        setup_python_env
        ;;
    *)
        echo "Usage:"
        echo "  $0 --run                    # Run every client x server combination (SHARD=i/n: a slice)"
        echo "  $0 --single 7.6.0 7.8.0     # Test single combination (client, server)"
        echo "  $0 --tbm-run                # Run every client x TBM cluster pair"
        echo "  $0 --tbm-single 8.4.0 7.4.0 8.4.0  # One TBM combination (client, cluster A, cluster B)"
        echo "  $0 --parse results_dir      # Parse existing results"
        echo "  $0 --setup-env              # Set up Python environment only"
        echo ""
        echo "🐍 Python packages will be automatically installed in 'venv/' directory"
        ;;
esac
