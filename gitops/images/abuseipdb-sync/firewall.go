package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"sort"
	"strings"
	"time"
)

const firewallLokiBatchLimit = 5000

// cfFirewallEvent is one row of the Cloudflare Security Events dataset
// (firewallEventsAdaptive).
type cfFirewallEvent struct {
	Action    string `json:"action"`
	Source    string `json:"source"`
	ClientIP  string `json:"clientIP"`
	ClientASN int    `json:"clientAsn"`
	Country   string `json:"clientCountryName"`
	Path      string `json:"clientRequestPath"`
	Host      string `json:"clientRequestHTTPHost"`
	UserAgent string `json:"userAgent"`
	RuleID    string `json:"ruleId"`
	Datetime  string `json:"datetime"`
}

// FirewallCollector polls Cloudflare Security Events and ships blocked
// requests to Loki so Grafana can show the blocked client IPs. Only bounded
// labels are used; client IPs stay in the log body.
type FirewallCollector struct {
	zoneID    string
	token     string
	baseURL   string
	lokiURL   string
	interval  time.Duration
	lookback  time.Duration
	maxWindow time.Duration
	limit     int
	http      *http.Client
	log       *slog.Logger

	lastWindowEnd time.Time
}

func NewFirewallCollector(cfg *Config, httpClient *http.Client, log *slog.Logger) *FirewallCollector {
	return &FirewallCollector{
		zoneID:    cfg.CloudflareZoneID,
		token:     cfg.CloudflareAPIToken,
		baseURL:   strings.TrimRight(envString("CLOUDFLARE_API_BASE", defaultCloudflareAPIBase), "/"),
		lokiURL:   cfg.LokiPushURL,
		interval:  cfg.FirewallPollInterval,
		lookback:  cfg.FirewallLookback,
		maxWindow: cfg.FirewallMaxWindow,
		limit:     cfg.FirewallLimit,
		http:      httpClient,
		log:       log,
	}
}

// Run polls immediately and then on the configured interval. Windows are
// non-overlapping: lastWindowEnd only advances after a successful fetch and
// Loki push, so a failure is retried (and covered) by the next poll.
func (c *FirewallCollector) Run(ctx context.Context) {
	if c.lastWindowEnd.IsZero() {
		c.lastWindowEnd = time.Now().UTC().Add(-c.lookback)
	}
	c.pollWithLogging(ctx)
	ticker := time.NewTicker(c.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			c.pollWithLogging(ctx)
		}
	}
}

func (c *FirewallCollector) pollWithLogging(ctx context.Context) {
	if err := c.pollOnce(ctx); err != nil {
		reason := firewallErrorReason(err)
		metricFirewallCollectorSuccess.Set(0)
		metricFirewallCollectorErrors.WithLabelValues(reason).Inc()
		c.log.Error("cloudflare firewall event collection failed", "error", err, "reason", reason)
	}
}

func (c *FirewallCollector) pollOnce(ctx context.Context) error {
	end := time.Now().UTC()
	start := c.lastWindowEnd
	if start.IsZero() {
		start = end.Add(-c.lookback)
	}
	if end.Sub(start) > c.maxWindow {
		c.log.Warn("firewall event window truncated",
			"requested", end.Sub(start).String(), "max", c.maxWindow.String())
		start = end.Add(-c.maxWindow)
	}
	if !end.After(start) {
		return nil
	}

	events, err := c.fetchEvents(ctx, start, end)
	if err != nil {
		return err
	}
	groups := aggregateFirewallEvents(events)
	if err := c.pushToLoki(ctx, groups); err != nil {
		return err
	}

	c.lastWindowEnd = end
	metricFirewallCollectorSuccess.Set(1)
	metricFirewallLastSuccess.Set(float64(end.Unix()))
	metricFirewallLastWindowEvents.Set(float64(len(events)))
	for _, g := range groups {
		metricFirewallEvents.WithLabelValues(g.Action, g.Source).Add(float64(g.Count))
	}
	c.log.Info("cloudflare firewall events collected",
		"events", len(events),
		"groups", len(groups),
		"window_start", start.Format(time.RFC3339),
		"window_end", end.Format(time.RFC3339))
	return nil
}

func (c *FirewallCollector) fetchEvents(ctx context.Context, start, end time.Time) ([]cfFirewallEvent, error) {
	query := fmt.Sprintf(`query FirewallEvents($zoneTag: string!, $filter: FirewallEventsAdaptiveFilter_InputObject!) {
  viewer {
    zones(filter: { zoneTag: $zoneTag }) {
      firewallEventsAdaptive(filter: $filter, limit: %d, orderBy: [datetime_ASC]) {
        action
        source
        clientIP
        clientAsn
        clientCountryName
        clientRequestPath
        clientRequestHTTPHost
        userAgent
        ruleId
        datetime
      }
    }
  }
}`, c.limit)

	filter := map[string]any{
		"datetime_geq": start.Format(time.RFC3339),
		"datetime_lt":  end.Format(time.RFC3339),
		"action":       "block",
	}

	events, err := c.doGraphQL(ctx, query, filter)
	if err != nil && isGraphQLFilterError(err) {
		// Some plans/datasets reject the action filter; fetch everything in the
		// window and filter client-side instead.
		c.log.Warn("action filter rejected by Cloudflare GraphQL, retrying without it", "error", err)
		delete(filter, "action")
		events, err = c.doGraphQL(ctx, query, filter)
	}
	if err != nil {
		return nil, err
	}

	blocked := make([]cfFirewallEvent, 0, len(events))
	for _, e := range events {
		if e.Action == "block" {
			blocked = append(blocked, e)
		}
	}
	return blocked, nil
}

func (c *FirewallCollector) doGraphQL(ctx context.Context, query string, filter map[string]any) ([]cfFirewallEvent, error) {
	payload, err := json.Marshal(map[string]any{
		"query": query,
		"variables": map[string]any{
			"zoneTag": c.zoneID,
			"filter":  filter,
		},
	})
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/graphql", bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "abuseipdb-sync/"+version)

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, cloudflareMaxResponse))
	if err != nil {
		return nil, err
	}

	var parsed struct {
		Data struct {
			Viewer struct {
				Zones []struct {
					FirewallEventsAdaptive []cfFirewallEvent `json:"firewallEventsAdaptive"`
				} `json:"zones"`
			} `json:"viewer"`
		} `json:"data"`
		Errors []struct {
			Message string `json:"message"`
		} `json:"errors"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return nil, &cloudflareError{status: resp.StatusCode, message: fmt.Sprintf("invalid GraphQL response: %.200s", strings.TrimSpace(string(body)))}
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		msg := ""
		if len(parsed.Errors) > 0 {
			msg = parsed.Errors[0].Message
		}
		return nil, &cloudflareError{status: resp.StatusCode, message: msg}
	}
	if len(parsed.Errors) > 0 {
		return nil, &cloudflareGraphQLError{message: parsed.Errors[0].Message}
	}
	if len(parsed.Data.Viewer.Zones) == 0 {
		return nil, nil
	}
	return parsed.Data.Viewer.Zones[0].FirewallEventsAdaptive, nil
}

type cloudflareGraphQLError struct{ message string }

func (e *cloudflareGraphQLError) Error() string { return "Cloudflare GraphQL error: " + e.message }

// isGraphQLFilterError reports whether the error looks like a rejected filter
// field rather than an auth/transport problem.
func isGraphQLFilterError(err error) bool {
	var gqlErr *cloudflareGraphQLError
	if !errors.As(err, &gqlErr) {
		return false
	}
	msg := strings.ToLower(gqlErr.message)
	return strings.Contains(msg, "unknown") || strings.Contains(msg, "invalid") || strings.Contains(msg, "filter")
}

func firewallErrorReason(err error) string {
	if err == nil {
		return ""
	}
	var gqlErr *cloudflareGraphQLError
	if errors.As(err, &gqlErr) {
		if strings.Contains(strings.ToLower(gqlErr.message), "permission") {
			return "authz"
		}
		return "graphql"
	}
	var ce *cloudflareError
	if errors.As(err, &ce) {
		if ce.status == http.StatusTooManyRequests {
			return "rate_limited"
		}
		return "http"
	}
	var le *lokiError
	if errors.As(err, &le) {
		return "loki"
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		return "timeout"
	}
	return "network"
}

type firewallGroup struct {
	Minute    time.Time
	Action    string
	Source    string
	ClientIP  string
	RuleID    string
	Host      string
	Path      string
	UserAgent string
	ASN       int
	Country   string
	Count     int
}

// aggregateFirewallEvents collapses events into per-minute groups keyed by
// client IP, action, rule source and host. Path and user agent are sampled
// from the first event of the group.
func aggregateFirewallEvents(events []cfFirewallEvent) []firewallGroup {
	index := map[string]*firewallGroup{}
	for _, e := range events {
		ts, err := time.Parse(time.RFC3339, e.Datetime)
		if err != nil {
			continue
		}
		minute := ts.UTC().Truncate(time.Minute)
		key := strings.Join([]string{
			e.ClientIP, e.Action, e.Source, e.RuleID, e.Host, minute.Format(time.RFC3339),
		}, "|")
		if g, ok := index[key]; ok {
			g.Count++
			continue
		}
		index[key] = &firewallGroup{
			Minute:    minute,
			Action:    e.Action,
			Source:    e.Source,
			ClientIP:  e.ClientIP,
			RuleID:    e.RuleID,
			Host:      e.Host,
			Path:      e.Path,
			UserAgent: e.UserAgent,
			ASN:       e.ClientASN,
			Country:   e.Country,
			Count:     1,
		}
	}
	groups := make([]firewallGroup, 0, len(index))
	for _, g := range index {
		groups = append(groups, *g)
	}
	sort.Slice(groups, func(i, j int) bool {
		if !groups[i].Minute.Equal(groups[j].Minute) {
			return groups[i].Minute.Before(groups[j].Minute)
		}
		return groups[i].ClientIP < groups[j].ClientIP
	})
	return groups
}

type lokiError struct {
	status int
	body   string
}

func (e *lokiError) Error() string {
	return fmt.Sprintf("Loki push failed with status %d: %s", e.status, e.body)
}

type firewallLogLine struct {
	ClientIP  string `json:"client_ip"`
	Action    string `json:"action"`
	Source    string `json:"source"`
	RuleID    string `json:"rule_id,omitempty"`
	Host      string `json:"host,omitempty"`
	Path      string `json:"path,omitempty"`
	UserAgent string `json:"user_agent,omitempty"`
	ASN       int    `json:"asn,omitempty"`
	Country   string `json:"country,omitempty"`
	Count     int    `json:"count"`
}

func (c *FirewallCollector) pushToLoki(ctx context.Context, groups []firewallGroup) error {
	if len(groups) == 0 {
		return nil
	}
	if len(groups) > firewallLokiBatchLimit {
		c.log.Warn("truncating firewall event batch for Loki",
			"groups", len(groups), "limit", firewallLokiBatchLimit)
		groups = groups[:firewallLokiBatchLimit]
	}

	type stream struct {
		labels map[string]string
		values [][2]string
	}
	streams := map[string]*stream{}
	for _, g := range groups {
		labels := map[string]string{
			"job":    "cloudflare-firewall",
			"action": g.Action,
			"source": g.Source,
		}
		key := g.Action + "|" + g.Source
		s, ok := streams[key]
		if !ok {
			s = &stream{labels: labels}
			streams[key] = s
		}
		line, err := json.Marshal(firewallLogLine{
			ClientIP:  g.ClientIP,
			Action:    g.Action,
			Source:    g.Source,
			RuleID:    g.RuleID,
			Host:      g.Host,
			Path:      g.Path,
			UserAgent: g.UserAgent,
			ASN:       g.ASN,
			Country:   g.Country,
			Count:     g.Count,
		})
		if err != nil {
			return err
		}
		ts := fmt.Sprintf("%d", g.Minute.UnixNano())
		s.values = append(s.values, [2]string{ts, string(line)})
	}

	type lokiStream struct {
		Stream map[string]string `json:"stream"`
		Values [][2]string       `json:"values"`
	}
	payload := struct {
		Streams []lokiStream `json:"streams"`
	}{}
	// Deterministic order for stable payloads.
	keys := make([]string, 0, len(streams))
	for k := range streams {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		payload.Streams = append(payload.Streams, lokiStream{Stream: streams[k].labels, Values: streams[k].values})
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.lokiURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return &lokiError{status: resp.StatusCode, body: strings.TrimSpace(string(respBody))}
	}
	return nil
}
