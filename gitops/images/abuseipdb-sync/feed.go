package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/rand"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	blacklistEndpoint = "https://api.abuseipdb.com/api/v2/blacklist"
	maxResponseBytes  = 64 << 20 // 64 MiB covers the 500k-entry premium tier
	maxAttempts       = 3
)

type FeedClient struct {
	apiKey            string
	limit             int
	confidenceMinimum int
	http              *http.Client
	log               *slog.Logger
}

// rateLimitError indicates the API daily limit has been reached. It is never
// retried inside the process; the regular synchronization interval governs the
// next attempt so the controller cannot hammer the API.
type rateLimitError struct {
	retryAfter time.Duration
	resetAt    time.Time
}

func (e *rateLimitError) Error() string {
	switch {
	case !e.resetAt.IsZero():
		return fmt.Sprintf("AbuseIPDB daily rate limit reached; window resets at %s", e.resetAt.UTC().Format(time.RFC3339))
	case e.retryAfter > 0:
		return fmt.Sprintf("AbuseIPDB daily rate limit reached; retry after %s", e.retryAfter)
	default:
		return "AbuseIPDB daily rate limit reached"
	}
}

type httpStatusError struct {
	status    int
	body      string
	retryable bool
}

func (e *httpStatusError) Error() string {
	return fmt.Sprintf("unexpected HTTP status %d from AbuseIPDB: %s", e.status, e.body)
}

// Fetch downloads the blacklist and returns the raw body and HTTP status. It
// retries transient failures with bounded exponential backoff and never
// retries rate limiting.
func (c *FeedClient) Fetch(ctx context.Context) ([]byte, int, error) {
	endpoint, err := url.Parse(blacklistEndpoint)
	if err != nil {
		return nil, 0, err
	}
	q := endpoint.Query()
	q.Set("plaintext", "true")
	q.Set("limit", strconv.Itoa(c.limit))
	if c.confidenceMinimum > 0 {
		q.Set("confidenceMinimum", strconv.Itoa(c.confidenceMinimum))
	}
	endpoint.RawQuery = q.Encode()

	backoff := 2 * time.Second
	var lastErr error
	var lastStatus int
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		body, status, err := c.do(ctx, endpoint.String())
		lastStatus = status
		if err == nil {
			return body, status, nil
		}
		lastErr = err

		var rl *rateLimitError
		var hs *httpStatusError
		if errors.As(err, &rl) {
			return nil, status, err
		}
		if errors.As(err, &hs) && !hs.retryable {
			return nil, status, err
		}
		if attempt == maxAttempts {
			break
		}
		wait := backoff + time.Duration(rand.Int63n(int64(backoff/2+1)))
		c.log.Warn("retrying feed download", "attempt", attempt, "wait", wait.String(), "error", err)
		select {
		case <-time.After(wait):
		case <-ctx.Done():
			return nil, status, ctx.Err()
		}
		backoff *= 2
	}
	return nil, lastStatus, lastErr
}

func (c *FeedClient) do(ctx context.Context, rawURL string) ([]byte, int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Key", c.apiKey)
	req.Header.Set("Accept", "text/plain")
	req.Header.Set("User-Agent", "abuseipdb-sync/"+version)

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes))
	if err != nil {
		return nil, resp.StatusCode, err
	}

	switch {
	case resp.StatusCode == http.StatusOK:
		if err := validateFeedBody(resp.Header.Get("Content-Type"), body); err != nil {
			return nil, resp.StatusCode, err
		}
		return body, resp.StatusCode, nil
	case resp.StatusCode == http.StatusTooManyRequests:
		return nil, resp.StatusCode, parseRateLimit(resp.Header)
	case resp.StatusCode >= 500:
		return nil, resp.StatusCode, &httpStatusError{status: resp.StatusCode, body: bodySnippet(body), retryable: true}
	default:
		return nil, resp.StatusCode, &httpStatusError{status: resp.StatusCode, body: bodySnippet(body), retryable: false}
	}
}

// validateFeedBody rejects error pages, JSON error payloads and empty bodies
// before any parsing is attempted.
func validateFeedBody(contentType string, body []byte) error {
	ct := strings.ToLower(contentType)
	if ct != "" && !strings.Contains(ct, "text/plain") {
		return fmt.Errorf("unexpected content type %q (expected text/plain)", contentType)
	}
	trimmed := bytes.TrimSpace(body)
	if len(trimmed) == 0 {
		return errors.New("empty feed body")
	}
	switch trimmed[0] {
	case '<', '{', '[':
		return fmt.Errorf("unexpected response body (content-type %q): %.80q", contentType, trimmed)
	}
	return nil
}

func parseRateLimit(h http.Header) *rateLimitError {
	rl := &rateLimitError{}
	if v := strings.TrimSpace(h.Get("Retry-After")); v != "" {
		if secs, err := strconv.Atoi(v); err == nil && secs > 0 {
			rl.retryAfter = time.Duration(secs) * time.Second
		} else if t, err := http.ParseTime(v); err == nil {
			rl.retryAfter = time.Until(t)
		}
	}
	if v := strings.TrimSpace(h.Get("X-RateLimit-Reset")); v != "" {
		if epoch, err := strconv.ParseInt(v, 10, 64); err == nil && epoch > 0 {
			rl.resetAt = time.Unix(epoch, 0)
		}
	}
	return rl
}

func bodySnippet(body []byte) string {
	s := strings.TrimSpace(string(body))
	if len(s) > 200 {
		s = s[:200]
	}
	return s
}

// errorReason maps an error to a bounded metric label.
func errorReason(err error) string {
	if err == nil {
		return ""
	}
	var rl *rateLimitError
	if errors.As(err, &rl) {
		return "rate_limited"
	}
	var hs *httpStatusError
	if errors.As(err, &hs) {
		return "http"
	}
	if errors.Is(err, context.DeadlineExceeded) || os.IsTimeout(err) {
		return "timeout"
	}
	return "network"
}
