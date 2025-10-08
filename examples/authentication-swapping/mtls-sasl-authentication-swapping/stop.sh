#!/usr/bin/env bash

# Set required environment variables
export KAFKA_SERVER_JAAS_CONF="$(pwd)/../jaas-config-for-broker-authn.conf"
export GATEWAY_JAAS_TEMPLATE_FOR_GW_SWAPPING="$(pwd)/../jaas-template-for-gw-swapping.conf"

echo "Stopping mTLS SASL Authentication Swapping example..."

docker compose down -v

docker container prune -f

echo "Services stopped successfully."

read -p "Do you want to remove the generated SSL certificates? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if [ -d "ssl" ]; then
        echo "Removing SSL certificates..."
        rm -rf ssl/
        echo "SSL certificates removed."
    else
        echo "No SSL directory found."
    fi
else
    echo "SSL certificates preserved."
fi

echo "Cleanup completed."
