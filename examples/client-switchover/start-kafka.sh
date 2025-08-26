#!/usr/bin/env bash

export KAFKA_SERVER_JAAS_CONF="$(pwd)/kafka_server_jaas.conf"

echo "Starting Kafka containers..."
docker compose -f kafka-compose.yaml down -v || true
docker compose -f kafka-compose.yaml up -d

echo "Kafka containers started. You can now start the Gateway with: ./start-gateway.sh"
