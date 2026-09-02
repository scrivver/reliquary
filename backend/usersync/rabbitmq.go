package usersync

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
)

// Publisher announces user-store changes to the other replicas.
type Publisher struct {
	conn     *amqp.Connection
	ch       *amqp.Channel
	exchange string
	origin   string
	mu       sync.Mutex
}

func NewPublisher(amqpURL, exchange, origin string) (*Publisher, error) {
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
	if err := ch.ExchangeDeclarePassive(exchange, amqp.ExchangeFanout, true, false, false, false, nil); err != nil {
		ch.Close()
		conn.Close()
		return nil, fmt.Errorf("required exchange %q is unavailable: %w", exchange, err)
	}
	return &Publisher{conn: conn, ch: ch, exchange: exchange, origin: origin}, nil
}

// NotifyChanged publishes the new version.
//
// Unlike the file-event and thumbnail publishers, this one is NOT mandatory. A
// fanout with no bound queues is the normal state for a single-replica
// deployment, and treating that as an error would turn every admin action into
// a logged failure on a healthy install.
//
// Delivery is transient for the same reason it is best-effort: the message is a
// cache hint. If the broker restarts and drops it, the periodic reload closes
// the gap, and persisting it would buy a disk write per admin action for
// nothing.
func (p *Publisher) NotifyChanged(ctx context.Context, etag string) error {
	body, err := Change{ETag: etag, Origin: p.origin, At: time.Now().UTC().Format(time.RFC3339)}.marshal()
	if err != nil {
		return fmt.Errorf("marshal user store change: %w", err)
	}

	p.mu.Lock()
	defer p.mu.Unlock()

	confirmation, err := p.ch.PublishWithDeferredConfirmWithContext(
		ctx,
		p.exchange,
		"",
		false,
		false,
		amqp.Publishing{
			ContentType:  "application/json",
			DeliveryMode: amqp.Transient,
			Body:         body,
		},
	)
	if err != nil {
		return fmt.Errorf("publish user store change: %w", err)
	}
	acknowledged, err := confirmation.WaitContext(ctx)
	if err != nil {
		return fmt.Errorf("wait for publish confirmation: %w", err)
	}
	if !acknowledged {
		return errors.New("RabbitMQ negatively acknowledged user store change")
	}
	return nil
}

func (p *Publisher) Close() error {
	if err := p.ch.Close(); err != nil {
		p.conn.Close()
		return err
	}
	return p.conn.Close()
}

// Subscriber keeps one replica's user store fresh by reloading whenever another
// replica reports a change.
type Subscriber struct {
	amqpURL  string
	exchange string
	origin   string
	store    Reloader
	// bound reports that the queue is declared, bound, and consuming. A fanout
	// drops messages published while nothing is bound, so tests wait on this
	// rather than sleeping and hoping.
	bound atomic.Bool
}

func NewSubscriber(amqpURL, exchange, origin string, store Reloader) *Subscriber {
	return &Subscriber{amqpURL: amqpURL, exchange: exchange, origin: origin, store: store}
}

// Run consumes invalidations until ctx is cancelled, reconnecting on failure.
//
// The reconnect loop matters more than it looks: without it a single broker
// restart would silently stop invalidation for the life of the process, leaving
// the replica quietly falling back to the periodic reload with nothing in the
// logs to say so.
func (s *Subscriber) Run(ctx context.Context) {
	const (
		minBackoff = 1 * time.Second
		maxBackoff = 30 * time.Second
	)
	backoff := minBackoff

	for {
		if ctx.Err() != nil {
			return
		}

		err := s.consume(ctx)
		if ctx.Err() != nil {
			return
		}
		slog.Warn(
			"user store invalidation stream lost; falling back to periodic reload until it recovers",
			"error", err,
			"retry_in", backoff,
		)

		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		if backoff *= 2; backoff > maxBackoff {
			backoff = maxBackoff
		}
	}
}

// consume runs one connection's worth of consumption, returning when it fails.
func (s *Subscriber) consume(ctx context.Context) error {
	conn, err := amqp.Dial(s.amqpURL)
	if err != nil {
		return fmt.Errorf("connect to RabbitMQ: %w", err)
	}
	defer conn.Close()

	// Only the connection is closed, deliberately. Channel.Close performs an
	// RPC and waits for the broker's reply; once the consume context has been
	// cancelled that reply never arrives and the close blocks forever, wedging
	// this goroutine and, with it, all future reconnect attempts. Closing the
	// connection tears the channel down on both ends without the round trip.
	ch, err := conn.Channel()
	if err != nil {
		return fmt.Errorf("open RabbitMQ channel: %w", err)
	}

	if err := ch.ExchangeDeclarePassive(s.exchange, amqp.ExchangeFanout, true, false, false, false, nil); err != nil {
		return fmt.Errorf("required exchange %q is unavailable: %w", s.exchange, err)
	}

	// The queue is per-replica and lives only as long as this connection, so
	// unlike every other queue in this codebase it cannot be predeclared in the
	// infrastructure definitions and is declared here. Exclusive and
	// auto-delete so a replica going away leaves nothing behind to fill up.
	queue, err := ch.QueueDeclare("", false, true, true, false, nil)
	if err != nil {
		return fmt.Errorf("declare invalidation queue: %w", err)
	}
	if err := ch.QueueBind(queue.Name, "", s.exchange, false, nil); err != nil {
		return fmt.Errorf("bind invalidation queue: %w", err)
	}

	// autoAck: a lost hint costs latency, not correctness, so there is nothing
	// to gain from redelivery.
	deliveries, err := ch.ConsumeWithContext(ctx, queue.Name, "", true, true, false, false, nil)
	if err != nil {
		return fmt.Errorf("consume user store changes: %w", err)
	}

	slog.Info("user store invalidation subscriber ready", "exchange", s.exchange, "queue", queue.Name)
	s.bound.Store(true)
	defer s.bound.Store(false)

	closed := conn.NotifyClose(make(chan *amqp.Error, 1))
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case err := <-closed:
			return fmt.Errorf("connection closed: %w", err)
		case delivery, ok := <-deliveries:
			if !ok {
				return errors.New("delivery channel closed")
			}
			s.handle(ctx, delivery.Body)
		}
	}
}

// ready reports whether the subscriber is currently bound and consuming.
func (s *Subscriber) ready() bool { return s.bound.Load() }

func (s *Subscriber) handle(ctx context.Context, body []byte) {
	var change Change
	if err := json.Unmarshal(body, &change); err != nil {
		slog.Warn("discarding malformed user store change", "error", err)
		return
	}
	if change.Origin == s.origin {
		return // our own publish, echoed back by the fanout
	}
	if change.ETag != "" && change.ETag == s.store.CurrentETag() {
		return // already on this version
	}

	if err := s.store.Reload(ctx); err != nil {
		slog.Warn("user store reload after invalidation failed", "error", err)
		return
	}
	slog.Info("user store reloaded after change by another writer", "origin", change.Origin)
}

// Notifier is a ChangeNotifier that connects on first use and reconnects after
// a failure.
//
// It exists because connecting eagerly at startup has two failure modes that
// are both permanent for the life of the process. On a cold `docker compose
// up`, the broker can answer its healthcheck before the definitions naming this
// exchange have been applied, so an eager connect fails and invalidation never
// starts. And if the broker restarts later, an already-open publisher never
// recovers — the subscriber reconnects, but the publish side would not.
//
// Connecting lazily and dropping the connection on error makes both
// self-healing: the next mutation reconnects. Failures still surface to the
// caller, which logs them and carries on, because announcing a change is
// best-effort by design.
type Notifier struct {
	amqpURL  string
	exchange string
	origin   string

	mu  sync.Mutex
	pub *Publisher
}

func NewNotifier(amqpURL, exchange, origin string) *Notifier {
	return &Notifier{amqpURL: amqpURL, exchange: exchange, origin: origin}
}

func (n *Notifier) NotifyChanged(ctx context.Context, etag string) error {
	n.mu.Lock()
	defer n.mu.Unlock()

	if n.pub == nil {
		pub, err := NewPublisher(n.amqpURL, n.exchange, n.origin)
		if err != nil {
			return err
		}
		n.pub = pub
	}

	if err := n.pub.NotifyChanged(ctx, etag); err != nil {
		// The connection may be the reason. Drop it so the next call rebuilds
		// it rather than failing identically forever.
		n.pub.Close()
		n.pub = nil
		return err
	}
	return nil
}

func (n *Notifier) Close() error {
	n.mu.Lock()
	defer n.mu.Unlock()

	if n.pub == nil {
		return nil
	}
	err := n.pub.Close()
	n.pub = nil
	return err
}
