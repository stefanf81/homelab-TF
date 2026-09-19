package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"
)

type cfMock struct {
	t *testing.T

	listID           string
	items            []string
	entryPointExists bool
	rules            []map[string]any

	listCreates    int
	itemPuts       int
	itemPutBodies  [][]map[string]any
	rulesetCreates []map[string]any
	ruleCreates    []map[string]any
	rulePatches    []map[string]any
	bulkPolls      int
}

func (m *cfMock) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	m.t.Helper()
	writeJSON := func(v any) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"success": true, "result": v})
	}

	switch {
	case r.Method == http.MethodGet && r.URL.Path == "/accounts/acc/rules/lists":
		if m.listID == "" {
			writeJSON([]any{})
			return
		}
		writeJSON([]map[string]any{{"id": m.listID, "name": "abuseipdb", "kind": "ip"}})
	case r.Method == http.MethodPost && r.URL.Path == "/accounts/acc/rules/lists":
		m.listCreates++
		m.listID = "list-1"
		writeJSON(map[string]any{"id": m.listID, "name": "abuseipdb", "kind": "ip"})
	case r.Method == http.MethodGet && r.URL.Path == "/accounts/acc/rules/lists/list-1/items":
		items := make([]map[string]string, 0, len(m.items))
		for _, ip := range m.items {
			items = append(items, map[string]string{"id": ip, "ip": ip})
		}
		writeJSON(items)
	case r.Method == http.MethodPut && r.URL.Path == "/accounts/acc/rules/lists/list-1/items":
		m.itemPuts++
		var body []map[string]any
		decodeBody(m.t, r, &body)
		m.itemPutBodies = append(m.itemPutBodies, body)
		m.items = m.items[:0]
		for _, obj := range body {
			if ip, ok := obj["ip"].(string); ok {
				m.items = append(m.items, ip)
			}
		}
		writeJSON(map[string]string{"operation_id": "op-1"})
	case r.Method == http.MethodGet && r.URL.Path == "/accounts/acc/rules/lists/bulk_operations/op-1":
		m.bulkPolls++
		writeJSON(map[string]string{"id": "op-1", "status": "completed"})
	case r.Method == http.MethodGet && r.URL.Path == "/zones/zone/rulesets/phases/http_request_firewall_custom/entrypoint":
		if !m.entryPointExists {
			w.WriteHeader(http.StatusNotFound)
			_ = json.NewEncoder(w).Encode(map[string]any{"success": false, "errors": []map[string]any{{"code": 10000, "message": "not found"}}})
			return
		}
		writeJSON(map[string]any{"id": "rs-1", "name": "entry", "kind": "root", "phase": "http_request_firewall_custom", "rules": m.rules})
	case r.Method == http.MethodPost && r.URL.Path == "/zones/zone/rulesets":
		var body map[string]any
		decodeBody(m.t, r, &body)
		m.rulesetCreates = append(m.rulesetCreates, body)
		m.entryPointExists = true
		if raw, ok := body["rules"].([]any); ok {
			for _, rule := range raw {
				if obj, ok := rule.(map[string]any); ok {
					m.rules = append(m.rules, obj)
					m.ruleCreates = append(m.ruleCreates, obj)
				}
			}
		}
		writeJSON(map[string]any{"id": "rs-1", "rules": m.rules})
	case r.Method == http.MethodPost && r.URL.Path == "/zones/zone/rulesets/rs-1/rules":
		var body map[string]any
		decodeBody(m.t, r, &body)
		body["id"] = "rule-2"
		m.rules = append(m.rules, body)
		m.ruleCreates = append(m.ruleCreates, body)
		writeJSON(body)
	case r.Method == http.MethodPatch && strings.HasPrefix(r.URL.Path, "/zones/zone/rulesets/rs-1/rules/"):
		var body map[string]any
		decodeBody(m.t, r, &body)
		body["id"] = "rule-1"
		m.rules = []map[string]any{body}
		m.rulePatches = append(m.rulePatches, body)
		writeJSON(body)
	default:
		m.t.Fatalf("unexpected request: %s %s", r.Method, r.URL.Path)
	}
}

func decodeBody(t *testing.T, r *http.Request, out any) {
	t.Helper()
	data, err := io.ReadAll(r.Body)
	if err != nil {
		t.Fatalf("reading request body: %v", err)
	}
	if err := json.Unmarshal(data, out); err != nil {
		t.Fatalf("decoding request body %q: %v", data, err)
	}
}

func testCloudflareClient(t *testing.T, srv *httptest.Server, maxEntries int) *CloudflareClient {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	return &CloudflareClient{
		baseURL:    srv.URL,
		token:      "test-token",
		accountID:  "acc",
		zoneID:     "zone",
		listName:   "abuseipdb",
		maxEntries: maxEntries,
		ruleRef:    "abuseipdb",
		http:       srv.Client(),
		log:        logger,
	}
}

func mustPrefixes(t *testing.T, raw string) []netip.Prefix {
	t.Helper()
	prefixes, err := ParseFilterList([]byte(raw))
	if err != nil {
		t.Fatalf("parsing prefixes: %v", err)
	}
	return SortDedup(prefixes)
}

func TestCloudflareSyncCreatesListAndRule(t *testing.T) {
	mock := &cfMock{t: t}
	srv := httptest.NewServer(mock)
	defer srv.Close()

	client := testCloudflareClient(t, srv, 10000)
	desired := mustPrefixes(t, "192.0.2.10\n198.51.100.0/24\n")

	entries, changed, err := client.Sync(context.Background(), desired)
	if err != nil {
		t.Fatalf("sync failed: %v", err)
	}
	if entries != 2 || !changed {
		t.Fatalf("want entries=2 changed=true, got entries=%d changed=%v", entries, changed)
	}
	if mock.listCreates != 1 {
		t.Fatalf("want 1 list create, got %d", mock.listCreates)
	}
	if mock.itemPuts != 1 || len(mock.itemPutBodies) != 1 {
		t.Fatalf("want 1 item PUT, got %d", mock.itemPuts)
	}
	if len(mock.ruleCreates) != 1 {
		t.Fatalf("want 1 rule create, got %d", len(mock.ruleCreates))
	}
	if len(mock.rulesetCreates) != 1 || mock.rulesetCreates[0]["kind"] != "zone" {
		t.Fatalf("entry point must be created with kind=zone: %v", mock.rulesetCreates)
	}
	rule := mock.ruleCreates[0]
	if rule["action"] != "block" || rule["expression"] != "ip.src in $abuseipdb" || rule["ref"] != "abuseipdb" {
		t.Fatalf("unexpected rule body: %v", rule)
	}
	if mock.bulkPolls == 0 {
		t.Fatal("expected bulk operation polling")
	}

	// Second sync with the same list must be a no-op.
	_, changed, err = client.Sync(context.Background(), desired)
	if err != nil {
		t.Fatalf("second sync failed: %v", err)
	}
	if changed || mock.itemPuts != 1 || len(mock.rulePatches) != 0 || len(mock.ruleCreates) != 1 {
		t.Fatalf("expected no-op second sync, changed=%v puts=%d patches=%d creates=%d",
			changed, mock.itemPuts, len(mock.rulePatches), len(mock.ruleCreates))
	}

	// A changed list triggers one replacement.
	updated := mustPrefixes(t, "192.0.2.10\n8.8.8.8\n")
	_, changed, err = client.Sync(context.Background(), updated)
	if err != nil {
		t.Fatalf("third sync failed: %v", err)
	}
	if !changed || mock.itemPuts != 2 {
		t.Fatalf("want replacement, changed=%v puts=%d", changed, mock.itemPuts)
	}
}

func TestCloudflareSyncEmptyListClearsItems(t *testing.T) {
	mock := &cfMock{t: t, listID: "list-1", items: []string{"192.0.2.10/32"}, entryPointExists: true,
		rules: []map[string]any{{"id": "rule-1", "ref": "abuseipdb", "action": "block", "expression": "ip.src in $abuseipdb", "enabled": true}}}
	srv := httptest.NewServer(mock)
	defer srv.Close()

	client := testCloudflareClient(t, srv, 10000)
	if _, _, err := client.Sync(context.Background(), nil); err != nil {
		t.Fatalf("sync failed: %v", err)
	}
	if mock.itemPuts != 1 || len(mock.items) != 0 {
		t.Fatalf("expected empty replacement, puts=%d items=%v", mock.itemPuts, mock.items)
	}
}

func TestCloudflareEnsureRuleDriftPatches(t *testing.T) {
	mock := &cfMock{t: t, listID: "list-1", items: []string{}, entryPointExists: true,
		rules: []map[string]any{{"id": "rule-1", "ref": "abuseipdb", "action": "challenge", "expression": "ip.src in $abuseipdb", "enabled": true}}}
	srv := httptest.NewServer(mock)
	defer srv.Close()

	client := testCloudflareClient(t, srv, 10000)
	if _, _, err := client.Sync(context.Background(), nil); err != nil {
		t.Fatalf("sync failed: %v", err)
	}
	if len(mock.rulePatches) != 1 {
		t.Fatalf("want 1 rule patch, got %d", len(mock.rulePatches))
	}
	if mock.rulePatches[0]["action"] != "block" {
		t.Fatalf("patched rule should block: %v", mock.rulePatches[0])
	}
}

func TestCloudflareEnsureRuleExistingCorrectIsNoop(t *testing.T) {
	mock := &cfMock{t: t, listID: "list-1", entryPointExists: true,
		rules: []map[string]any{{"id": "rule-1", "ref": "abuseipdb", "action": "block", "expression": "ip.src in $abuseipdb", "enabled": true}}}
	srv := httptest.NewServer(mock)
	defer srv.Close()

	client := testCloudflareClient(t, srv, 10000)
	if _, _, err := client.Sync(context.Background(), nil); err != nil {
		t.Fatalf("sync failed: %v", err)
	}
	if len(mock.rulePatches) != 0 || len(mock.ruleCreates) != 0 {
		t.Fatalf("expected no rule changes, patches=%d creates=%d", len(mock.rulePatches), len(mock.ruleCreates))
	}
}

func TestCloudflareListItemsCursorPagination(t *testing.T) {
	const total = 250
	items := make([]string, 0, total)
	for i := 0; i < total; i++ {
		items = append(items, fmt.Sprintf("10.0.%d.%d/32", i/250, i%250))
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/accounts/acc/rules/lists/list-1/items" {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		first := 0
		nextCursor := "c1"
		switch cursor := r.URL.Query().Get("cursor"); cursor {
		case "":
			if page := r.URL.Query().Get("page"); page != "1" {
				t.Fatalf("unexpected page %q", page)
			}
		case "c1":
			first = 100
			nextCursor = "c2"
		case "c2":
			first = 200
			nextCursor = ""
		default:
			t.Fatalf("unexpected cursor %q", cursor)
		}
		end := first + 100
		if end > len(items) {
			end = len(items)
		}
		type item struct {
			IP string `json:"ip"`
		}
		resp := make([]item, 0, end-first)
		for _, ip := range items[first:end] {
			resp = append(resp, item{IP: ip})
		}
		resultInfo := map[string]any{}
		if nextCursor != "" {
			resultInfo["cursors"] = map[string]string{"after": nextCursor}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"success": true, "result": resp, "result_info": resultInfo})
	}))
	defer srv.Close()

	client := testCloudflareClient(t, srv, 10000)
	got, err := client.ListItems(context.Background(), "list-1")
	if err != nil {
		t.Fatalf("ListItems failed: %v", err)
	}
	if len(got) != total {
		t.Fatalf("want %d items across cursor pages, got %d", total, len(got))
	}
}

func TestCloudflareMaxEntriesRejected(t *testing.T) {
	mock := &cfMock{t: t, listID: "list-1"}
	srv := httptest.NewServer(mock)
	defer srv.Close()

	client := testCloudflareClient(t, srv, 1)
	_, _, err := client.Sync(context.Background(), mustPrefixes(t, "8.8.8.8\n9.9.9.9\n"))
	if err == nil || cfErrorReason(err) != "validation" {
		t.Fatalf("want validation error, got %v", err)
	}
	if mock.itemPuts != 0 {
		t.Fatalf("no items should be pushed, got %d PUTs", mock.itemPuts)
	}
}
