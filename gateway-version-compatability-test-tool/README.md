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
cd gateway-version-compatability-test-tool

# Set up Python environment (one-time setup)
./version-compatability.sh --setup-env

# Run all compatibility tests (16 combinations)
./version-compatability.sh --run

# Or test a single combination
./version-compatability.sh --single 7.6.0 7.8.0
```

## Usage Options

| Command | Description |
|---------|-------------|
| `--run` | Run all test combinations |
| `--single <client> <server>` | Test single client-server combination |
| `--parse <results_dir>` | Re-parse existing results |
| `--setup-env` | Set up Python environment only |

### Example Usage

```bash
# Test all combinations
./version-compatability.sh --run

# Test specific versions
./version-compatability.sh --single 7.8.0 8.0.0

# Parse existing results
./version-compatability.sh --parse compatibility-results/20240903_090000
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
./version-compatability.sh --setup-env
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
gateway-version-compatability-test-tool/
├── version-compatability.sh      # Main test script
├── docker-compose.yml            # Container orchestration
├── enhanced_metrics_parser.py    # Advanced metrics parser
├── api_keys.py                   # Kafka API mappings
├── requirements.txt              # Python dependencies
└── compatibility-results/        # Test outputs
```

### Adding New Versions
Update the version arrays in `version-compatability.sh`:
```bash
CLIENTS=("7.9.0" "8.1.0")
SERVERS=("7.9.0" "8.1.0")
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Test your changes with `--single` mode first
4. Submit a pull request

## License

[Add your license information here]
