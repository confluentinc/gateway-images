#!/usr/bin/env bash

export GATEWAY_IMAGE="confluentinc/cpc-gateway:latest"

export KAFKA_SERVER_JAAS_CONF="$(pwd)/jaas-config-for-broker-authn.conf"
export GATEWAY_JAAS_TEMPLATE_FOR_GW_SWAPPING="$(pwd)/jaas-template-for-gw-swapping.conf"

docker compose down -v || true
docker container prune -f || true

# 2. Start only vault first
docker compose up -d vault

# 3. Wait for vault to be ready (watch for "sealed: false")
echo "Waiting for Vault..."
until curl -sf http://localhost:8200/v1/sys/health | grep -q '"sealed":false'; do
  sleep 2
  echo "  still waiting..."
done
echo "Vault is ready!"

# 4. Add SCRAM authentication secrets to Vault
echo "Adding secrets to Vault..."
docker exec -e VAULT_TOKEN=vault-plaintext-root-token vault vault kv put secret/admin-user password=admin/admin-secret
docker exec -e VAULT_TOKEN=vault-plaintext-root-token vault vault kv put secret/test_user password=test_user/swapped_password

# 5. Verify the secrets were created
echo "Verifying secrets..."
docker exec -e VAULT_TOKEN=vault-plaintext-root-token vault vault kv get secret/admin-user
docker exec -e VAULT_TOKEN=vault-plaintext-root-token vault vault kv get secret/test_user

# 4. Verify the secret was created
curl -s -H "X-Vault-Token: vault-plaintext-root-token" \
  http://localhost:8200/v1/secret/data/testing

# 5. Now start kafka and gateway
docker compose up -d kafka-1
sleep 10
docker compose up -d gateway

