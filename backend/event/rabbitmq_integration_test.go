package event

import (
	"context"
	"os"
	"testing"
	"time"
)

func TestRabbitMQEmitterPublishesConfirmedRoutableMessage(t *testing.T) {
	amqpURL := os.Getenv("RABBITMQ_INTEGRATION_URL")
	if amqpURL == "" {
		t.Skip("RABBITMQ_INTEGRATION_URL is not set")
	}

	emitter, err := NewRabbitMQEmitter(amqpURL, DefaultQueue)
	if err != nil {
		t.Fatal(err)
	}
	defer emitter.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	err = emitter.Emit(ctx, FileEvent{
		Event:       Delete,
		FilePath:    "files/integration/nonexistent-phase3-probe",
		Filename:    "nonexistent-phase3-probe",
		DeviceName:  "reliquary-integration-test",
		StorageType: StorageS3,
	})
	if err != nil {
		t.Fatal(err)
	}
}
