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
# Function to run test and capture metrics
run_compatibility_test() {
    local client_ver=$1
    local server_ver=$2
    local test_id="java${client_ver}_server${server_ver}"
    
    echo "Testing: Java Client ${client_ver} with Kafka Server ${server_ver}"
    echo "Test ID: $test_id"
    echo "----------------------------------------"

    # print images being used
    export KAFKA_CLIENT_VERSION="$client_ver"
    export KAFKA_SERVER_VERSION="$server_ver"
    echo "Using Kafka Client Image: $KAFKA_CLIENT_VERSION"
    echo "Using Kafka Server Image: $KAFKA_SERVER_VERSION"
    # Start environment
    # if kafka_server_version starts after 8.0.0, use KRaft mode: docker-compose-kraft.yml
    if version_ge $server_ver "8.0.0"; then
        echo "Starting Kafka in KRaft mode..."
        docker-compose -f docker-compose-kraft.yml up -d
    else
        docker-compose -f docker-compose.yml up -d
    fi
    
    # Wait for startup
    echo "Waiting for services to stabilize...(10s)"
    sleep 10
    
    # Reset metrics baseline (restart gateway to clear counters)
    # docker-compose -f docker-compose.yml restart gateway
    # sleep 10
    echo "Checking service availability..."
    if ! curl -s "$GATEWAY_METRICS" > /dev/null; then
        echo "Gateway not responding. Exiting test."
        docker-compose -f docker-compose.yml down
        return
    fi

    # if kafka is not up, exit
    if ! docker exec kafka-client-test kafka-topics --bootstrap-server kafka-server:9092 --list > /dev/null 2>&1; then
        echo "❌ Kafka server not responding. Exiting test."
        docker-compose -f docker-compose.yml down
        return
    fi
    
    # Run test operations
    echo "Running API tests..."
    
    # Test 1: API Versions
    echo "=== API Versions Test ==="
    docker exec kafka-client-test kafka-broker-api-versions \
        --bootstrap-server gateway:19092 || true
    echo ""
    
    # Test 2: Topic operations
    # topic replace . with _
    echo "=== Topic Create Test ==="
    TEST_TOPIC="version-compatibility-test-${test_id//./-}"
    echo "Creating topic: $TEST_TOPIC"
    docker exec kafka-client-test kafka-topics \
        --bootstrap-server gateway:19092 \
        --create --topic $TEST_TOPIC --partitions 1 2>/dev/null || true
    
    # Test 3: Producer
    echo "=== Producer Test ==="
    echo "Sending message: test-message-$test_id"
    echo "test-message-$test_id" | docker exec -i kafka-client-test \
        kafka-console-producer \
        --bootstrap-server gateway:19092 \
        --topic $TEST_TOPIC \
        --property parse.key=false \
        --property key.separator=: || {
        echo "❌ Producer failed"
        return 1
    }

    echo "✅ Message sent successfully"
    
    # Test 4: Consumer
    echo "=== Consumer Test ==="
    echo "Reading messages from topic: $TEST_TOPIC"
    timeout 10 docker exec kafka-client-test kafka-console-consumer \
        --bootstrap-server gateway:19092 \
        --from-beginning \
        --topic $TEST_TOPIC \
        --max-messages 1 \
        --timeout-ms 8000 || true
    echo ""
    echo "Ignore FetchSessionHandler. It is not harmful."
    
    # Test 5: Consumer groups
    echo "=== Consumer Groups Test ==="
    docker exec kafka-client-test kafka-consumer-groups \
        --bootstrap-server gateway:19092 --list || true
    echo ""
    
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

# Main execution
main() {
    client_count=${#CLIENTS[@]}
    server_count=${#SERVERS[@]}
    total_combinations=$((client_count * server_count))
    echo "KAFKA CLIENT COMPATIBILITY TESTING"
    echo "Matrix: $client_count Java client versions × $server_count server versions = $total_combinations combinations"
    echo "Results: $RESULTS_DIR"
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
