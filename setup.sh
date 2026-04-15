#!/bin/bash

# ============================================================================
# Simple Stream Alert - Setup Script
# This script sets up the simplified streaming application
# ============================================================================

set -e  # Exit on error

echo "Setting up Simple Stream Alert..."
echo "===================================="
echo ""

# Allow user to specify container runtime via environment variable or argument
if [ -n "$1" ]; then
    CONTAINER_CMD="$1"
    echo "Using container runtime from argument: ${CONTAINER_CMD}"
elif [ -n "$CONTAINER_CMD" ]; then
    echo "Using container runtime from environment: ${CONTAINER_CMD}"
else
    # Auto-detect
    if command -v podman &> /dev/null; then
        CONTAINER_CMD="podman"
        echo "Auto-detected: Podman"
    elif command -v docker &> /dev/null; then
        CONTAINER_CMD="docker"
        echo "Auto-detected: Docker"
    else
        echo "Neither Podman nor Docker is installed."
        exit 1
    fi
fi

# For Podman, use dedicated startup script to avoid podman-compose issues
if [ "$CONTAINER_CMD" = "podman" ]; then
    echo "Note: Using dedicated Podman startup script (bypasses podman-compose issues)"
    echo ""
fi

# Set compose command
if [ "$CONTAINER_CMD" = "podman" ]; then
    COMPOSE_CMD="podman-compose"
    if ! command -v podman-compose &> /dev/null; then
        echo "podman-compose is not installed."
        echo "Install: pip install podman-compose"
        exit 1
    fi
elif [ "$CONTAINER_CMD" = "docker" ]; then
    COMPOSE_CMD="docker-compose"
    if ! command -v docker-compose &> /dev/null; then
        echo "docker-compose is not installed."
        exit 1
    fi
else
    echo "Invalid container runtime: ${CONTAINER_CMD}"
    exit 1
fi

echo "${CONTAINER_CMD} is installed"
echo "${COMPOSE_CMD} is installed"

# Check Python
if ! command -v python3 &> /dev/null; then
    echo "Python 3 is not installed."
    exit 1
fi

echo "Python is installed"
echo ""

# Step 1: Setup Flink connector (BEFORE starting containers)
echo "🔌 Step 1: Setting up Flink connector..."
mkdir -p flink-connectors
if [ ! -f "flink-connectors/flink-sql-connector-kafka-3.0.1-1.18.jar" ]; then
    echo "Downloading Flink Kafka connector..."
    curl -s -L -o flink-connectors/flink-sql-connector-kafka-3.0.1-1.18.jar \
        https://repo.maven.apache.org/maven2/org/apache/flink/flink-sql-connector-kafka/3.0.1-1.18/flink-sql-connector-kafka-3.0.1-1.18.jar
    echo "Flink connector downloaded"
else
    echo "Flink connector already exists"
fi
echo ""

# Step 2: Start containers
echo "Step 2: Starting Kafka and Flink with ${CONTAINER_CMD}..."

if [ "$CONTAINER_CMD" = "podman" ]; then
    # Use dedicated Podman script
    ./start-podman.sh
    
    # Additional wait to ensure services are fully ready
    echo "Waiting for services to be fully ready (10 seconds)..."
    sleep 10
    
    # Verify services are running
    echo "Verifying Podman containers..."
    if podman ps | grep -q kafka; then
        echo "Kafka is running"
    else
        echo "Kafka failed to start. Check logs: podman logs kafka"
        exit 1
    fi
    
    if podman ps | grep -q flink-jobmanager; then
        echo "Flink JobManager is running"
    else
        echo "Flink JobManager failed to start. Check logs: podman logs flink-jobmanager"
        exit 1
    fi
    
    if podman ps | grep -q flink-taskmanager; then
        echo "Flink TaskManager is running"
    else
        echo "Flink TaskManager failed to start. Check logs: podman logs flink-taskmanager"
        exit 1
    fi
    
    # Copy connector JARs to /opt/flink/lib/ in all Flink containers
    echo ""
    echo "Copying Flink connector JARs to containers..."
    
    echo "Copying to JobManager..."
    if podman exec flink-jobmanager cp /opt/flink/connectors/flink-sql-connector-kafka-3.0.1-1.18.jar /opt/flink/lib/ 2>/dev/null; then
        echo "JobManager: Connector copied"
    else
        echo "JobManager: Failed to copy connector"
        exit 1
    fi
    
    echo "Copying to TaskManager..."
    if podman exec flink-taskmanager cp /opt/flink/connectors/flink-sql-connector-kafka-3.0.1-1.18.jar /opt/flink/lib/ 2>/dev/null; then
        echo "TaskManager: Connector copied"
    else
        echo "TaskManager: Failed to copy connector"
        exit 1
    fi
    
    echo "Copying to SQL Client..."
    if podman exec flink-sql-client cp /opt/flink/connectors/flink-sql-connector-kafka-3.0.1-1.18.jar /opt/flink/lib/ 2>/dev/null; then
        echo "SQL Client: Connector copied"
    else
        echo "SQL Client: Failed to copy connector"
        exit 1
    fi
    
    # Verify the JARs are in place
    echo ""
    echo "Verifying connector installation..."
    
    if podman exec flink-jobmanager sh -c 'ls /opt/flink/lib/flink-sql-connector-kafka*.jar' &>/dev/null; then
        echo "JobManager: Connector verified in /opt/flink/lib/"
    else
        echo "JobManager: Connector not found in /opt/flink/lib/"
        exit 1
    fi
    
    if podman exec flink-taskmanager sh -c 'ls /opt/flink/lib/flink-sql-connector-kafka*.jar' &>/dev/null; then
        echo "TaskManager: Connector verified in /opt/flink/lib/"
    else
        echo "TaskManager: Connector not found in /opt/flink/lib/"
        exit 1
    fi
    
    if podman exec flink-sql-client sh -c 'ls /opt/flink/lib/flink-sql-connector-kafka*.jar' &>/dev/null; then
        echo "SQL Client: Connector verified in /opt/flink/lib/"
    else
        echo "SQL Client: Connector not found in /opt/flink/lib/"
        exit 1
    fi
    
    echo "All Flink connectors successfully installed!"
else
    # Use docker-compose for Docker
    echo "Cleaning up existing containers..."
    "${COMPOSE_CMD}" down 2>/dev/null || true
    sleep 2
    
    echo "Starting all services..."
    "${COMPOSE_CMD}" up -d
    
    echo "Waiting for services to start (30 seconds)..."
    sleep 30
    
    # Verify services
    if "${CONTAINER_CMD}" ps | grep -q kafka; then
        echo "Kafka is running"
    else
        echo "Kafka failed to start. Check logs: ${CONTAINER_CMD} logs kafka"
        exit 1
    fi
    
    if "${CONTAINER_CMD}" ps | grep -q flink-jobmanager; then
        echo "Flink is running"
    else
        echo "Flink failed to start. Check logs: ${CONTAINER_CMD} logs flink-jobmanager"
        exit 1
    fi
fi

echo ""

# Step 3: Install Python dependencies
echo "Step 3: Installing Python dependencies..."
if [ -d "venv" ]; then
    echo "Virtual environment already exists"
else
    echo "Creating virtual environment..."
    python3 -m venv venv
fi

echo "Activating virtual environment..."
source venv/bin/activate

echo "Installing packages..."
pip install -q --upgrade pip
pip install -q -r requirements.txt

echo "Python dependencies installed"
echo ""

# Step 4: Create Kafka topics
echo "Step 4: Creating Kafka topics..."
echo "Waiting a bit more for Kafka to be fully ready..."
sleep 10

"${CONTAINER_CMD}" exec kafka kafka-topics --create \
    --bootstrap-server localhost:9092 \
    --topic payment-events \
    --partitions 1 \
    --replication-factor 1 \
    --if-not-exists 2>/dev/null || true

"${CONTAINER_CMD}" exec kafka kafka-topics --create \
    --bootstrap-server localhost:9092 \
    --topic payment-alerts \
    --partitions 1 \
    --replication-factor 1 \
    --if-not-exists 2>/dev/null || true

echo "Kafka topics created"
echo ""

# Final instructions
echo "===================================="
echo "Setup Complete!"
echo "===================================="
echo ""
echo "Next Steps:"
echo ""
echo "1. Set up Flink SQL (RECOMMENDED):"
echo "./run_flink_sql.sh"
echo ""
echo "2. Start the Producer (Terminal 1):"
echo "source venv/bin/activate"
echo "python simple_producer.py"
echo ""
echo "3. Start the Dashboard (Terminal 2):"
echo "source venv/bin/activate"
echo "streamlit run dashboard.py"
echo "Open: http://localhost:8501"
echo ""
echo "4. (Optional) View alerts in terminal:"
echo "source venv/bin/activate"
echo "python simple_consumer.py"
echo ""
echo "5. Monitor Flink Web UI:"
echo "http://localhost:8081"
echo ""
echo "For detailed instructions, see README.md"
echo ""
echo "To stop all services:"
echo "\"${COMPOSE_CMD}\" down"
echo ""
echo "Note: Using ${CONTAINER_CMD} for container management"
echo ""


