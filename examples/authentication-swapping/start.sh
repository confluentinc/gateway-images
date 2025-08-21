#!/usr/bin/env bash

export GATEWAY_IMAGE="confluentinc/cpc-gateway:latest"

export KAFKA_SERVER_JAAS_CONF="$(pwd)/jaas-config-for-broker-authn.conf"
export GATEWAY_JAAS_CONF_FOR_GW_AUTHN="$(pwd)/jaas-config-for-gw-authn.conf"
export GATEWAY_JAAS_TEMPLATE_FOR_GW_SWAPPING="$(pwd)/jaas-template-for-gw-swapping.conf"

# AWS Credentials for authentication swapping
export AWS_ACCESS_KEY="<your-aws-access-key>"
export AWS_SECRET_KEY="<your-aws-secret-key>"

docker compose down -v || true
docker container prune -f || true
docker compose up -d
