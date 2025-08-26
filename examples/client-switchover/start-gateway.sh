#!/usr/bin/env bash

export GATEWAY_IMAGE="confluentinc/cpc-gateway:latest"

echo "Starting Gateway container..."
docker compose -f gateway-compose.yaml down -v || true
docker compose -f gateway-compose.yaml up -d

echo "Gateway container started."
