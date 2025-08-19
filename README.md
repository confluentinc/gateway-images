# gateway-images

This repository hosts the docker image source files for Confluent Private Cloud Gateway. Please checkout the examples section more details on Confluent Private Cloud Gateway and how to get started with it.

It is part of the Confluent organization on GitHub. It is public and open to contributions from the community.

Please see the LICENSE file for contribution terms.
Please see the CHANGELOG.md for details of recent updates.

# Build Docker Locally

## Export Environment Variables
```bash
export CONFLUENT_PACKAGES_REPO="https://staging-packages.confluent.io/rpm/8.0"
export GATEWAY_VERSION=1.0.0
export DOCKER_REGISTRY="519856050701.dkr.ecr.us-west-2.amazonaws.com/docker/dev/"
export BUILD_NUMBER=$(date +%Y%m%d%H%M%S)
export GIT_COMMIT=$(git rev-parse HEAD)
export DOCKER_DEV_TAG="local-dev-${BUILD_NUMBER}-${GIT_COMMIT}"
export DOCKER_TAG=$DOCKER_DEV_TAG
```

# Build the Docker image
```bash
./mvnw \
  -Dmaven.wagon.http.retryHandler.count=3 \
  --batch-mode \
  -P docker-arm \
  clean package dependency:analyze validate -U \
  -Ddocker.registry=$DOCKER_REGISTRY \
  -Ddocker.upstream-registry=$DOCKER_UPSTREAM_REGISTRY \
  -DBUILD_NUMBER=$BUILD_NUMBER \
  -DGIT_COMMIT=$GIT_COMMIT \
  -Ddocker.tag=$DOCKER_DEV_TAG$OS_TAG$AMD_ARCH \
  -Ddocker.upstream-tag=$DOCKER_UPSTREAM_TAG$OS_TAG \
  -Darch.type=$AMD_ARCH \
  -Ddocker.os_type=ubi9
```

# Run Docker
```bash
export DOCKER_REGISTRY="519856050701.dkr.ecr.us-west-2.amazonaws.com/docker/dev/"
export GATEWAY_DOCKER_IMAGE=$DOCKER_REGISTRY/confluentinc/gateway:dev-master-d1f36e72-ubi9.arm64
docker compose up -d
```