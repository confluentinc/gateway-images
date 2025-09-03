#!/usr/bin/env python3
"""
Kafka API Key to Integer Mapping
Maps Kafka protocol API key names to their integer values
"""

KAFKA_API_KEYS = {
    'produce': 0,
    'fetch': 1,
    'list_offsets': 2,
    'metadata': 3,
    'leader_and_isr': 4,
    'stop_replica': 5,
    'update_metadata': 6,
    'controlled_shutdown': 7,
    'offset_commit': 8,
    'offset_fetch': 9,
    'find_coordinator': 10,
    'join_group': 11,
    'heartbeat': 12,
    'leave_group': 13,
    'sync_group': 14,
    'describe_groups': 15,
    'list_groups': 16,
    'sasl_handshake': 17,
    'api_versions': 18,
    'create_topics': 19,
    'delete_topics': 20,
    'delete_records': 21,
    'init_producer_id': 22,
    'offset_for_leader_epoch': 23,
    'add_partitions_to_txn': 24,
    'add_offsets_to_txn': 25,
    'end_txn': 26,
    'write_txn_markers': 27,
    'txn_offset_commit': 28,
    'describe_acls': 29,
    'create_acls': 30,
    'delete_acls': 31,
    'describe_configs': 32,
    'alter_configs': 33,
    'alter_replica_log_dirs': 34,
    'describe_log_dirs': 35,
    'sasl_authenticate': 36,
    'create_partitions': 37,
    'create_delegation_token': 38,
    'renew_delegation_token': 39,
    'expire_delegation_token': 40,
    'describe_delegation_token': 41,
    'delete_groups': 42,
    'elect_leaders': 43,
    'incremental_alter_configs': 44,
    'alter_partition_reassignments': 45,
    'list_partition_reassignments': 46,
    'offset_delete': 47,
    'describe_client_quotas': 48,
    'alter_client_quotas': 49,
    'describe_user_scram_credentials': 50,
    'alter_user_scram_credentials': 51,
    'alter_partition': 52,
    'update_features': 53,
    'envelope': 54,
    'fetch_snapshot': 55,
    'describe_cluster': 60,
    'describe_producers': 61,
    'broker_registration': 62,
    'broker_heartbeat': 63,
    'unregister_broker': 64,
    'describe_transactions': 65,
    'list_transactions': 66,
    'allocate_producer_ids': 67,
    'consumer_group_heartbeat': 68,
    'consumer_group_describe': 69,
    'controller_registration': 70,
    'get_telemetry_subscriptions': 71,
    'push_telemetry': 72,
    'assign_replicas_to_dirs': 73,
    'list_client_metrics_resources': 74,
    'describe_topic_partitions': 75,
}

def get_api_key_int(api_name):
    """Convert API name to integer, return name if not found"""
    return KAFKA_API_KEYS.get(api_name.lower(), api_name)

def get_api_name(api_int):
    """Convert API integer to name"""
    for name, num in KAFKA_API_KEYS.items():
        if num == api_int:
            return name
    return str(api_int)
