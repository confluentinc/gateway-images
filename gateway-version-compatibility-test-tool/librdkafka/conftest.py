"""
Pytest configuration and shared fixtures for librdkafka version compatibility tests.

Handles PLAINTEXT, SASL_PLAINTEXT, and SSL authentication modes via environment variables,
mirroring the Java test's configuration pattern.
"""

import os
import time
import pytest


def get_base_config():
    """Build base Kafka client configuration from environment variables."""
    bootstrap_servers = os.environ.get("BOOTSTRAP_SERVERS", "gateway:19092")
    config = {
        "bootstrap.servers": bootstrap_servers,
    }

    sasl_enabled = os.environ.get("KAFKA_SASL_ENABLED", "").lower() == "true"
    ssl_enabled = os.environ.get("KAFKA_SSL_ENABLED", "").lower() == "true"

    if ssl_enabled and not sasl_enabled:
        config["security.protocol"] = "SSL"
        config["ssl.ca.location"] = "/etc/kafka/secrets/ca-cert"
        config["enable.ssl.certificate.verification"] = False
    elif sasl_enabled:
        mechanism = os.environ.get("KAFKA_SASL_MECHANISM", "PLAIN")
        username = os.environ.get("KAFKA_SASL_USERNAME", "admin")
        password = os.environ.get("KAFKA_SASL_PASSWORD", "admin-secret")
        config["security.protocol"] = "SASL_PLAINTEXT"
        config["sasl.mechanism"] = mechanism
        config["sasl.username"] = username
        config["sasl.password"] = password

    return config


@pytest.fixture(scope="session")
def base_config():
    """Session-scoped base Kafka config dict."""
    return get_base_config()


@pytest.fixture(scope="session")
def bootstrap_servers():
    """Bootstrap servers string."""
    return os.environ.get("BOOTSTRAP_SERVERS", "gateway:19092")


@pytest.fixture
def unique_topic():
    """Generate a unique topic name for each test."""
    return f"test-topic-{int(time.time() * 1000)}"


@pytest.fixture
def producer_config(base_config):
    """Producer configuration with defaults."""
    config = dict(base_config)
    config["acks"] = "all"
    return config


@pytest.fixture
def consumer_config(base_config):
    """Consumer configuration with defaults."""
    config = dict(base_config)
    config["group.id"] = f"test-group-{int(time.time() * 1000)}"
    config["auto.offset.reset"] = "earliest"
    config["enable.auto.commit"] = True
    return config


@pytest.fixture
def admin_config(base_config):
    """Admin client configuration."""
    config = dict(base_config)
    config["request.timeout.ms"] = 10000
    return config


@pytest.fixture
def reauth_producer_config():
    """SASL/PLAIN producer config for the AuthSwap reauth route (reauth tests only)."""
    return {
        "bootstrap.servers": os.environ.get("REAUTH_BOOTSTRAP_SERVERS", "gateway:19092"),
        "security.protocol": "SASL_PLAINTEXT",
        "sasl.mechanism": "PLAIN",
        "sasl.username": os.environ.get("REAUTH_SASL_USERNAME", "user1"),
        "sasl.password": os.environ.get("REAUTH_SASL_PASSWORD", "user1-secret"),
        "acks": "all",
    }


@pytest.fixture
def jaas_config_path():
    """Path inside this container to the gateway's mutable client-auth JAAS file.

    The docker-compose-librdkafka-reauth-kraft.yml bind-mounts the host configs/
    directory into the gateway (as /etc/gateway/config) and into this container
    (as /mutable-configs).  Writing to this path is therefore immediately visible
    to the gateway, which hot-reloads the file — mirroring
    authSwapFeature.removeUserFromClientJaasConfig() in the Java integration test.
    """
    return os.environ.get("GATEWAY_JAAS_CONFIG_PATH", "/mutable-configs/jaas-gw-authn.conf")
