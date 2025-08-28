#!/bin/bash

# Helper script to add required /etc/hosts entries for Gateway SNI routing

echo "🌐 Adding /etc/hosts entries for Gateway SNI-based routing..."

HOSTS_FILE="/etc/hosts"
TEMP_FILE=$(mktemp)

# Check if running with sudo
if [ "$EUID" -ne 0 ]; then
    echo "⚠️ This script requires root privileges to modify /etc/hosts"
    echo "💡 Run with: sudo ./add-hosts.sh"
    exit 1
fi

# Backup current hosts file
cp "$HOSTS_FILE" "${HOSTS_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
echo "📋 Backup created: ${HOSTS_FILE}.backup.$(date +%Y%m%d_%H%M%S)"

# Remove any existing entries for our domains
echo "🧹 Removing any existing entries..."
grep -v "kafka.gateway.local\|broker1.kafka.gateway.local" "$HOSTS_FILE" > "$TEMP_FILE"

# Add our entries
echo "➕ Adding new entries..."
echo "" >> "$TEMP_FILE"
echo "# Gateway SNI-Based Routing entries (added by start.sh)" >> "$TEMP_FILE"
echo "127.0.0.1   kafka.gateway.local broker1.kafka.gateway.local" >> "$TEMP_FILE"

# Replace hosts file
mv "$TEMP_FILE" "$HOSTS_FILE"

echo "✅ /etc/hosts updated successfully!"
echo ""
echo "📋 Added entries:"
echo "  127.0.0.1   kafka.gateway.local"
echo "  127.0.0.1   broker1.kafka.gateway.local"
echo ""
echo "🔍 Current entries:"
grep "gateway.local" "$HOSTS_FILE" | sed 's/^/  /'
