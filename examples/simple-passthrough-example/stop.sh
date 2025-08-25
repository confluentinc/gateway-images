export GATEWAY_IMAGE="confluentinc/cpc-gateway:latest"
export KAFKA_SERVER_JAAS_CONF="$(pwd)/kafka_server_jaas.conf"

docker compose down -v || true
docker container prune -f || true
