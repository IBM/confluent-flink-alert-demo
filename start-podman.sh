#!/bin/bash

# ============================================================================
# Podman-specific startup script
# Bypasses podman-compose dependency issues by using plain podman commands
# ============================================================================

set -e

echo "Starting services with Podman..."
echo "===================================="
echo ""

# Create network if it doesn't exist
echo "Creating network..."
podman network create stream-network 2>/dev/null || echo "   Network already exists"
echo ""

# Create volumes if they don't exist
echo "Creating volumes..."
podman volume create kafka-data 2>/dev/null || echo "   kafka-data already exists"
podman volume create flink-checkpoints 2>/dev/null || echo "   flink-checkpoints already exists"
podman volume create flink-savepoints 2>/dev/null || echo "   flink-savepoints already exists"
echo ""

# Stop and remove existing containers
echo "🧹 Cleaning up existing containers..."
podman rm -f kafka control-center flink-jobmanager flink-taskmanager flink-sql-client 2>/dev/null || true
echo ""

# Start Kafka
echo "Starting Kafka..."
podman run -d \
  --name kafka \
  --hostname kafka \
  --network stream-network \
  -p 9092:9092 \
  -v kafka-data:/tmp/kraft-combined-logs:Z \
  -e KAFKA_NODE_ID=1 \
  -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP='CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT,PLAINTEXT_HOST:PLAINTEXT' \
  -e KAFKA_ADVERTISED_LISTENERS='PLAINTEXT://kafka:29092,PLAINTEXT_HOST://localhost:9092' \
  -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 \
  -e KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS=0 \
  -e KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1 \
  -e KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1 \
  -e KAFKA_PROCESS_ROLES='broker,controller' \
  -e KAFKA_CONTROLLER_QUORUM_VOTERS='1@kafka:29093' \
  -e KAFKA_LISTENERS='PLAINTEXT://kafka:29092,CONTROLLER://kafka:29093,PLAINTEXT_HOST://0.0.0.0:9092' \
  -e KAFKA_INTER_BROKER_LISTENER_NAME='PLAINTEXT' \
  -e KAFKA_CONTROLLER_LISTENER_NAMES='CONTROLLER' \
  -e KAFKA_LOG_DIRS='/tmp/kraft-combined-logs' \
  -e KAFKA_AUTO_CREATE_TOPICS_ENABLE='true' \
  -e CLUSTER_ID='MkU3OEVBNTcwNTJENDM2Qk' \
  confluentinc/cp-kafka:7.8.7

echo "   Waiting for Kafka to start (30 seconds)..."
sleep 30
echo "Kafka started"
echo ""

# Start Confluent Control Center
echo "Starting Confluent Control Center..."
podman run -d \
  --name control-center \
  --hostname control-center \
  --network stream-network \
  -p 9021:9021 \
  -e CONTROL_CENTER_BOOTSTRAP_SERVERS='kafka:29092' \
  -e CONTROL_CENTER_REPLICATION_FACTOR=1 \
  -e CONTROL_CENTER_INTERNAL_TOPICS_PARTITIONS=1 \
  -e CONTROL_CENTER_MONITORING_INTERCEPTOR_TOPIC_PARTITIONS=1 \
  -e CONFLUENT_METRICS_TOPIC_REPLICATION=1 \
  -e CONTROL_CENTER_REST_LISTENERS=http://0.0.0.0:9021 \
  -e METRICS_REPORTER_BOOTSTRAP_SERVERS=localhost:9092 \
  -e PORT=9021 \
  confluentinc/cp-enterprise-control-center:7.8.7

echo "   Waiting for Control Center to start (45 seconds)..."
sleep 45
echo "Control Center started"
echo ""

# Start Flink JobManager
echo "Starting Flink JobManager..."
podman run -d \
  --name flink-jobmanager \
  --hostname flink-jobmanager \
  --network stream-network \
  -p 8081:8081 \
  -v flink-checkpoints:/tmp/flink-checkpoints:Z \
  -v flink-savepoints:/tmp/flink-savepoints:Z \
  -v ./flink-connectors:/opt/flink/connectors:Z \
  -e FLINK_PROPERTIES="jobmanager.rpc.address: flink-jobmanager
parallelism.default: 2" \
  flink:1.18-scala_2.12 \
  bash -c "cp /opt/flink/connectors/*.jar /opt/flink/lib/ 2>/dev/null || true && /docker-entrypoint.sh jobmanager"

echo "   Waiting for JobManager (10 seconds)..."
sleep 10
echo "Flink JobManager started"
echo ""

# Start Flink TaskManager
echo "Starting Flink TaskManager..."
podman run -d \
  --name flink-taskmanager \
  --hostname flink-taskmanager \
  --network stream-network \
  -v flink-checkpoints:/tmp/flink-checkpoints:Z \
  -v flink-savepoints:/tmp/flink-savepoints:Z \
  -v ./flink-connectors:/opt/flink/connectors:Z \
  -e FLINK_PROPERTIES="jobmanager.rpc.address: flink-jobmanager
taskmanager.numberOfTaskSlots: 2
parallelism.default: 2" \
  flink:1.18-scala_2.12 \
  bash -c "cp /opt/flink/connectors/*.jar /opt/flink/lib/ 2>/dev/null || true && /docker-entrypoint.sh taskmanager"

echo "   Waiting for TaskManager (5 seconds)..."
sleep 5
echo "Flink TaskManager started"
echo ""

# Start Flink SQL Client
echo "Starting Flink SQL Client..."
podman run -d \
  --name flink-sql-client \
  --hostname flink-sql-client \
  --network stream-network \
  -v ./flink-sql:/opt/flink-sql:Z \
  -v ./flink-connectors:/opt/flink/connectors:Z \
  -e FLINK_PROPERTIES="jobmanager.rpc.address: flink-jobmanager
rest.address: flink-jobmanager" \
  flink:1.18-scala_2.12 \
  /bin/sh -c "while true; do sleep 30; done"

echo "Flink SQL Client started"
echo ""

# Verify all containers are running
echo "Verifying containers..."
podman ps --format "table {{.Names}}\t{{.Status}}" | grep -E "kafka|control-center|flink"
echo ""

echo "===================================="
echo "All services started!"
echo "===================================="
echo ""
echo "Service URLs:"
echo "   Kafka: localhost:9092"
echo "   Confluent Control Center: http://localhost:9021"
echo "   Flink Web UI: http://localhost:8081"
echo ""
echo "Control Center may take 1-2 minutes to fully initialize"
echo "   Modern UI with comprehensive monitoring capabilities"
echo "   Once ready, you can monitor topics, consumers, and cluster health"
echo ""
echo "To stop all services:"
echo "   podman rm -f kafka control-center flink-jobmanager flink-taskmanager flink-sql-client"
echo ""
