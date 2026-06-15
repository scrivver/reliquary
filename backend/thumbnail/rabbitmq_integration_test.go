package thumbnail

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
)

type integrationProcessor struct {
	err       error
	processed chan Job
}

func (p *integrationProcessor) Process(_ context.Context, job Job) error {
	p.processed <- job
	return p.err
}

func TestRabbitMQThumbnailPublishAndConsume(t *testing.T) {
	amqpURL := os.Getenv("RABBITMQ_INTEGRATION_URL")
	if amqpURL == "" {
		t.Skip("RABBITMQ_INTEGRATION_URL is not set")
	}

	queue, deadQueue, cleanup := declareIntegrationQueues(t, amqpURL)
	defer cleanup()

	processor := &integrationProcessor{processed: make(chan Job, 1)}
	consumer, err := NewConsumer(amqpURL, queue, deadQueue, 1, 1, 2, processor)
	if err != nil {
		t.Fatal(err)
	}
	defer consumer.Close()

	ctx, cancel := context.WithCancel(context.Background())
	runDone := make(chan error, 1)
	go func() { runDone <- consumer.Run(ctx) }()

	publisher, err := NewRabbitMQPublisher(amqpURL, queue)
	if err != nil {
		t.Fatal(err)
	}
	defer publisher.Close()

	job := Job{
		Version:     JobVersion,
		FileKey:     "files/integration/image.png",
		ContentType: "image/png",
		Checksum:    "abc123",
	}
	if err := publisher.Publish(context.Background(), job); err != nil {
		t.Fatal(err)
	}

	select {
	case got := <-processor.processed:
		if got != job {
			t.Fatalf("got %+v, want %+v", got, job)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("thumbnail job was not consumed")
	}

	cancel()
	select {
	case err := <-runDone:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("consumer did not stop")
	}
}

func TestRabbitMQThumbnailFailureDeadLetters(t *testing.T) {
	amqpURL := os.Getenv("RABBITMQ_INTEGRATION_URL")
	if amqpURL == "" {
		t.Skip("RABBITMQ_INTEGRATION_URL is not set")
	}

	queue, deadQueue, cleanup := declareIntegrationQueues(t, amqpURL)
	defer cleanup()

	processor := &integrationProcessor{
		err:       errors.New("render failed"),
		processed: make(chan Job, 1),
	}
	consumer, err := NewConsumer(amqpURL, queue, deadQueue, 1, 1, 1, processor)
	if err != nil {
		t.Fatal(err)
	}
	defer consumer.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go consumer.Run(ctx)

	publisher, err := NewRabbitMQPublisher(amqpURL, queue)
	if err != nil {
		t.Fatal(err)
	}
	defer publisher.Close()

	job := Job{
		Version:     JobVersion,
		FileKey:     "files/integration/broken.png",
		ContentType: "image/png",
		Checksum:    "broken",
	}
	if err := publisher.Publish(context.Background(), job); err != nil {
		t.Fatal(err)
	}
	select {
	case <-processor.processed:
	case <-time.After(5 * time.Second):
		t.Fatal("thumbnail job was not processed")
	}

	conn, err := amqp.Dial(amqpURL)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	ch, err := conn.Channel()
	if err != nil {
		t.Fatal(err)
	}
	defer ch.Close()

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		message, ok, err := ch.Get(deadQueue, true)
		if err != nil {
			t.Fatal(err)
		}
		if ok {
			var got Job
			if err := json.Unmarshal(message.Body, &got); err != nil {
				t.Fatal(err)
			}
			if got != job {
				t.Fatalf("got %+v, want %+v", got, job)
			}
			if message.Headers[attemptHeader] != int32(1) {
				t.Fatalf("unexpected headers: %+v", message.Headers)
			}
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("dead-letter message was not published")
}

func declareIntegrationQueues(
	t *testing.T,
	amqpURL string,
) (string, string, func()) {
	t.Helper()
	conn, err := amqp.Dial(amqpURL)
	if err != nil {
		t.Fatal(err)
	}
	ch, err := conn.Channel()
	if err != nil {
		conn.Close()
		t.Fatal(err)
	}

	suffix := fmt.Sprintf("%d", time.Now().UnixNano())
	queue := "reliquary.thumbnail.test." + suffix
	deadQueue := queue + ".dead"
	for _, name := range []string{queue, deadQueue} {
		if _, err := ch.QueueDeclare(name, true, false, false, false, nil); err != nil {
			t.Fatal(err)
		}
		if err := ch.QueueBind(name, name, exchange, false, nil); err != nil {
			t.Fatal(err)
		}
	}

	return queue, deadQueue, func() {
		ch.QueueDelete(queue, false, false, false)
		ch.QueueDelete(deadQueue, false, false, false)
		ch.Close()
		conn.Close()
	}
}
