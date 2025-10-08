#!/bin/bash
# streamlined-compatibility-test.sh
# 16 combinations: Java clients only (4×4 matrix)

GATEWAY_METRICS="http://localhost:9190/metrics"
RESULTS_DIR="compatibility-results/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

# Simplified matrix - Java clients only
CLIENTS=("7.4.0" "7.5.0" "7.6.0" "7.7.0" "7.8.0" "7.9.0" "8.0.0")
SERVERS=("7.4.0" "7.5.0" "7.6.0" "7.7.0" "7.8.0" "7.9.0" "8.0.0")

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
        pip install requests pandas numpy matplotlib seaborn
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
    
    # Set up volume mounts for JUnit test results
    mkdir -p "$RESULTS_DIR/${test_id}_junit"
    mkdir -p "$RESULTS_DIR/${test_id}_html" 
    mkdir -p "$RESULTS_DIR/${test_id}_m2"
    
    export JUNIT_RESULTS_DIR="$PWD/$RESULTS_DIR/${test_id}_junit"
    export HTML_RESULTS_DIR="$PWD/$RESULTS_DIR/${test_id}_html"
    export MAVEN_REPO_DIR="$PWD/$RESULTS_DIR/${test_id}_m2"
    
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
    
    # Health checks will ensure services are ready
    echo "Services started with health checks - verifying final connectivity..."
    if ! curl -s "$GATEWAY_METRICS" > /dev/null; then
        echo "❌ Gateway not responding. Exiting test."
        # Create status file to track the failure
        echo "SETUP_FAILED: Gateway not responding" > "$RESULTS_DIR/${test_id}_status.txt"
        echo "FAILURE_TYPE: GATEWAY_NOT_RESPONDING" >> "$RESULTS_DIR/${test_id}_status.txt"
        echo "TIMESTAMP: $(date -Iseconds)" >> "$RESULTS_DIR/${test_id}_status.txt"
        docker-compose -f $COMPOSE_FILE down
        return 1
    fi

    # if kafka is not up, exit
    if ! docker exec kafka-client-test kafka-topics --bootstrap-server kafka-server:9092 --list > /dev/null 2>&1; then
        echo "❌ Kafka server not responding. Exiting test."
        # Create status file to track the failure
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
    if [[ "$client_ver" == "8.0.0" ]]; then
        java_settings="export JAVA_HOME=/usr/lib/jvm/java-11-zulu-openjdk-ca && export PATH=\$JAVA_HOME/bin:\$PATH && "
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
        return 1
    fi
    
    # Scrape metrics
    sleep 5
    curl -s "$GATEWAY_METRICS" > "$RESULTS_DIR/${test_id}_metrics.txt"
    
    # Cleanup
    docker-compose -f docker-compose.yml down
    
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


# Main execution
main() {
    client_count=${#CLIENTS[@]}
    server_count=${#SERVERS[@]}
    total_combinations=$((client_count * server_count))
    echo "KAFKA CLIENT COMPATIBILITY TESTING"
    echo "Matrix: $client_count Java client versions × $server_count server versions = $total_combinations combinations"
    echo "Results: $RESULTS_DIR"
    echo ""
    echo "ℹ️  Tests will be compiled and run via Maven inside the test container"
    echo ""
    
    local test_count=0
    local total_tests=$total_combinations

    # start timer
    CURRENT_TIME=$(date +%s)
    
    # Run all combinations
    for client_ver in "${CLIENTS[@]}"; do
        for server_ver in "${SERVERS[@]}"; do
            test_count=$((test_count + 1))
            echo "[$test_count/$total_tests] Testing combination..."
            run_compatibility_test $client_ver $server_ver
            
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
}

# Usage
case "$1" in
    "--run")
        setup_python_env  # Set up Python environment before running tests
        main
        ;;
    "--single")
        if [ $# -ne 3 ]; then
            echo "Usage: $0 --single <client_version> <server_version>"
            exit 1
        fi
        setup_python_env  # Set up Python environment before running tests
        run_compatibility_test $2 $3
        # Generate report for single test
        source venv/bin/activate
        python3 enhanced_metrics_parser.py "$RESULTS_DIR"
        deactivate
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
        echo "  $0 --run                    # Run all 16 test combinations"
        echo "  $0 --single 7.6.0 7.8.0     # Test single combination"
        echo "  $0 --parse results_dir      # Parse existing results"
        echo "  $0 --setup-env              # Set up Python environment only"
        echo ""
        echo "🐍 Python packages will be automatically installed in 'venv/' directory"
        ;;
esac
