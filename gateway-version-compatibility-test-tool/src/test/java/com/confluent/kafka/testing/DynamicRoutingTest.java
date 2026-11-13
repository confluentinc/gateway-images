package com.confluent.kafka.testing;

import java.time.Duration;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.Set;
import java.util.concurrent.Callable;
import java.util.concurrent.TimeUnit;

import org.apache.kafka.clients.admin.Admin;
import org.apache.kafka.clients.admin.AdminClientConfig;
import org.apache.kafka.clients.admin.NewTopic;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.kafka.clients.consumer.OffsetAndMetadata;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.PartitionInfo;
import org.apache.kafka.common.TopicPartition;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.apache.kafka.common.serialization.StringSerializer;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.MethodOrderer;
import org.junit.jupiter.api.Order;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestMethodOrder;
import org.junit.jupiter.api.condition.EnabledIfSystemProperty;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Topic-based routing (TBM): one dynamic gateway route over two Kafka clusters
 * (docker-compose-tbm.yml). Each test acts through the gateway, then checks each cluster directly:
 * a topic and its records must land on the cluster the route's conditions name (tbm-a-* on A,
 * tbm-b-* on B), and consumer groups on A, the coordination cluster.
 *
 * <p>Only the APIs the dynamic router serves are exercised (metadata, topic create/delete, produce,
 * fetch, list offsets, consumer groups, producer ids); it rejects the rest (e.g. transactions), so
 * AdvancedKafkaTest doesn't run here. Offsets are committed for cluster A's topic only: the router
 * forwards commits to the coordination cluster, which rejects a topic it doesn't have.
 *
 * <p>Enabled by -Dtbm.cluster.b.bootstrap; written against the APIs common to every client
 * version tested (and Java 8).
 */
@DisplayName("Topic-based routing across two Kafka clusters")
@EnabledIfSystemProperty(named = "tbm.cluster.b.bootstrap", matches = ".+")
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
public class DynamicRoutingTest {

  private static final String GATEWAY = System.getProperty("bootstrap.servers", "gateway.tbm.test:19400");
  private static final String CLUSTER_A = System.getProperty("tbm.cluster.a.bootstrap", "kafka-server:9092");
  private static final String CLUSTER_B = System.getProperty("tbm.cluster.b.bootstrap");
  private static final String TRUSTSTORE = "/etc/kafka/secrets/kafka.truststore.jks";
  private static final String TRUSTSTORE_PASSWORD = "confluent";

  // Unique per run: the clusters outlive a failed run's cleanup only until compose down.
  private static final String RUN = Long.toString(System.currentTimeMillis(), 36);
  private static final String TOPIC_A = "tbm-a-" + RUN;
  private static final String TOPIC_B = "tbm-b-" + RUN;
  private static final String GROUP = "tbm-group-" + RUN;
  private static final int PARTITIONS = 3;
  private static final int RECORDS = 10;
  private static final long TIMEOUT_MS = 30_000;

  @Test
  @Order(1)
  @DisplayName("Topics created through the gateway land on the cluster their name routes to")
  void createTopicsOnOwningClusters() throws Exception {
    try (Admin gateway = Admin.create(gatewayProps())) {
      gateway.createTopics(Arrays.asList(
          new NewTopic(TOPIC_A, PARTITIONS, (short) 1),
          new NewTopic(TOPIC_B, PARTITIONS, (short) 1))).all().get(TIMEOUT_MS, TimeUnit.MILLISECONDS);
    }
    awaitTopics(CLUSTER_A, TOPIC_A, true);
    awaitTopics(CLUSTER_B, TOPIC_B, true);
    assertFalse(topics(CLUSTER_A).contains(TOPIC_B), TOPIC_B + " was created on cluster A");
    assertFalse(topics(CLUSTER_B).contains(TOPIC_A), TOPIC_A + " was created on cluster B");
  }

  @Test
  @Order(2)
  @DisplayName("The gateway lists the topics of both clusters")
  void listTopicsOfBothClusters() throws Exception {
    Set<String> listed = topics(GATEWAY);
    assertTrue(listed.contains(TOPIC_A), "gateway doesn't list " + TOPIC_A + ": " + listed);
    assertTrue(listed.contains(TOPIC_B), "gateway doesn't list " + TOPIC_B + ": " + listed);
  }

  @Test
  @Order(3)
  @DisplayName("An idempotent producer through the gateway writes each topic's records to its cluster")
  void produceToOwningClusters() throws Exception {
    Properties props = gatewayProps();
    props.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, "true");
    props.put(ProducerConfig.ACKS_CONFIG, "all");
    try (KafkaProducer<String, String> producer =
             new KafkaProducer<>(props, new StringSerializer(), new StringSerializer())) {
      for (int i = 0; i < RECORDS; i++) {
        producer.send(new ProducerRecord<>(TOPIC_A, "key-" + i, "a-" + i)).get(TIMEOUT_MS, TimeUnit.MILLISECONDS);
        producer.send(new ProducerRecord<>(TOPIC_B, "key-" + i, "b-" + i)).get(TIMEOUT_MS, TimeUnit.MILLISECONDS);
      }
    }
    assertEquals(RECORDS, endOffsetTotal(CLUSTER_A, TOPIC_A), "records on cluster A's " + TOPIC_A);
    assertEquals(RECORDS, endOffsetTotal(CLUSTER_B, TOPIC_B), "records on cluster B's " + TOPIC_B);
  }

  @Test
  @Order(4)
  @DisplayName("A consumer group reads both clusters, with its offsets on the coordination cluster")
  void consumeBothClustersInOneGroup() throws Exception {
    Properties props = gatewayProps();
    props.put(ConsumerConfig.GROUP_ID_CONFIG, GROUP);
    props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
    props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "false");
    Map<String, Integer> received = new HashMap<>();
    Map<TopicPartition, OffsetAndMetadata> offsetsA = new HashMap<>();
    Map<TopicPartition, Long> expected = new HashMap<>();
    try (KafkaConsumer<String, String> consumer =
             new KafkaConsumer<>(props, new StringDeserializer(), new StringDeserializer())) {
      consumer.subscribe(Arrays.asList(TOPIC_A, TOPIC_B));
      long deadline = System.currentTimeMillis() + TIMEOUT_MS;
      while (count(received) < 2 * RECORDS && System.currentTimeMillis() < deadline) {
        for (ConsumerRecord<String, String> r : consumer.poll(Duration.ofSeconds(1))) {
          received.merge(r.topic(), 1, Integer::sum);
          if (r.topic().equals(TOPIC_A)) {
            TopicPartition tp = new TopicPartition(r.topic(), r.partition());
            offsetsA.put(tp, new OffsetAndMetadata(r.offset() + 1));
            expected.put(tp, r.offset() + 1);
          }
        }
      }
      assertEquals(RECORDS, received.getOrDefault(TOPIC_A, 0).intValue(), "records read from " + TOPIC_A);
      assertEquals(RECORDS, received.getOrDefault(TOPIC_B, 0).intValue(), "records read from " + TOPIC_B);
      consumer.commitSync(offsetsA);
    }
    try (Admin a = Admin.create(directProps(CLUSTER_A))) {
      Map<TopicPartition, OffsetAndMetadata> committed =
          a.listConsumerGroupOffsets(GROUP).partitionsToOffsetAndMetadata().get(TIMEOUT_MS, TimeUnit.MILLISECONDS);
      assertEquals(expected, offsets(committed), "group offsets on cluster A");
    }
    try (Admin b = Admin.create(directProps(CLUSTER_B))) {
      Map<TopicPartition, OffsetAndMetadata> committed =
          b.listConsumerGroupOffsets(GROUP).partitionsToOffsetAndMetadata().get(TIMEOUT_MS, TimeUnit.MILLISECONDS);
      assertTrue(committed.isEmpty(), "group offsets on cluster B: " + committed);
    }
  }

  @Test
  @Order(5)
  @DisplayName("Topics deleted through the gateway are deleted on their clusters")
  void deleteTopicsOnOwningClusters() throws Exception {
    try (Admin gateway = Admin.create(gatewayProps())) {
      gateway.deleteTopics(Arrays.asList(TOPIC_A, TOPIC_B)).all().get(TIMEOUT_MS, TimeUnit.MILLISECONDS);
    }
    awaitTopics(CLUSTER_A, TOPIC_A, false);
    awaitTopics(CLUSTER_B, TOPIC_B, false);
  }

  /** Client properties through the gateway: TLS (the route's SNI strategy), no hostname check. */
  private static Properties gatewayProps() {
    Properties props = new Properties();
    props.put(AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG, GATEWAY);
    props.put(AdminClientConfig.SECURITY_PROTOCOL_CONFIG, "SSL");
    props.put("ssl.endpoint.identification.algorithm", "");
    props.put("ssl.truststore.location", TRUSTSTORE);
    props.put("ssl.truststore.password", TRUSTSTORE_PASSWORD);
    return props;
  }

  /** Client properties straight to one cluster (PLAINTEXT), bypassing the gateway. */
  private static Properties directProps(String bootstrap) {
    Properties props = new Properties();
    props.put(AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrap);
    return props;
  }

  private static Set<String> topics(String bootstrap) throws Exception {
    Properties props = GATEWAY.equals(bootstrap) ? gatewayProps() : directProps(bootstrap);
    try (Admin admin = Admin.create(props)) {
      return new HashSet<>(admin.listTopics().names().get(TIMEOUT_MS, TimeUnit.MILLISECONDS));
    }
  }

  /** Waits until {@code topic} exists (or no longer does) on the cluster at {@code bootstrap}. */
  private static void awaitTopics(String bootstrap, String topic, boolean exists) throws Exception {
    boolean done = await(() -> topics(bootstrap).contains(topic) == exists);
    assertTrue(done, topic + (exists ? " never appeared on " : " was never deleted from ") + bootstrap);
  }

  /** The sum of {@code topic}'s partition end offsets on the cluster at {@code bootstrap}. */
  private static long endOffsetTotal(String bootstrap, String topic) {
    try (KafkaConsumer<String, String> consumer =
             new KafkaConsumer<>(directProps(bootstrap), new StringDeserializer(), new StringDeserializer())) {
      List<TopicPartition> partitions = new ArrayList<>();
      for (PartitionInfo p : consumer.partitionsFor(topic)) {
        partitions.add(new TopicPartition(p.topic(), p.partition()));
      }
      long total = 0;
      for (Long end : consumer.endOffsets(partitions).values()) {
        total += end;
      }
      return total;
    }
  }

  private static Map<TopicPartition, Long> offsets(Map<TopicPartition, OffsetAndMetadata> committed) {
    Map<TopicPartition, Long> offsets = new HashMap<>();
    for (Map.Entry<TopicPartition, OffsetAndMetadata> e : committed.entrySet()) {
      offsets.put(e.getKey(), e.getValue().offset());
    }
    return offsets;
  }

  private static int count(Map<String, Integer> received) {
    int total = 0;
    for (int n : received.values()) {
      total += n;
    }
    return total;
  }

  private static boolean await(Callable<Boolean> condition) throws Exception {
    long deadline = System.currentTimeMillis() + TIMEOUT_MS;
    while (System.currentTimeMillis() < deadline) {
      if (condition.call()) {
        return true;
      }
      Thread.sleep(500);
    }
    return condition.call();
  }
}
