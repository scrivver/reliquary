package thumbnail

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"

	amqp "github.com/rabbitmq/amqp091-go"
)

const exchange = "amq.direct"

type RabbitMQPublisher struct {
	conn    *amqp.Connection
	ch      *amqp.Channel
	queue   string
	returns <-chan amqp.Return
	mu      sync.Mutex
}

func NewRabbitMQPublisher(amqpURL, queue string) (*RabbitMQPublisher, error) {
	conn, ch, returns, err := openPublishingChannel(amqpURL, queue)
	if err != nil {
		return nil, err
	}
	return &RabbitMQPublisher{
		conn:    conn,
		ch:      ch,
		queue:   queue,
		returns: returns,
	}, nil
}

func (p *RabbitMQPublisher) Publish(ctx context.Context, job Job) error {
	if err := job.Validate(); err != nil {
		return err
	}
	body, err := json.Marshal(job)
	if err != nil {
		return fmt.Errorf("marshal thumbnail job: %w", err)
	}

	p.mu.Lock()
	defer p.mu.Unlock()
	return publishConfirmed(ctx, p.ch, p.returns, p.queue, body, nil)
}

func (p *RabbitMQPublisher) Close() error {
	if err := p.ch.Close(); err != nil {
		p.conn.Close()
		return err
	}
	return p.conn.Close()
}

func openPublishingChannel(
	amqpURL string,
	requiredQueues ...string,
) (*amqp.Connection, *amqp.Channel, <-chan amqp.Return, error) {
	conn, err := amqp.Dial(amqpURL)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("connect to RabbitMQ: %w", err)
	}
	ch, err := conn.Channel()
	if err != nil {
		conn.Close()
		return nil, nil, nil, fmt.Errorf("open RabbitMQ channel: %w", err)
	}
	if err := ch.Confirm(false); err != nil {
		ch.Close()
		conn.Close()
		return nil, nil, nil, fmt.Errorf("enable publisher confirms: %w", err)
	}
	for _, queue := range requiredQueues {
		if _, err := ch.QueueDeclarePassive(queue, true, false, false, false, nil); err != nil {
			ch.Close()
			conn.Close()
			return nil, nil, nil, fmt.Errorf("required queue %q is unavailable: %w", queue, err)
		}
	}
	returns := ch.NotifyReturn(make(chan amqp.Return, 1))
	return conn, ch, returns, nil
}

func publishConfirmed(
	ctx context.Context,
	ch *amqp.Channel,
	returns <-chan amqp.Return,
	routingKey string,
	body []byte,
	headers amqp.Table,
) error {
	select {
	case returned := <-returns:
		return fmt.Errorf("stale unroutable message: %s", returned.ReplyText)
	default:
	}

	confirmation, err := ch.PublishWithDeferredConfirmWithContext(
		ctx,
		exchange,
		routingKey,
		true,
		false,
		amqp.Publishing{
			Headers:      headers,
			ContentType:  "application/json",
			DeliveryMode: amqp.Persistent,
			Body:         body,
		},
	)
	if err != nil {
		return fmt.Errorf("publish to %q: %w", routingKey, err)
	}
	acknowledged, err := confirmation.WaitContext(ctx)
	if err != nil {
		return fmt.Errorf("wait for publish confirmation: %w", err)
	}
	select {
	case returned := <-returns:
		return fmt.Errorf(
			"message was unroutable: code=%d text=%q routing_key=%q",
			returned.ReplyCode,
			returned.ReplyText,
			returned.RoutingKey,
		)
	default:
	}
	if !acknowledged {
		return fmt.Errorf("RabbitMQ negatively acknowledged message")
	}
	return nil
}
