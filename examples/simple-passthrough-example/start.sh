#!/usr/bin/env bash

export GATEWAY_IMAGE="519856050701.dkr.ecr.us-west-2.amazonaws.com/docker/prod/confluentinc/gateway:master-latest-ubi9"

export KAFKA_SERVER_JAAS_CONF="$(pwd)/kafka_server_jaas.conf"

docker compose down -v || true
docker container prune -f || true
docker compose up -d
