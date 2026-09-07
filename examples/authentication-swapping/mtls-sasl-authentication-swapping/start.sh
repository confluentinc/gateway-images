#!/usr/bin/env bash

export GATEWAY_IMAGE="confluentinc/cpc-gateway:latest"

export KAFKA_SERVER_JAAS_CONF="$(pwd)/../jaas-config-for-broker-authn.conf"
export GATEWAY_JAAS_TEMPLATE_FOR_GW_SWAPPING="$(pwd)/../jaas-template-for-gw-swapping.conf"

create_certificates() {
    echo "Creating certificates for mTLS authentication..."
    
    # Create certificates directory
    mkdir -p ssl
    
    # Create password file
    echo "password" > ssl/password.txt
    
    # Generate CA private key
    openssl genrsa -out ssl/ca-key.pem 4096
    
    # Generate CA certificate
    openssl req -new -x509 -days 365 -key ssl/ca-key.pem -out ssl/ca-cert.pem -subj "/C=US/ST=CA/L=San Francisco/O=Confluent/OU=Engineering/CN=Test-CA"
    
    # Generate server private key
    openssl genrsa -out ssl/server-key.pem 4096
    
    # Generate server certificate signing request
    openssl req -new -key ssl/server-key.pem -out ssl/server-csr.pem -subj "/C=US/ST=CA/L=San Francisco/O=Confluent/OU=Engineering/CN=localhost"
    
    # Generate server certificate signed by CA
    openssl x509 -req -days 365 -in ssl/server-csr.pem -CA ssl/ca-cert.pem -CAkey ssl/ca-key.pem -CAcreateserial -out ssl/server-cert.pem
    
    # Generate client private key
    openssl genrsa -out ssl/client-key.pem 4096
    
    # Generate client certificate signing request with test_user as CN
    openssl req -new -key ssl/client-key.pem -out ssl/client-csr.pem -subj "/C=US/ST=CA/L=San Francisco/O=Confluent/OU=Engineering/CN=test_user"
    
    # Generate client certificate signed by CA
    openssl x509 -req -days 365 -in ssl/client-csr.pem -CA ssl/ca-cert.pem -CAkey ssl/ca-key.pem -CAcreateserial -out ssl/client-cert.pem
    
    # Create JKS keystores via temporary PKCS12 keystores
    openssl pkcs12 -export -in ssl/server-cert.pem -inkey ssl/server-key.pem -out ssl/server-temp.p12 -name server -CAfile ssl/ca-cert.pem -caname ca -password pass:password
    keytool -importkeystore -srckeystore ssl/server-temp.p12 -srcstoretype PKCS12 -srcstorepass password -destkeystore ssl/server-keystore.jks -deststoretype JKS -deststorepass password -noprompt
    
    openssl pkcs12 -export -in ssl/client-cert.pem -inkey ssl/client-key.pem -out ssl/client-temp.p12 -name test_user -CAfile ssl/ca-cert.pem -caname ca -password pass:password
    keytool -importkeystore -srckeystore ssl/client-temp.p12 -srcstoretype PKCS12 -srcstorepass password -destkeystore ssl/client-keystore.jks -deststoretype JKS -deststorepass password -noprompt
    
    # Create truststore with CA certificate
    keytool -import -file ssl/ca-cert.pem -alias ca -keystore ssl/truststore.jks -storepass password -noprompt
    
    # Remove temporary PKCS12 files
    rm ssl/server-temp.p12 ssl/client-temp.p12
    
    # Set proper permissions
    chmod 644 ssl/*.pem ssl/*.jks
    chmod 600 ssl/*-key.pem ssl/password.txt
    
    echo "Certificates created successfully:"
    echo "  - CA Certificate: ssl/ca-cert.pem"
    echo "  - Server Certificate: ssl/server-cert.pem (CN=localhost)"
    echo "  - Client Certificate: ssl/client-cert.pem (CN=test_user)"
    echo "  - Server Keystore: ssl/server-keystore.jks (password: password)"
    echo "  - Client Keystore: ssl/client-keystore.jks (password: password)"
    echo "  - Truststore: ssl/truststore.jks (password: password)"
}

if [ ! -d "ssl" ] || [ ! -f "ssl/server-keystore.jks" ] || [ ! -f "ssl/client-keystore.jks" ] || [ ! -f "ssl/truststore.jks" ]; then
    create_certificates
else
    echo "SSL certificates already exist, skipping certificate generation."
fi

docker compose down -v || true
docker container prune -f || true
docker compose up -d
