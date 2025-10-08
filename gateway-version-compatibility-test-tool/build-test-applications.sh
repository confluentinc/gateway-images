#!/bin/bash
# Build Advanced Kafka Test Suite for multiple client versions

echo "🔨 Building Advanced Kafka Test Suite for multiple client versions..."

# Check if Maven is available
if ! command -v mvn &> /dev/null; then
    echo "❌ Maven not found. Please install Maven to build Java test applications."
    echo "   On macOS: brew install maven"
    echo "   On Ubuntu: sudo apt-get install maven"
    exit 1
fi

# Create target directory for versioned JARs
mkdir -p target

# Client versions to build for
CLIENT_VERSIONS=("7.4.0" "7.5.0" "7.6.0" "7.7.0" "7.8.0" "7.9.0" "8.0.0")

echo "Building test applications for client versions: ${CLIENT_VERSIONS[*]}"

# Initial clean to start fresh
echo "🧹 Cleaning previous builds..."
mvn clean -q

# Build counter
successful_builds=0
total_builds=${#CLIENT_VERSIONS[@]}

for version in "${CLIENT_VERSIONS[@]}"; do
    echo ""
    echo "🔨 Building for Kafka client version: $version"
    
    # Create version-specific directory first
    mkdir -p target/$version
    
    # Build with specific version
    mvn package -Dkafka.client.version=$version -q
    
    if [ $? -eq 0 ]; then
        # The JAR file name uses just the version number (without -ce suffix)
        source_jar="target/advanced-kafka-test-suite-${version}.jar"
        dest_jar="target/$version/advanced-kafka-test-suite-${version}.jar"
        
        if [ -f "$source_jar" ]; then
            # Copy immediately after successful build
            cp "$source_jar" "$dest_jar"
            echo "✅ Successfully built for client version $version"
            ((successful_builds++))
        else
            echo "❌ JAR file not found: $source_jar"
            echo "Available files:"
            ls -la target/*.jar 2>/dev/null || echo "No JAR files found"
        fi
    else
        echo "❌ Failed to build for client version $version"
    fi
done

echo ""
echo "🎉 Build process completed!"
echo "📊 Successfully built: $successful_builds/$total_builds versions"

if [ $successful_builds -eq $total_builds ]; then
    echo "✅ All versions built successfully!"
else
    echo "⚠️  Some versions failed to build. Check Maven dependencies and connectivity."
fi

# List generated JARs
echo ""
echo "📋 Generated JAR files:"
find target -name "*.jar" -type f | sort
