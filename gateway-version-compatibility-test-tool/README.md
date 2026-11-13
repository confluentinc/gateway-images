# Kafka Gateway Version Compatibility Test Tool

A comprehensive testing framework to validate Kafka client-server compatibility across different versions using the Kroxylicious gateway.

## Overview

This tool tests compatibility between different Kafka client and server versions by running them through a Kroxylicious gateway and analyzing the API usage metrics. It generates detailed reports showing which APIs work successfully and which ones fail.

## Features

- **🔍 Version Matrix Testing**: Tests all combinations (m client × n server versions)
- **📊 API Analysis**: Shows API keys as both names AND integers for protocol debugging
- **🐍 Zero-Setup Python**: Automatic virtual environment and dependency management
- **📈 Multiple Report Formats**: CSV, JSON, and human-readable summaries
- **⚡ Docker-Based**: Isolated testing environment using Docker containers
- **🎯 Gateway Metrics**: Real-time metrics collection from Kroxylicious gateway

## Quick Start

### Prerequisites
- Docker and Docker Compose
- Python 3.7+
- Bash shell

### Setup and Run

```bash
# Clone/navigate to the tool directory
cd gateway-version-compatibility-test-tool

# Set up Python environment (one-time setup)
./version-compatibility.sh --setup-env

# Run all compatibility tests (11 client x 11 server versions, CP 7.4.0-8.4.0)
./version-compatibility.sh --run

# Or test a single combination
./version-compatibility.sh --single 7.6.0 7.8.0
```

## Usage Options

| Command | Description |
|---------|-------------|
| `--run` | Run all test combinations (`SHARD=<i>/<n>`: only the i-th of n slices) |
| `--single <client> <server>` | Test single client-server combination |
| `--tbm-run` | Run topic-based routing (two clusters): every client x `TBM_SERVER_PAIRS` |
| `--tbm-single <client> <cluster A> <cluster B>` | Test one topic-based routing combination |
| `--parse <results_dir>` | Re-parse existing results |
| `--setup-env` | Set up Python environment only |

### Example Usage

```bash
# Test all combinations
./version-compatibility.sh --run

# Test specific versions
./version-compatibility.sh --single 7.8.0 8.0.0

# Parse existing results
./version-compatibility.sh --parse compatibility-results/20240903_090000
```

## Test Workflow

1. **Environment Setup**: Start Zookeeper, Kafka server, and Kroxylicious gateway
2. **API Testing**: Run various Kafka operations:
   - `kafka-broker-api-versions` - Check supported APIs
   - `kafka-topics --create` - Topic management
   - `kafka-console-producer` - Message production  
   - `kafka-console-consumer` - Message consumption
   - `kafka-consumer-groups` - Consumer group operations
3. **Metrics Collection**: Scrape Prometheus metrics from gateway
4. **Report Generation**: Parse metrics and generate compatibility reports

## Topic-Based Routing (TBM)

`--tbm-run` / `--tbm-single` test one dynamic (topic-based) gateway route over two Kafka clusters
(`docker-compose-tbm.yml`): cluster A holds `tbm-a-*` topics and the consumer groups (the
coordination cluster), cluster B holds `tbm-b-*` topics. Both run KRaft at every version. The
route uses the host (SNI) broker strategy, so clients connect over TLS to
`gateway.tbm.test:19400`.

`DynamicRoutingTest` acts through the gateway and checks each cluster directly: topics are
created and deleted on the cluster their name routes to, an idempotent producer's records land
there, and one consumer group reads both clusters with its offsets on cluster A. It covers only
the APIs the dynamic router serves (it rejects others, e.g. transactions), so
`AdvancedKafkaTest` isn't run here. Offsets are committed for cluster A's topic only: the router
forwards commits to the coordination cluster, which rejects a topic it doesn't have.

`TBM_SERVER_PAIRS` holds same-version pairs plus oldest/newest mixes: the router advertises only
the API versions both clusters support. Results use the same layout and reports, with the
server column reading `<cluster A>+<cluster B>`.

In CI (`.semaphore/version_compatibility_tests.yml`, weekly) the standard matrix runs in three
parallel slices and TBM in a job of its own; a Report job merges each suite's results
(`ci-report.sh`), uploads them to S3 (`version-testing-results/` and
`version-testing-results-tbm/`) and posts one Slack message per suite.

## Generated Reports

After running tests, you'll find these files in `compatibility-results/TIMESTAMP/`:

### 📊 compatibility_summary.txt
Human-readable summary with pass/fail status:
```
CLIENT   | SERVER   | SUCCESSFUL_APIS              | FAILED_APIS    | REQUESTS | ERRORS   | STATUS
7.6      | 7.8      | metadata(3),fetch(1)         |                | 45       | 0        | ✅ PASS
```

### 📋 detailed_api_usage.csv
Complete API usage data with integer mappings:
```csv
api_key,api_key_int,api_version,client_version,server_version,request_count,status
fetch,1,11,7.6,7.8,12,SUCCESS
metadata,3,9,7.6,7.8,8,SUCCESS
```

### 📖 api_key_reference.txt
API name to integer mapping for all used APIs:
```
API_NAME                      | API_INT
fetch                         | 1
metadata                      | 3
offset_fetch                  | 9
```

### 🗃️ compatibility_report.json
Machine-readable results for programmatic analysis

## Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Kafka Client  │───▶│ Gateway          │───▶│   Kafka Server  │
│   (Test Runner) │    │ :19092           │    │   (Target Ver)  │
│                 │    │ :9190/metrics    │    │                 │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                              │
                              ▼
                       ┌──────────────────┐
                       │ Metrics Collector│
                       │ & Report Generator│
                       └──────────────────┘
```

## API Key Mappings

The tool includes complete Kafka protocol API mappings (0-74):

| API Name | Integer | Description |
|----------|---------|-------------|
| produce | 0 | Message production |
| fetch | 1 | Message consumption |
| metadata | 3 | Broker/topic metadata |
| offset_fetch | 9 | Consumer offset retrieval |
| join_group | 11 | Consumer group joining |
| api_versions | 18 | Supported API versions |
| create_topics | 19 | Topic creation |

[See `api_keys.py` for complete mapping]

## Troubleshooting

### Consumer Offset Errors
If you see `InvalidReplicationFactorException`, the tool automatically configures single-broker replication factors in `docker-compose.yml`.

### Python Dependencies
All Python packages are automatically installed in `venv/` directory. If issues occur:
```bash
rm -rf venv/
./version-compatibility.sh --setup-env
```

### Consumer Test Issues
The `FetchSessionHandler` warning is normal and doesn't affect test results. The consumer should still show "Processed a total of 1 messages".

### Gateway Connection
Ensure gateway is responding at `http://localhost:9190/metrics`:
```bash
curl -s http://localhost:9190/metrics | grep kroxylicious
```

## Development

### File Structure
```
gateway-version-compatibility-test-tool/
├── version-compatibility.sh      # Main test script
├── docker-compose.yml            # Container orchestration (ZooKeeper servers)
├── docker-compose-kraft.yml      # Container orchestration (8.0.0+ KRaft servers)
├── docker-compose-tbm.yml        # Two clusters behind one dynamic route (TBM)
├── ci-report.sh / ci-push-results.sh  # CI: merge, upload and notify per suite
├── enhanced_metrics_parser.py    # Advanced metrics parser
├── api_keys.py                   # Kafka API mappings
├── requirements.txt              # Python dependencies
└── compatibility-results/        # Test outputs
```

### Adding New Versions
Update the version arrays in `version-compatibility.sh`:
```bash
CLIENTS=("7.9.0" "8.1.0")
SERVERS=("7.9.0" "8.1.0")
TBM_SERVER_PAIRS=("7.9.0 8.1.0")
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Test your changes with `--single` mode first
4. Submit a pull request

## License

[Add your license information here]
