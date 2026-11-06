#!/bin/bash

# SSL Certificate Download and Truststore Creation Script
# Downloads CA certificates from any SSL server and creates a Java truststore

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Default values
DEFAULT_PASSWORD="confluent"
DEFAULT_BOOTSTRAP="pkc-12576z.us-west2.gcp.confluent.cloud:9092"

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS] [BOOTSTRAP_SERVER]"
    echo ""
    echo "Downloads SSL certificates and creates a Java truststore"
    echo ""
    echo "Arguments:"
    echo "  BOOTSTRAP_SERVER    Server to download certificates from"
    echo "                      Default: $DEFAULT_BOOTSTRAP"
    echo ""
    echo "Options:"
    echo "  -d, --dir DIR       Directory to store certificates"
    echo "                      Default: ssl/<server_domain>"
    echo "  -p, --password PASS Truststore password"
    echo "                      Default: $DEFAULT_PASSWORD"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0"
    echo "  $0 my-kafka.example.com:9092"
    echo "  $0 -d ssl/myserver -p mypassword kafka.example.com:9093"
}

# Function to extract domain from bootstrap server
extract_domain() {
    local bootstrap="$1"
    # Remove port and protocol if present
    echo "$bootstrap" | sed 's|.*://||' | sed 's|:.*||'
}

# Parse command line arguments
parse_args() {
    BOOTSTRAP_SERVER="$DEFAULT_BOOTSTRAP"
    SSL_DIR=""
    TRUSTSTORE_PASSWORD="$DEFAULT_PASSWORD"

    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--dir)
                SSL_DIR="$2"
                shift 2
                ;;
            -p|--password)
                TRUSTSTORE_PASSWORD="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -*)
                echo "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                BOOTSTRAP_SERVER="$1"
                shift
                ;;
        esac
    done

    # Set default SSL_DIR if not provided
    if [ -z "$SSL_DIR" ]; then
        local domain=$(extract_domain "$BOOTSTRAP_SERVER")
        SSL_DIR="ssl/$domain"
    fi

    # Set derived variables
    TRUSTSTORE_FILE="$SSL_DIR/truststore.p12"
    PASSWORD_FILE="$SSL_DIR/truststore.password"
    SERVER_DOMAIN=$(extract_domain "$BOOTSTRAP_SERVER")
}

# Function to print messages
print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_header() {
    echo -e "\n${BOLD}${BLUE}=== $1 ===${NC}"
}

# Check if required tools are available
check_prerequisites() {
    print_header "Checking Prerequisites"

    if ! command -v keytool &> /dev/null; then
        print_error "keytool not found. Please install Java JDK."
        exit 1
    fi

    if ! command -v openssl &> /dev/null; then
        print_error "openssl not found. Please install OpenSSL."
        exit 1
    fi

    print_success "Prerequisites check passed"
}

# Create directory structure
create_directories() {
    print_header "Creating Directory Structure"

    mkdir -p "$SSL_DIR"
    print_success "Created directory: $SSL_DIR"
}

# Download CA certificates from the server
download_certificates() {
    print_header "Downloading SSL Certificates"

    cd "$SSL_DIR"

    print_info "Fetching certificate chain from $BOOTSTRAP_SERVER..."
    print_info "Server domain: $SERVER_DOMAIN"

    # Get the certificate chain
    if ! echo | openssl s_client -servername "$SERVER_DOMAIN" -connect "$BOOTSTRAP_SERVER" -showcerts 2>/dev/null | \
    awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' > certificate-chain.pem; then
        print_error "Failed to connect to $BOOTSTRAP_SERVER"
        exit 1
    fi

    if [ ! -s certificate-chain.pem ]; then
        print_error "Failed to download certificate chain or no certificates found"
        exit 1
    fi

    print_success "Downloaded certificate chain to certificate-chain.pem"

    # Split the chain into individual certificates
    print_info "Splitting certificate chain..."
    # More robust certificate splitting using shell loops
    cert_num=1
    while IFS= read -r line; do
        if [[ "$line" == "-----BEGIN CERTIFICATE-----" ]]; then
            cert_file="cert${cert_num}.pem"
            echo "$line" > "$cert_file"
        elif [[ "$line" == "-----END CERTIFICATE-----" ]]; then
            echo "$line" >> "$cert_file"
            ((cert_num++))
        elif [[ -n "$cert_file" ]]; then
            echo "$line" >> "$cert_file"
        fi
    done < certificate-chain.pem

    # Count certificates
    cert_count=$(ls cert*.pem 2>/dev/null | wc -l)
    print_success "Split chain into $cert_count certificates"

    cd - > /dev/null
}

# Create truststore
create_truststore() {
    print_header "Creating Truststore"

    cd "$SSL_DIR"

    # Remove existing truststore if it exists
    if [ -f "truststore.p12" ]; then
        rm -f "truststore.p12"
        print_info "Removed existing truststore"
    fi

    # Add each certificate to the truststore
    cert_num=1
    for cert_file in cert*.pem; do
        if [ -f "$cert_file" ]; then
            print_info "Adding $cert_file to truststore as ca-cert-$cert_num..."
            keytool -import -alias "ca-cert-$cert_num" \
                    -file "$cert_file" \
                    -keystore "truststore.p12" \
                    -storepass "$TRUSTSTORE_PASSWORD" \
                    -storetype PKCS12 \
                    -noprompt
            ((cert_num++))
        fi
    done

    print_success "Created truststore: $TRUSTSTORE_FILE"

    cd - > /dev/null
}

# Create password file
create_password_file() {
    print_header "Creating Password File"

    echo "$TRUSTSTORE_PASSWORD" > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"

    print_success "Created password file: $PASSWORD_FILE"
}

# Verify truststore
verify_truststore() {
    print_header "Verifying Truststore"

    print_info "Listing certificates in truststore..."
    if keytool -list -keystore "$TRUSTSTORE_FILE" -storepass "$TRUSTSTORE_PASSWORD" > /dev/null 2>&1; then
        local cert_count=$(keytool -list -keystore "$TRUSTSTORE_FILE" -storepass "$TRUSTSTORE_PASSWORD" 2>/dev/null | grep -c "Certificate fingerprint")
        print_success "Truststore contains $cert_count certificate(s)"
    else
        print_error "Failed to verify truststore"
        exit 1
    fi
}

# Test SSL connection
test_connection() {
    print_header "Testing SSL Connection"

    print_info "Testing connection to $BOOTSTRAP_SERVER..."

    # Test with openssl using the downloaded certificates
    if echo | openssl s_client -connect "$BOOTSTRAP_SERVER" -CAfile "$SSL_DIR/certificate-chain.pem" -verify_return_error >/dev/null 2>&1; then
        print_success "SSL connection test passed"
    else
        print_warning "SSL connection test had warnings (this might be normal depending on the server configuration)"
    fi
}

# Cleanup temporary files
cleanup() {
    print_header "Cleaning Up"

    cd "$SSL_DIR"
    rm -f cert*.pem certificate-chain.pem
    print_success "Cleaned up temporary certificate files"
    cd - > /dev/null
}

# Show final summary
show_summary() {
    print_header "Setup Summary"

    echo -e "${BOLD}Configuration Details:${NC}"
    echo "  Server:      $BOOTSTRAP_SERVER"
    echo "  Domain:      $SERVER_DOMAIN"
    echo "  Directory:   $SSL_DIR"
    echo "  Password:    $TRUSTSTORE_PASSWORD"
    echo ""
    echo -e "${BOLD}Files Created:${NC}"
    echo "  📁 $TRUSTSTORE_FILE"
    echo "  🔑 $PASSWORD_FILE"
    echo ""
    echo -e "${BOLD}Usage in Configuration:${NC}"
    echo "  tls:"
    echo "    trust:"
    echo "      storeFile: ./$TRUSTSTORE_FILE"
    echo "      storePassword:"
    echo "        passwordFile: ./$PASSWORD_FILE"
}

# Main execution
main() {
    echo -e "${BOLD}${GREEN}"
    echo "🔒 SSL Certificate Download & Truststore Creation"
    echo "================================================"
    echo -e "${NC}"

    parse_args "$@"
    check_prerequisites
    create_directories
    download_certificates
    create_truststore
    create_password_file
    verify_truststore
    test_connection
    cleanup
    show_summary

    echo -e "\n${BOLD}${GREEN}🎉 Setup completed successfully!${NC}\n"
}

# Run main function
main "$@"