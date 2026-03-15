package auth

import (
	"net"
	"net/http"
	"sync"
	"time"
)

const (
	maxAttempts    = 5
	windowDuration = 1 * time.Minute
	cleanupInterval = 5 * time.Minute
)

type loginAttempt struct {
	count    int
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

// ExtractIP gets the client IP from the request, checking X-Forwarded-For
// for requests behind a reverse proxy.
func ExtractIP(r *http.Request) string {
	if forwarded := r.Header.Get("X-Forwarded-For"); forwarded != "" {
		// Take the first IP in the chain (original client).
		if ip, _, err := net.SplitHostPort(forwarded); err == nil {
			return ip
		}
		return forwarded
	}
	if ip, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		return ip
	}
	return r.RemoteAddr
}
