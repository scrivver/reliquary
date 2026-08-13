package auth

import (
	"net/http"
	"net/http/httptest"
	"net/netip"
	"testing"
)

func mustProxies(t *testing.T, cidrs ...string) TrustedProxies {
	t.Helper()
	var out TrustedProxies
	for _, c := range cidrs {
		p, err := netip.ParsePrefix(c)
		if err != nil {
			t.Fatalf("ParsePrefix(%q): %v", c, err)
		}
		out = append(out, p)
	}
	return out
}

func requestFrom(remoteAddr, forwarded string) *http.Request {
	r := httptest.NewRequest(http.MethodPost, "/api/login", nil)
	r.RemoteAddr = remoteAddr
	if forwarded != "" {
		r.Header.Set("X-Forwarded-For", forwarded)
	}
	return r
}

func TestClientIPIgnoresForwardedHeaderFromUntrustedPeer(t *testing.T) {
	trusted := mustProxies(t, "10.0.0.0/8")

	// The peer is not a proxy this server knows, so its claim about the
	// client address carries no weight and the connection address wins.
	tests := []struct {
		name      string
		forwarded string
	}{
		{"single forged address", "9.9.9.9"},
		{"forged chain", "9.9.9.9, 8.8.8.8, 7.7.7.7"},
		{"chain naming a trusted range", "9.9.9.9, 10.1.2.3"},
		{"garbage", "not-an-ip"},
		{"empty entries", " , , "},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := trusted.ClientIP(requestFrom("203.0.113.5:44321", tt.forwarded))
			if got != "203.0.113.5" {
				t.Errorf("ClientIP() = %q, want the peer address 203.0.113.5", got)
			}
		})
	}
}

func TestClientIPHonoursForwardedHeaderFromTrustedPeer(t *testing.T) {
	trusted := mustProxies(t, "10.0.0.0/8", "127.0.0.0/8")

	tests := []struct {
		name      string
		remote    string
		forwarded string
		want      string
	}{
		{"single hop", "10.0.0.2:5000", "198.51.100.7", "198.51.100.7"},
		// Proxies append, so the rightmost untrusted entry is the furthest
		// hop that can still be corroborated. Everything left of it is
		// whatever the original client chose to claim.
		{"forged prefix, real client appended", "10.0.0.2:5000", "9.9.9.9, 198.51.100.7", "198.51.100.7"},
		{"two trusted hops in front", "10.0.0.2:5000", "198.51.100.7, 10.0.0.9", "198.51.100.7"},
		{"loopback peer", "127.0.0.1:5000", "198.51.100.7", "198.51.100.7"},
		{"ipv6 client", "10.0.0.2:5000", "2001:db8::1", "2001:db8::1"},
		{"spacing tolerated", "10.0.0.2:5000", "  198.51.100.7  ", "198.51.100.7"},
		// Nothing in the chain is attributable, so fall back to the peer.
		{"entirely trusted chain", "10.0.0.2:5000", "10.0.0.8, 10.0.0.9", "10.0.0.2"},
		{"unreadable chain", "10.0.0.2:5000", "junk", "10.0.0.2"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := trusted.ClientIP(requestFrom(tt.remote, tt.forwarded)); got != tt.want {
				t.Errorf("ClientIP() = %q, want %q", got, tt.want)
			}
		})
	}
}

// A unix-socket peer reports RemoteAddr "@". Only a local process can open the
// socket, so the header it sets is believed — this is the default deployment.
func TestClientIPTrustsUnixSocketPeer(t *testing.T) {
	var none TrustedProxies

	if got := none.ClientIP(requestFrom("@", "198.51.100.7")); got != "198.51.100.7" {
		t.Errorf("ClientIP() = %q, want 198.51.100.7", got)
	}
	if got := none.ClientIP(requestFrom("@", "")); got != "@" {
		t.Errorf("ClientIP() with no header = %q, want @", got)
	}
}

func TestClientIPWithNoTrustedProxies(t *testing.T) {
	var none TrustedProxies

	if got := none.ClientIP(requestFrom("10.0.0.2:5000", "198.51.100.7")); got != "10.0.0.2" {
		t.Errorf("ClientIP() = %q, want the peer address 10.0.0.2", got)
	}
}

// The regression test for the bypass: rotating X-Forwarded-For from a peer that
// is not a trusted proxy must not mint a fresh quota per request.
func TestRateLimitNotBypassableByRotatingForwardedHeader(t *testing.T) {
	trusted := mustProxies(t, "10.0.0.0/8")
	rl := NewRateLimiter()

	allowed := 0
	for i := range 20 {
		r := requestFrom("203.0.113.5:44321", netip.AddrFrom4([4]byte{9, 9, byte(i / 256), byte(i % 256)}).String())
		if rl.Allow(trusted.ClientIP(r)) {
			allowed++
		}
	}

	if allowed != maxAttempts {
		t.Errorf("allowed %d attempts across 20 rotated headers, want %d", allowed, maxAttempts)
	}
}

// Behind a trusted proxy the header is the only way to tell clients apart, so
// distinct clients must still get distinct quotas.
func TestRateLimitSeparatesClientsBehindTrustedProxy(t *testing.T) {
	trusted := mustProxies(t, "10.0.0.0/8")
	rl := NewRateLimiter()

	for i := range maxAttempts {
		if !rl.Allow(trusted.ClientIP(requestFrom("10.0.0.2:5000", "198.51.100.7"))) {
			t.Fatalf("attempt %d from the first client was limited early", i+1)
		}
	}
	if rl.Allow(trusted.ClientIP(requestFrom("10.0.0.2:5000", "198.51.100.7"))) {
		t.Error("first client was not limited after exhausting its quota")
	}
	if !rl.Allow(trusted.ClientIP(requestFrom("10.0.0.2:5000", "198.51.100.9"))) {
		t.Error("a second client behind the same proxy was limited by the first client's attempts")
	}
}
