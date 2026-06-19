package thumbnail

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"sync"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
)

const attemptHeader = "x-reliquary-attempt"

type Consumer struct {
	conn        *amqp.Connection
	ch          *amqp.Channel
	queue       string
	deadQueue   string
	maxAttempts int
	concurrency int
	returns     <-chan amqp.Return
	publishMu   sync.Mutex
	processor   Processor
}

func NewConsumer(
	amqpURL string,
	queue string,
	deadQueue string,
	prefetch int,
	concurrency int,
	maxAttempts int,
	processor Processor,
) (*Consumer, error) {
	if prefetch < 1 || concurrency < 1 || maxAttempts < 1 {
		return nil, fmt.Errorf("prefetch, concurrency, and max attempts must be positive")
	}
	conn, ch, returns, err := openPublishingChannel(amqpURL, queue, deadQueue)
	if err != nil {
		return nil, err
	}
	if err := ch.Qos(prefetch*concurrency, 0, false); err != nil {
		ch.Close()
		conn.Close()
		return nil, fmt.Errorf("set thumbnail prefetch: %w", err)
	}
	return &Consumer{
		conn:        conn,
		ch:          ch,
		queue:       queue,
		deadQueue:   deadQueue,
		maxAttempts: maxAttempts,
		concurrency: concurrency,
		returns:     returns,
		processor:   processor,
	}, nil
}

func (c *Consumer) Run(ctx context.Context) error {
	deliveries, err := c.ch.ConsumeWithContext(
		ctx,
		c.queue,
		"",
		false,
		false,
		false,
		false,
		nil,
	)
	if err != nil {
		return fmt.Errorf("consume thumbnail jobs: %w", err)
	}

	var workers sync.WaitGroup
	limit := make(chan struct{}, c.concurrency)
	for delivery := range deliveries {
		select {
		case limit <- struct{}{}:
		case <-ctx.Done():
			workers.Wait()
			return nil
		}

		workers.Add(1)
		go func(delivery amqp.Delivery) {
			defer workers.Done()
			defer func() { <-limit }()
			c.handle(ctx, delivery)
		}(delivery)
	}
	workers.Wait()
	return nil
}

func (c *Consumer) handle(ctx context.Context, delivery amqp.Delivery) {
	var job Job
	if err := json.Unmarshal(delivery.Body, &job); err != nil {
		slog.Error("discarding malformed thumbnail job", "error", err)
		c.deadLetter(ctx, delivery, 1, fmt.Errorf("decode job: %w", err))
		return
	}
	if err := job.Validate(); err != nil {
		slog.Error("discarding invalid thumbnail job", "error", err, "key", job.FileKey)
		c.deadLetter(ctx, delivery, 1, err)
		return
	}

	err := c.processor.Process(ctx, job)
	if err == nil || IsDiscard(err) {
		if err != nil {
			slog.Info("thumbnail job discarded", "key", job.FileKey, "reason", err)
		}
		if ackErr := delivery.Ack(false); ackErr != nil {
			slog.Error("ack thumbnail job", "key", job.FileKey, "error", ackErr)
		}
		return
	}

	attempt := deliveryAttempt(delivery) + 1
	if attempt >= c.maxAttempts {
		slog.Error(
			"thumbnail job failed; dead-lettering",
			"key",
			job.FileKey,
			"content_type",
			job.ContentType,
			"attempt",
			attempt,
			"max_attempts",
			c.maxAttempts,
			"error",
			err,
		)
		c.deadLetter(ctx, delivery, attempt, err)
		return
	}

	delay := time.Duration(1<<(attempt-1)) * time.Second
	slog.Warn(
		"thumbnail job failed; retrying",
		"key",
		job.FileKey,
		"content_type",
		job.ContentType,
		"attempt",
		attempt,
		"max_attempts",
		c.maxAttempts,
		"retry_in",
		delay,
		"error",
		err,
	)
	select {
	case <-time.After(delay):
	case <-ctx.Done():
		if nackErr := delivery.Nack(false, true); nackErr != nil {
			slog.Error("requeue thumbnail job on shutdown", "error", nackErr)
		}
		return
	}

	headers := cloneHeaders(delivery.Headers)
	headers[attemptHeader] = int32(attempt)
	if err := c.publish(delivery.Body, c.queue, headers); err != nil {
		slog.Error("republish thumbnail job", "key", job.FileKey, "error", err)
		if nackErr := delivery.Nack(false, true); nackErr != nil {
			slog.Error("requeue thumbnail job", "error", nackErr)
		}
		return
	}
	if err := delivery.Ack(false); err != nil {
		slog.Error("ack republished thumbnail job", "key", job.FileKey, "error", err)
	}
}

func (c *Consumer) deadLetter(
	_ context.Context,
	delivery amqp.Delivery,
	attempt int,
	cause error,
) {
	headers := cloneHeaders(delivery.Headers)
	headers[attemptHeader] = int32(attempt)
	headers["x-reliquary-error"] = cause.Error()
	if err := c.publish(delivery.Body, c.deadQueue, headers); err != nil {
		slog.Error("publish thumbnail dead letter", "error", err)
		if nackErr := delivery.Nack(false, true); nackErr != nil {
			slog.Error("requeue thumbnail job after dead-letter failure", "error", nackErr)
		}
		return
	}
	if err := delivery.Ack(false); err != nil {
		slog.Error("ack dead-lettered thumbnail job", "error", err)
	}
}

func (c *Consumer) publish(body []byte, queue string, headers amqp.Table) error {
	c.publishMu.Lock()
	defer c.publishMu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return publishConfirmed(ctx, c.ch, c.returns, queue, body, headers)
}

func (c *Consumer) Close() error {
	if err := c.ch.Close(); err != nil {
		c.conn.Close()
		return err
	}
	return c.conn.Close()
}

func deliveryAttempt(delivery amqp.Delivery) int {
	switch value := delivery.Headers[attemptHeader].(type) {
	case int8:
		return int(value)
	case int16:
		return int(value)
	case int32:
		return int(value)
	case int64:
		return int(value)
	case int:
		return value
	default:
		return 0
	}
}

func cloneHeaders(headers amqp.Table) amqp.Table {
	cloned := make(amqp.Table, len(headers)+2)
	for key, value := range headers {
		cloned[key] = value
	}
	return cloned
}
