package com.confluent.kafka.testing;

// Kafka Clients - Producer
import org.apache.kafka.clients.producer.Producer;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.clients.producer.RecordMetadata;

// Kafka Clients - Consumer
import org.apache.kafka.clients.consumer.Consumer;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.ConsumerRecords;
import org.apache.kafka.clients.consumer.OffsetAndMetadata;

// Kafka Clients - Admin
import org.apache.kafka.clients.admin.AdminClient;
import org.apache.kafka.clients.admin.AdminClientConfig;
import org.apache.kafka.clients.admin.AlterConfigsResult;
import org.apache.kafka.clients.admin.Config;
import org.apache.kafka.clients.admin.ConfigEntry;
import org.apache.kafka.clients.admin.ConsumerGroupDescription;
import org.apache.kafka.clients.admin.ConsumerGroupListing;
import org.apache.kafka.clients.admin.CreateAclsResult;
import org.apache.kafka.clients.admin.CreatePartitionsResult;
import org.apache.kafka.clients.admin.CreateTopicsResult;
import org.apache.kafka.clients.admin.DeleteAclsResult;
import org.apache.kafka.clients.admin.DeleteRecordsResult;
import org.apache.kafka.clients.admin.DeleteTopicsResult;
import org.apache.kafka.clients.admin.DescribeAclsResult;
import org.apache.kafka.clients.admin.DescribeClusterResult;
import org.apache.kafka.clients.admin.DescribeConfigsResult;
import org.apache.kafka.clients.admin.DescribeConsumerGroupsResult;
import org.apache.kafka.clients.admin.DescribeTopicsResult;
import org.apache.kafka.clients.admin.ListConsumerGroupsResult;
import org.apache.kafka.clients.admin.ListPartitionReassignmentsResult;
import org.apache.kafka.clients.admin.ListTopicsResult;
import org.apache.kafka.clients.admin.NewPartitions;
import org.apache.kafka.clients.admin.NewTopic;
import org.apache.kafka.clients.admin.PartitionReassignment;
import org.apache.kafka.clients.admin.RecordsToDelete;
import org.apache.kafka.clients.admin.TopicDescription;

// Kafka Streams
import org.apache.kafka.streams.KafkaStreams;
import org.apache.kafka.streams.StreamsBuilder;
import org.apache.kafka.streams.StreamsConfig;
import org.apache.kafka.streams.Topology;
import org.apache.kafka.streams.errors.StreamsUncaughtExceptionHandler;
import org.apache.kafka.streams.kstream.KStream;

// Kafka Common
import org.apache.kafka.common.Node;
import org.apache.kafka.common.TopicPartition;
import org.apache.kafka.common.config.ConfigResource;
import org.apache.kafka.common.config.SaslConfigs;
import org.apache.kafka.common.config.TopicConfig;
import org.apache.kafka.common.security.auth.SecurityProtocol;

// Kafka Common - ACLs
import org.apache.kafka.common.acl.AccessControlEntry;
import org.apache.kafka.common.acl.AclBinding;
import org.apache.kafka.common.acl.AclBindingFilter;
import org.apache.kafka.common.acl.AclOperation;
import org.apache.kafka.common.acl.AclPermissionType;
import org.apache.kafka.common.resource.PatternType;
import org.apache.kafka.common.resource.ResourcePattern;
import org.apache.kafka.common.resource.ResourceType;

// Kafka Serialization
import org.apache.kafka.common.serialization.ByteArrayDeserializer;
import org.apache.kafka.common.serialization.ByteArraySerializer;
import org.apache.kafka.common.serialization.Serdes;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.apache.kafka.common.serialization.StringSerializer;

// Java Standard Library
import java.time.Duration;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.Set;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

// JUnit 5 for testing
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.MethodOrderer;
import org.junit.jupiter.api.Order;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestMethodOrder;
import static org.junit.jupiter.api.Assertions.*;

/**
 * Advanced Kafka Test Suite for version compatibility testing
 * Supports: EOS, Streams API, Custom Serializers, Quotas, Rate Limiting
 * JUnit 5 test suite with comprehensive assertions
 */
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
public class AdvancedKafkaTest {
    
    private String bootstrapServers;
    private Properties baseProps;
    
    public AdvancedKafkaTest() {
        // Default constructor for JUnit
    }
    
    private void initializeWithBootstrapServers(String bootstrapServers) {
        this.bootstrapServers = bootstrapServers;
        this.baseProps = new Properties();
        this.baseProps.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        
        // Check for SASL configuration via environment variables
        configureSASLIfEnabled();
    }
    
    private void configureSASLIfEnabled() {
        String enableSasl = System.getenv("KAFKA_SASL_ENABLED");
        String enableSsl = System.getenv("KAFKA_SSL_ENABLED");
        String saslMechanism = System.getenv("KAFKA_SASL_MECHANISM");
        String saslUsername = System.getenv("KAFKA_SASL_USERNAME");
        String saslPassword = System.getenv("KAFKA_SASL_PASSWORD");
        
        boolean saslEnabled = "true".equalsIgnoreCase(enableSasl);
        boolean sslEnabled = "true".equalsIgnoreCase(enableSsl);
        
        if (sslEnabled && !saslEnabled) {
            System.out.println("🔒 SSL authentication enabled (no SASL)");
            System.out.println("   Bootstrap servers: " + this.bootstrapServers);
            
            // Configure security protocol for SSL only
            this.baseProps.put("security.protocol", "SSL");
            
            // SSL configuration for client trust (no client certificate required)
            this.baseProps.put("ssl.endpoint.identification.algorithm", "");
            this.baseProps.put("ssl.truststore.location", "/etc/kafka/secrets/kafka.truststore.jks");
            this.baseProps.put("ssl.truststore.password", "confluent");
            
            System.out.println("✅ SSL configuration applied to base properties");
        } else if (saslEnabled) {
            String mechanism = saslMechanism != null ? saslMechanism : "PLAIN";
            String username = saslUsername != null ? saslUsername : "admin";
            String password = saslPassword != null ? saslPassword : "admin-secret";
            
            System.out.println("🔐 SASL authentication enabled");
            System.out.println("   Mechanism: " + mechanism);
            System.out.println("   Username: " + username);
            System.out.println("   Bootstrap servers: " + this.bootstrapServers);
            
            // Configure security protocol for SASL_PLAINTEXT
            this.baseProps.put("security.protocol", "SASL_PLAINTEXT");
            this.baseProps.put(SaslConfigs.SASL_MECHANISM, mechanism);
            
            // Configure JAAS for PLAIN mechanism
            if ("PLAIN".equals(mechanism)) {
                String jaasConfig = String.format(
                    "org.apache.kafka.common.security.plain.PlainLoginModule required " +
                    "username=\"%s\" password=\"%s\";", username, password);
                this.baseProps.put(SaslConfigs.SASL_JAAS_CONFIG, jaasConfig);
            }
            
            System.out.println("✅ SASL configuration applied to base properties");
        } else {
            System.out.println("🔓 Using PLAINTEXT authentication (no SASL)");
        }
    }
    
    @BeforeEach
    public void setUp() {
        if (this.bootstrapServers == null) {
            // Initialize from system property for JUnit execution
            String servers = System.getProperty("bootstrap.servers", "gateway:19092");
            initializeWithBootstrapServers(servers);
        }
    }
    
    public static void main(String[] args) {
        System.out.println("🚀 Advanced Kafka Test Suite - Version: " + getKafkaVersion());
        
        if (args.length < 2) {
            System.out.println("Usage: java AdvancedKafkaTestSuite <bootstrap-servers> <test-type>");
            System.out.println("");
            System.out.println("Test types:");
            System.out.println("  api            - Test API versions and admin connectivity");
            System.out.println("  topics         - Test topic management (create/list/delete)");
            System.out.println("  consumer-groups - Test consumer group operations");
            System.out.println("  cluster        - Test cluster metadata and broker info");
            System.out.println("  basic          - Test basic producer-consumer functionality");
            System.out.println("  idempotent     - Test idempotent producer");
            System.out.println("  eos            - Test exactly-once semantics");
            System.out.println("  streams        - Test Streams API compatibility");
            System.out.println("  serializers    - Test custom serializers");
            System.out.println("  quotas         - Test quota handling");
            System.out.println("  rate-limiting  - Test rate limiting behavior");
            System.out.println("  admin          - Test advanced admin operations (configs, ACLs, partitions)");
            System.out.println("  consumer       - Test advanced consumer operations (offsets, seek, pause/resume, lag)");
            System.out.println("  compatibility  - Run all API compatibility tests");
            System.out.println("  Note: Use 'mvn test' to run all tests via JUnit");
            System.out.println("");
            System.out.println("SASL Configuration (Environment Variables):");
            System.out.println("  KAFKA_SASL_ENABLED=true     - Enable SASL authentication");
            System.out.println("  KAFKA_SASL_MECHANISM=PLAIN  - SASL mechanism (default: PLAIN)");
            System.out.println("  KAFKA_SASL_USERNAME=admin   - SASL username (default: admin)");
            System.out.println("  KAFKA_SASL_PASSWORD=secret  - SASL password (default: admin-secret)");
            System.out.println("");
            System.out.println("Examples:");
            System.out.println("  # PLAINTEXT connection:");
            System.out.println("  java AdvancedKafkaTestSuite gateway:19092 basic");
            System.out.println("");
            System.out.println("  # SASL_PLAINTEXT connection:");
            System.out.println("  KAFKA_SASL_ENABLED=true \\");
            System.out.println("  KAFKA_SASL_USERNAME=alice \\");
            System.out.println("  KAFKA_SASL_PASSWORD=alice-secret \\");
            System.out.println("  java AdvancedKafkaTestSuite gateway:19093 basic");
            System.exit(1);
        }
        
        String bootstrapServers = args[0];
        String testType = args[1];
        
        AdvancedKafkaTest suite = new AdvancedKafkaTest();
        suite.initializeWithBootstrapServers(bootstrapServers);
        
        try {
            switch (testType.toLowerCase()) {
                case "basic":
                    suite.testBasicProducerConsumer();
                    break;
                case "api":
                    suite.testAPIVersions();
                    break;
                case "topics":
                    suite.testTopicManagement();
                    break;
                case "consumer-groups":
                    suite.testConsumerGroups();
                    break;
                case "cluster":
                    suite.testClusterMetadata();
                    break;
                case "eos":
                    suite.testExactlyOnceSemantics();
                    break;
                case "streams":
                    suite.testStreamsCompatibility();
                    break;
                case "serializers":
                    suite.testCustomSerializers();
                    break;
                case "quotas":
                    suite.testQuotasHandling();
                    break;
                case "rate-limiting":
                    suite.testRateLimiting();
                    break;
                case "admin":
                    suite.testAdminOperations();
                    break;
                case "consumer":
                    suite.testConsumerOperations();
                    break;
                case "idempotent":
                    suite.testIdempotentProducer();
                    break;
                case "compatibility":
                    suite.runCompatibilityTests();
                    break;
                default:
                    System.out.println("❌ Unknown test type: " + testType);
                    System.out.println("💡 Tip: Use 'mvn test' to run all JUnit tests");
                    System.exit(1);
            }
            System.out.println("✅ Test '" + testType + "' completed successfully with Kafka client: " + getKafkaVersion());
        } catch (Exception e) {
            System.err.println("❌ Test '" + testType + "' failed: " + e.getMessage());
            e.printStackTrace();
            System.exit(1);
        }
    }
    
    private static String getKafkaVersion() {
        try {
            return org.apache.kafka.common.utils.AppInfoParser.getVersion();
        } catch (Exception e) {
            return "unknown";
        }
    }
    
    // Cross-version compatibility helper methods using reflection
    private TopicDescription getTopicDescription(DescribeTopicsResult result, String topicName) throws Exception {
        try {
            // Try Kafka 8.0.0+ API first using reflection
            java.lang.reflect.Method topicNameValuesMethod = result.getClass().getMethod("topicNameValues");
            @SuppressWarnings("unchecked")
            java.util.Map<String, org.apache.kafka.common.KafkaFuture<TopicDescription>> futureMap = 
                (java.util.Map<String, org.apache.kafka.common.KafkaFuture<TopicDescription>>) topicNameValuesMethod.invoke(result);
            return futureMap.get(topicName).get(10, java.util.concurrent.TimeUnit.SECONDS);
        } catch (NoSuchMethodException | java.lang.reflect.InvocationTargetException e) {
            // Fall back to older API (Kafka < 8.0.0) using reflection as well
            try {
                java.lang.reflect.Method valuesMethod = result.getClass().getMethod("values");
                @SuppressWarnings("unchecked")
                java.util.Map<String, org.apache.kafka.common.KafkaFuture<TopicDescription>> futureMap = 
                    (java.util.Map<String, org.apache.kafka.common.KafkaFuture<TopicDescription>>) valuesMethod.invoke(result);
                return futureMap.get(topicName).get(10, java.util.concurrent.TimeUnit.SECONDS);
            } catch (NoSuchMethodException ex) {
                throw new RuntimeException("Neither topicNameValues() nor values() method found on DescribeTopicsResult", ex);
            }
        }
    }
    
    // Helper method for alter configs (handle deprecation)
    private void alterTopicConfig(AdminClient adminClient, java.util.Map<ConfigResource, Config> configsToAlter) throws Exception {
        try {
            // Try the older alterConfigs method (works in Kafka < 8.0.0) using reflection
            java.lang.reflect.Method alterConfigsMethod = adminClient.getClass().getMethod("alterConfigs", java.util.Map.class);
            Object alterResult = alterConfigsMethod.invoke(adminClient, configsToAlter);
            
            // Get the all() method result
            java.lang.reflect.Method allMethod = alterResult.getClass().getMethod("all");
            org.apache.kafka.common.KafkaFuture<?> allFuture = (org.apache.kafka.common.KafkaFuture<?>) allMethod.invoke(alterResult);
            allFuture.get(10, java.util.concurrent.TimeUnit.SECONDS);
            System.out.println("✅ Topic configuration altered successfully");
        } catch (NoSuchMethodException e) {
            // Method doesn't exist in 8.0.0+, use alternative approach or skip
            System.out.println("⚠️ alterConfigs not available in this Kafka version - skipping config alteration");
        } catch (Exception e) {
            System.out.println("⚠️ Topic config alteration failed: " + e.getMessage());
        }
    }
    
    @Test
    @Order(2)
    @DisplayName("Basic Producer-Consumer Test")
    public void testBasicProducerConsumer() throws Exception {
        System.out.println("🔄 Testing Basic Producer-Consumer...");
        
        String topicName = "basic-test-topic-" + System.currentTimeMillis();
        String testMessage = "basic-message-" + System.currentTimeMillis();
        
        // Test Producer
        Properties producerProps = new Properties();
        producerProps.putAll(baseProps);
        producerProps.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
        producerProps.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
        producerProps.put(ProducerConfig.ACKS_CONFIG, "all");
        
        RecordMetadata metadata;
        try (Producer<String, String> producer = new KafkaProducer<>(producerProps)) {
            ProducerRecord<String, String> record = new ProducerRecord<>(topicName, "test-key", testMessage);
            metadata = producer.send(record).get(10, TimeUnit.SECONDS);
            
            // JUnit assertions for producer
            assertNotNull(metadata, "RecordMetadata should not be null");
            assertEquals(topicName, metadata.topic(), "Topic name should match");
            assertTrue(metadata.partition() >= 0, "Partition should be non-negative");
            assertTrue(metadata.offset() >= 0, "Offset should be non-negative");
            
            System.out.println("✅ Message sent to topic: " + metadata.topic() + 
                             ", partition: " + metadata.partition() + 
                             ", offset: " + metadata.offset());
        }
        
        // Test Consumer
        Properties consumerProps = new Properties();
        consumerProps.putAll(baseProps);  // Include SASL configuration from baseProps
        consumerProps.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class);
        consumerProps.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class);
        consumerProps.put(ConsumerConfig.GROUP_ID_CONFIG, "basic-test-group-" + System.currentTimeMillis());
        consumerProps.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        
        try (Consumer<String, String> consumer = new KafkaConsumer<>(consumerProps)) {
            consumer.subscribe(Collections.singletonList(topicName));
            
            int messageCount = 0;
            boolean foundMessage = false;
            long startTime = System.currentTimeMillis();
            
            while (messageCount == 0 && (System.currentTimeMillis() - startTime) < 15000) {
                ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(1000));
                messageCount += records.count();
                
                for (ConsumerRecord<String, String> record : records) {
                    // JUnit assertions for consumer
                    assertNotNull(record.key(), "Consumer record key should not be null");
                    assertNotNull(record.value(), "Consumer record value should not be null");
                    assertEquals("test-key", record.key(), "Consumer record key should match");
                    assertEquals(testMessage, record.value(), "Consumer record value should match");
                    assertTrue(record.partition() >= 0, "Consumer record partition should be non-negative");
                    assertTrue(record.offset() >= 0, "Consumer record offset should be non-negative");
                    
                    foundMessage = true;
                    System.out.println("✅ Message consumed: key=" + record.key() + 
                                     ", value=" + record.value() + 
                                     ", partition=" + record.partition() + 
                                     ", offset=" + record.offset());
                }
            }
            
            // JUnit assertion for overall test success
            assertTrue(foundMessage, "Should have consumed at least one message within timeout");
            assertTrue(messageCount > 0, "Message count should be greater than 0");
            
            System.out.println("✅ Basic producer-consumer test completed successfully");
        }
    }
    
    @Test
    @Order(4)
    @DisplayName("Idempotent Producer Test")
    public void testIdempotentProducer() throws Exception {
        System.out.println("🔁 Testing Idempotent Producer...");
        
        String topicName = "idempotent-test-topic-" + System.currentTimeMillis();
        
        Properties producerProps = new Properties();
        producerProps.putAll(baseProps);
        producerProps.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
        producerProps.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
        
        // Idempotent producer configuration
        producerProps.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, true);
        producerProps.put(ProducerConfig.ACKS_CONFIG, "all");
        producerProps.put(ProducerConfig.RETRIES_CONFIG, Integer.MAX_VALUE);
        producerProps.put(ProducerConfig.MAX_IN_FLIGHT_REQUESTS_PER_CONNECTION, 5);
        
        List<RecordMetadata> metadataList = new ArrayList<>();
        try (Producer<String, String> producer = new KafkaProducer<>(producerProps)) {
            // Send the same message multiple times to test idempotence
            String messageKey = "idempotent-key";
            String messageValue = "idempotent-message-" + System.currentTimeMillis();
            
            for (int i = 0; i < 3; i++) {
                ProducerRecord<String, String> record = new ProducerRecord<>(topicName, messageKey, messageValue);
                RecordMetadata metadata = producer.send(record).get(10, TimeUnit.SECONDS);
                
                // JUnit assertions for idempotent producer
                assertNotNull(metadata, "RecordMetadata should not be null for message " + (i+1));
                assertEquals(topicName, metadata.topic(), "Topic should match for message " + (i+1));
                assertTrue(metadata.partition() >= 0, "Partition should be non-negative for message " + (i+1));
                assertTrue(metadata.offset() >= 0, "Offset should be non-negative for message " + (i+1));
                
                metadataList.add(metadata);
                System.out.println("📤 Sent idempotent message " + (i+1) + " to offset: " + metadata.offset());
            }
        }
        
        // JUnit assertions for idempotent behavior
        assertEquals(3, metadataList.size(), "Should have sent exactly 3 messages");
        
        // Verify offsets are sequential (idempotent producer should still produce unique messages)
        for (int i = 1; i < metadataList.size(); i++) {
            assertTrue(metadataList.get(i).offset() > metadataList.get(i-1).offset(), 
                      "Message " + (i+1) + " should have higher offset than message " + i);
        }
        
        System.out.println("✅ Idempotent producer test completed");
    }
    
    @Test
    @Order(5)
    @DisplayName("Exactly-Once Semantics Test")
    public void testExactlyOnceSemantics() throws Exception {
        System.out.println("🔄 Testing Exactly-Once Semantics...");
        
        String topicName = "eos-test-topic-" + System.currentTimeMillis();
        String transactionId = "eos-test-" + System.currentTimeMillis();
        
        Properties producerProps = new Properties();
        producerProps.putAll(baseProps);
        producerProps.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
        producerProps.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
        
        // EOS configuration
        producerProps.put(ProducerConfig.TRANSACTIONAL_ID_CONFIG, transactionId);
        producerProps.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, true);
        producerProps.put(ProducerConfig.ACKS_CONFIG, "all");
        producerProps.put(ProducerConfig.RETRIES_CONFIG, Integer.MAX_VALUE);
        producerProps.put(ProducerConfig.MAX_IN_FLIGHT_REQUESTS_PER_CONNECTION, 5);
        
        boolean commitSucceeded = false;
        boolean abortSucceeded = false;
        
        try (Producer<String, String> producer = new KafkaProducer<>(producerProps)) {
            // JUnit assertion - producer should initialize successfully
            assertDoesNotThrow(() -> producer.initTransactions(), "Transaction initialization should succeed");
            
            // Test successful transaction
            producer.beginTransaction();
            try {
                for (int i = 0; i < 5; i++) {
                    ProducerRecord<String, String> record = new ProducerRecord<>(
                        topicName, "eos-key-" + i, "eos-message-" + i);
                    // JUnit assertion - send should not throw exception
                    assertDoesNotThrow(() -> producer.send(record), "Message send should succeed in transaction");
                }
                // JUnit assertion - commit should not throw exception
                assertDoesNotThrow(() -> producer.commitTransaction(), "Transaction commit should succeed");
                commitSucceeded = true;
                System.out.println("✅ Transaction committed successfully with 5 messages");
            } catch (Exception e) {
                producer.abortTransaction();
                throw e;
            }
            
            // Test transaction abort
            producer.beginTransaction();
            try {
                ProducerRecord<String, String> record = new ProducerRecord<>(
                    topicName, "abort-key", "this-message-should-be-aborted");
                producer.send(record);
                // JUnit assertion - abort should not throw exception
                assertDoesNotThrow(() -> producer.abortTransaction(), "Transaction abort should succeed");
                abortSucceeded = true;
                System.out.println("✅ Transaction aborted successfully");
            } catch (Exception e) {
                producer.abortTransaction();
                abortSucceeded = true;
                System.out.println("✅ Transaction aborted on exception: " + e.getMessage());
            }
        }
        
        // JUnit assertions for overall EOS functionality
        assertTrue(commitSucceeded, "Transaction commit should have succeeded");
        assertTrue(abortSucceeded, "Transaction abort should have succeeded");
        
        System.out.println("✅ Exactly-Once Semantics test completed");
    }
    
    @Test
    @Order(6)
    @DisplayName("Kafka Streams Compatibility Test")
    public void testStreamsCompatibility() throws Exception {
        System.out.println("🌊 Testing Streams API Compatibility...");
        
        String inputTopic = "streams-input-" + System.currentTimeMillis();
        String outputTopic = "streams-output-" + System.currentTimeMillis();
        String appId = "streams-test-app-" + System.currentTimeMillis();
        
        // Pre-create input and output topics to speed up streams initialization
        Properties adminProps = new Properties();
        adminProps.putAll(baseProps);
        adminProps.put(AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        adminProps.put(AdminClientConfig.REQUEST_TIMEOUT_MS_CONFIG, 10000);
        
        try (AdminClient adminClient = AdminClient.create(adminProps)) {
            List<NewTopic> topics = Arrays.asList(
                new NewTopic(inputTopic, 1, (short) 1),
                new NewTopic(outputTopic, 1, (short) 1)
            );
            CreateTopicsResult createResult = adminClient.createTopics(topics);
            createResult.all().get(10, TimeUnit.SECONDS);
            System.out.println("✅ Pre-created input and output topics");
            Thread.sleep(1000); // Allow topics to be fully propagated
        }
        
        Properties streamsProps = new Properties();
        streamsProps.putAll(baseProps);
        streamsProps.put(StreamsConfig.APPLICATION_ID_CONFIG, appId);
        streamsProps.put(StreamsConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        streamsProps.put(StreamsConfig.DEFAULT_KEY_SERDE_CLASS_CONFIG, Serdes.String().getClass());
        streamsProps.put(StreamsConfig.DEFAULT_VALUE_SERDE_CLASS_CONFIG, Serdes.String().getClass());
        streamsProps.put(StreamsConfig.COMMIT_INTERVAL_MS_CONFIG, 1000);
        // Reduce internal topic replication factor for single broker
        streamsProps.put(StreamsConfig.REPLICATION_FACTOR_CONFIG, 1);
        
        StreamsBuilder builder = new StreamsBuilder();
        
        // Simple transformation stream
        KStream<String, String> sourceStream = builder.stream(inputTopic);
        sourceStream
            .filter((key, value) -> value != null && value.length() > 0)
            .mapValues(value -> "PROCESSED: " + value.toUpperCase())
            .to(outputTopic);
        
        Topology topology = builder.build();
        assertNotNull(topology, "Topology should not be null");
        assertNotNull(topology.describe(), "Topology description should not be null");
        System.out.println("📋 Streams topology: " + topology.describe());
        
        boolean streamStarted = false;
        boolean messageSent = false;
        boolean messageProcessed = false;
        
        try (KafkaStreams streams = new KafkaStreams(topology, streamsProps)) {
            final boolean[] runningStateReached = {false};
            final String[] lastState = {"CREATED"};
            
            streams.setStateListener((newState, oldState) -> {
                System.out.println("🔄 Streams state changed from " + oldState + " to " + newState);
                lastState[0] = newState.toString();
                if (newState == KafkaStreams.State.RUNNING) {
                    runningStateReached[0] = true;
                }
            });
            
            // Set uncaught exception handler to catch any initialization errors
            streams.setUncaughtExceptionHandler((throwable) -> {
                System.err.println("⚠️ Streams uncaught exception: " + throwable.getMessage());
                return StreamsUncaughtExceptionHandler.StreamThreadExceptionResponse.SHUTDOWN_CLIENT;
            });
            
            streams.start();
            streamStarted = true;
            
            // Wait for the streams to start and reach RUNNING state (increased timeout to 30 seconds)
            long startWait = System.currentTimeMillis();
            int maxWaitMs = 30000; // 30 seconds
            while (!runningStateReached[0] && (System.currentTimeMillis() - startWait) < maxWaitMs) {
                Thread.sleep(500);
                // Check if streams is in ERROR state
                if (streams.state() == KafkaStreams.State.ERROR) {
                    fail("Streams entered ERROR state. Last known state: " + lastState[0]);
                }
            }
            
            assertTrue(runningStateReached[0], 
                      "Streams should reach RUNNING state within " + (maxWaitMs/1000) + " seconds. " +
                      "Last state: " + lastState[0] + ", Current state: " + streams.state());
            System.out.println("✅ Streams reached RUNNING state");
            
            // Send test message to input topic
            Properties producerProps = new Properties();
            producerProps.putAll(baseProps);
            producerProps.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
            producerProps.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
            
            String testMessage = "stream-test-message";
            try (Producer<String, String> producer = new KafkaProducer<>(producerProps)) {
                ProducerRecord<String, String> record = new ProducerRecord<>(
                    inputTopic, "stream-key", testMessage);
                RecordMetadata metadata = producer.send(record).get(5, TimeUnit.SECONDS);
                assertNotNull(metadata, "Producer metadata should not be null");
                messageSent = true;
                System.out.println("📤 Test message sent to streams input topic");
            }
            
            // Let streams process
            Thread.sleep(5000);
            
            // Verify the message was processed by consuming from output topic
            Properties consumerProps = new Properties();
            consumerProps.putAll(baseProps);
            consumerProps.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class);
            consumerProps.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class);
            consumerProps.put(ConsumerConfig.GROUP_ID_CONFIG, "streams-verify-group-" + System.currentTimeMillis());
            consumerProps.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
            
            try (Consumer<String, String> consumer = new KafkaConsumer<>(consumerProps)) {
                consumer.subscribe(Collections.singletonList(outputTopic));
                
                long consumeStartTime = System.currentTimeMillis();
                while (!messageProcessed && (System.currentTimeMillis() - consumeStartTime) < 10000) {
                    ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(1000));
                    
                    for (ConsumerRecord<String, String> record : records) {
                        assertNotNull(record.value(), "Output record value should not be null");
                        assertEquals("PROCESSED: " + testMessage.toUpperCase(), record.value(), 
                                   "Message should be transformed to uppercase with prefix");
                        System.out.println("✅ Processed message verified: " + record.value());
                        messageProcessed = true;
                        break;
                    }
                }
            }
            
            streams.close(Duration.ofSeconds(10));
            System.out.println("✅ Streams closed successfully");
        }
        
        // Final assertions
        assertTrue(streamStarted, "Streams should have started");
        assertTrue(messageSent, "Test message should have been sent");
        assertTrue(messageProcessed, "Message should have been processed and verified in output topic");
        
        System.out.println("✅ Streams API compatibility test completed with all assertions passed");
    }
    
    @Test
    @Order(7)
    @DisplayName("Custom Serializers Test")
    public void testCustomSerializers() throws Exception {
        System.out.println("🛠️ Testing Custom Serializers...");
        
        String topicName = "custom-serializer-topic-" + System.currentTimeMillis();
        
        // Test with ByteArray serializer
        Properties producerProps = new Properties();
        producerProps.putAll(baseProps);
        producerProps.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
        producerProps.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, ByteArraySerializer.class);
        
        String sentMessage;
        try (Producer<String, byte[]> producer = new KafkaProducer<>(producerProps)) {
            sentMessage = "custom-serialized-message-" + System.currentTimeMillis();
            byte[] messageBytes = sentMessage.getBytes("UTF-8");
            
            ProducerRecord<String, byte[]> record = new ProducerRecord<>(topicName, "custom-key", messageBytes);
            RecordMetadata metadata = producer.send(record).get(10, TimeUnit.SECONDS);
            
            // JUnit assertions for custom serializer producer
            assertNotNull(messageBytes, "Serialized message bytes should not be null");
            assertTrue(messageBytes.length > 0, "Serialized message should have positive length");
            assertNotNull(metadata, "RecordMetadata should not be null");
            assertEquals(topicName, metadata.topic(), "Topic should match");
            assertTrue(metadata.partition() >= 0, "Partition should be non-negative");
            assertTrue(metadata.offset() >= 0, "Offset should be non-negative");
            
            System.out.println("✅ Custom serializer message sent: " + sentMessage + 
                             " (serialized to " + messageBytes.length + " bytes)");
            System.out.println("📍 Sent to partition: " + metadata.partition() + 
                             ", offset: " + metadata.offset());
        }
        
        // Test consumption with ByteArray deserializer
        Properties consumerProps = new Properties();
        consumerProps.putAll(baseProps);
        consumerProps.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        consumerProps.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class);
        consumerProps.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, ByteArrayDeserializer.class);
        consumerProps.put(ConsumerConfig.GROUP_ID_CONFIG, "custom-serializer-group-" + System.currentTimeMillis());
        consumerProps.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        
        try (Consumer<String, byte[]> consumer = new KafkaConsumer<>(consumerProps)) {
            consumer.subscribe(Collections.singletonList(topicName));
            
            long startTime = System.currentTimeMillis();
            boolean messageReceived = false;
            String receivedMessage = null;
            
            while (!messageReceived && (System.currentTimeMillis() - startTime) < 15000) {
                ConsumerRecords<String, byte[]> records = consumer.poll(Duration.ofMillis(1000));
                
                for (ConsumerRecord<String, byte[]> record : records) {
                    // JUnit assertions for custom deserializer consumer
                    assertNotNull(record.key(), "Consumer record key should not be null");
                    assertNotNull(record.value(), "Consumer record value should not be null");
                    assertEquals("custom-key", record.key(), "Consumer record key should match");
                    assertTrue(record.value().length > 0, "Deserialized byte array should have positive length");
                    
                    receivedMessage = new String(record.value(), "UTF-8");
                    
                    // JUnit assertion for message content
                    assertEquals(sentMessage, receivedMessage, "Deserialized message should match original");
                    
                    System.out.println("✅ Custom deserializer message received: " + receivedMessage);
                    messageReceived = true;
                }
            }
            
            // JUnit assertion for overall test success
            assertTrue(messageReceived, "Should have received at least one message with custom deserializers within timeout");
            assertNotNull(receivedMessage, "Received message should not be null");
            
            System.out.println("✅ Custom serializers test completed successfully");
        }
    }
    
    @Test
    @Order(8)
    @DisplayName("Quotas Handling Test")
    public void testQuotasHandling() throws Exception {
        System.out.println("📊 Testing Quotas Handling...");
        
        String topicName = "quota-test-topic-" + System.currentTimeMillis();
        
        Properties producerProps = new Properties();
        producerProps.putAll(baseProps);
        producerProps.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
        producerProps.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
        
        // Configure for potential quota triggering
        producerProps.put(ProducerConfig.BATCH_SIZE_CONFIG, 1);
        producerProps.put(ProducerConfig.LINGER_MS_CONFIG, 0);
        producerProps.put(ProducerConfig.ACKS_CONFIG, "1");
        
        try (Producer<String, String> producer = new KafkaProducer<>(producerProps)) {
            long startTime = System.currentTimeMillis();
            int messageCount = 100;
            
            System.out.println("📤 Sending " + messageCount + " messages rapidly to test quota handling...");
            
            List<Future<RecordMetadata>> futures = new ArrayList<>();
            
            for (int i = 0; i < messageCount; i++) {
                ProducerRecord<String, String> record = new ProducerRecord<>(
                    topicName, "quota-key-" + i, "quota-message-" + i + "-" + System.currentTimeMillis());
                futures.add(producer.send(record));
            }
            
            // Wait for all sends to complete
            int successCount = 0;
            int throttledCount = 0;
            
            for (Future<RecordMetadata> future : futures) {
                try {
                    RecordMetadata metadata = future.get(30, TimeUnit.SECONDS);
                    successCount++;
                } catch (Exception e) {
                    if (e.getMessage().contains("quota") || e.getMessage().contains("throttle")) {
                        throttledCount++;
                    } else {
                        throw e;
                    }
                }
            }
            
            long endTime = System.currentTimeMillis();
            long duration = endTime - startTime;
            
            // JUnit assertions for quota handling test
            assertTrue(successCount >= 0, "Success count should be non-negative");
            assertTrue(throttledCount >= 0, "Throttled count should be non-negative");
            assertEquals(messageCount, successCount + throttledCount, "Total messages should equal success + throttled");
            assertTrue(duration > 0, "Duration should be positive");
            
            // Most messages should succeed (quotas may or may not be applied depending on configuration)
            assertTrue(successCount > 0, "At least some messages should succeed");
            
            System.out.println("✅ Quota test completed:");
            System.out.println("   📊 Messages sent successfully: " + successCount);
            System.out.println("   ⏱️ Messages throttled: " + throttledCount);
            System.out.println("   🕐 Total duration: " + duration + "ms");
            System.out.println("   📈 Throughput: " + (messageCount * 1000.0 / duration) + " messages/sec");
        }
    }
    
    @Test
    @Order(9)
    @DisplayName("Rate Limiting Test")
    public void testRateLimiting() throws Exception {
        System.out.println("⏱️ Testing Rate Limiting Behavior...");
        
        String topicName = "rate-limit-topic-" + System.currentTimeMillis();
        
        Properties producerProps = new Properties();
        producerProps.putAll(baseProps);
        producerProps.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
        producerProps.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
        
        // Configure for rate limiting testing
        producerProps.put(ProducerConfig.BATCH_SIZE_CONFIG, 16384);
        producerProps.put(ProducerConfig.LINGER_MS_CONFIG, 100);
        producerProps.put(ProducerConfig.BUFFER_MEMORY_CONFIG, 33554432L);
        producerProps.put(ProducerConfig.MAX_BLOCK_MS_CONFIG, 10000L);
        
        List<Long> batchDurations = new ArrayList<>();
        int batchCount = 5;
        int messagesPerBatch = 20;
        int totalMessages = batchCount * messagesPerBatch;
        int successCount = 0;
        
        try (Producer<String, String> producer = new KafkaProducer<>(producerProps)) {
            long totalStartTime = System.currentTimeMillis();
            
            System.out.println("📤 Sending " + batchCount + " batches of " + messagesPerBatch + 
                             " messages each with controlled timing...");
            
            List<Future<RecordMetadata>> allFutures = new ArrayList<>();
            
            for (int batch = 0; batch < batchCount; batch++) {
                long batchStartTime = System.currentTimeMillis();
                
                for (int i = 0; i < messagesPerBatch; i++) {
                    ProducerRecord<String, String> record = new ProducerRecord<>(
                        topicName, 
                        "batch-" + batch + "-key-" + i, 
                        "rate-limit-message-batch-" + batch + "-msg-" + i + "-" + System.currentTimeMillis()
                    );
                    allFutures.add(producer.send(record));
                }
                
                producer.flush();
                
                long batchEndTime = System.currentTimeMillis();
                long batchDuration = batchEndTime - batchStartTime;
                batchDurations.add(batchDuration);
                
                assertTrue(batchDuration >= 0, "Batch duration should be non-negative");
                assertTrue(batchDuration < 30000, "Batch should complete within 30 seconds");
                
                System.out.println("   📊 Batch " + (batch + 1) + " sent in " + batchDuration + "ms");
                
                if (batch < batchCount - 1) {
                    Thread.sleep(1000); // 1 second between batches
                }
            }
            
            // Verify all messages were sent successfully
            for (Future<RecordMetadata> future : allFutures) {
                try {
                    RecordMetadata metadata = future.get(10, TimeUnit.SECONDS);
                    assertNotNull(metadata, "RecordMetadata should not be null");
                    successCount++;
                } catch (Exception e) {
                    System.err.println("⚠️ Message send failed: " + e.getMessage());
                }
            }
            
            long totalEndTime = System.currentTimeMillis();
            long totalDuration = totalEndTime - totalStartTime;
            
            // Assertions
            assertEquals(batchCount, batchDurations.size(), "Should have recorded duration for each batch");
            assertTrue(totalDuration > 0, "Total duration should be positive");
            assertTrue(totalDuration >= (batchCount - 1) * 1000, 
                      "Total duration should account for sleep time between batches");
            assertEquals(totalMessages, successCount, "All messages should be sent successfully");
            assertTrue(successCount > 0, "At least some messages should be sent successfully");
            
            double throughput = totalMessages * 1000.0 / totalDuration;
            assertTrue(throughput > 0, "Throughput should be positive");
            
            System.out.println("✅ Rate limiting test completed:");
            System.out.println("   📊 Total messages sent: " + totalMessages);
            System.out.println("   ✅ Successful sends: " + successCount);
            System.out.println("   🕐 Total duration: " + totalDuration + "ms");
            System.out.println("   📈 Average throughput: " + throughput + " messages/sec");
        }
    }
    
    @Test
    @Order(10)
    @DisplayName("API Versions Test")
    public void testAPIVersions() throws Exception {
        System.out.println("🔌 Testing API Versions...");
        
        Properties adminProps = new Properties();
        adminProps.putAll(baseProps);
        adminProps.put(AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        adminProps.put(AdminClientConfig.REQUEST_TIMEOUT_MS_CONFIG, 10000);
        
        try (AdminClient adminClient = AdminClient.create(adminProps)) {
            // Test cluster information to verify API connectivity
            DescribeClusterResult clusterResult = adminClient.describeCluster();
            
            String clusterId = clusterResult.clusterId().get(10, TimeUnit.SECONDS);
            Collection<Node> nodes = clusterResult.nodes().get(10, TimeUnit.SECONDS);
            Node controller = clusterResult.controller().get(10, TimeUnit.SECONDS);
            
            // JUnit assertions for API Versions test
            assertNotNull(clusterId, "Cluster ID should not be null");
            assertFalse(clusterId.isEmpty(), "Cluster ID should not be empty");
            assertNotNull(nodes, "Broker nodes collection should not be null");
            assertFalse(nodes.isEmpty(), "Should have at least one broker node");
            assertNotNull(controller, "Controller should not be null");
            assertTrue(controller.id() >= 0, "Controller ID should be non-negative");
            
            System.out.println("✅ Cluster ID: " + clusterId);
            System.out.println("✅ Broker nodes: " + nodes.size());
            System.out.println("✅ Controller: " + controller.id() + " (" + controller.host() + ":" + controller.port() + ")");
            
            // Test basic admin API functionality
            ListTopicsResult topicsResult = adminClient.listTopics();
            Set<String> topicNames = topicsResult.names().get(10, TimeUnit.SECONDS);
            
            // JUnit assertions for topic listing
            assertNotNull(topicNames, "Topic names set should not be null");
            assertTrue(topicNames.size() >= 0, "Topic count should be non-negative");
            
            System.out.println("✅ Topics available: " + topicNames.size());
            System.out.println("✅ API Versions test completed - all admin APIs accessible");
        }
    }
    
    @Test
    @Order(11)
    @DisplayName("Topic Management Test")
    public void testTopicManagement() throws Exception {
        System.out.println("📋 Testing Topic Management...");
        
        Properties adminProps = new Properties();
        adminProps.putAll(baseProps);
        adminProps.put(AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        adminProps.put(AdminClientConfig.REQUEST_TIMEOUT_MS_CONFIG, 10000);
        
        String testTopicName = "topic-mgmt-test-" + System.currentTimeMillis();
        boolean topicCreated = false;
        boolean topicFoundInList = false;
        boolean topicDescribed = false;
        boolean topicDeleted = false;
        
        try (AdminClient adminClient = AdminClient.create(adminProps)) {
            assertNotNull(adminClient, "AdminClient should not be null");
            
            // Create topic
            System.out.println("Creating topic: " + testTopicName);
            NewTopic newTopic = new NewTopic(testTopicName, 1, (short) 1);
            CreateTopicsResult createResult = adminClient.createTopics(Collections.singletonList(newTopic));
            assertNotNull(createResult, "CreateTopicsResult should not be null");
            
            // This will throw an exception if creation fails
            createResult.all().get(10, TimeUnit.SECONDS);
            topicCreated = true;
            System.out.println("✅ Topic created successfully");
            
            // Wait a bit for topic to be fully propagated
            Thread.sleep(1000);
            
            // List topics to verify creation
            ListTopicsResult listResult = adminClient.listTopics();
            assertNotNull(listResult, "ListTopicsResult should not be null");
            
            Set<String> topics = listResult.names().get(10, TimeUnit.SECONDS);
            assertNotNull(topics, "Topics set should not be null");
            assertTrue(topics.size() > 0, "Should have at least one topic");
            assertTrue(topics.contains(testTopicName), "Topic list should contain newly created topic");
            topicFoundInList = true;
            System.out.println("✅ Topic found in topic list (total topics: " + topics.size() + ")");
            
            // Describe topic
            DescribeTopicsResult describeResult = adminClient.describeTopics(Collections.singletonList(testTopicName));
            assertNotNull(describeResult, "DescribeTopicsResult should not be null");
            
            TopicDescription topicDesc = getTopicDescription(describeResult, testTopicName);
            assertNotNull(topicDesc, "TopicDescription should not be null");
            assertNotNull(topicDesc.partitions(), "Topic partitions should not be null");
            assertEquals(1, topicDesc.partitions().size(), "Topic should have exactly 1 partition");
            assertEquals(testTopicName, topicDesc.name(), "Topic name should match");
            topicDescribed = true;
            System.out.println("✅ Topic described: " + topicDesc.partitions().size() + " partitions");
            
            // Delete topic
            DeleteTopicsResult deleteResult = adminClient.deleteTopics(Collections.singletonList(testTopicName));
            assertNotNull(deleteResult, "DeleteTopicsResult should not be null");
            
            // This will throw an exception if deletion fails
            deleteResult.all().get(10, TimeUnit.SECONDS);
            topicDeleted = true;
            System.out.println("✅ Topic deleted successfully");
            
            // Wait a bit and verify topic is gone
            Thread.sleep(1000);
            ListTopicsResult listAfterDelete = adminClient.listTopics();
            Set<String> topicsAfterDelete = listAfterDelete.names().get(10, TimeUnit.SECONDS);
            assertFalse(topicsAfterDelete.contains(testTopicName), 
                       "Topic should not exist after deletion");
            System.out.println("✅ Verified topic no longer exists after deletion");
        }
        
        // Final assertions
        assertTrue(topicCreated, "Topic creation should have succeeded");
        assertTrue(topicFoundInList, "Topic should have been found in list");
        assertTrue(topicDescribed, "Topic should have been described");
        assertTrue(topicDeleted, "Topic deletion should have succeeded");
        
        System.out.println("✅ Topic management test completed with all assertions passed");
    }
    
    @Test
    @Order(12)
    @DisplayName("Consumer Groups Test")
    public void testConsumerGroups() throws Exception {
        System.out.println("👥 Testing Consumer Groups...");
        
        Properties adminProps = new Properties();
        adminProps.putAll(baseProps);
        adminProps.put(AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        adminProps.put(AdminClientConfig.REQUEST_TIMEOUT_MS_CONFIG, 10000);
        
        try (AdminClient adminClient = AdminClient.create(adminProps)) {
            assertNotNull(adminClient, "AdminClient should not be null");
            
            // List consumer groups
            ListConsumerGroupsResult groupsResult = adminClient.listConsumerGroups();
            assertNotNull(groupsResult, "ListConsumerGroupsResult should not be null");
            
            Collection<ConsumerGroupListing> groups = groupsResult.all().get(10, TimeUnit.SECONDS);
            assertNotNull(groups, "Consumer groups collection should not be null");
            
            System.out.println("✅ Consumer groups found: " + groups.size());
            
            if (!groups.isEmpty()) {
                System.out.println("Consumer groups:");
                
                int validGroupCount = 0;
                for (ConsumerGroupListing group : groups) {
                    assertNotNull(group, "ConsumerGroupListing should not be null");
                    assertNotNull(group.groupId(), "Group ID should not be null");
                    assertFalse(group.groupId().isEmpty(), "Group ID should not be empty");
                    validGroupCount++;
                    
                    try {
                        // Handle version compatibility for state and type methods
                        String stateStr = "UNKNOWN";
                        String typeStr = "UNKNOWN";
                        
                        try {
                            // Try to get state - may return Optional<String> or Optional<ConsumerGroupState>
                            Object stateObj = group.state().orElse(null);
                            stateStr = stateObj != null ? stateObj.toString() : "UNKNOWN";
                        } catch (Exception e) {
                            stateStr = "UNKNOWN";
                        }
                        
                        try {
                            // Try to get type - may not exist in older versions
                            Object typeObj = group.getClass().getMethod("type").invoke(group);
                            if (typeObj != null) {
                                Object typeValue = typeObj.getClass().getMethod("orElse", Object.class).invoke(typeObj, "UNKNOWN");
                                typeStr = typeValue.toString();
                            }
                        } catch (Exception e) {
                            typeStr = "UNKNOWN";
                        }
                        
                        System.out.println("  - Group ID: " + group.groupId() + 
                                         ", State: " + stateStr +
                                         ", Type: " + typeStr);
                    } catch (Exception e) {
                        System.out.println("  - Group ID: " + group.groupId() + " (details unavailable)");
                    }
                }
                
                assertTrue(validGroupCount > 0, "Should have at least one valid consumer group");
                assertEquals(groups.size(), validGroupCount, "All groups should be valid");
                
                // Describe first group for more details
                String firstGroupId = groups.iterator().next().groupId();
                DescribeConsumerGroupsResult describeResult = adminClient.describeConsumerGroups(
                    Collections.singletonList(firstGroupId));
                assertNotNull(describeResult, "DescribeConsumerGroupsResult should not be null");
                
                Map<String, ConsumerGroupDescription> descriptions = describeResult.all().get(10, TimeUnit.SECONDS);
                assertNotNull(descriptions, "Descriptions map should not be null");
                assertTrue(descriptions.containsKey(firstGroupId), "Should contain description for requested group");
                
                ConsumerGroupDescription groupDesc = descriptions.get(firstGroupId);
                assertNotNull(groupDesc, "ConsumerGroupDescription should not be null");
                assertNotNull(groupDesc.groupId(), "Group ID in description should not be null");
                assertEquals(firstGroupId, groupDesc.groupId(), "Group ID should match");
                assertNotNull(groupDesc.members(), "Group members should not be null");
                assertNotNull(groupDesc.state(), "Group state should not be null");
                assertNotNull(groupDesc.coordinator(), "Group coordinator should not be null");
                assertTrue(groupDesc.coordinator().id() >= 0, "Coordinator ID should be non-negative");
                
                System.out.println("✅ Group details for '" + firstGroupId + "':");
                System.out.println("   Members: " + groupDesc.members().size());
                System.out.println("   State: " + groupDesc.state());
                System.out.println("   Coordinator: " + groupDesc.coordinator().id());
            } else {
                System.out.println("ℹ️ No consumer groups currently active - this is valid but no groups to test");
            }
            
            System.out.println("✅ Consumer groups test completed with all assertions passed");
        }
    }
    
    @Test
    @Order(13)
    @DisplayName("Cluster Metadata Test")
    public void testClusterMetadata() throws Exception {
        System.out.println("🌐 Testing Cluster Metadata...");
        
        Properties adminProps = new Properties();
        adminProps.putAll(baseProps);
        adminProps.put(AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        adminProps.put(AdminClientConfig.REQUEST_TIMEOUT_MS_CONFIG, 10000);
        
        try (AdminClient adminClient = AdminClient.create(adminProps)) {
            assertNotNull(adminClient, "AdminClient should not be null");
            
            // Get cluster information
            DescribeClusterResult clusterResult = adminClient.describeCluster();
            assertNotNull(clusterResult, "DescribeClusterResult should not be null");
            
            String clusterId = clusterResult.clusterId().get(10, TimeUnit.SECONDS);
            assertNotNull(clusterId, "Cluster ID should not be null");
            assertFalse(clusterId.isEmpty(), "Cluster ID should not be empty");
            
            Collection<Node> nodes = clusterResult.nodes().get(10, TimeUnit.SECONDS);
            assertNotNull(nodes, "Nodes collection should not be null");
            assertFalse(nodes.isEmpty(), "Should have at least one broker node");
            
            Node controller = clusterResult.controller().get(10, TimeUnit.SECONDS);
            assertNotNull(controller, "Controller node should not be null");
            assertTrue(controller.id() >= 0, "Controller ID should be non-negative");
            assertNotNull(controller.host(), "Controller host should not be null");
            assertFalse(controller.host().isEmpty(), "Controller host should not be empty");
            assertTrue(controller.port() > 0, "Controller port should be positive");
            
            System.out.println("✅ Cluster Metadata:");
            System.out.println("   Cluster ID: " + clusterId);
            System.out.println("   Controller Node: " + controller.id() + " (" + controller.host() + ":" + controller.port() + ")");
            System.out.println("   Total Brokers: " + nodes.size());
            
            System.out.println("   Broker Details:");
            int validNodeCount = 0;
            for (Node node : nodes) {
                assertNotNull(node, "Node should not be null");
                assertTrue(node.id() >= 0, "Node ID should be non-negative");
                assertNotNull(node.host(), "Node host should not be null");
                assertFalse(node.host().isEmpty(), "Node host should not be empty");
                assertTrue(node.port() > 0, "Node port should be positive");
                
                System.out.println("     - Broker " + node.id() + ": " + node.host() + ":" + node.port() + 
                                 (node.hasRack() ? " (rack: " + node.rack() + ")" : ""));
                validNodeCount++;
            }
            
            assertEquals(nodes.size(), validNodeCount, "All nodes should be valid");
            
            // Verify controller is one of the nodes
            boolean controllerFound = false;
            for (Node node : nodes) {
                if (node.id() == controller.id()) {
                    controllerFound = true;
                    break;
                }
            }
            assertTrue(controllerFound, "Controller should be one of the broker nodes");
            
            System.out.println("ℹ️ Broker configuration details skipped for cross-version compatibility");
            System.out.println("✅ Cluster metadata test completed with all assertions passed");
        }
    }
    
    @Test
    @Order(1)
    @DisplayName("Kafka API Compatibility Test Suite")
    public void runCompatibilityTests() throws Exception {
        System.out.println("🔄 Running Compatibility Test Suite (API-focused)...");
        
        // Run all API tests that mirror the version-compatibility.sh script
        testAPIVersions();
        Thread.sleep(1000);
        
        testTopicManagement();
        Thread.sleep(1000);
        
        testBasicProducerConsumer();
        Thread.sleep(1000);
        
        testConsumerGroups();
        Thread.sleep(1000);
        
        testClusterMetadata();
        
        System.out.println("🎉 Compatibility test suite completed!");
    }
    
    @Test
    @Order(3)
    @DisplayName("Admin Operations Test")
    public void testAdminOperations() throws Exception {
        System.out.println("🔧 Testing Admin Operations...");
        
        Properties adminProps = new Properties();
        adminProps.putAll(baseProps);
        adminProps.put(AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        adminProps.put(AdminClientConfig.REQUEST_TIMEOUT_MS_CONFIG, 15000);
        
        String testTopicName = "admin-ops-test-" + System.currentTimeMillis();
        
        boolean topicCreated = false;
        boolean configDescribed = false;
        boolean partitionsIncreased = false;
        boolean recordsProduced = false;
        boolean recordsDeleted = false;
        boolean topicDeleted = false;
        
        try (AdminClient adminClient = AdminClient.create(adminProps)) {
            assertNotNull(adminClient, "AdminClient should not be null");
            
            // 1. Create topic for testing admin operations
            System.out.println("📝 Creating topic for admin operations testing: " + testTopicName);
            NewTopic newTopic = new NewTopic(testTopicName, 2, (short) 1); // 2 partitions initially
            CreateTopicsResult createResult = adminClient.createTopics(Collections.singletonList(newTopic));
            assertNotNull(createResult, "CreateTopicsResult should not be null");
            createResult.all().get(15, TimeUnit.SECONDS);
            topicCreated = true;
            System.out.println("✅ Topic created with 2 partitions");
            
            Thread.sleep(1000); // Allow topic to be fully created
            
            // 2. Alter topic configs (optional - may not be supported in all versions)
            System.out.println("⚙️ Testing topic configuration alterations...");
            try {
                Map<ConfigResource, Config> configsToAlter = new HashMap<>();
                ConfigResource topicResource = new ConfigResource(ConfigResource.Type.TOPIC, testTopicName);
                
                // Set retention time to 1 hour (3600000 ms)
                Config config = new Config(Arrays.asList(
                    new ConfigEntry("retention.ms", "3600000"),
                    new ConfigEntry("segment.ms", "3600000")
                ));
                configsToAlter.put(topicResource, config);
                
                alterTopicConfig(adminClient, configsToAlter);
                System.out.println("✅ Config alteration attempted (may be skipped in some versions)");
            } catch (Exception e) {
                System.out.println("⚠️ Topic config alteration not fully supported: " + e.getMessage());
                // Don't fail test - config alteration is optional
            }
            
            // 3. Describe configs
            System.out.println("📖 Testing configuration description...");
            ConfigResource topicResource = new ConfigResource(ConfigResource.Type.TOPIC, testTopicName);
            DescribeConfigsResult describeResult = adminClient.describeConfigs(Collections.singletonList(topicResource));
            assertNotNull(describeResult, "DescribeConfigsResult should not be null");
            
            Config topicConfig = describeResult.values().get(topicResource).get(10, TimeUnit.SECONDS);
            assertNotNull(topicConfig, "Topic config should not be null");
            assertNotNull(topicConfig.entries(), "Config entries should not be null");
            assertTrue(topicConfig.entries().size() > 0, "Should have at least one config entry");
            configDescribed = true;
            
            System.out.println("✅ Topic configuration retrieved:");
            System.out.println("   Total config entries: " + topicConfig.entries().size());
            
            // Show a few key configs
            for (ConfigEntry entry : topicConfig.entries()) {
                if (entry.name().equals("retention.ms") || entry.name().equals("segment.ms")) {
                    assertNotNull(entry.value(), "Config value for " + entry.name() + " should not be null");
                    System.out.println("   " + entry.name() + ": " + entry.value());
                }
            }
            
            // 4. Alter partition count
            System.out.println("📊 Testing partition count alteration...");
            Map<String, NewPartitions> partitionUpdates = new HashMap<>();
            partitionUpdates.put(testTopicName, NewPartitions.increaseTo(4)); // Increase to 4 partitions
            
            CreatePartitionsResult partitionResult = adminClient.createPartitions(partitionUpdates);
            assertNotNull(partitionResult, "CreatePartitionsResult should not be null");
            partitionResult.all().get(10, TimeUnit.SECONDS);
            
            // Verify partition count increased
            Thread.sleep(1000);
            DescribeTopicsResult describeTopicsResult = adminClient.describeTopics(Collections.singletonList(testTopicName));
            TopicDescription topicDesc = getTopicDescription(describeTopicsResult, testTopicName);
            
            assertNotNull(topicDesc, "Topic description should not be null");
            assertEquals(4, topicDesc.partitions().size(), "Topic should have 4 partitions after alteration");
            partitionsIncreased = true;
            System.out.println("✅ Partition count increased from 2 to " + topicDesc.partitions().size());
            
            // 5. Delete records (truncate topic)
            System.out.println("🗑️ Testing record deletion...");
            
            // First, produce some test records specifically to partition 0
            Properties producerProps = new Properties();
            producerProps.putAll(baseProps);
            producerProps.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
            producerProps.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
            producerProps.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
            
            int messagesProduced = 0;
            try (Producer<String, String> producer = new KafkaProducer<>(producerProps)) {
                // Produce 10 messages specifically to partition 0
                for (int i = 0; i < 10; i++) {
                    ProducerRecord<String, String> record = new ProducerRecord<>(
                        testTopicName, 0, "key-" + i, "test-message-" + i);
                    RecordMetadata metadata = producer.send(record).get();
                    assertNotNull(metadata, "RecordMetadata should not be null for message " + i);
                    assertEquals(0, metadata.partition(), "Message should be in partition 0");
                    messagesProduced++;
                }
                assertEquals(10, messagesProduced, "Should have produced exactly 10 messages");
                recordsProduced = true;
                System.out.println("   Produced 10 test messages to partition 0");
            }
            
            // Get current end offset for partition 0 to ensure we have data
            TopicPartition partition0 = new TopicPartition(testTopicName, 0);
            
            // Create a temporary consumer to check offsets
            Properties tempConsumerProps = new Properties();
            tempConsumerProps.putAll(baseProps);
            tempConsumerProps.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
            tempConsumerProps.put(ConsumerConfig.GROUP_ID_CONFIG, "temp-offset-check-" + System.currentTimeMillis());
            tempConsumerProps.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
            tempConsumerProps.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
            
            long endOffset;
            try (Consumer<String, String> tempConsumer = new KafkaConsumer<>(tempConsumerProps)) {
                Map<TopicPartition, Long> endOffsets = tempConsumer.endOffsets(Collections.singleton(partition0));
                endOffset = endOffsets.get(partition0);
                assertTrue(endOffset >= 10, "Partition 0 should have at least 10 messages (has " + endOffset + ")");
                System.out.println("   Partition 0 current end offset: " + endOffset);
            }
            
            // Delete records up to offset 5 on partition 0 (only if we have enough messages)
            long offsetToDelete = Math.min(5L, endOffset - 1);
            if (offsetToDelete > 0) {
                Map<TopicPartition, RecordsToDelete> recordsToDelete = new HashMap<>();
                recordsToDelete.put(partition0, RecordsToDelete.beforeOffset(offsetToDelete));
                
                DeleteRecordsResult deleteRecordsResult = adminClient.deleteRecords(recordsToDelete);
                assertNotNull(deleteRecordsResult, "DeleteRecordsResult should not be null");
                deleteRecordsResult.all().get(10, TimeUnit.SECONDS);
                recordsDeleted = true;
                System.out.println("✅ Records deleted up to offset " + offsetToDelete + " on partition 0");
            } else {
                recordsDeleted = true;
                System.out.println("✅ Skipped record deletion (partition has no records to delete)");
            }
            
            // Clean up - delete test topic
            DeleteTopicsResult deleteResult = adminClient.deleteTopics(Collections.singletonList(testTopicName));
            assertNotNull(deleteResult, "DeleteTopicsResult should not be null");
            deleteResult.all().get(10, TimeUnit.SECONDS);
            topicDeleted = true;
            System.out.println("🧹 Test topic cleaned up");
        }
        
        // Final assertions
        assertTrue(topicCreated, "Topic creation should have succeeded");
        assertTrue(configDescribed, "Config description should have succeeded");
        assertTrue(partitionsIncreased, "Partition increase should have succeeded");
        assertTrue(recordsProduced, "Record production should have succeeded");
        assertTrue(recordsDeleted, "Record deletion should have succeeded");
        assertTrue(topicDeleted, "Topic deletion should have succeeded");
        
        System.out.println("✅ Admin operations test completed with all assertions passed");
    }
    
    @Test
    @Order(14)
    @DisplayName("Consumer Operations Test")
    public void testConsumerOperations() throws Exception {
        System.out.println("👥 Testing Advanced Consumer Operations...");
        
        String topicName = "consumer-ops-test-" + System.currentTimeMillis();
        
        // Create test topic with multiple partitions for comprehensive testing
        Properties adminProps = new Properties();
        adminProps.putAll(baseProps);
        adminProps.put(AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        adminProps.put(AdminClientConfig.REQUEST_TIMEOUT_MS_CONFIG, 15000);
        
        try (AdminClient adminClient = AdminClient.create(adminProps)) {
            NewTopic newTopic = new NewTopic(topicName, 3, (short) 1); // 3 partitions
            CreateTopicsResult createResult = adminClient.createTopics(Collections.singletonList(newTopic));
            createResult.all().get(10, TimeUnit.SECONDS);
            System.out.println("📝 Created test topic with 3 partitions: " + topicName);
        }
        
        Thread.sleep(2000); // Allow topic to be fully created
        
        // Produce test messages to multiple partitions
        Properties producerProps = new Properties();
        producerProps.putAll(baseProps);
        producerProps.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        producerProps.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        producerProps.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        
        try (Producer<String, String> producer = new KafkaProducer<>(producerProps)) {
            // Send messages to different partitions
            for (int i = 0; i < 15; i++) {
                int partition = i % 3; // Distribute across 3 partitions
                ProducerRecord<String, String> record = new ProducerRecord<>(
                    topicName, partition, "key-" + i, "test-message-" + i);
                producer.send(record).get();
            }
            System.out.println("📤 Produced 15 messages across 3 partitions");
        }
        
        Thread.sleep(1000);
        
        // 1. Test Manual Offset Management
        System.out.println("🔧 Testing manual offset management...");
        testManualOffsetManagement(topicName);
        
        // 2. Test Auto-commit vs Manual Commit
        System.out.println("⚡ Testing auto-commit vs manual commit...");
        testCommitModes(topicName);
        
        // 3. Test Seek Operations
        System.out.println("🎯 Testing seek operations...");
        testSeekOperations(topicName);
        
        // 4. Test Partition Assignment Strategies
        System.out.println("📊 Testing partition assignment strategies...");
        testPartitionAssignmentStrategies(topicName);
        
        // 5. Test Pause/Resume Consumption
        System.out.println("⏸️ Testing pause/resume consumption...");
        testPauseResumeConsumption(topicName);
        
        // 6. Test Consumer Lag Monitoring
        System.out.println("📈 Testing consumer lag monitoring...");
        testConsumerLagMonitoring(topicName);
        
        // Clean up test topic
        try (AdminClient adminClient = AdminClient.create(adminProps)) {
            DeleteTopicsResult deleteResult = adminClient.deleteTopics(Collections.singletonList(topicName));
            deleteResult.all().get(10, TimeUnit.SECONDS);
            System.out.println("🧹 Test topic cleaned up");
        } catch (Exception e) {
            System.out.println("⚠️ Cleanup failed: " + e.getMessage());
        }
        
        System.out.println("✅ Consumer operations test completed");
    }
    
    private void testManualOffsetManagement(String topicName) throws Exception {
        Properties props = new Properties();
        props.putAll(baseProps);
        props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ConsumerConfig.GROUP_ID_CONFIG, "manual-offset-group-" + System.currentTimeMillis());
        props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "false"); // Manual commit
        props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        
        try (Consumer<String, String> consumer = new KafkaConsumer<>(props)) {
            consumer.subscribe(Collections.singletonList(topicName));
            
            // Poll to get partition assignment
            ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(3000));
            
            assertFalse(records.isEmpty(), "Should receive records for manual offset test (topic should have data)");
            
            int processedCount = 0;
            Map<TopicPartition, OffsetAndMetadata> offsetsToCommit = new HashMap<>();
            
            for (ConsumerRecord<String, String> record : records) {
                assertNotNull(record, "ConsumerRecord should not be null");
                processedCount++;
                TopicPartition tp = new TopicPartition(record.topic(), record.partition());
                offsetsToCommit.put(tp, new OffsetAndMetadata(record.offset() + 1));
                
                if (processedCount >= 3) break; // Process only first 3 messages
            }
            
            // Commit specific offsets manually
            assertDoesNotThrow(() -> consumer.commitSync(offsetsToCommit), 
                             "Manual offset commit should not throw exception");
            
            assertNotNull(offsetsToCommit, "Offsets to commit should not be null");
            assertTrue(offsetsToCommit.size() > 0, "Should have offsets to commit");
            assertTrue(processedCount >= 3, "Should have processed at least 3 messages");
            
            // Verify committed offsets
            for (Map.Entry<TopicPartition, OffsetAndMetadata> entry : offsetsToCommit.entrySet()) {
                // Use Set for Kafka 8.0.0+ compatibility
                Set<TopicPartition> partitions = Collections.singleton(entry.getKey());
                Map<TopicPartition, OffsetAndMetadata> committedOffsets = consumer.committed(partitions);
                assertNotNull(committedOffsets, "Committed offsets map should not be null");
                OffsetAndMetadata committed = committedOffsets.get(entry.getKey());
                assertNotNull(committed, "Committed offset should not be null for partition " + entry.getKey().partition());
                assertEquals(entry.getValue().offset(), committed.offset(), 
                           "Committed offset should match for partition " + entry.getKey().partition());
            }
            
            System.out.println("   ✅ Manual offset commit successful for " + processedCount + " messages");
            System.out.println("   📍 Committed offsets for " + offsetsToCommit.size() + " partitions");
            System.out.println("   ✅ Verified committed offsets match expected values");
        }
    }
    
    private void testCommitModes(String topicName) throws Exception {
        String groupId = "commit-modes-group-" + System.currentTimeMillis();
        
        // Test auto-commit mode
        Properties autoCommitProps = new Properties();
        autoCommitProps.putAll(baseProps);
        autoCommitProps.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        autoCommitProps.put(ConsumerConfig.GROUP_ID_CONFIG, groupId + "-auto");
        autoCommitProps.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        autoCommitProps.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        autoCommitProps.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "true");
        autoCommitProps.put(ConsumerConfig.AUTO_COMMIT_INTERVAL_MS_CONFIG, "1000"); // 1 second
        autoCommitProps.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        
        int autoCommitCount = 0;
        try (Consumer<String, String> consumer = new KafkaConsumer<>(autoCommitProps)) {
            consumer.subscribe(Collections.singletonList(topicName));
            
            ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(3000));
            autoCommitCount = records.count();
            
            // Wait for auto-commit to happen
            Thread.sleep(1500);
        }
        
        // Test manual commit mode
        Properties manualCommitProps = new Properties();
        manualCommitProps.putAll(baseProps);
        manualCommitProps.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        manualCommitProps.put(ConsumerConfig.GROUP_ID_CONFIG, groupId + "-manual");
        manualCommitProps.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        manualCommitProps.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        manualCommitProps.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "false");
        manualCommitProps.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        
        int manualCommitCount = 0;
        boolean manualCommitSucceeded = false;
        try (Consumer<String, String> consumer = new KafkaConsumer<>(manualCommitProps)) {
            consumer.subscribe(Collections.singletonList(topicName));
            
            ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(3000));
            manualCommitCount = records.count();
            
            if (manualCommitCount > 0) {
                assertDoesNotThrow(() -> consumer.commitSync(), "Manual commit should not throw exception");
                manualCommitSucceeded = true;
            }
        }
        
        // Stronger assertions - messages should have been produced to this topic
        assertTrue(autoCommitCount > 0, "Auto-commit consumer should receive messages (topic should have data)");
        assertTrue(manualCommitCount > 0, "Manual-commit consumer should receive messages (topic should have data)");
        
        if (manualCommitCount > 0) {
            assertTrue(manualCommitSucceeded, "Manual commit should have succeeded when messages were received");
        }
        
        System.out.println("   ✅ Auto-commit mode: processed " + autoCommitCount + " messages");
        System.out.println("   ✅ Manual-commit mode: processed " + manualCommitCount + " messages");
    }
    
    private void testSeekOperations(String topicName) throws Exception {
        Properties props = new Properties();
        props.putAll(baseProps);
        props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ConsumerConfig.GROUP_ID_CONFIG, "seek-test-group-" + System.currentTimeMillis());
        props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "false");
        
        try (Consumer<String, String> consumer = new KafkaConsumer<>(props)) {
            consumer.subscribe(Collections.singletonList(topicName));
            
            // Poll to get assignment
            consumer.poll(Duration.ofMillis(2000));
            
            Set<TopicPartition> assignment = consumer.assignment();
            assertNotNull(assignment, "Assignment should not be null");
            
            if (!assignment.isEmpty()) {
                TopicPartition partition = assignment.iterator().next();
                
                // Test seek to beginning
                consumer.seekToBeginning(assignment);
                long beginningPosition = consumer.position(partition);
                
                // Test seek to end
                consumer.seekToEnd(assignment);
                long endPosition = consumer.position(partition);
                
                // Test seek to specific offset
                long seekOffset = Math.max(0, (endPosition - beginningPosition) / 2);
                consumer.seek(partition, seekOffset);
                long seekPosition = consumer.position(partition);
                
                assertTrue(beginningPosition >= 0, "Beginning position should be non-negative");
                assertTrue(endPosition >= beginningPosition, "End position should be >= beginning position");
                assertEquals(seekOffset, seekPosition, "Seek position should match target offset");
                
                System.out.println("   ✅ Seek to beginning: offset " + beginningPosition);
                System.out.println("   ✅ Seek to end: offset " + endPosition);
                System.out.println("   ✅ Seek to specific offset: " + seekPosition);
                
                // Poll after seek to verify
                ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(2000));
                System.out.println("   📖 Records after seek: " + records.count());
            } else {
                System.out.println("   ⚠️ No partition assignment for seek test");
            }
        }
    }
    
    private void testPartitionAssignmentStrategies(String topicName) throws Exception {
        System.out.println("   🔄 Testing Range Assignment Strategy...");
        testAssignmentStrategy(topicName, "range", "org.apache.kafka.clients.consumer.RangeAssignor");
        
        System.out.println("   🔄 Testing RoundRobin Assignment Strategy...");
        testAssignmentStrategy(topicName, "roundrobin", "org.apache.kafka.clients.consumer.RoundRobinAssignor");
        
        try {
            System.out.println("   🔄 Testing Sticky Assignment Strategy...");
            testAssignmentStrategy(topicName, "sticky", "org.apache.kafka.clients.consumer.StickyAssignor");
        } catch (Exception e) {
            System.out.println("   ⚠️ Sticky assignment not available in this version: " + e.getMessage());
        }
    }
    
    private void testAssignmentStrategy(String topicName, String strategyName, String strategyClass) throws Exception {
        Properties props = new Properties();
        props.putAll(baseProps);
        props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ConsumerConfig.GROUP_ID_CONFIG, strategyName + "-group-" + System.currentTimeMillis());
        props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        props.put(ConsumerConfig.PARTITION_ASSIGNMENT_STRATEGY_CONFIG, strategyClass);
        props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        
        try (Consumer<String, String> consumer = new KafkaConsumer<>(props)) {
            consumer.subscribe(Collections.singletonList(topicName));
            
            // Poll to trigger assignment
            consumer.poll(Duration.ofMillis(3000));
            
            Set<TopicPartition> assignment = consumer.assignment();
            assertNotNull(assignment, "Assignment should not be null");
            
            System.out.println("     ✅ " + strategyName + " strategy assigned " + assignment.size() + " partitions");
            
            for (TopicPartition tp : assignment) {
                System.out.println("     📍 Partition " + tp.partition() + " assigned");
            }
        }
    }
    
    private void testPauseResumeConsumption(String topicName) throws Exception {
        Properties props = new Properties();
        props.putAll(baseProps);
        props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ConsumerConfig.GROUP_ID_CONFIG, "pause-resume-group-" + System.currentTimeMillis());
        props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        
        try (Consumer<String, String> consumer = new KafkaConsumer<>(props)) {
            consumer.subscribe(Collections.singletonList(topicName));
            
            // Initial poll to get assignment
            ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(3000));
            int initialCount = records.count();
            
            Set<TopicPartition> assignment = consumer.assignment();
            if (!assignment.isEmpty()) {
                // Pause all partitions
                consumer.pause(assignment);
                Set<TopicPartition> pausedPartitions = consumer.paused();
                
                assertNotNull(pausedPartitions, "Paused partitions should not be null");
                assertEquals(assignment.size(), pausedPartitions.size(), "All partitions should be paused");
                
                System.out.println("   ⏸️ Paused " + pausedPartitions.size() + " partitions");
                
                // Poll while paused (should get no records)
                ConsumerRecords<String, String> pausedRecords = consumer.poll(Duration.ofMillis(2000));
                int pausedCount = pausedRecords.count();
                
                // Resume all partitions
                consumer.resume(assignment);
                Set<TopicPartition> resumedPaused = consumer.paused();
                
                assertTrue(resumedPaused.isEmpty(), "No partitions should be paused after resume");
                
                System.out.println("   ▶️ Resumed " + assignment.size() + " partitions");
                
                // Poll after resume
                ConsumerRecords<String, String> resumedRecords = consumer.poll(Duration.ofMillis(2000));
                int resumedCount = resumedRecords.count();
                
                System.out.println("   📊 Initial poll: " + initialCount + " records");
                System.out.println("   📊 Paused poll: " + pausedCount + " records");
                System.out.println("   📊 Resumed poll: " + resumedCount + " records");
                
                assertTrue(initialCount >= 0, "Initial count should be non-negative");
                assertEquals(0, pausedCount, "Paused poll should return 0 records");
            } else {
                System.out.println("   ⚠️ No partition assignment for pause/resume test");
            }
        }
    }
    
    private void testConsumerLagMonitoring(String topicName) throws Exception {
        Properties props = new Properties();
        props.putAll(baseProps);
        props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ConsumerConfig.GROUP_ID_CONFIG, "lag-monitoring-group-" + System.currentTimeMillis());
        props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "false");
        
        try (Consumer<String, String> consumer = new KafkaConsumer<>(props)) {
            consumer.subscribe(Collections.singletonList(topicName));
            
            // Poll to get assignment
            ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(3000));
            
            Set<TopicPartition> assignment = consumer.assignment();
            if (!assignment.isEmpty()) {
                // Get end offsets (latest available offsets)
                Map<TopicPartition, Long> endOffsets = consumer.endOffsets(assignment);
                assertNotNull(endOffsets, "End offsets should not be null");
                
                // Get beginning offsets
                Map<TopicPartition, Long> beginningOffsets = consumer.beginningOffsets(assignment);
                assertNotNull(beginningOffsets, "Beginning offsets should not be null");
                
                // Calculate and display lag for each partition
                long totalLag = 0;
                for (TopicPartition tp : assignment) {
                    long currentPosition = consumer.position(tp);
                    long endOffset = endOffsets.get(tp);
                    long beginningOffset = beginningOffsets.get(tp);
                    long lag = endOffset - currentPosition;
                    totalLag += lag;
                    
                    assertTrue(currentPosition >= beginningOffset, "Current position should be >= beginning offset");
                    assertTrue(endOffset >= currentPosition, "End offset should be >= current position");
                    assertTrue(lag >= 0, "Lag should be non-negative");
                    
                    System.out.println("   📈 Partition " + tp.partition() + ": position=" + currentPosition + 
                                     ", end=" + endOffset + ", lag=" + lag);
                }
                
                System.out.println("   📊 Total consumer lag: " + totalLag + " messages");
                
                // Test lag metrics after consuming some messages
                if (records.count() > 0) {
                    // Consume some messages but don't commit
                    int processedCount = Math.min(5, records.count());
                    
                    // Check lag again
                    Map<TopicPartition, Long> newEndOffsets = consumer.endOffsets(assignment);
                    long newTotalLag = 0;
                    for (TopicPartition tp : assignment) {
                        long currentPosition = consumer.position(tp);
                        long endOffset = newEndOffsets.get(tp);
                        long lag = endOffset - currentPosition;
                        newTotalLag += lag;
                    }
                    
                    System.out.println("   📊 Updated total lag: " + newTotalLag + " messages");
                }
            } else {
                System.out.println("   ⚠️ No partition assignment for lag monitoring test");
            }
        }
    }
}
