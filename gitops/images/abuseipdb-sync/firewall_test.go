package main

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	dto "github.com/prometheus/client_model/go"
)

func firewallTestClient(t *testing.T, srv *httptest.Server) *FirewallCollector {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	return &FirewallCollector{
		zoneID:    "zone",
		token:     "test-token",
		baseURL:   srv.URL,
		lokiURL:   srv.URL + "/loki/api/v1/push",
		interval:  time.Minute,
		lookback:  5 * time.Minute,
		maxWindow: time.Hour,
		limit:     5000,
		http:      srv.Client(),
		log:       logger,
	}
}

func TestAggregateFirewallEvents(t *testing.T) {
	minute := "2026-09-19T10:00:30Z"
	events := []cfFirewallEvent{
		{Action: "block", Source: "firewallCustom", ClientIP: "192.0.2.10", RuleID: "r1", Host: "www.jokelab.dev", Path: "/a", Datetime: minute},
		{Action: "block", Source: "firewallCustom", ClientIP: "192.0.2.10", RuleID: "r1", Host: "www.jokelab.dev", Path: "/b", Datetime: "2026-09-19T10:00:45Z"},
		{Action: "block", Source: "firewallManaged", ClientIP: "192.0.2.11", RuleID: "r2", Host: "www.jokelab.dev", Datetime: minute},
	}
	groups := aggregateFirewallEvents(events)
	if len(groups) != 2 {
		t.Fatalf("want 2 groups, got %d", len(groups))
	}
	if groups[0].ClientIP != "192.0.2.10" || groups[0].Count != 2 {
		t.Fatalf("unexpected first group: %+v", groups[0])
	}
	if groups[0].Path != "/a" {
		t.Fatalf("expected first path to be sampled, got %q", groups[0].Path)
	}
}

func TestFirewallCollectorPollAndPush(t *testing.T) {
	// Both block events fall in the same minute bucket so they aggregate.
	base := time.Now().UTC().Add(-3 * time.Minute).Truncate(time.Minute).Add(10 * time.Second)
	mock := &firewallMock{
		t: t,
		events: []map[string]any{
			{"action": "block", "source": "firewallCustom", "clientIP": "192.0.2.10", "clientAsn": "64500",
				"clientCountryName": "NL", "clientRequestPath": "/wp-login.php", "clientRequestHTTPHost": "www.jokelab.dev",
				"userAgent": "curl/8", "ruleId": "", "datetime": base.Format(time.RFC3339)},
			{"action": "block", "source": "firewallCustom", "clientIP": "192.0.2.10", "clientAsn": "64500",
				"clientCountryName": "NL", "clientRequestPath": "/wp-login.php", "clientRequestHTTPHost": "www.jokelab.dev",
				"userAgent": "curl/8", "ruleId": "", "datetime": base.Add(20 * time.Second).Format(time.RFC3339)},
			{"action": "challenge", "source": "firewallManaged", "clientIP": "192.0.2.11",
				"datetime": base.Add(30 * time.Second).Format(time.RFC3339)},
		},
	}
	srv := httptest.NewServer(mock)
	defer srv.Close()

	client := firewallTestClient(t, srv)
	client.lastWindowEnd = time.Now().UTC().Add(-5 * time.Minute)
	if err := client.pollOnce(context.Background()); err != nil {
		t.Fatalf("poll failed: %v", err)
	}
	if mock.graphqlCalls != 1 {
		t.Fatalf("want 1 graphql call, got %d", mock.graphqlCalls)
	}
	if len(mock.lokiBodies) != 1 {
		t.Fatalf("want 1 loki push, got %d", len(mock.lokiBodies))
	}

	streams, _ := mock.lokiBodies[0]["streams"].([]any)
	if len(streams) != 1 {
		t.Fatalf("want 1 stream (block/firewallCustom), got %d", len(streams))
	}
	stream, _ := streams[0].(map[string]any)
	labels, _ := stream["stream"].(map[string]any)
	if labels["job"] != "cloudflare-firewall" || labels["source"] != "firewallCustom" || labels["action"] != "block" {
		t.Fatalf("unexpected labels: %v", labels)
	}
	values, _ := stream["values"].([]any)
	if len(values) != 1 {
		t.Fatalf("want 1 aggregated line, got %d", len(values))
	}
	pair, _ := values[0].([]any)
	line, _ := pair[1].(string)
	var parsed firewallLogLine
	if err := json.Unmarshal([]byte(line), &parsed); err != nil {
		t.Fatalf("invalid line json %q: %v", line, err)
	}
	if parsed.ClientIP != "192.0.2.10" || parsed.Count != 2 {
		t.Fatalf("unexpected aggregated line: %+v", parsed)
	}
	if !client.lastWindowEnd.After(time.Now().UTC().Add(-time.Minute)) {
		t.Fatalf("window end was not advanced: %s", client.lastWindowEnd)
	}
}

func TestFirewallGraphQLFallbackWithoutActionFilter(t *testing.T) {
	mock := &firewallMock{
		t:                  t,
		rejectActionFilter: true,
		events: []map[string]any{
			{"action": "block", "source": "firewallCustom", "clientIP": "192.0.2.20",
				"datetime": time.Now().UTC().Add(-time.Minute).Format(time.RFC3339)},
			{"action": "challenge", "source": "firewallManaged", "clientIP": "192.0.2.21",
				"datetime": time.Now().UTC().Add(-time.Minute).Format(time.RFC3339)},
		},
	}
	srv := httptest.NewServer(mock)
	defer srv.Close()

	client := firewallTestClient(t, srv)
	client.lastWindowEnd = time.Now().UTC().Add(-5 * time.Minute)
	if err := client.pollOnce(context.Background()); err != nil {
		t.Fatalf("poll failed: %v", err)
	}
	if mock.graphqlCalls != 2 {
		t.Fatalf("want fallback retry (2 graphql calls), got %d", mock.graphqlCalls)
	}
	streams, _ := mock.lokiBodies[0]["streams"].([]any)
	if len(streams) != 1 {
		t.Fatalf("non-block events must be filtered client-side, got %d streams", len(streams))
	}
}

func TestFirewallErrorReason(t *testing.T) {
	if got := firewallErrorReason(&cloudflareGraphQLError{message: "Actor does not have permission 'analytics.read'"}); got != "authz" {
		t.Fatalf("want authz, got %s", got)
	}
	if got := firewallErrorReason(&lokiError{status: 429}); got != "loki" {
		t.Fatalf("want loki, got %s", got)
	}
	if got := firewallErrorReason(&cloudflareGraphQLError{message: "unknown field"}); got != "graphql" {
		t.Fatalf("want graphql, got %s", got)
	}
}

type firewallMock struct {
	t                  *testing.T
	graphqlCalls       int
	rejectActionFilter bool
	lokiBodies         []map[string]any
	events             []map[string]any
	// honorWindow makes the mock behave like Cloudflare: only rows inside
	// [datetime_geq, datetime_lt) are returned, oldest first. maxRows caps the
	// response like the GraphQL limit argument (0 = no cap).
	honorWindow bool
	maxRows     int
	filters     []map[string]any
}

func (m *firewallMock) window(filter map[string]any) []map[string]any {
	if !m.honorWindow {
		return m.events
	}
	geq, _ := time.Parse(time.RFC3339, filter["datetime_geq"].(string))
	lt, _ := time.Parse(time.RFC3339, filter["datetime_lt"].(string))
	var rows []map[string]any
	for _, e := range m.events {
		ts, _ := time.Parse(time.RFC3339, e["datetime"].(string))
		if !ts.Before(geq) && ts.Before(lt) {
			rows = append(rows, e)
		}
	}
	if m.maxRows > 0 && len(rows) > m.maxRows {
		rows = rows[:m.maxRows]
	}
	return rows
}

func (m *firewallMock) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	m.t.Helper()
	w.Header().Set("Content-Type", "application/json")
	switch r.URL.Path {
	case "/graphql":
		m.graphqlCalls++
		var req struct {
			Variables map[string]any `json:"variables"`
		}
		decodeBody(m.t, r, &req)
		filter, _ := req.Variables["filter"].(map[string]any)
		m.filters = append(m.filters, filter)
		if m.rejectActionFilter && filter["action"] != nil {
			_ = json.NewEncoder(w).Encode(map[string]any{
				"data":   nil,
				"errors": []map[string]any{{"message": "unknown field action on filter"}},
			})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"data": map[string]any{
				"viewer": map[string]any{
					"zones": []map[string]any{{"firewallEventsAdaptive": m.window(filter)}},
				},
			},
			"errors": nil,
		})
	case "/loki/api/v1/push":
		var body map[string]any
		decodeBody(m.t, r, &body)
		m.lokiBodies = append(m.lokiBodies, body)
		w.WriteHeader(http.StatusNoContent)
	default:
		m.t.Fatalf("unexpected path %s", r.URL.Path)
	}
}

func blockEvent(ip string, ts time.Time) map[string]any {
	return map[string]any{"action": "block", "source": "firewallCustom", "clientIP": ip, "clientAsn": "64500",
		"clientCountryName": "NL", "clientRequestPath": "/wp-login.php", "clientRequestHTTPHost": "www.jokelab.dev",
		"userAgent": "curl/8", "ruleId": "", "datetime": ts.Format(time.RFC3339)}
}

type lokiEntry struct{ stream, ts, line string }

// lokiEntries flattens every pushed (stream, timestamp, line) of the mock.
func lokiEntries(t *testing.T, m *firewallMock) []lokiEntry {
	t.Helper()
	var out []lokiEntry
	for _, body := range m.lokiBodies {
		streams, _ := body["streams"].([]any)
		for _, s := range streams {
			stream, _ := s.(map[string]any)
			labels, _ := json.Marshal(stream["stream"])
			values, _ := stream["values"].([]any)
			for _, v := range values {
				pair, _ := v.([]any)
				out = append(out, lokiEntry{string(labels), pair[0].(string), pair[1].(string)})
			}
		}
	}
	return out
}

// lokiCountSum adds up the pushed counts and reports how many entries repeat
// an earlier (stream, timestamp, line) triple, which Loki silently drops.
func lokiCountSum(t *testing.T, m *firewallMock) (sum int, duplicates int) {
	t.Helper()
	seen := map[lokiEntry]bool{}
	for _, e := range lokiEntries(t, m) {
		if seen[e] {
			duplicates++
		}
		seen[e] = true
		var parsed firewallLogLine
		if err := json.Unmarshal([]byte(e.line), &parsed); err != nil {
			t.Fatalf("bad line %q: %v", e.line, err)
		}
		sum += parsed.Count
	}
	return sum, duplicates
}

func TestFirewallWindowsAreWholeMinutes(t *testing.T) {
	now := time.Date(2026, 10, 20, 10, 7, 25, 0, time.UTC)
	mock := &firewallMock{t: t, honorWindow: true}
	srv := httptest.NewServer(mock)
	defer srv.Close()

	client := firewallTestClient(t, srv)
	client.now = func() time.Time { return now }
	// A lookback and max window that are not whole minutes must still produce
	// whole-minute edges.
	client.lookback = 5*time.Minute + 20*time.Second
	client.maxWindow = 10 * time.Minute

	// First poll after a start: no lastWindowEnd yet.
	if err := client.pollOnce(context.Background()); err != nil {
		t.Fatalf("poll failed: %v", err)
	}
	// Second poll far later: the backlog is cut to maxWindow.
	client.maxWindow = 2*time.Minute + 30*time.Second
	now = now.Add(20 * time.Minute)
	if err := client.pollOnce(context.Background()); err != nil {
		t.Fatalf("poll failed: %v", err)
	}
	if len(mock.filters) != 2 {
		t.Fatalf("want 2 queries, got %d", len(mock.filters))
	}
	for i, f := range mock.filters {
		for _, k := range []string{"datetime_geq", "datetime_lt"} {
			ts, err := time.Parse(time.RFC3339, f[k].(string))
			if err != nil {
				t.Fatalf("query %d %s: %v", i, k, err)
			}
			if ts.Second() != 0 || ts.Nanosecond() != 0 {
				t.Errorf("query %d %s = %s is not a whole minute", i, k, f[k])
			}
		}
	}
	if got, want := mock.filters[0]["datetime_lt"], "2026-10-20T10:07:00Z"; got != want {
		t.Errorf("first window end = %v, want %v", got, want)
	}
	if got, want := mock.filters[0]["datetime_geq"], "2026-10-20T10:01:00Z"; got != want {
		t.Errorf("first window start = %v, want %v", got, want)
	}
	if got, want := mock.filters[1]["datetime_geq"], "2026-10-20T10:24:00Z"; got != want {
		t.Errorf("cut window start = %v, want %v", got, want)
	}
	if client.lastWindowEnd.Second() != 0 {
		t.Errorf("lastWindowEnd %s is not a whole minute", client.lastWindowEnd)
	}
}

// A minute that straddles two polls used to be pushed twice with the same
// timestamp; when both halves had the same count Loki dropped one of the two
// identical lines and the blocks of a steady client were undercounted.
func TestFirewallSplitMinuteIsNotPushedTwice(t *testing.T) {
	now := time.Date(2026, 10, 20, 10, 5, 25, 0, time.UTC)
	mock := &firewallMock{t: t, honorWindow: true}
	// A steady bot blocks at :10 and :40 of every minute, so the halves of a
	// minute split at second 25 are identical lines (count 1 each).
	total := 0
	for ts := time.Date(2026, 10, 20, 10, 0, 10, 0, time.UTC); ts.Before(time.Date(2026, 10, 20, 10, 12, 0, 0, time.UTC)); ts = ts.Add(30 * time.Second) {
		mock.events = append(mock.events, blockEvent("203.0.113.5", ts))
		total++
	}
	srv := httptest.NewServer(mock)
	defer srv.Close()

	client := firewallTestClient(t, srv)
	client.now = func() time.Time { return now }
	client.lastWindowEnd = time.Date(2026, 10, 20, 10, 0, 0, 0, time.UTC)
	for i := 0; i < 2; i++ {
		if err := client.pollOnce(context.Background()); err != nil {
			t.Fatalf("poll %d failed: %v", i, err)
		}
		now = now.Add(5 * time.Minute)
	}
	// Polls ran at 10:05:25 and 10:10:25 -> windows [10:00,10:05) and [10:05,10:10);
	// the second poll's data stops at the minute boundary 10:10:00.
	got, dup := lokiCountSum(t, mock)
	if dup != 0 {
		t.Fatalf("%d identical (stream, timestamp, line) pushes would be dropped by Loki", dup)
	}
	want := 0
	for _, e := range mock.events {
		ts, _ := time.Parse(time.RFC3339, e["datetime"].(string))
		if ts.Before(time.Date(2026, 10, 20, 10, 10, 0, 0, time.UTC)) {
			want++
		}
	}
	if got != want {
		t.Fatalf("pushed counts sum to %d, want %d of %d events", got, want, total)
	}
}

func TestFirewallTruncatedWindowIsCounted(t *testing.T) {
	now := time.Date(2026, 10, 20, 10, 7, 25, 0, time.UTC)
	mock := &firewallMock{t: t, honorWindow: true, maxRows: 3}
	for i := 0; i < 5; i++ {
		mock.events = append(mock.events, blockEvent("203.0.113.5", time.Date(2026, 10, 20, 10, 3, i*10, 0, time.UTC)))
	}
	srv := httptest.NewServer(mock)
	defer srv.Close()

	client := firewallTestClient(t, srv)
	client.now = func() time.Time { return now }
	client.limit = 3
	client.lastWindowEnd = time.Date(2026, 10, 20, 10, 2, 0, 0, time.UTC)

	before := counterValue(t, metricFirewallTruncatedWindows)
	if err := client.pollOnce(context.Background()); err != nil {
		t.Fatalf("poll failed: %v", err)
	}
	if got := counterValue(t, metricFirewallTruncatedWindows) - before; got != 1 {
		t.Fatalf("truncated windows incremented by %v, want 1", got)
	}

	// A window below the limit is not counted.
	now = now.Add(5 * time.Minute)
	mock.events = nil
	before = counterValue(t, metricFirewallTruncatedWindows)
	if err := client.pollOnce(context.Background()); err != nil {
		t.Fatalf("poll failed: %v", err)
	}
	if got := counterValue(t, metricFirewallTruncatedWindows) - before; got != 0 {
		t.Fatalf("complete window counted as truncated (+%v)", got)
	}
}

func counterValue(t *testing.T, c prometheus.Counter) float64 {
	t.Helper()
	m := &dto.Metric{}
	if err := c.Write(m); err != nil {
		t.Fatal(err)
	}
	return m.GetCounter().GetValue()
}
