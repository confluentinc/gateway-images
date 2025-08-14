#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSL_DIR="${SCRIPT_DIR}/ssl"
STOREPASS="confluent"
KEYPASS="confluent"

mkdir -p "${SSL_DIR}"

echo "Cleaning up existing certificates..."
rm -f "${SSL_DIR}"/*.jks "${SSL_DIR}"/*.pwd "${SSL_DIR}"/*.key "${SSL_DIR}"/*.crt "${SSL_DIR}"/*.csr "${SSL_DIR}"/*.p12 "${SSL_DIR}"/*.ext "${SSL_DIR}"/*.srl

echo "Generating TLS artifacts under ${SSL_DIR} ..."
  docker run --rm -u 0:0 -v "${SSL_DIR}:/ssl" confluentinc/cp-server:latest bash -lc '
    set -euo pipefail
    SSL_DIR="/ssl"
    STOREPASS="'"${STOREPASS}"'"
    KEYPASS="'"${KEYPASS}"'"
    cd "$SSL_DIR"

    echo "Creating local CA ..."
    openssl genrsa -out ca.key 4096
    openssl req -x509 -new -nodes -key ca.key -sha256 -days 365 -subj "/CN=Local Test CA" -out ca.crt

    gen_identity() {
      local name="$1" alias="$2" sans="$3"
      echo "Generating identity for ${name} (${alias}) ..."
      openssl genrsa -out "${name}.key" 2048
      openssl req -new -key "${name}.key" -subj "/CN=${alias}" -out "${name}.csr"
      printf "subjectAltName=%s\n" "${sans}" > "${name}.ext"
      openssl x509 -req -in "${name}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
        -out "${name}.crt" -days 365 -sha256 -extfile "${name}.ext"
      openssl pkcs12 -export -name "${alias}" -in "${name}.crt" -inkey "${name}.key" \
        -out "${name}.p12" -passout pass:"$STOREPASS"
      keytool -importkeystore \
        -deststorepass "$STOREPASS" -destkeypass "$KEYPASS" -destkeystore "${name}.keystore.jks" \
        -srckeystore "${name}.p12" -srcstoretype PKCS12 -srcstorepass "$STOREPASS" -alias "${alias}"
      keytool -import -trustcacerts -noprompt -alias local-ca -file ca.crt \
        -keystore "${name}.truststore.jks" -storepass "$STOREPASS"
    }

    # SANs for gateway must match how clients connect (host.docker.internal/localhost/127.0.0.1)
    gen_identity "gateway" "gateway" "DNS:gateway,DNS:host.docker.internal,DNS:broker1.host.docker.internal,DNS:localhost,IP:127.0.0.1"
    gen_identity "client" "client" "DNS:client"

    printf "%s" "$STOREPASS" > gateway.keystore.pwd
    printf "%s" "$KEYPASS" > gateway.key.pwd
    printf "%s" "$STOREPASS" > gateway.truststore.pwd

    chmod 600 \
      gateway.keystore.jks gateway.truststore.jks client.keystore.jks client.truststore.jks \
      gateway.keystore.pwd gateway.key.pwd gateway.truststore.pwd || true

    echo "TLS artifacts generated."
  '

cd "${SCRIPT_DIR}"


docker-compose up --no-recreate -d kafka-1 gateway
