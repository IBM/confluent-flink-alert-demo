import json
import time
import random
from datetime import datetime
from confluent_kafka import Producer

# Kafka configuration
KAFKA_BROKER = 'localhost:9092'
TOPIC_NAME = 'payment-events'

# Simple event generator
def generate_payment_event():
    """
    Generate a payment transaction event with realistic data
    Flink SQL will analyze these events to detect:
    - Failed payments (status = 'failed')
    - High latency (latency_ms > 1500)
    - Failure spikes (multiple failures in time window)
    """

    rand = random.random()
    
    if rand < 0.70:
        # Successful payment
        status = 'success'
        latency_ms = random.randint(100, 800)
        error_code = None
    elif rand < 0.90:
        # Failed payment
        status = 'failed'
        latency_ms = random.randint(200, 1200)
        error_code = random.choice(['INSUFFICIENT_FUNDS', 'CARD_DECLINED', 'TIMEOUT', 'FRAUD_DETECTED'])
    else:
        # High latency payment (may succeed or fail)
        status = random.choice(['success', 'failed'])
        latency_ms = random.randint(1500, 3000)  # High latency
        error_code = random.choice(['TIMEOUT', None]) if status == 'failed' else None
    
    event = {
        'event_id': f'evt-{random.randint(10000, 99999)}',
        'event_type': 'payment_transaction',  # Single event type
        'status': status,  # Flink will classify based on this
        'service': random.choice(['payment-service', 'checkout-service', 'billing-service']),
        'amount': round(random.uniform(10.0, 1000.0), 2),
        'customer_id': f'cust-{random.randint(1000, 9999)}',
        'latency_ms': latency_ms,  # Flink will detect high latency
        'error_code': error_code,  # Present only for failures
        'timestamp': datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
    }
    
    return event

def delivery_callback(err, msg):
    if err:
        print(f'Message delivery failed: {err}')

def main():
    print("Starting Payment Transaction Producer")
    print(f"Connecting to Kafka broker: {KAFKA_BROKER}")
    print(f"Publishing to topic: {TOPIC_NAME}")
    print("\nProducer sends ALL payment transactions")
    print("   Flink SQL will classify and detect failures/alerts")
    print("-" * 60)
    
    # Create Kafka producer
    producer = Producer({
        'bootstrap.servers': KAFKA_BROKER,
        'client.id': 'simple-producer'
    })
    
    try:
        event_count = 0
        success_count = 0
        failed_count = 0
        
        while True:
            # Generate event
            event = generate_payment_event()
            event_count += 1
            
            # Track stats
            if event['status'] == 'success':
                success_count += 1
            else:
                failed_count += 1
            
            # Convert to JSON
            event_json = json.dumps(event)
            
            # Send to Kafka
            producer.produce(
                topic=TOPIC_NAME,
                value=event_json.encode('utf-8'),
                key=event['event_id'].encode('utf-8'),
                callback=delivery_callback
            )
            
            # Trigger delivery reports
            producer.poll(0)
            
            
            print(f"\nEvent #{event_count}")
            print(f"Status: {event['status']}")
            print(f"Latency: {event['latency_ms']}ms")
            print(f"Amount: ${event['amount']}")
            print(f"Service: {event['service']}")
            if event['error_code']:
                print(f"Error: {event['error_code']}")
            
            # Show stats every 10 events
            if event_count % 10 == 0:
                failure_rate = (failed_count / event_count) * 100
                print(f"\nStats: {success_count} success, {failed_count} failed ({failure_rate:.1f}% failure rate)")
            
            # Wait before sending next event
            time.sleep(1)
            
    except KeyboardInterrupt:
        print("\n\n⏹Stopping producer...")
    finally:
        # Wait for all messages to be delivered
        producer.flush()
        print(f"\nTotal events sent: {event_count}")
        print(f"   Success: {success_count}")
        print(f"   Failed: {failed_count}")
        print("Producer stopped")


if __name__ == '__main__':
    main()

