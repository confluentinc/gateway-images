#!/bin/bash
# streamlined-compatibility-test.sh
# 16 combinations: Java clients only (4×4 matrix)

GATEWAY_METRICS="http://localhost:9190/metrics"
RESULTS_DIR="compatibility-results/$(date +%Y%m%d_%H%M%S)"
mkdir -p $RESULTS_DIR

# Simplified matrix - Java clients only
CLIENTS=("3.4" "3.6" "3.8" "4.0")
SERVERS=("3.4" "3.6" "3.8" "4.0")

get_image() {
    local version="$1"
    case "$version" in
        "3.4") echo "7.4.0" ;;
        "3.6") echo "7.6.0" ;;
        "3.8") echo "7.8.0" ;;
        "4.0") echo "8.0.0" ;;
        *) echo "latest" ;;
    esac
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
    export KAFKA_CLIENT_VERSION="$(get_image "$client_ver")"
    export KAFKA_SERVER_VERSION="$(get_image "$server_ver")"
    echo "Using Kafka Client Image: $KAFKA_CLIENT_VERSION"
    echo "Using Kafka Server Image: $KAFKA_SERVER_VERSION"
    # Start environment
    docker-compose -f docker-compose.yml up -d
    
    # Wait for startup
    echo "Waiting for services to stabilize...(10s)"
    sleep 10
    
    # Reset metrics baseline (restart gateway to clear counters)
    # docker-compose -f docker-compose.yml restart gateway
    # sleep 10
    # if gateway is not up, exit
    if ! curl -s $GATEWAY_METRICS > /dev/null; then
        echo "Gateway not responding. Exiting test."
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

    echo "=== Topic Verification ==="
    docker exec kafka-client-test kafka-run-class kafka.tools.GetOffsetShell \
        --broker-list gateway:19092 \
        --topic $TEST_TOPIC --time -1 || true
    
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
    sleep 10
    curl -s $GATEWAY_METRICS > "$RESULTS_DIR/${test_id}_metrics.txt"
    
    # Parse metrics to CSV
    parse_metrics_to_csv "$RESULTS_DIR/${test_id}_metrics.txt" $client_ver $server_ver $test_id
    
    # Cleanup
    docker-compose -f docker-compose.yml down
    
    echo "Completed: $test_id"
}

# Function to parse metrics into CSV format
parse_metrics_to_csv() {
    local metrics_file=$1
    local client_ver=$2
    local server_ver=$3
    local test_id=$4

    # write header if file doesn't exist
    if [ ! -f "$RESULTS_DIR/raw_results.csv" ]; then
        echo "API_KEY,API_VERSION,CLIENT_VERSION,SERVER_VERSION,REQUEST_COUNT,CLIENT_ERRORS,UPSTREAM_ERRORS,STATUS" > "$RESULTS_DIR/raw_results.csv"
    fi
    
    # Extract API request data
    grep "kroxylicious_client_to_proxy_request_total" $metrics_file | \
    sed -n 's/.*api_key="\([^"]*\)".*api_version="\([^"]*\)".*} \([0-9.]*\)/\1|\2|\3/p' | \
    while IFS='|' read -r api_key api_version count; do
        
        # Get error counts (aggregate all error metrics)
        client_errors=$(grep "kroxylicious_client_to_proxy_errors_total" $metrics_file | \
                       awk '{sum += $NF} END {print sum+0}')
        upstream_errors=$(grep "kroxylicious_upstream_connection_failures_total" $metrics_file | \
                         awk '{sum += $NF} END {print sum+0}')
        
        # Determine status
        if [ "$client_errors" = "0" ] && [ "$upstream_errors" = "0" ] && [ "$(echo "$count > 0" | bc 2>/dev/null || echo 0)" = "1" ]; then
            status="SUCCESS"
        elif [ "$client_errors" != "0" ] || [ "$upstream_errors" != "0" ]; then
            status="ERROR"
        else
            status="NO_TRAFFIC"
        fi
        
        # Write to results CSV
        echo "$api_key,$api_version,$client_ver,$server_ver,$count,$client_errors,$upstream_errors,$status" >> "$RESULTS_DIR/raw_results.csv"
    done
}

# Function to generate final compatibility report
generate_final_report() {
    echo "Generating compatibility summary..."
    
    # Create summary table
    cat > "$RESULTS_DIR/compatibility_summary.txt" << 'EOF'
KAFKA CLIENT COMPATIBILITY TEST RESULTS
========================================

API_KEY          | API_VERSIONS | CLIENT_VER | SERVER_VER | REQUESTS | ERRORS | STATUS
EOF
    echo "-------------------------------------------------------------------------------" >> "$RESULTS_DIR/compatibility_summary.txt"
    
    # Group results by client-server combination
    if [ -f "$RESULTS_DIR/raw_results.csv" ]; then
        # Process CSV to create grouped summary  
        python3 << PYTHON_SCRIPT
import csv
from collections import defaultdict

# Group by client-server combination
combinations = defaultdict(lambda: {'apis': [], 'versions': [], 'requests': 0, 'errors': 0})

try:
    with open('$RESULTS_DIR/raw_results.csv', 'r') as f:
        reader = csv.reader(f)
        for row in reader:
            if len(row) >= 8:
                api_key, api_ver, client_ver, server_ver, requests, errors, upstream_errors, status = row
                key = f"{client_ver}-{server_ver}"
                combinations[key]['apis'].append(api_key)
                combinations[key]['versions'].append(api_ver)
                combinations[key]['requests'] += float(requests)
                combinations[key]['errors'] += float(errors) + float(upstream_errors)
    
    # Write summary
    with open('$RESULTS_DIR/compatibility_summary.txt', 'a') as f:
        for key, data in sorted(combinations.items()):
            client_ver, server_ver = key.split('-')
            apis = ','.join(set(data['apis']))[:15] + "..." if len(','.join(set(data['apis']))) > 15 else ','.join(set(data['apis']))
            versions = ','.join(set(data['versions']))
            requests = int(data['requests'])
            errors = int(data['errors'])
            
            if errors == 0 and requests > 0:
                status = "✅ PASS"
            elif errors > 0:
                status = "❌ FAIL"
            else:
                status = "⚠️ NO_DATA"
            
            f.write(f"{apis:<16} | {versions:<12} | {client_ver:<10} | {server_ver:<10} | {requests:<8} | {errors:<6} | {status}\n")

except Exception as e:
    print(f"Error processing results: {e}")
PYTHON_SCRIPT
    fi
    
    echo ""
    echo "Compatibility testing completed!"
    echo "Results in: $RESULTS_DIR"
    echo ""
    cat "$RESULTS_DIR/compatibility_summary.txt"
}

# Main execution
main() {
    echo "KAFKA CLIENT COMPATIBILITY TESTING"
    echo "Matrix: 16 combinations (4 Java clients × 4 servers)" 
    echo "Results: $RESULTS_DIR"
    echo ""
    
    # Initialize results CSV
    echo "API_KEY,API_VERSION,CLIENT_VERSION,SERVER_VERSION,REQUEST_COUNT,CLIENT_ERRORS,UPSTREAM_ERRORS,STATUS" > "$RESULTS_DIR/raw_results.csv"
    
    local test_count=0
    local total_tests=16
    
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
    
    # Generate final reports
    generate_final_report
}

# Usage
case "$1" in
    "--run")
        main
        ;;
    "--single")
        if [ $# -ne 3 ]; then
            echo "Usage: $0 --single <client_version> <server_version>"
            exit 1
        fi
        run_compatibility_test $2 $3
        ;;
    "--parse")
        if [ $# -ne 2 ]; then
            echo "Usage: $0 --parse <results_directory>"
            exit 1
        fi
        cd $2 && python3 ../metrics_parser.py .
        ;;
    *)
        echo "Usage:"
        echo "  $0 --run                    # Run all 16 test combinations"
        echo "  $0 --single 3.6 3.8        # Test single combination"
        echo "  $0 --parse results_dir      # Parse existing results"
        ;;
esac