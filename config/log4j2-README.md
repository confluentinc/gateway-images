# Log4j2 YAML Configuration for Gateway

This file contains the Log4j2 logging configuration in YAML format.

## Features

- **Console output**: Immediate visibility of logs
- **Rolling file logs**: Main application logs with automatic rotation
- **Startup/shutdown logs**: Separate log file for initialization events
- **Multiple loggers**: Configured for different components:
  - `io.confluent.gateway.*` - Gateway application logs
  - `io.kroxylicious.*` - Kroxylicious proxy logs  
  - Third-party libraries (Kafka, Jetty, Netty) with reduced verbosity

## Log Files

- `logs/gateway.log` - Main application logs (rotates at 100MB, keeps 10 files)
- `logs/gateway-startup.log` - Startup/shutdown events (rotates at 50MB, keeps 5 files)

## Customization

You can modify log levels by editing the Logger sections:

```yaml
Logger:
  - name: io.confluent.gateway
    level: DEBUG  # Change from INFO to DEBUG for more verbose logging
```

## Environment Variables

- `LOG_DIR` - Directory for log files (default: logs/)
- `GATEWAY_LOG4J_OPTS` - Override log4j configuration file location

## Alternative Configuration

You can specify a different log4j2 configuration file:

```bash
GATEWAY_LOG4J_OPTS="-Dlog4j.configurationFile=file:/path/to/custom-log4j2.yaml" ./bin/gateway-start -c config/gateway-config.yaml
```