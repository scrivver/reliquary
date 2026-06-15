package thumbnail

import (
	"errors"
	"testing"

	amqp "github.com/rabbitmq/amqp091-go"
)

func TestJobValidate(t *testing.T) {
	valid := Job{
		Version:     JobVersion,
		FileKey:     "files/alice/2026/06/report.pdf",
		ContentType: "application/pdf",
		Checksum:    "abc123",
	}
	if err := valid.Validate(); err != nil {
		t.Fatal(err)
	}

	tests := []Job{
		{Version: 2, FileKey: valid.FileKey, ContentType: valid.ContentType, Checksum: valid.Checksum},
		{Version: JobVersion, FileKey: "thumbs/alice/a.jpg", ContentType: valid.ContentType, Checksum: valid.Checksum},
		{Version: JobVersion, FileKey: valid.FileKey, Checksum: valid.Checksum},
		{Version: JobVersion, FileKey: valid.FileKey, ContentType: valid.ContentType},
	}
	for _, job := range tests {
		if err := job.Validate(); err == nil {
			t.Fatalf("expected invalid job: %+v", job)
		}
	}
}

func TestDeliveryAttempt(t *testing.T) {
	tests := []struct {
		value any
		want  int
	}{
		{nil, 0},
		{int32(3), 3},
		{int64(4), 4},
		{"invalid", 0},
	}
	for _, test := range tests {
		delivery := amqp.Delivery{Headers: amqp.Table{}}
		if test.value != nil {
			delivery.Headers[attemptHeader] = test.value
		}
		if got := deliveryAttempt(delivery); got != test.want {
			t.Errorf("deliveryAttempt(%v)=%d, want %d", test.value, got, test.want)
		}
	}
}

func TestDiscardClassification(t *testing.T) {
	err := Discard(errors.New("source missing"))
	if !IsDiscard(err) {
		t.Fatalf("expected discard error: %v", err)
	}
	if IsDiscard(errors.New("transient")) {
		t.Fatal("transient error classified as discard")
	}
}
