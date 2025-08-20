#!/usr/bin/env bash

export GATEWAY_IMAGE="519856050701.dkr.ecr.us-west-2.amazonaws.com/docker/prod/confluentinc/gateway:master-latest-ubi9"

echo "Starting Gateway container..."
docker compose -f gateway-compose.yaml down -v || true
docker compose -f gateway-compose.yaml up -d

echo "Gateway container started."
