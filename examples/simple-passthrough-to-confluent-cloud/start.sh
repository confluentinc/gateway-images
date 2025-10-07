#!/usr/bin/env bash

export GATEWAY_IMAGE="confluentinc/cpc-gateway:latest"

docker compose down -v || true
docker container prune -f || true
docker compose up -d
