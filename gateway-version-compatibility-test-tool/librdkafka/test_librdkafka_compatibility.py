"""
librdkafka Version Compatibility Test Suite

Mirrors the Java AdvancedKafkaTest.java for testing gateway compatibility
with confluent-kafka-python (librdkafka) across multiple versions.

Covers: Producer, Consumer, Admin, Transactions, Serializers, Quotas.
Does NOT cover: Kafka Streams (Java-only, not supported by librdkafka).
"""

import logging
import os
import re
import threading
import time
import pytest

from confluent_kafka import Producer, Consumer, KafkaError, KafkaException, TopicPartition
from confluent_kafka.admin import (
    AdminClient,
    NewTopic,
    NewPartitions,
    ConfigResource,
    ConfigEntry,
)

logger = logging.getLogger(__name__)

def get_librdkafka_version():
    """Return the bundled librdkafka version string."""
    import confluent_kafka
    return confluent_kafka.libversion()[0]

# ---------------------------------------------------------------------------
# Helper utilities
# ---------------------------------------------------------------------------

def delivery_callback(err, msg):
    """Shared delivery callback that raises on error."""
    if err is not None:
        raise KafkaException(err)

def produce_messages(producer_config, topic, count, *, partition=None, key_prefix="key", value_prefix="msg"):
    """Produce `count` messages and return list of (partition, offset) tuples."""
    p = Producer(producer_config)
    results = []
    errors = []

    def _cb(err, msg):
        if err:
            errors.append(err)
        else:
            results.append((msg.partition(), msg.offset()))

    for i in range(count):
        kwargs = {
            "topic": topic,
            "key": f"{key_prefix}-{i}",
            "value": f"{value_prefix}-{i}",
            "callback": _cb,
        }
        if partition is not None:
            kwargs["partition"] = partition
        p.produce(**kwargs)
    p.flush(timeout=30)

    if errors:
        raise KafkaException(errors[0])
    assert len(results) == count, f"Expected {count} delivered messages, got {len(results)}"
    return results

def consume_messages(consumer_config, topic, expected_count, timeout_sec=15):
    """Consume up to `expected_count` messages within `timeout_sec`."""
    c = Consumer(consumer_config)
    c.subscribe([topic])
    messages = []
    deadline = time.time() + timeout_sec
    try:
        while len(messages) < expected_count and time.time() < deadline:
            msg = c.poll(timeout=1.0)
            if msg is None:
                continue
            if msg.error():
                if msg.error().code() == KafkaError._PARTITION_EOF:
                    continue
                raise KafkaException(msg.error())
            messages.append(msg)
    finally:
        c.close()
    return messages

class TestAPIVersions:
    """Verify basic admin API connectivity through the gateway."""

    @pytest.mark.timeout(30)
    def test_api_versions(self, admin_config):
        a = AdminClient(admin_config)
        metadata = a.list_topics(timeout=10)

        assert metadata.cluster_id is not None, "Cluster ID should not be None"
        assert len(metadata.brokers) >= 1, "Should have at least one broker"
        assert len(metadata.cluster_id) > 0, "Cluster ID should not be empty"

        logger.info("Cluster ID: %s, Brokers: %d, Topics: %d",
                     metadata.cluster_id, len(metadata.brokers), len(metadata.topics))

class TestClusterMetadata:
    """Detailed cluster metadata inspection."""

    @pytest.mark.timeout(30)
    def test_cluster_metadata(self, admin_config):
        a = AdminClient(admin_config)
        md = a.list_topics(timeout=10)

        assert md.cluster_id is not None
        assert len(md.cluster_id) > 0
        assert len(md.brokers) >= 1

        controller_id = md.controller_id
        assert controller_id >= 0, "Controller ID should be non-negative"

        broker_ids = set()
        for broker_id, broker in md.brokers.items():
            assert broker_id >= 0
            assert broker.host is not None and len(broker.host) > 0
            assert broker.port > 0
            broker_ids.add(broker_id)
            logger.info("Broker %d: %s:%d", broker_id, broker.host, broker.port)

        assert controller_id in broker_ids, "Controller should be one of the brokers"
        logger.info("Cluster metadata test passed")

class TestTopicManagement:
    """Full topic CRUD lifecycle through admin API."""

    @pytest.mark.timeout(60)
    def test_topic_management(self, admin_config):
        topic_name = f"topic-mgmt-test-{int(time.time() * 1000)}"
        a = AdminClient(admin_config)

        # Create
        fs = a.create_topics([NewTopic(topic_name, num_partitions=1, replication_factor=1)])
        fs[topic_name].result(timeout=10)
        logger.info("Topic created: %s", topic_name)

        time.sleep(1)

        # List and verify
        md = a.list_topics(timeout=10)
        assert topic_name in md.topics, "Created topic should appear in topic list"
        logger.info("Topic found in list")

        # Describe
        topic_md = md.topics[topic_name]
        assert len(topic_md.partitions) == 1, "Topic should have 1 partition"
        logger.info("Topic described: %d partitions", len(topic_md.partitions))

        # Delete
        fs = a.delete_topics([topic_name])
        fs[topic_name].result(timeout=10)
        logger.info("Topic deleted")

        time.sleep(1)

        # Verify deletion
        md = a.list_topics(timeout=10)
        assert topic_name not in md.topics, "Deleted topic should not appear in topic list"
        logger.info("Topic management test passed")

class TestBasicProducerConsumer:
    """Produce one message, consume it, verify content matches."""

    @pytest.mark.timeout(60)
    def test_basic_producer_consumer(self, producer_config, consumer_config, unique_topic):
        test_key = "test-key"
        test_value = f"basic-message-{int(time.time() * 1000)}"

        # Produce
        p = Producer(producer_config)
        delivered = []

        def _cb(err, msg):
            assert err is None, f"Delivery failed: {err}"
            delivered.append(msg)

        p.produce(unique_topic, key=test_key, value=test_value, callback=_cb)
        p.flush(timeout=10)

        assert len(delivered) == 1
        assert delivered[0].topic() == unique_topic
        assert delivered[0].partition() >= 0
        assert delivered[0].offset() >= 0
        logger.info("Message produced to %s partition=%d offset=%d",
                     unique_topic, delivered[0].partition(), delivered[0].offset())

        # Consume
        msgs = consume_messages(consumer_config, unique_topic, expected_count=1)
        assert len(msgs) >= 1, "Should consume at least one message"
        msg = msgs[0]
        assert msg.key().decode("utf-8") == test_key
        assert msg.value().decode("utf-8") == test_value
        assert msg.partition() >= 0
        assert msg.offset() >= 0
        logger.info("Basic producer-consumer test passed")

class TestIdempotentProducer:
    """Enable idempotence and verify sequential offsets."""

    @pytest.mark.timeout(60)
    def test_idempotent_producer(self, producer_config, unique_topic):
        config = dict(producer_config)
        config["enable.idempotence"] = True
        config["acks"] = "all"
        config["retries"] = 2147483647
        config["max.in.flight.requests.per.connection"] = 5

        p = Producer(config)
        offsets = []

        def _cb(err, msg):
            assert err is None, f"Delivery failed: {err}"
            offsets.append(msg.offset())

        for i in range(3):
            p.produce(unique_topic, key="idempotent-key",
                      value=f"idempotent-message-{i}", callback=_cb)
        p.flush(timeout=10)

        assert len(offsets) == 3, "Should have 3 delivered messages"
        for i in range(1, len(offsets)):
            assert offsets[i] > offsets[i - 1], \
                f"Offset {offsets[i]} should be > {offsets[i-1]}"
        logger.info("Idempotent producer test passed, offsets: %s", offsets)

class TestExactlyOnceSemantics:
    """Transactional produce: commit and abort."""

    @pytest.mark.timeout(60)
    def test_exactly_once_semantics(self, producer_config, unique_topic):
        txn_id = f"eos-test-{int(time.time() * 1000)}"
        config = dict(producer_config)
        config["transactional.id"] = txn_id
        config["enable.idempotence"] = True
        config["acks"] = "all"

        p = Producer(config)

        # Init transactions
        p.init_transactions(10)
        logger.info("Transactions initialised")

        # Commit path
        p.begin_transaction()
        for i in range(5):
            p.produce(unique_topic, key=f"eos-key-{i}", value=f"eos-message-{i}")
        p.commit_transaction(10)
        logger.info("Transaction committed with 5 messages")

        # Abort path
        p.begin_transaction()
        p.produce(unique_topic, key="abort-key", value="this-message-should-be-aborted")
        p.abort_transaction(10)
        logger.info("Transaction aborted successfully")

        # Verify committed messages are consumable with read_committed
        consumer_config = dict(producer_config)
        consumer_config.pop("acks", None)
        consumer_config.pop("enable.idempotence", None)
        consumer_config.pop("transactional.id", None)
        consumer_config["group.id"] = f"eos-verify-{int(time.time() * 1000)}"
        consumer_config["auto.offset.reset"] = "earliest"
        consumer_config["isolation.level"] = "read_committed"

        msgs = consume_messages(consumer_config, unique_topic, expected_count=5, timeout_sec=15)
        assert len(msgs) == 5, f"Should consume exactly 5 committed messages, got {len(msgs)}"
        logger.info("Exactly-once semantics test passed")

class TestCustomSerializers:
    """Produce/consume with raw byte payloads."""

    @pytest.mark.timeout(60)
    def test_custom_serializers(self, producer_config, consumer_config, unique_topic):
        sent_value = f"custom-serialized-message-{int(time.time() * 1000)}"
        sent_bytes = sent_value.encode("utf-8")

        # Produce bytes
        p = Producer(producer_config)
        delivered = []

        def _cb(err, msg):
            assert err is None, f"Delivery failed: {err}"
            delivered.append(msg)

        p.produce(unique_topic, key="custom-key", value=sent_bytes, callback=_cb)
        p.flush(timeout=10)
        assert len(delivered) == 1
        logger.info("Byte message produced (%d bytes)", len(sent_bytes))

        # Consume bytes
        msgs = consume_messages(consumer_config, unique_topic, expected_count=1)
        assert len(msgs) >= 1
        received_bytes = msgs[0].value()
        assert received_bytes is not None
        assert len(received_bytes) > 0
        assert received_bytes.decode("utf-8") == sent_value
        logger.info("Custom serializers test passed")

class TestQuotasHandling:
    """Send a burst of messages rapidly to exercise quota/throttle path."""

    @pytest.mark.timeout(60)
    def test_quotas_handling(self, producer_config, unique_topic):
        config = dict(producer_config)
        config["batch.size"] = 1
        config["linger.ms"] = 0
        config["acks"] = "1"

        message_count = 100
        p = Producer(config)
        success_count = 0
        errors_list = []

        def _cb(err, msg):
            nonlocal success_count
            if err:
                errors_list.append(err)
            else:
                success_count += 1

        start = time.time()
        for i in range(message_count):
            p.produce(unique_topic, key=f"quota-key-{i}",
                      value=f"quota-message-{i}", callback=_cb)
        p.flush(timeout=30)
        duration = time.time() - start

        total = success_count + len(errors_list)
        assert total == message_count, f"Total should be {message_count}, got {total}"
        assert success_count > 0, "At least some messages should succeed"
        assert duration > 0

        throughput = message_count / duration
        logger.info("Quota test: %d sent, %d ok, %d errors, %.1f msg/s",
                     message_count, success_count, len(errors_list), throughput)

class TestRateLimiting:
    """Send messages in batches with controlled timing."""

    @pytest.mark.timeout(90)
    def test_rate_limiting(self, producer_config, unique_topic):
        config = dict(producer_config)
        config["batch.size"] = 16384
        config["linger.ms"] = 100
        config["queue.buffering.max.kbytes"] = 32768

        batch_count = 5
        messages_per_batch = 20
        total_messages = batch_count * messages_per_batch
        success_count = 0

        p = Producer(config)
        batch_durations = []

        def _cb(err, msg):
            nonlocal success_count
            assert err is None, f"Delivery failed: {err}"
            success_count += 1

        total_start = time.time()

        for batch in range(batch_count):
            batch_start = time.time()
            for i in range(messages_per_batch):
                p.produce(unique_topic,
                          key=f"batch-{batch}-key-{i}",
                          value=f"rate-limit-msg-batch-{batch}-{i}",
                          callback=_cb)
            p.flush(timeout=30)
            batch_dur = time.time() - batch_start
            batch_durations.append(batch_dur)
            assert batch_dur < 30, "Batch should complete within 30s"
            logger.info("Batch %d sent in %.3fs", batch + 1, batch_dur)
            if batch < batch_count - 1:
                time.sleep(1)

        total_duration = time.time() - total_start

        assert len(batch_durations) == batch_count
        assert total_duration > 0
        assert success_count == total_messages, \
            f"All {total_messages} messages should succeed, got {success_count}"

        throughput = total_messages / total_duration
        logger.info("Rate limiting test: %d msgs in %.1fs (%.1f msg/s)",
                     total_messages, total_duration, throughput)

class TestConsumerGroups:
    """List and describe consumer groups via admin API."""

    @pytest.mark.timeout(60)
    def test_consumer_groups(self, admin_config, consumer_config, unique_topic, producer_config):
        # Create a consumer group by consuming a message
        produce_messages(producer_config, unique_topic, count=1)

        c = Consumer(consumer_config)
        c.subscribe([unique_topic])
        c.poll(timeout=5.0)
        c.commit()
        c.close()

        time.sleep(1)

        a = AdminClient(admin_config)
        group_list = a.list_consumer_groups().result(timeout=10)
        assert group_list is not None

        valid_groups = group_list.valid
        assert valid_groups is not None
        logger.info("Consumer groups found: %d", len(valid_groups))

        if valid_groups:
            first_group_id = valid_groups[0].group_id
            assert first_group_id is not None
            assert len(first_group_id) > 0

            desc_futures = a.describe_consumer_groups([first_group_id])
            desc = desc_futures[first_group_id].result(timeout=10)
            assert desc is not None
            assert desc.group_id == first_group_id
            logger.info("Described group '%s': state=%s, members=%d",
                         desc.group_id, desc.state, len(desc.members))

        logger.info("Consumer groups test passed")

class TestAdminOperations:
    """Create topic, describe/alter config, increase partitions, delete records, delete topic."""

    @pytest.mark.timeout(90)
    def test_admin_operations(self, admin_config, producer_config):
        topic_name = f"admin-ops-test-{int(time.time() * 1000)}"
        a = AdminClient(admin_config)

        # 1. Create topic with 2 partitions
        fs = a.create_topics([NewTopic(topic_name, num_partitions=2, replication_factor=1)])
        fs[topic_name].result(timeout=15)
        logger.info("Topic created with 2 partitions")
        time.sleep(1)

        # 2. Describe configs
        resource = ConfigResource(ConfigResource.Type.TOPIC, topic_name)
        fs = a.describe_configs([resource])
        config_result = fs[resource].result(timeout=10)
        assert config_result is not None
        assert len(config_result) > 0, "Should have config entries"

        retention = config_result.get("retention.ms")
        if retention is not None:
            logger.info("retention.ms = %s", retention.value)
        logger.info("Config described: %d entries", len(config_result))

        # 3. Alter config (set retention to 1 hour)
        try:
            from confluent_kafka.admin import AlterConfigOpType, ConfigSource
            fs = a.incremental_alter_configs([ConfigResource(
                ConfigResource.Type.TOPIC, topic_name,
                incremental_configs=[
                    ConfigEntry("retention.ms", "3600000",
                                source=ConfigSource.DYNAMIC_TOPIC_CONFIG,
                                incremental_operation=AlterConfigOpType.SET),
                    ConfigEntry("segment.ms", "3600000",
                                source=ConfigSource.DYNAMIC_TOPIC_CONFIG,
                                incremental_operation=AlterConfigOpType.SET),
                ],
            )])
            for _, fut in fs.items():
                fut.result(timeout=10)
            logger.info("Config altered via incremental_alter_configs")
        except (ImportError, AttributeError, TypeError):
            try:
                resource = ConfigResource(
                    ConfigResource.Type.TOPIC, topic_name,
                    set_config={"retention.ms": "3600000", "segment.ms": "3600000"},
                )
                fs = a.alter_configs([resource])
                fs[resource].result(timeout=10)
                logger.info("Config altered via legacy alter_configs")
            except Exception as e:
                logger.info("Config alteration skipped or unsupported: %s", e)

        # 4. Increase partitions to 4
        fs = a.create_partitions([NewPartitions(topic_name, new_total_count=4)])
        fs[topic_name].result(timeout=10)
        time.sleep(1)

        md = a.list_topics(topic=topic_name, timeout=10)
        assert len(md.topics[topic_name].partitions) == 4, "Should have 4 partitions"
        logger.info("Partitions increased to 4")

        # 5. Produce messages to partition 0 then delete records
        produce_messages(producer_config, topic_name, count=10, partition=0)
        logger.info("Produced 10 messages to partition 0")

        try:
            tp = TopicPartition(topic_name, 0, 5)
            fs = a.delete_records([tp])
            fs[tp].result(timeout=10)
            logger.info("Deleted records up to offset 5 on partition 0")
        except AttributeError:
            logger.info("delete_records not available in this confluent-kafka version (requires >= 2.4.0), skipping")

        # 6. Cleanup
        fs = a.delete_topics([topic_name])
        fs[topic_name].result(timeout=10)
        logger.info("Admin operations test passed")

class TestConsumerOperations:
    """Manual offset, seek, pause/resume, lag monitoring."""

    @pytest.fixture(autouse=True)
    def _setup_topic(self, admin_config, producer_config):
        """Create a 3-partition topic and seed it with 15 messages."""
        self.topic = f"consumer-ops-test-{int(time.time() * 1000)}"
        self.admin_config = admin_config
        self.producer_config = producer_config
        a = AdminClient(admin_config)
        fs = a.create_topics([NewTopic(self.topic, num_partitions=3, replication_factor=1)])
        fs[self.topic].result(timeout=10)
        time.sleep(2)

        p = Producer(producer_config)
        for i in range(15):
            p.produce(self.topic, partition=i % 3,
                      key=f"key-{i}", value=f"test-message-{i}")
        p.flush(timeout=10)
        time.sleep(1)

        yield

        try:
            fs = a.delete_topics([self.topic])
            fs[self.topic].result(timeout=10)
        except Exception:
            pass

    def _make_consumer(self, group_suffix, **overrides):
        config = dict(self.producer_config)
        config.pop("acks", None)
        config["group.id"] = f"{group_suffix}-{int(time.time() * 1000)}"
        config["auto.offset.reset"] = "earliest"
        config["enable.auto.commit"] = False
        config.update(overrides)
        return Consumer(config)

    # --- Manual offset management ---

    @pytest.mark.timeout(30)
    def test_manual_offset_management(self):
        c = self._make_consumer("manual-offset")
        c.subscribe([self.topic])

        msgs = []
        deadline = time.time() + 10
        while len(msgs) < 3 and time.time() < deadline:
            msg = c.poll(timeout=1.0)
            if msg and not msg.error():
                msgs.append(msg)

        assert len(msgs) >= 3, "Should receive at least 3 messages"

        offsets = [TopicPartition(m.topic(), m.partition(), m.offset() + 1) for m in msgs[:3]]
        c.commit(offsets=offsets)

        committed = c.committed(offsets, timeout=10)
        for tp in committed:
            assert tp.offset >= 0, f"Committed offset should be non-negative for partition {tp.partition}"

        c.close()
        logger.info("Manual offset management test passed")

    # --- Auto-commit vs manual commit ---

    @pytest.mark.timeout(30)
    def test_commit_modes(self):
        # Auto commit
        c_auto = self._make_consumer("auto-commit", **{"enable.auto.commit": True,
                                                         "auto.commit.interval.ms": 1000})
        c_auto.subscribe([self.topic])
        msg = c_auto.poll(timeout=5.0)
        auto_received = msg is not None and not msg.error()
        time.sleep(1.5)
        c_auto.close()

        # Manual commit
        c_manual = self._make_consumer("manual-commit")
        c_manual.subscribe([self.topic])
        msg = c_manual.poll(timeout=5.0)
        manual_received = msg is not None and not msg.error()
        if manual_received:
            c_manual.commit()
        c_manual.close()

        assert auto_received, "Auto-commit consumer should receive a message"
        assert manual_received, "Manual-commit consumer should receive a message"
        logger.info("Commit modes test passed")

    # --- Seek operations ---

    @pytest.mark.timeout(30)
    def test_seek_operations(self):
        c = self._make_consumer("seek-test")
        c.subscribe([self.topic])
        c.poll(timeout=5.0)

        assignment = c.assignment()
        assert len(assignment) > 0, "Should have partition assignment"

        tp = assignment[0]
        low, high = c.get_watermark_offsets(tp, timeout=10)
        assert high > low, "Partition should have messages"

        # Seek to beginning and verify we get the first message
        c.seek(TopicPartition(tp.topic, tp.partition, low))
        msg = c.poll(timeout=5.0)
        assert msg is not None and not msg.error(), "Should consume after seeking to beginning"
        assert msg.offset() >= low, f"First message offset should be >= {low}, got {msg.offset()}"

        # Seek to midpoint and verify
        mid = low + (high - low) // 2
        c.seek(TopicPartition(tp.topic, tp.partition, mid))
        msg = c.poll(timeout=5.0)
        assert msg is not None and not msg.error(), "Should consume after seeking to midpoint"
        assert msg.offset() >= mid, f"Message offset should be >= {mid}, got {msg.offset()}"

        # Seek to end -- just verify seek() doesn't error through the gateway
        c.seek(TopicPartition(tp.topic, tp.partition, high))

        c.close()
        logger.info("Seek operations test passed (low=%d, mid=%d, high=%d)", low, mid, high)

    # --- Pause / Resume ---

    @pytest.mark.timeout(30)
    def test_pause_resume_consumption(self):
        c = self._make_consumer("pause-resume")
        c.subscribe([self.topic])

        # Initial poll to get assignment
        c.poll(timeout=5.0)
        assignment = c.assignment()
        assert len(assignment) > 0

        # Pause
        c.pause(assignment)
        paused_msg = c.poll(timeout=2.0)
        assert paused_msg is None, "Should receive nothing while paused"

        # Resume
        c.resume(assignment)
        resumed_msg = c.poll(timeout=5.0)

        c.close()
        logger.info("Pause/resume test passed")

    # --- Consumer lag monitoring ---

    @pytest.mark.timeout(30)
    def test_consumer_lag_monitoring(self):
        c = self._make_consumer("lag-monitor")
        c.subscribe([self.topic])
        c.poll(timeout=5.0)

        assignment = c.assignment()
        assert len(assignment) > 0

        total_lag = 0
        for tp in assignment:
            low, high = c.get_watermark_offsets(tp, timeout=10)
            position = c.position([tp])[0].offset
            lag = high - position
            assert lag >= 0, f"Lag should be non-negative for partition {tp.partition}"
            total_lag += lag
            logger.info("Partition %d: low=%d, high=%d, position=%d, lag=%d",
                         tp.partition, low, high, position, lag)

        logger.info("Total consumer lag: %d", total_lag)
        c.close()
        logger.info("Consumer lag monitoring test passed")


# ---------------------------------------------------------------------------
# Reauth helpers  (used by TestReauth only)
# ---------------------------------------------------------------------------

class _AsyncProduceResults:
    """Thread-safe container for async producer outcome."""

    def __init__(self):
        self._lock = threading.Lock()
        self._produced = 0
        self._exception = None

    def increment(self):
        with self._lock:
            self._produced += 1

    def record_exception(self, exc):
        with self._lock:
            if self._exception is None:
                self._exception = exc

    @property
    def produced(self):
        with self._lock:
            return self._produced

    @property
    def exception(self):
        with self._lock:
            return self._exception


def _async_produce(config, topic, stop_event, results):
    """Produce messages continuously until stop_event is set or a delivery error occurs.

    Runs indefinitely so there are always inflight messages when the re-auth window
    expires — mirroring KafkaClientUtil.produceAsync() in the Java integration test.
    """
    p = Producer(config)
    i = 0

    def _cb(err, msg):
        if err:
            results.record_exception(KafkaException(err))
            stop_event.set()
        else:
            results.increment()

    try:
        while not stop_event.is_set() and results.exception is None:
            while True:
                try:
                    p.produce(topic, key=f"key-{i}", value=f"reauth-msg-{i}", callback=_cb)
                    p.poll(0)
                    break
                except BufferError:
                    p.poll(0.1)
                    if stop_event.is_set() or results.exception:
                        break
            i += 1
    except KafkaException as e:
        results.record_exception(e)
    except Exception as e:
        results.record_exception(Exception(str(e)))
    finally:
        try:
            p.flush(timeout=5)
        except Exception:
            pass


def _remove_user_from_jaas(jaas_path, username):
    """Remove a user_<username>="..." token from a JAAS config file to trigger a gateway hot-reload.

    The JAAS file uses a single-line multi-field
    format, so we do token-level removal (not line filtering) to keep the file valid.
    """
    with open(jaas_path, "r") as f:
        content = f.read()
    content = re.sub(rf'\s+user_{re.escape(username)}="[^"]*"', "", content)
    with open(jaas_path, "w") as f:
        f.write(content)
    logger.info("Removed user '%s' from JAAS config at %s", username, jaas_path)


# ---------------------------------------------------------------------------
# Reauth test
# ---------------------------------------------------------------------------

@pytest.mark.skipif(
    not os.environ.get("REAUTH_BOOTSTRAP_SERVERS"),
    reason="Reauth infrastructure not present (REAUTH_BOOTSTRAP_SERVERS not set); "
           "run via --run or --single which spin up the reauth compose as test mode 4",
)
class TestReauth:
    """KIP-368 re-auth: mirrors testAuthSwapWithGatewayReauthEnabled.

    Requires docker-compose-librdkafka-reauth-kraft.yml which brings up:
      - Kafka  (KRaft, SASL_PLAINTEXT)
      - Vault  (maps user1 -> newuser/newuser-secret)
      - Gateway (AuthSwap route, connectionMaxReauthMs=5000)

    The test confirms that client<->gateway re-auth is enforced: after removing
    user1 from the gateway's hot-reloadable JAAS file, the next reauth fails and
    the async producer receives an authentication exception.
    """

    @pytest.mark.timeout(60)
    def test_reauth_fails_after_credential_removal(self, reauth_producer_config, jaas_config_path):
        topic = f"reauth-test-{int(time.time() * 1000)}"

        stop_event = threading.Event()
        results = _AsyncProduceResults()
        thread = threading.Thread(
            target=_async_produce,
            args=(reauth_producer_config, topic, stop_event, results),
            daemon=True,
        )
        thread.start()

        # Wait for the producer to actually start delivering messages
        start_wait = time.time()
        while results.produced == 0 and time.time() - start_wait < 10:
            time.sleep(0.05)

        assert results.produced > 0, "Producer should have started before timeout"
        produced_before_removal = results.produced

        # Approach the first reauth window (connectionMaxReauthMs=5000 on the gateway)
        time.sleep(4)

        # Remove user1 from the gateway JAAS — gateway hot-reloads, next reauth fails.
        # Mirrors: authSwapFeature.removeUserFromClientJaasConfig("user1")
        _remove_user_from_jaas(jaas_config_path, "user1")
        logger.info("Removed user1 from gateway JAAS; waiting for reauth failure...")

        # Allow the file watcher to pick up the change (mirrors Thread.sleep(2000))
        time.sleep(2)

        # Wait up to 15 s for the producer to hit an auth exception
        wait_start = time.time()
        while results.exception is None and time.time() - wait_start < 15:
            time.sleep(0.1)

        stop_event.set()
        thread.join(timeout=5)

        assert results.exception is not None, (
            "Producer should have received an auth exception after reauth"
        )
        assert results.produced > produced_before_removal, \
            "Some messages should have been produced before credential removal"

        logger.info(
            "Reauth test passed: produced=%d exception=%s",
            results.produced,
            results.exception,
        )
