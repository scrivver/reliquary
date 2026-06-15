package config

import "testing"

func TestEventsEnabledByDefault(t *testing.T) {
	t.Setenv("MINIO_PORT", "9000")
	t.Setenv("EVENTS_ENABLED", "")

	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.EventsEnabled {
		t.Fatal("events should be enabled by default")
	}
	if cfg.EventQueue != "engram.ingest" || cfg.EventDeviceName != "reliquary" {
		t.Fatalf("unexpected event config: %+v", cfg)
	}
}

func TestEventsCanBeExplicitlyDisabled(t *testing.T) {
	t.Setenv("MINIO_PORT", "9000")
	t.Setenv("EVENTS_ENABLED", "false")

	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.EventsEnabled {
		t.Fatal("events should be disabled")
	}
}
