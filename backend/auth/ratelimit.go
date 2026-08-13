package auth

import (
	"net"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"time"
)

const (
	maxAttempts     = 5
	windowDuration  = 1 * time.Minute
	cleanupInterval = 5 * time.Minute
)

type loginAttempt struct {
	count       int
	windowStart time.Time
}

type RateLimiter struct {
	mu       sync.Mutex
	attempts map[string]*loginAttempt
}

func NewRateLimiter() *RateLimiter {
	rl := &RateLimiter{
		attempts: make(map[string]*loginAttempt),
	}
	go rl.cleanup()
	return rl
}

// Allow checks if the IP is allowed to attempt login.
// Returns false if the rate limit is exceeded.
func (rl *RateLimiter) Allow(ip string) bool {
	rl.mu.Lock()
	defer rl.mu.Unlock()

	now := time.Now()
	attempt, exists := rl.attempts[ip]

	if !exists || now.Sub(attempt.windowStart) > windowDuration {
		rl.attempts[ip] = &loginAttempt{count: 1, windowStart: now}
		return true
	}

	attempt.count++
	return attempt.count <= maxAttempts
}

// Reset clears the attempt counter for an IP (called on successful login).
func (rl *RateLimiter) Reset(ip string) {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	delete(rl.attempts, ip)
}

func (rl *RateLimiter) cleanup() {
	for {
		time.Sleep(cleanupInterval)
		rl.mu.Lock()
		now := time.Now()
		for ip, attempt := range rl.attempts {
			if now.Sub(attempt.windowStart) > windowDuration {
				delete(rl.attempts, ip)
			}
		}
		rl.mu.Unlock()
	}
}

// TrustedProxies is the set of peers whose X-Forwarded-For header is believed.
type TrustedProxies []netip.Prefix

func (t TrustedProxies) contains(addr netip.Addr) bool {
	addr = addr.Unmap()
	for _, p := range t {
		if p.Contains(addr) {
			return true
		}
	}
	return false
}

// ClientIP returns the address the rate limiter keys on.
//
// X-Forwarded-For is honoured only from a trusted peer. The header is written
// by whoever sent the request, so trusting it unconditionally lets a caller
// rotate it and draw a fresh quota per attempt — unlimited password guesses
// against an endpoint whose whole purpose is to bound them.
//
// The chain is walked from the right, because proxies append: the rightmost
// entry is the hop nearest this server and the leftmost is whatever the
// original client chose to claim. The first entry that is not itself a trusted
// proxy is the furthest point that can still be corroborated.
//
// A peer whose address does not parse is reached over a unix socket, where
// RemoteAddr is "@". Only a local process can open that socket, so it is
// trusted — this is the default deployment, with Caddy in front.
func (t TrustedProxies) ClientIP(r *http.Request) string {
	peer, err := netip.ParseAddr(hostOnly(r.RemoteAddr))
	trustPeer := err != nil || t.contains(peer)

	if trustPeer {
		if fwd := r.Header.Get("X-Forwarded-For"); fwd != "" {
			hops := strings.Split(fwd, ",")
			for i := len(hops) - 1; i >= 0; i-- {
				addr, err := netip.ParseAddr(strings.TrimSpace(hops[i]))
				if err != nil {
					// A chain this server cannot read is not a chain it can
					// draw conclusions from; fall back to the peer.
					break
				}
				if !t.contains(addr) {
					return addr.Unmap().String()
				}
			}
		}
	}

	if err == nil {
		return peer.Unmap().String()
	}
	return r.RemoteAddr
}

// hostOnly strips the port from a "host:port" address, leaving anything else
// (a unix socket's "@", a bare address) untouched.
func hostOnly(addr string) string {
	if host, _, err := net.SplitHostPort(addr); err == nil {
		return host
	}
	return addr
}
