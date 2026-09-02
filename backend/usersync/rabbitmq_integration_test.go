package usersync

import (
	"context"
	"os"
	"testing"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
)

func integrationURL(t *testing.T) string {
	t.Helper()
	url := os.Getenv("RABBITMQ_INTEGRATION_URL")
	if url == "" {
		t.Skip("RABBITMQ_INTEGRATION_URL is not set")
	}
	return url
}

const testExchange = "reliquary.userstore"

func TestIntegrationPublishReachesOtherReplica(t *testing.T) {
	url := integrationURL(t)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	store := &fakeReloader{etag: "etag-old"}
	sub := NewSubscriber(url, testExchange, "api-subscriber", store)

	subCtx, stop := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		sub.Run(subCtx)
		close(done)
	}()
	// Wait for Run to return, not just for cancellation: the queue is
	// auto-delete, and leaving it half torn down leaks into the next test.
	defer func() {
		stop()
		<-done
	}()

	// Wait for the subscriber's queue to exist and be bound before publishing;
	// a fanout drops messages that arrive with nothing bound.
	waitFor(t, ctx, func() bool { return sub.ready() })

	pub, err := NewPublisher(url, testExchange, "api-publisher")
	if err != nil {
		t.Fatal(err)
	}
	defer pub.Close()

	if err := pub.NotifyChanged(ctx, "etag-new"); err != nil {
		t.Fatalf("publish: %v", err)
	}

	waitFor(t, ctx, func() bool { return store.count() > 0 })
}

// TestIntegrationPublishWithNoSubscribers is the single-replica case: a fanout
// with nothing bound must not be treated as a failure, or every admin action on
// a healthy one-node install would log an error.
//
// It uses its own exchange rather than the shared one. A queue that is still
// being auto-deleted counts as bound, and the broker nacks a message routed to
// a queue that disappears underneath it — which is a real (and correctly
// handled) best-effort case, but not the one under test here.
func TestIntegrationPublishWithNoSubscribers(t *testing.T) {
	url := integrationURL(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	exchange := declareTestExchange(t, url)

	pub, err := NewPublisher(url, exchange, "api-lonely")
	if err != nil {
		t.Fatal(err)
	}
	defer pub.Close()

	if err := pub.NotifyChanged(ctx, "etag-new"); err != nil {
		t.Fatalf("publishing with no subscribers must succeed, got: %v", err)
	}
}

// declareTestExchange creates an isolated fanout exchange and removes it when
// the test finishes.
func declareTestExchange(t *testing.T, url string) string {
	t.Helper()

	conn, err := amqp.Dial(url)
	if err != nil {
		t.Fatal(err)
	}
	ch, err := conn.Channel()
	if err != nil {
		t.Fatal(err)
	}

	name := "reliquary.userstore.test-" + NewOrigin("x")
	if err := ch.ExchangeDeclare(name, amqp.ExchangeFanout, true, false, false, false, nil); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := ch.ExchangeDelete(name, false, false); err != nil {
			t.Logf("cleanup exchange %s: %v", name, err)
		}
		ch.Close()
		conn.Close()
	})
	return name
}

// TestIntegrationSubscriberStopsPromptly is a regression test. Channel.Close
// performs an RPC and waits for a reply that never arrives once the consume
// context is cancelled, so closing the channel on the way out deadlocked the
// subscriber goroutine — and with it every future reconnect, silently ending
// invalidation for the life of the process after a single broker blip.
func TestIntegrationSubscriberStopsPromptly(t *testing.T) {
	url := integrationURL(t)

	sub := NewSubscriber(url, testExchange, "api-shutdown", &fakeReloader{})
	ctx, stop := context.WithCancel(context.Background())

	done := make(chan struct{})
	go func() {
		sub.Run(ctx)
		close(done)
	}()

	waitFor(t, context.Background(), func() bool { return sub.ready() })

	// Cancel with a delivery already consumed. The deadlock needs the channel
	// to have live consumer state; cancelling an idle subscriber closes
	// cleanly and would not reproduce it.
	pub, err := NewPublisher(url, testExchange, "api-shutdown-pub")
	if err != nil {
		t.Fatal(err)
	}
	defer pub.Close()
	if err := pub.NotifyChanged(context.Background(), "etag-shutdown"); err != nil {
		t.Fatal(err)
	}
	waitFor(t, context.Background(), func() bool { return sub.store.(*fakeReloader).count() > 0 })

	stop()

	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("subscriber did not stop within 10s of cancellation; it is deadlocked on shutdown")
	}
}

func TestIntegrationMissingExchangeIsReported(t *testing.T) {
	url := integrationURL(t)

	_, err := NewPublisher(url, "reliquary.userstore.does-not-exist", "api-1")
	if err == nil {
		t.Fatal("a missing exchange must be reported at construction, not silently ignored")
	}
}

func waitFor(t *testing.T, ctx context.Context, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		select {
		case <-ctx.Done():
			t.Fatal("context cancelled while waiting")
		case <-time.After(50 * time.Millisecond):
		}
	}
	t.Fatal("timed out waiting for condition")
}
