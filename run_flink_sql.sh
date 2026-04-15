#!/bin/bash

# ============================================================================
# Flink SQL Execution Script
# This script submits Flink SQL queries as continuous streaming jobs
# ============================================================================

set -e

echo "Deploying Flink SQL Jobs..."
echo "=================================="
echo ""

# Detect container runtime
if command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
elif command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
else
    echo "Neither Podman nor Docker is installed."
    exit 1
fi

echo "Using container runtime: ${CONTAINER_CMD}"
echo ""

# Check if Flink JobManager is running
if ! "${CONTAINER_CMD}" ps | grep -q flink-jobmanager; then
    echo "Flink JobManager is not running."
    if [ "$CONTAINER_CMD" = "podman" ]; then
        echo "   Start it with: ./start-podman.sh"
    else
        echo "   Start it with: docker-compose up -d"
    fi
    exit 1
fi

echo "Flink cluster is running"
echo ""

echo "Step 1: Waiting for Flink JobManager to be ready..."
API_READY=false
for i in {1..30}; do
    if "${CONTAINER_CMD}" exec flink-jobmanager curl -s http://localhost:8081/overview &>/dev/null; then
        echo "JobManager REST API is ready"
        API_READY=true
        break
    fi
    echo "   Waiting for JobManager API... ($i/30)"
    sleep 2
done

if [ "$API_READY" = false ]; then
    echo "Flink JobManager REST API failed to become ready"
    echo "   Check logs with: ${CONTAINER_CMD} logs flink-jobmanager"
    exit 1
fi

# Verify Kafka connector is available
echo ""
echo "Step 2: Verifying Flink Kafka connector..."
if "${CONTAINER_CMD}" exec flink-jobmanager sh -c 'ls /opt/flink/lib/flink-sql-connector-kafka*.jar' >/dev/null 2>&1; then
    echo "Kafka connector is available in /opt/flink/lib/"
else
    echo "Kafka connector not found in /opt/flink/lib/"
    echo "   The connector should have been copied during setup"
    echo "   Please run ./setup.sh to properly install the connector"
    exit 1
fi
echo ""

# Create separate SQL files for tables and each job
echo "Step 3: Preparing SQL deployment..."

# Create tables SQL
cat > /tmp/flink_tables.sql << 'EOF'
-- Drop existing tables
DROP TABLE IF EXISTS payment_events;
DROP TABLE IF EXISTS payment_alerts;

-- Create source table
CREATE TABLE payment_events (
    event_id STRING,
    event_type STRING,
    status STRING,
    service STRING,
    amount DOUBLE,
    customer_id STRING,
    error_code STRING,
    latency_ms INT,
    `timestamp` STRING,
    event_time AS TO_TIMESTAMP(`timestamp`),
    WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'payment-events',
    'properties.bootstrap.servers' = 'kafka:29092',
    'properties.group.id' = 'flink-consumer-group',
    'scan.startup.mode' = 'latest-offset',
    'format' = 'json',
    'json.fail-on-missing-field' = 'false',
    'json.ignore-parse-errors' = 'true'
);

-- Create sink table
CREATE TABLE payment_alerts (
    alert_id STRING,
    alert_type STRING,
    severity STRING,
    message STRING,
    event_count BIGINT,
    window_start TIMESTAMP(3),
    window_end TIMESTAMP(3),
    service STRING,
    alert_time TIMESTAMP(3)
) WITH (
    'connector' = 'kafka',
    'topic' = 'payment-alerts',
    'properties.bootstrap.servers' = 'kafka:29092',
    'format' = 'json'
);
EOF

# Job 1: Payment Failure Spike Detection
cat > /tmp/flink_job1.sql << 'EOF'
INSERT INTO payment_alerts
SELECT
    CONCAT('alert-failure-', CAST(UNIX_TIMESTAMP(CURRENT_TIMESTAMP) AS STRING)) AS alert_id,
    'PAYMENT_FAILURE_SPIKE' AS alert_type,
    'CRITICAL' AS severity,
    CONCAT(
        CAST(COUNT(*) AS STRING),
        ' payment failures detected in 2 minutes for service: ',
        service
    ) AS message,
    COUNT(*) AS event_count,
    TUMBLE_START(event_time, INTERVAL '2' MINUTE) AS window_start,
    TUMBLE_END(event_time, INTERVAL '2' MINUTE) AS window_end,
    service,
    CURRENT_TIMESTAMP AS alert_time
FROM payment_events
WHERE status = 'failed'
GROUP BY
    TUMBLE(event_time, INTERVAL '2' MINUTE),
    service
HAVING COUNT(*) >= 5;
EOF

# Job 2: High Latency Detection
cat > /tmp/flink_job2.sql << 'EOF'
INSERT INTO payment_alerts
SELECT
    CONCAT('alert-latency-', event_id) AS alert_id,
    'HIGH_LATENCY' AS alert_type,
    'WARNING' AS severity,
    CONCAT(
        'High latency detected: ',
        CAST(latency_ms AS STRING),
        'ms for transaction ',
        event_id
    ) AS message,
    1 AS event_count,
    event_time AS window_start,
    event_time AS window_end,
    service,
    CURRENT_TIMESTAMP AS alert_time
FROM payment_events
WHERE latency_ms > 1500;
EOF

# Job 3: High Failure Rate Detection
cat > /tmp/flink_job3.sql << 'EOF'
INSERT INTO payment_alerts
SELECT
    CONCAT('alert-rate-', CAST(UNIX_TIMESTAMP(CURRENT_TIMESTAMP) AS STRING)) AS alert_id,
    'HIGH_FAILURE_RATE' AS alert_type,
    'CRITICAL' AS severity,
    CONCAT(
        'High failure rate: ',
        CAST(ROUND(
            SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) * 100.0 / COUNT(*),
            2
        ) AS STRING),
        '% (',
        CAST(SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS STRING),
        ' failures / ',
        CAST(COUNT(*) AS STRING),
        ' total)'
    ) AS message,
    COUNT(*) AS event_count,
    TUMBLE_START(event_time, INTERVAL '5' MINUTE) AS window_start,
    TUMBLE_END(event_time, INTERVAL '5' MINUTE) AS window_end,
    service,
    CURRENT_TIMESTAMP AS alert_time
FROM payment_events
GROUP BY
    TUMBLE(event_time, INTERVAL '5' MINUTE),
    service
HAVING
    SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) * 100.0 / COUNT(*) > 30
    AND COUNT(*) >= 10;
EOF

echo "SQL files prepared"
echo ""

# Copy SQL files to container
echo "Step 4: Copying SQL files to Flink container..."
"${CONTAINER_CMD}" cp /tmp/flink_tables.sql flink-jobmanager:/tmp/
"${CONTAINER_CMD}" cp /tmp/flink_job1.sql flink-jobmanager:/tmp/
"${CONTAINER_CMD}" cp /tmp/flink_job2.sql flink-jobmanager:/tmp/
"${CONTAINER_CMD}" cp /tmp/flink_job3.sql flink-jobmanager:/tmp/
echo "SQL files copied"
echo ""

# Submit the SQL files as streaming jobs using STATEMENT SET
echo "Step 5: Submitting Flink SQL jobs..."
echo ""

# Create a combined statement set file
cat > /tmp/flink_statement_set.sql << 'EOF'
-- First create the tables
DROP TABLE IF EXISTS payment_events;
DROP TABLE IF EXISTS payment_alerts;

CREATE TABLE payment_events (
    event_id STRING,
    event_type STRING,
    status STRING,
    service STRING,
    amount DOUBLE,
    customer_id STRING,
    error_code STRING,
    latency_ms INT,
    `timestamp` STRING,
    event_time AS TO_TIMESTAMP(`timestamp`),
    WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'payment-events',
    'properties.bootstrap.servers' = 'kafka:29092',
    'properties.group.id' = 'flink-consumer-group',
    'scan.startup.mode' = 'latest-offset',
    'format' = 'json',
    'json.fail-on-missing-field' = 'false',
    'json.ignore-parse-errors' = 'true'
);

CREATE TABLE payment_alerts (
    alert_id STRING,
    alert_type STRING,
    severity STRING,
    message STRING,
    event_count BIGINT,
    window_start TIMESTAMP(3),
    window_end TIMESTAMP(3),
    service STRING,
    alert_time TIMESTAMP(3)
) WITH (
    'connector' = 'kafka',
    'topic' = 'payment-alerts',
    'properties.bootstrap.servers' = 'kafka:29092',
    'format' = 'json'
);

-- Submit all jobs as a statement set
EXECUTE STATEMENT SET
BEGIN

-- Job 1: Payment Failure Spike Detection
INSERT INTO payment_alerts
SELECT
    CONCAT('alert-failure-', CAST(UNIX_TIMESTAMP() AS STRING), '-', service) AS alert_id,
    'PAYMENT_FAILURE_SPIKE' AS alert_type,
    'CRITICAL' AS severity,
    CONCAT(
        CAST(COUNT(*) AS STRING),
        ' payment failures detected in 2 minutes for service: ',
        service
    ) AS message,
    COUNT(*) AS event_count,
    TUMBLE_START(event_time, INTERVAL '2' MINUTE) AS window_start,
    TUMBLE_END(event_time, INTERVAL '2' MINUTE) AS window_end,
    service,
    CURRENT_TIMESTAMP AS alert_time
FROM payment_events
WHERE status = 'failed'
GROUP BY
    TUMBLE(event_time, INTERVAL '2' MINUTE),
    service
HAVING COUNT(*) >= 5;

-- Job 2: High Latency Detection
INSERT INTO payment_alerts
SELECT
    CONCAT('alert-latency-', event_id) AS alert_id,
    'HIGH_LATENCY' AS alert_type,
    'WARNING' AS severity,
    CONCAT(
        'High latency detected: ',
        CAST(latency_ms AS STRING),
        'ms for transaction ',
        event_id
    ) AS message,
    1 AS event_count,
    event_time AS window_start,
    event_time AS window_end,
    service,
    CURRENT_TIMESTAMP AS alert_time
FROM payment_events
WHERE latency_ms > 1500;

-- Job 3: High Failure Rate Detection
INSERT INTO payment_alerts
SELECT
    CONCAT('alert-rate-', CAST(UNIX_TIMESTAMP() AS STRING), '-', service) AS alert_id,
    'HIGH_FAILURE_RATE' AS alert_type,
    'CRITICAL' AS severity,
    CONCAT(
        'High failure rate: ',
        CAST(ROUND(
            SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) * 100.0 / COUNT(*),
            2
        ) AS STRING),
        '% (',
        CAST(SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS STRING),
        ' failures / ',
        CAST(COUNT(*) AS STRING),
        ' total)'
    ) AS message,
    COUNT(*) AS event_count,
    TUMBLE_START(event_time, INTERVAL '5' MINUTE) AS window_start,
    TUMBLE_END(event_time, INTERVAL '5' MINUTE) AS window_end,
    service,
    CURRENT_TIMESTAMP AS alert_time
FROM payment_events
GROUP BY
    TUMBLE(event_time, INTERVAL '5' MINUTE),
    service
HAVING
    SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) * 100.0 / COUNT(*) > 30
    AND COUNT(*) >= 10;

END;
EOF

# Copy the statement set file
"${CONTAINER_CMD}" cp /tmp/flink_statement_set.sql flink-jobmanager:/tmp/

# Submit using nohup to run in background
echo "   Submitting all jobs as a statement set..."
"${CONTAINER_CMD}" exec -d flink-jobmanager sh -c "nohup /opt/flink/bin/sql-client.sh -f /tmp/flink_statement_set.sql > /tmp/flink_job.log 2>&1 &"

# Wait for jobs to start
echo "   Waiting for jobs to initialize (10 seconds)..."
sleep 10

echo ""
echo "=================================="
echo "Flink SQL Jobs Submitted!"
echo "=================================="
echo ""
echo "Verification:"
echo ""
echo "1. Check Flink Web UI:"
echo "   http://localhost:8081"
echo "   You should see 3 running jobs"
echo ""
echo "2. View job details:"
echo "   - Payment Failure Spike Detection"
echo "   - High Latency Detection"
echo "   - High Failure Rate Detection"
echo ""
echo "3. Start producer to generate events:"
echo "   python simple_producer.py"
echo ""
echo "4. Monitor alerts:"
echo "   python simple_consumer.py  (choose option 2)"
echo "   OR"
echo "   streamlit run dashboard.py"
echo ""
echo "Note: Jobs are now running continuously!"
echo "   They will process events in real-time and generate alerts"
echo ""


