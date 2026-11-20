package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/rand"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	defaultCloudflareAPIBase = "https://api.cloudflare.com/client/v4"
	cloudflareMaxResponse    = 16 << 20
	// Page sizes: list items accept up to 500 per page (Cloudflare API reference,
	// GET .../rules/lists/{id}/items), so reading a 10k-entry list takes 20 requests
	// instead of 100. The lists endpoint documents no paging parameters; it keeps
	// the size it always sent.
	cloudflareItemsPageSize = 500
	cloudflareListsPageSize = 100
	// cloudflareMaxPages bounds a walk whose cursor never ends (an API fault would
	// otherwise loop and grow memory without limit).
	cloudflareMaxPages    = 1000
	cloudflareBulkTimeout = 2 * time.Minute
	// cloudflareMaxAttempts bounds in-process retries of one idempotent API
	// call after a transient failure (network error, timeout, 429, 5xx).
	cloudflareMaxAttempts = 3
)

// cloudflareError represents a non-successful Cloudflare API response.
type cloudflareError struct {
	status  int
	code    int
	message string
	// retryAfter is the Retry-After of a 429 (seconds form), zero otherwise.
	retryAfter time.Duration
}

// cloudflareMaxRetryAfter is the longest Retry-After a sync waits for in-process;
// a longer one ends the attempt and the next interval tries again.
const cloudflareMaxRetryAfter = time.Minute

func (e *cloudflareError) Error() string {
	return fmt.Sprintf("Cloudflare API error (status %d, code %d): %s", e.status, e.code, e.message)
}

type cloudflareBulkError struct{ message string }

func (e *cloudflareBulkError) Error() string { return "Cloudflare bulk operation: " + e.message }

type cloudflareConfigError struct{ message string }

func (e *cloudflareConfigError) Error() string { return "Cloudflare sink configuration: " + e.message }

func cfIsNotFound(err error) bool {
	var ce *cloudflareError
	return errors.As(err, &ce) && ce.status == http.StatusNotFound
}

// cfErrorReason maps an error to a bounded metric label.
func cfErrorReason(err error) string {
	if err == nil {
		return ""
	}
	var ce *cloudflareError
	if errors.As(err, &ce) {
		if ce.status == http.StatusTooManyRequests {
			return "rate_limited"
		}
		return "http"
	}
	var be *cloudflareBulkError
	if errors.As(err, &be) {
		return "bulk"
	}
	var cfe *cloudflareConfigError
	if errors.As(err, &cfe) {
		return "validation"
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		return "timeout"
	}
	return "network"
}

type CloudflareClient struct {
	baseURL    string
	token      string
	accountID  string
	zoneID     string
	listName   string
	maxEntries int
	ruleRef    string
	http       *http.Client
	log        *slog.Logger
	// retryBase is the first retry delay (doubled per attempt, plus jitter).
	// Zero retries immediately; tests rely on that.
	retryBase time.Duration

	// listID caches the resolved list. Not goroutine-safe: App serializes all
	// sink operations through its opMu.
	listID string
}

func NewCloudflareClient(cfg *Config, httpClient *http.Client, log *slog.Logger) *CloudflareClient {
	return &CloudflareClient{
		baseURL:    strings.TrimRight(envString("CLOUDFLARE_API_BASE", defaultCloudflareAPIBase), "/"),
		token:      cfg.CloudflareAPIToken,
		accountID:  cfg.CloudflareAccountID,
		zoneID:     cfg.CloudflareZoneID,
		listName:   cfg.CloudflareListName,
		maxEntries: cfg.CloudflareMaxEntries,
		ruleRef:    cfg.CloudflareRuleRef,
		http:       httpClient,
		log:        log,
		retryBase:  time.Second,
	}
}

type cfEnvelope struct {
	Success    bool            `json:"success"`
	Errors     []cfAPIError    `json:"errors"`
	Result     json.RawMessage `json:"result"`
	ResultInfo *cfResultInfo   `json:"result_info"`
}

type cfAPIError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type cfResultInfo struct {
	Page       int `json:"page"`
	TotalPages int `json:"total_pages"`
	Cursors    struct {
		After string `json:"after"`
	} `json:"cursors"`
}

type cfList struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Kind     string `json:"kind"`
	NumItems int    `json:"numitems"`
}

type cfListItem struct {
	ID      string `json:"id"`
	IP      string `json:"ip"`
	Comment string `json:"comment"`
}

type cfRule struct {
	ID          string `json:"id"`
	Ref         string `json:"ref"`
	Action      string `json:"action"`
	Expression  string `json:"expression"`
	Description string `json:"description"`
	Enabled     bool   `json:"enabled"`
}

type cfRuleset struct {
	ID    string   `json:"id"`
	Name  string   `json:"name"`
	Kind  string   `json:"kind"`
	Phase string   `json:"phase"`
	Rules []cfRule `json:"rules"`
}

type cfBulkOperation struct {
	ID     string `json:"id"`
	Status string `json:"status"`
	Error  string `json:"error"`
}

// Sync applies the desired list to the Cloudflare edge: it ensures the account
// IP list exists, replaces its items atomically when they changed, and ensures
// the managed zone WAF custom rule exists and references the list.
func (c *CloudflareClient) Sync(ctx context.Context, prefixes []netip.Prefix) (entries int, changed bool, err error) {
	if c.maxEntries > 0 && len(prefixes) > c.maxEntries {
		return 0, false, &cloudflareConfigError{
			fmt.Sprintf("desired list has %d entries, above CLOUDFLARE_MAX_ENTRIES=%d", len(prefixes), c.maxEntries),
		}
	}

	listID, err := c.EnsureList(ctx)
	if err != nil {
		return 0, false, fmt.Errorf("ensuring IP list: %w", err)
	}

	changed, err = c.ReplaceItems(ctx, listID, prefixes)
	if err != nil && cfIsNotFound(err) {
		// The list disappeared outside of the controller; recreate it once.
		c.log.Warn("Cloudflare IP list not found, recreating", "list", c.listName)
		c.listID = ""
		if listID, err = c.EnsureList(ctx); err == nil {
			changed, err = c.ReplaceItems(ctx, listID, prefixes)
		}
	}
	if err != nil {
		return 0, false, fmt.Errorf("updating IP list items: %w", err)
	}

	if err := c.EnsureRule(ctx); err != nil {
		metricCloudflareRulePresent.Set(0)
		return len(prefixes), changed, &cloudflareRuleError{err}
	}
	metricCloudflareRulePresent.Set(1)
	return len(prefixes), changed, nil
}

// cloudflareRuleError means the IP list was updated but the zone WAF rule could
// not be ensured. The list content is fresh (it counts for stale-feed age); the
// sink still reports a failed sync until the rule is in place.
type cloudflareRuleError struct{ err error }

func (e *cloudflareRuleError) Error() string { return "ensuring WAF rule: " + e.err.Error() }
func (e *cloudflareRuleError) Unwrap() error { return e.err }

// ClearList empties the managed IP list (stale fail-open) without the WAF rule
// check of Sync: a failing rule check used to make every clear count as failed,
// so the list was emptied again on each retry and after every refill.
func (c *CloudflareClient) ClearList(ctx context.Context) (changed bool, err error) {
	listID, err := c.EnsureList(ctx)
	if err != nil {
		return false, fmt.Errorf("ensuring IP list: %w", err)
	}
	changed, err = c.ReplaceItems(ctx, listID, nil)
	if err != nil && cfIsNotFound(err) {
		// Deleted outside of the controller: nothing left to clear.
		c.listID = ""
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("clearing IP list items: %w", err)
	}
	return changed, nil
}

// EnsureList resolves the account-level IP list by name, creating it when
// missing. The list ID is cached for the process lifetime.
func (c *CloudflareClient) EnsureList(ctx context.Context) (string, error) {
	if c.listID != "" {
		return c.listID, nil
	}
	lists, err := c.listLists(ctx)
	if err != nil {
		return "", err
	}
	for _, l := range lists {
		if l.Name != c.listName {
			continue
		}
		if l.Kind != "ip" {
			return "", &cloudflareConfigError{fmt.Sprintf("list %q exists with kind %q, expected \"ip\"", c.listName, l.Kind)}
		}
		c.listID = l.ID
		return l.ID, nil
	}

	var created cfList
	body := map[string]string{
		"name":        c.listName,
		"kind":        "ip",
		"description": "AbuseIPDB reputation feed (managed by abuseipdb-sync)",
	}
	if err := c.do(ctx, http.MethodPost, c.accountPath("/rules/lists"), nil, body, &created); err != nil {
		return "", fmt.Errorf("creating IP list %q: %w", c.listName, err)
	}
	c.log.Info("created Cloudflare IP list", "name", c.listName, "id", created.ID)
	c.listID = created.ID
	return created.ID, nil
}

func (c *CloudflareClient) listLists(ctx context.Context) ([]cfList, error) {
	var out []cfList
	err := c.walk(ctx, c.accountPath("/rules/lists"), cloudflareListsPageSize, func(raw json.RawMessage) error {
		var lists []cfList
		if err := json.Unmarshal(raw, &lists); err != nil {
			return fmt.Errorf("decoding Cloudflare response: %w", err)
		}
		out = append(out, lists...)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("listing IP lists: %w", err)
	}
	return out, nil
}

// ListItems returns the current items of the list, canonicalized and sorted.
func (c *CloudflareClient) ListItems(ctx context.Context, listID string) ([]netip.Prefix, error) {
	var out []netip.Prefix
	err := c.walk(ctx, fmt.Sprintf("/accounts/%s/rules/lists/%s/items", c.accountID, listID), cloudflareItemsPageSize, func(raw json.RawMessage) error {
		var items []cfListItem
		if err := json.Unmarshal(raw, &items); err != nil {
			return fmt.Errorf("decoding Cloudflare response: %w", err)
		}
		for _, it := range items {
			if it.IP == "" {
				continue
			}
			p, err := parseEntry(it.IP)
			if err != nil {
				return fmt.Errorf("Cloudflare list contains unparseable item %q: %w", it.IP, err)
			}
			out = append(out, p)
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("listing IP list items: %w", err)
	}
	return SortDedup(out), nil
}

// ReplaceItems atomically replaces all list items when the desired list
// differs from the current one, then waits for the asynchronous bulk
// operation to complete.
func (c *CloudflareClient) ReplaceItems(ctx context.Context, listID string, prefixes []netip.Prefix) (bool, error) {
	current, err := c.ListItems(ctx, listID)
	if err != nil {
		return false, err
	}
	if prefixesEqual(current, prefixes) {
		return false, nil
	}

	items := make([]map[string]string, 0, len(prefixes))
	for _, p := range prefixes {
		items = append(items, map[string]string{"ip": p.String()})
	}
	var result struct {
		OperationID string `json:"operation_id"`
	}
	if err := c.do(ctx, http.MethodPut, fmt.Sprintf("/accounts/%s/rules/lists/%s/items", c.accountID, listID), nil, items, &result); err != nil {
		return false, fmt.Errorf("replacing IP list items: %w", err)
	}
	if result.OperationID == "" {
		return true, nil
	}
	metricCloudflareBulkOperationPending.Set(1)
	if err := c.waitBulkOperation(ctx, result.OperationID); err != nil {
		return true, err
	}
	metricCloudflareBulkOperationPending.Set(0)
	return true, nil
}

func (c *CloudflareClient) waitBulkOperation(ctx context.Context, operationID string) error {
	deadline := time.Now().Add(cloudflareBulkTimeout)
	wait := time.Second
	for {
		var op cfBulkOperation
		err := c.do(ctx, http.MethodGet, fmt.Sprintf("/accounts/%s/rules/lists/bulk_operations/%s", c.accountID, operationID), nil, nil, &op)
		if err != nil {
			return fmt.Errorf("polling bulk operation %s: %w", operationID, err)
		}
		switch op.Status {
		case "completed":
			return nil
		case "failed":
			return &cloudflareBulkError{fmt.Sprintf("operation %s failed: %s", operationID, op.Error)}
		}
		if time.Now().After(deadline) {
			return &cloudflareBulkError{fmt.Sprintf("operation %s still %q after %s", operationID, op.Status, cloudflareBulkTimeout)}
		}
		select {
		case <-time.After(wait):
		case <-ctx.Done():
			return ctx.Err()
		}
		if wait < 15*time.Second {
			wait *= 2
		}
	}
}

// EnsureRule ensures the zone WAF custom rule for the managed list exists,
// references the list name, blocks matching requests, and has not drifted.
// Only the rule with our ref is ever modified; other rules are preserved.
func (c *CloudflareClient) EnsureRule(ctx context.Context) error {
	desired := cfRule{
		Ref:         c.ruleRef,
		Action:      "block",
		Expression:  fmt.Sprintf("ip.src in $%s", c.listName),
		Description: "AbuseIPDB denylist (managed by abuseipdb-sync)",
		Enabled:     true,
	}

	entryPoint := fmt.Sprintf("/zones/%s/rulesets/phases/http_request_firewall_custom/entrypoint", c.zoneID)
	var ruleset cfRuleset
	err := c.do(ctx, http.MethodGet, entryPoint, nil, nil, &ruleset)
	if err != nil {
		if !cfIsNotFound(err) {
			return err
		}
		create := map[string]any{
			"name":        "abuseipdb_denylist",
			"description": "Zone entry point for the AbuseIPDB denylist",
			"kind":        "zone",
			"phase":       "http_request_firewall_custom",
			"rules":       []cfRule{desired},
		}
		if err := c.do(ctx, http.MethodPost, fmt.Sprintf("/zones/%s/rulesets", c.zoneID), nil, create, &ruleset); err != nil {
			return fmt.Errorf("creating zone entry point ruleset: %w", err)
		}
		c.log.Info("created Cloudflare WAF custom rule", "ref", c.ruleRef, "expression", desired.Expression)
		return nil
	}

	for _, r := range ruleset.Rules {
		if r.Ref != c.ruleRef {
			continue
		}
		if r.Action == desired.Action && r.Expression == desired.Expression && r.Enabled {
			return nil
		}
		patchPath := fmt.Sprintf("/zones/%s/rulesets/%s/rules/%s", c.zoneID, ruleset.ID, r.ID)
		if err := c.do(ctx, http.MethodPatch, patchPath, nil, desired, nil); err != nil {
			return fmt.Errorf("updating WAF rule %q: %w", c.ruleRef, err)
		}
		c.log.Info("updated Cloudflare WAF custom rule", "ref", c.ruleRef, "expression", desired.Expression)
		return nil
	}

	if err := c.do(ctx, http.MethodPost, fmt.Sprintf("/zones/%s/rulesets/%s/rules", c.zoneID, ruleset.ID), nil, desired, nil); err != nil {
		return fmt.Errorf("creating WAF rule %q: %w", c.ruleRef, err)
	}
	c.log.Info("created Cloudflare WAF custom rule", "ref", c.ruleRef, "expression", desired.Expression)
	return nil
}

func (c *CloudflareClient) accountPath(suffix string) string {
	return fmt.Sprintf("/accounts/%s%s", c.accountID, suffix)
}

// walk pages through a Cloudflare list endpoint. The Lists API paginates with
// an opaque `cursor` (page/per_page is accepted for the first request), so the
// loop prefers the returned cursor and only falls back to page numbers when a
// total_pages count is provided.
func (c *CloudflareClient) walk(ctx context.Context, path string, pageSize int, handle func(json.RawMessage) error) error {
	cursor := ""
	page := 1
	for requests := 1; ; requests++ {
		if requests > cloudflareMaxPages {
			return fmt.Errorf("listing %s: pagination did not end after %d pages", path, cloudflareMaxPages)
		}
		q := url.Values{}
		q.Set("per_page", fmt.Sprintf("%d", pageSize))
		if cursor != "" {
			q.Set("cursor", cursor)
		} else {
			q.Set("page", fmt.Sprintf("%d", page))
		}
		env, err := c.request(ctx, http.MethodGet, path, q, nil)
		if err != nil {
			return err
		}
		if handle != nil && len(env.Result) > 0 {
			if err := handle(env.Result); err != nil {
				return err
			}
		}
		if env.ResultInfo == nil {
			return nil
		}
		if after := env.ResultInfo.Cursors.After; after != "" {
			cursor = after
			continue
		}
		if env.ResultInfo.TotalPages > page {
			page++
			continue
		}
		return nil
	}
}

func (c *CloudflareClient) do(ctx context.Context, method, path string, q url.Values, body any, out any) error {
	env, err := c.request(ctx, method, path, q, body)
	if err != nil {
		return err
	}
	if out != nil && len(env.Result) > 0 {
		if err := json.Unmarshal(env.Result, out); err != nil {
			return fmt.Errorf("decoding Cloudflare response: %w", err)
		}
	}
	return nil
}

// request performs one API call. Idempotent methods (everything except POST)
// are retried up to cloudflareMaxAttempts times on transient failures, so a
// single 5xx or reset among the ~100 page reads of a large list does not cost
// a whole sync interval. POST (list/ruleset/rule creation) is never retried:
// a lost response could otherwise create a duplicate.
func (c *CloudflareClient) request(ctx context.Context, method, path string, q url.Values, body any) (*cfEnvelope, error) {
	var encoded []byte
	if body != nil {
		var err error
		if encoded, err = json.Marshal(body); err != nil {
			return nil, err
		}
	}
	attempts := cloudflareMaxAttempts
	if method == http.MethodPost {
		attempts = 1
	}
	wait := c.retryBase
	for attempt := 1; ; attempt++ {
		env, err := c.requestOnce(ctx, method, path, q, encoded)
		if err == nil || attempt >= attempts || !cfRetryable(ctx, err) {
			return env, err
		}
		d := wait
		if d > 0 {
			d += time.Duration(rand.Int63n(int64(d/2) + 1))
		}
		// Honour the server's Retry-After on 429: retrying sooner only spends the
		// remaining attempts inside the same rate-limit window.
		var ce *cloudflareError
		if errors.As(err, &ce) && ce.retryAfter > 0 {
			if ce.retryAfter > cloudflareMaxRetryAfter {
				return env, err
			}
			d = max(d, ce.retryAfter)
		}
		c.log.Warn("retrying Cloudflare API request", "method", method, "path", path, "attempt", attempt, "wait", d.String(), "error", err)
		select {
		case <-time.After(d):
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		wait *= 2
	}
}

// cfRetryable reports whether a failed call may succeed when repeated:
// rate limiting, server errors and transport failures, but not 4xx answers,
// configuration errors or a cancelled sync.
func cfRetryable(ctx context.Context, err error) bool {
	if ctx.Err() != nil {
		return false
	}
	var ce *cloudflareError
	if errors.As(err, &ce) {
		return ce.status == http.StatusTooManyRequests || ce.status >= 500
	}
	var tooLarge *responseTooLargeError
	return !errors.As(err, &tooLarge)
}

func (c *CloudflareClient) requestOnce(ctx context.Context, method, path string, q url.Values, encoded []byte) (*cfEnvelope, error) {
	var reader io.Reader
	if encoded != nil {
		reader = bytes.NewReader(encoded)
	}
	endpoint := c.baseURL + path
	if len(q) > 0 {
		endpoint += "?" + q.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, method, endpoint, reader)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "abuseipdb-sync/"+version)
	if encoded != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, err := readBounded(resp.Body, cloudflareMaxResponse)
	if err != nil {
		return nil, err
	}

	var env cfEnvelope
	if len(data) > 0 {
		if err := json.Unmarshal(data, &env); err != nil {
			return nil, &cloudflareError{status: resp.StatusCode, message: fmt.Sprintf("invalid JSON response: %.200s", strings.TrimSpace(string(data)))}
		}
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 || !env.Success {
		ce := &cloudflareError{status: resp.StatusCode}
		if resp.StatusCode == http.StatusTooManyRequests {
			if secs, err := strconv.Atoi(strings.TrimSpace(resp.Header.Get("Retry-After"))); err == nil && secs > 0 {
				ce.retryAfter = time.Duration(secs) * time.Second
			}
		}
		if len(env.Errors) > 0 {
			ce.code = env.Errors[0].Code
			ce.message = env.Errors[0].Message
		} else {
			ce.message = fmt.Sprintf("unexpected status %d: %.200s", resp.StatusCode, strings.TrimSpace(string(data)))
		}
		return nil, ce
	}
	return &env, nil
}

func prefixesEqual(a, b []netip.Prefix) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
