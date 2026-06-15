package event

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"

	amqp "github.com/rabbitmq/amqp091-go"
)

// RabbitMQEmitter publishes persistent messages and waits for broker confirms.
// Queue declaration and binding remain infrastructure responsibilities.
type RabbitMQEmitter struct {
	conn       *amqp.Connection
	ch         *amqp.Channel
	exchange   string
	routingKey string
	returns    <-chan amqp.Return
	mu         sync.Mutex
}

func NewRabbitMQEmitter(amqpURL, queue string) (*RabbitMQEmitter, error) {
	conn, err := amqp.Dial(amqpURL)
	if err != nil {
		return nil, fmt.Errorf("connect to RabbitMQ: %w", err)
	}

	ch, err := conn.Channel()
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("open RabbitMQ channel: %w", err)
	}
	if err := ch.Confirm(false); err != nil {
		ch.Close()
		conn.Close()
		return nil, fmt.Errorf("enable publisher confirms: %w", err)
	}
	if _, err := ch.QueueDeclarePassive(queue, true, false, false, false, nil); err != nil {
		ch.Close()
		conn.Close()
		return nil, fmt.Errorf("required event queue %q is unavailable: %w", queue, err)
	}

	returns := ch.NotifyReturn(make(chan amqp.Return, 1))
	return &RabbitMQEmitter{
		conn:       conn,
		ch:         ch,
		exchange:   "amq.direct",
		routingKey: queue,
		returns:    returns,
	}, nil
}

func (e *RabbitMQEmitter) Emit(ctx context.Context, event FileEvent) error {
	body, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("marshal file event: %w", err)
	}

	// A channel's return and confirmation streams are shared. Serialize
	// publishes so an unroutable result cannot be attributed to another event.
	e.mu.Lock()
	defer e.mu.Unlock()

	select {
	case returned := <-e.returns:
		return fmt.Errorf("stale unroutable message: %s", returned.ReplyText)
	default:
	}

	confirmation, err := e.ch.PublishWithDeferredConfirmWithContext(
		ctx,
		e.exchange,
		e.routingKey,
		true,
		false,
		amqp.Publishing{
			ContentType:  "application/json",
			DeliveryMode: amqp.Persistent,
			Body:         body,
		},
	)
	if err != nil {
		return fmt.Errorf("publish file event: %w", err)
	}

	acknowledged, err := confirmation.WaitContext(ctx)
	if err != nil {
		return fmt.Errorf("wait for publish confirmation: %w", err)
	}

	// RabbitMQ sends basic.return before basic.ack for mandatory unroutable
	// messages, and amqp091-go dispatches returns before confirmations.
	select {
	case returned := <-e.returns:
		return fmt.Errorf(
			"file event was unroutable: code=%d text=%q exchange=%q routing_key=%q",
			returned.ReplyCode,
			returned.ReplyText,
			returned.Exchange,
			returned.RoutingKey,
		)
	default:
	}
	if !acknowledged {
		return fmt.Errorf("RabbitMQ negatively acknowledged file event")
	}
	return nil
}

func (e *RabbitMQEmitter) Close() error {
	if err := e.ch.Close(); err != nil {
		e.conn.Close()
		return err
	}
	return e.conn.Close()
}
