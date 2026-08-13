package config

import (
	"net/netip"
	"testing"
)

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
	if cfg.ThumbnailQueue != "reliquary.thumbnail" ||
		cfg.ThumbnailDeadQueue != "reliquary.thumbnail.dead" ||
		cfg.ThumbnailPrefetch != 1 ||
		cfg.ThumbnailConcurrency != 4 ||
		cfg.ThumbnailMaxAttempts != 5 {
		t.Fatalf("unexpected thumbnail config: %+v", cfg)
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

func TestAuthModeDefaultsToPasswordProvider(t *testing.T) {
	t.Setenv("MINIO_PORT", "9000")

	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}

	if !cfg.PasswordAuthEnabled || cfg.OIDCAuthEnabled || cfg.ProxyAuthEnabled || cfg.NoAuthEnabled {
		t.Fatalf("unexpected auth providers: %+v", cfg)
	}
}

func TestAuthModeOIDCEnablesOIDCProvider(t *testing.T) {
	t.Setenv("MINIO_PORT", "9000")
	t.Setenv("AUTH_MODE", "oidc")

	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}

	if cfg.PasswordAuthEnabled || !cfg.OIDCAuthEnabled || cfg.ProxyAuthEnabled || cfg.NoAuthEnabled {
		t.Fatalf("unexpected auth providers: %+v", cfg)
	}
}

func TestAuthProviderFlagsCanCombinePasswordAndOIDC(t *testing.T) {
	t.Setenv("MINIO_PORT", "9000")
	t.Setenv("AUTH_MODE", "full")
	t.Setenv("AUTH_OIDC_ENABLED", "true")

	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}

	if !cfg.PasswordAuthEnabled || !cfg.OIDCAuthEnabled || cfg.ProxyAuthEnabled || cfg.NoAuthEnabled {
		t.Fatalf("unexpected auth providers: %+v", cfg)
	}
}

func TestTrustedProxiesDefaultsToPrivateRanges(t *testing.T) {
	t.Setenv("MINIO_PORT", "9000")

	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}

	// The shipped topologies put the reverse proxy on loopback or a container
	// network, and never publish the API port.
	for _, addr := range []string{"127.0.0.1", "10.1.2.3", "172.20.0.5", "192.168.1.9", "::1"} {
		if !containsAddr(t, cfg.TrustedProxies, addr) {
			t.Errorf("%s should be trusted by default", addr)
		}
	}
	// A peer here is reaching the API directly, not proxying for someone else.
	for _, addr := range []string{"203.0.113.5", "8.8.8.8", "2001:db8::1"} {
		if containsAddr(t, cfg.TrustedProxies, addr) {
			t.Errorf("%s should not be trusted by default", addr)
		}
	}
}

func TestTrustedProxiesExplicitEmptyTrustsNobody(t *testing.T) {
	t.Setenv("MINIO_PORT", "9000")
	t.Setenv("TRUSTED_PROXIES", "")

	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.TrustedProxies) != 0 {
		t.Fatalf("explicitly empty TRUSTED_PROXIES should trust nobody, got %v", cfg.TrustedProxies)
	}
}

func TestTrustedProxiesAcceptsCIDRsAndBareAddresses(t *testing.T) {
	t.Setenv("MINIO_PORT", "9000")
	t.Setenv("TRUSTED_PROXIES", "172.18.0.0/16, 203.0.113.9 ,2001:db8::/32")

	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	for _, addr := range []string{"172.18.5.1", "203.0.113.9", "2001:db8::5"} {
		if !containsAddr(t, cfg.TrustedProxies, addr) {
			t.Errorf("%s should be trusted", addr)
		}
	}
	for _, addr := range []string{"172.19.0.1", "203.0.113.10", "127.0.0.1"} {
		if containsAddr(t, cfg.TrustedProxies, addr) {
			t.Errorf("%s should not be trusted", addr)
		}
	}
}

// A typo must not silently downgrade to trusting less than the operator
// intended, so it is a startup error rather than a dropped entry.
func TestTrustedProxiesRejectsMalformedEntries(t *testing.T) {
	for _, raw := range []string{"not-an-ip", "10.0.0.0/33", "10.0.0.0/8,garbage"} {
		t.Run(raw, func(t *testing.T) {
			t.Setenv("MINIO_PORT", "9000")
			t.Setenv("TRUSTED_PROXIES", raw)

			if _, err := Load(); err == nil {
				t.Fatalf("TRUSTED_PROXIES=%q should fail to load", raw)
			}
		})
	}
}

func containsAddr(t *testing.T, prefixes []netip.Prefix, addr string) bool {
	t.Helper()
	a, err := netip.ParseAddr(addr)
	if err != nil {
		t.Fatalf("ParseAddr(%q): %v", addr, err)
	}
	for _, p := range prefixes {
		if p.Contains(a) {
			return true
		}
	}
	return false
}
