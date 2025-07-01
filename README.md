# gateway-images

This repository is part of the Confluent organization on GitHub.
It is public and open to contributions from the community.

Please see the LICENSE file for contribution terms.
Please see the CHANGELOG.md for details of recent updates.

# Build Docker Locally

```bash
export CONFLUENT_PACKAGES_REPO="https://staging-packages.confluent.io/rpm/8.0"
export CONFLUENT_VERSION=8.0.0
export DOCKER_REGISTRY="519856050701.dkr.ecr.us-west-2.amazonaws.com/docker/dev/"
export BUILD_NUMBER=$(date +%Y%m%d%H%M%S)
export GIT_COMMIT=$(git rev-parse HEAD)
export DOCKER_DEV_TAG="local-dev-${BUILD_NUMBER}-${GIT_COMMIT}"
export DOCKER_TAG=$DOCKER_DEV_TAG
```
