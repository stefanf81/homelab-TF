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
					"zones": []map[string]any{{"firewallEventsAdaptive": m.events}},
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
