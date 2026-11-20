package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
)

func discardLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

// --- AbuseIPDB feed retries -------------------------------------------------

func TestFetchDoesNotRetryUnusableBody(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"errors":[{"detail":"maintenance"}]}`))
	}))
	defer srv.Close()

	feed := &FeedClient{apiKey: "k", limit: 10, http: srv.Client(), log: discardLogger(), endpoint: srv.URL, retryBase: time.Millisecond}
	_, status, err := feed.Fetch(context.Background())
	if err == nil {
		t.Fatal("expected an error for a JSON body")
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("unusable body was requested %d times, want 1 (each call spends daily quota)", got)
	}
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200", status)
	}
	if got := errorReason(err); got != "parse" {
		t.Fatalf("errorReason = %q, want parse", got)
	}
}

// A body that breaks off after AbuseIPDB answered 200 was already counted
// against the daily quota: it must not be retried in-process.
func TestFetchDoesNotRetryBodyCutOffAfter200(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Content-Length", "1000")
		_, _ = w.Write([]byte("198.51.100.7\n")) // short write: the server drops the connection
	}))
	defer srv.Close()

	feed := &FeedClient{apiKey: "k", limit: 10, http: srv.Client(), log: discardLogger(), endpoint: srv.URL, retryBase: time.Millisecond}
	_, status, err := feed.Fetch(context.Background())
	if err == nil {
		t.Fatal("expected an error for a truncated body")
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("truncated 200 was requested %d times, want 1 (each call spends daily quota)", got)
	}
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200", status)
	}
	if got := errorReason(err); got != "network" {
		t.Fatalf("errorReason = %q, want network", got)
	}
}

func TestFetchDoesNotRetryBodyTimeoutAfter200(t *testing.T) {
	var calls atomic.Int32
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("198.51.100.7\n"))
		w.(http.Flusher).Flush()
		select { // stall the rest of the body past the client timeout
		case <-release:
		case <-r.Context().Done():
		}
	}))
	defer srv.Close()
	defer close(release)

	client := srv.Client()
	client.Timeout = 200 * time.Millisecond
	feed := &FeedClient{apiKey: "k", limit: 10, http: client, log: discardLogger(), endpoint: srv.URL, retryBase: time.Millisecond}
	_, _, err := feed.Fetch(context.Background())
	if err == nil {
		t.Fatal("expected a timeout reading the body")
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("stalled 200 was requested %d times, want 1", got)
	}
	if got := errorReason(err); got != "timeout" {
		t.Fatalf("errorReason = %q, want timeout (err: %v)", got, err)
	}
}

// A 5xx is retried whether or not its body arrives intact.
func TestFetchRetriesServerErrorWithBrokenBody(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if calls.Add(1) == 1 {
			w.Header().Set("Content-Length", "1000")
			w.WriteHeader(http.StatusBadGateway)
			_, _ = w.Write([]byte("bad gateway"))
			return
		}
		w.Header().Set("Content-Type", "text/plain")
		_, _ = w.Write([]byte("198.51.100.7\n"))
	}))
	defer srv.Close()

	feed := &FeedClient{apiKey: "k", limit: 10, http: srv.Client(), log: discardLogger(), endpoint: srv.URL, retryBase: time.Millisecond}
	if _, _, err := feed.Fetch(context.Background()); err != nil {
		t.Fatalf("Fetch: %v", err)
	}
	if got := calls.Load(); got != 2 {
		t.Fatalf("calls = %d, want 2 (the broken 502 is retried)", got)
	}
}

func TestFetchRetriesServerErrors(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if calls.Add(1) == 1 {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "text/plain")
		_, _ = w.Write([]byte("198.51.100.7\n"))
	}))
	defer srv.Close()

	feed := &FeedClient{apiKey: "k", limit: 10, http: srv.Client(), log: discardLogger(), endpoint: srv.URL, retryBase: time.Millisecond}
	body, _, err := feed.Fetch(context.Background())
	if err != nil {
		t.Fatalf("Fetch: %v", err)
	}
	if calls.Load() != 2 || strings.TrimSpace(string(body)) != "198.51.100.7" {
		t.Fatalf("calls=%d body=%q, want 2 calls and the second body", calls.Load(), body)
	}
}

func TestReadBoundedOverflowIsTyped(t *testing.T) {
	_, err := readBounded(strings.NewReader("12345"), 4)
	var tooLarge *responseTooLargeError
	if err == nil || !errors.As(err, &tooLarge) {
		t.Fatalf("want *responseTooLargeError, got %v", err)
	}
}

// --- Cloudflare retries -----------------------------------------------------

func cfOK(w http.ResponseWriter, result any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"success": true, "result": result})
}

func cfFail(w http.ResponseWriter, status int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{"success": false, "errors": []map[string]any{{"code": 1, "message": "boom"}}})
}

func TestCloudflareRetriesTransientGet(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if calls.Add(1) == 1 {
			cfFail(w, http.StatusBadGateway)
			return
		}
		cfOK(w, []map[string]any{{"id": "list-1", "name": "abuseipdb", "kind": "ip"}})
	}))
	defer srv.Close()

	c := testCloudflareClient(t, srv, 0)
	id, err := c.EnsureList(context.Background())
	if err != nil || id != "list-1" {
		t.Fatalf("EnsureList = %q, %v; want list-1 after one retry", id, err)
	}
	if calls.Load() != 2 {
		t.Fatalf("calls = %d, want 2", calls.Load())
	}
}

func TestCloudflareDoesNotRetryPostOrClientErrors(t *testing.T) {
	var posts, gets atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			posts.Add(1)
			cfFail(w, http.StatusServiceUnavailable)
			return
		}
		gets.Add(1)
		cfOK(w, []any{}) // no list yet -> EnsureList creates one
	}))
	defer srv.Close()

	c := testCloudflareClient(t, srv, 0)
	if _, err := c.EnsureList(context.Background()); err == nil {
		t.Fatal("expected list creation to fail")
	}
	if posts.Load() != 1 {
		t.Fatalf("POST attempts = %d, want 1 (creation must not be repeated)", posts.Load())
	}

	var forbidden atomic.Int32
	srv403 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		forbidden.Add(1)
		cfFail(w, http.StatusForbidden)
	}))
	defer srv403.Close()
	if _, err := testCloudflareClient(t, srv403, 0).EnsureList(context.Background()); err == nil {
		t.Fatal("expected 403 to fail")
	}
	if forbidden.Load() != 1 {
		t.Fatalf("403 attempts = %d, want 1", forbidden.Load())
	}
}

// --- Stale fail-open clearing ----------------------------------------------

func TestClearBackoffSchedule(t *testing.T) {
	var b clearBackoff
	now := time.Unix(0, 0)
	want := []time.Duration{time.Minute, 2 * time.Minute, 4 * time.Minute, 8 * time.Minute, 16 * time.Minute, 30 * time.Minute, 30 * time.Minute}
	for i, w := range want {
		if got := b.failed(now); got != w {
			t.Fatalf("failure %d: delay %s, want %s", i+1, got, w)
		}
	}
	if b.ready(now.Add(29 * time.Minute)) {
		t.Fatal("ready before the backoff elapsed")
	}
	if !b.ready(now.Add(30 * time.Minute)) {
		t.Fatal("not ready after the backoff elapsed")
	}
	b.reset()
	if !b.ready(now) {
		t.Fatal("not ready after reset")
	}
}

func staleCloudflareApp(t *testing.T, srv *httptest.Server) *App {
	t.Helper()
	return &App{
		cfg: &Config{MaxStaleAge: 24 * time.Hour, StaleBehavior: staleBehaviorFailOpen},
		log: discardLogger(),
		cf:  testCloudflareClient(t, srv, 0),
		// Cloudflare sink stale; Cilium has no recorded success so its clear is skipped.
		cfLastSuccess: time.Now().Add(-25 * time.Hour),
	}
}

func TestStaleCloudflareClearBacksOffAfterFailure(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		cfFail(w, http.StatusInternalServerError)
	}))
	defer srv.Close()

	app := staleCloudflareApp(t, srv)
	ctx := context.Background()

	app.updateCloudflareStaleness(ctx)
	first := calls.Load()
	if first != cloudflareMaxAttempts {
		t.Fatalf("first clear made %d requests, want %d (one call, retried)", first, cloudflareMaxAttempts)
	}
	app.updateCloudflareStaleness(ctx)
	if calls.Load() != first {
		t.Fatalf("clear retried immediately (%d requests); want it held back by the backoff", calls.Load()-first)
	}
	app.mu.Lock()
	app.cfClearRetry.next = time.Now().Add(-time.Second)
	app.mu.Unlock()
	app.updateCloudflareStaleness(ctx)
	if calls.Load() != 2*first {
		t.Fatalf("clear was not retried once the backoff elapsed (requests=%d)", calls.Load())
	}
	if app.staleCFCleared {
		t.Fatal("staleCFCleared set although every clear failed")
	}
}

func TestStaleTickSkipsWhileSinkOperationRuns(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		switch {
		case r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "/rules/lists"):
			cfOK(w, []map[string]any{{"id": "list-1", "name": "abuseipdb", "kind": "ip"}})
		case r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "/items"):
			cfOK(w, []any{})
		default:
			cfOK(w, map[string]any{"id": "rs-1", "rules": []map[string]any{{"id": "r1", "ref": "abuseipdb", "action": "block", "expression": "ip.src in $abuseipdb", "enabled": true}}})
		}
	}))
	defer srv.Close()

	app := staleCloudflareApp(t, srv)
	ctx := context.Background()

	app.opMu.Lock() // a synchronization is in flight
	app.staleTick(ctx)
	if calls.Load() != 0 || app.staleCFCleared {
		t.Fatalf("stale tick touched the sink during a synchronization (requests=%d)", calls.Load())
	}
	app.opMu.Unlock()

	app.staleTick(ctx)
	if !app.staleCFCleared {
		t.Fatal("stale tick did not clear the stale sink once the synchronization finished")
	}
}

// --- Startup delay and shrink guard ----------------------------------------

func TestInitialSyncDelayUsesOlderSink(t *testing.T) {
	now := time.Date(2026, 11, 12, 12, 0, 0, 0, time.UTC)
	sample := mustPrefixes(t, "8.8.8.8/32")
	state := &GroupState{Exists: true, Prefixes: sample, LastSuccess: now.Add(-1 * time.Hour), CloudflareLastSuccess: now.Add(-20 * time.Hour)}
	if got := initialSyncDelay(now, state, 6*time.Hour, 1, true); got != 0 {
		t.Fatalf("Cloudflare 20h behind: want immediate sync, got %s", got)
	}
	state.CloudflareLastSuccess = now.Add(-2 * time.Hour)
	if got := initialSyncDelay(now, state, 6*time.Hour, 1, true); got != 4*time.Hour {
		t.Fatalf("older sink 2h: want 4h, got %s", got)
	}
	if got := initialSyncDelay(now, state, 6*time.Hour, 1, false); got != 5*time.Hour {
		t.Fatalf("Cloudflare disabled: want 5h from the Cilium sink, got %s", got)
	}
}

func TestCurrentListStale(t *testing.T) {
	now := time.Now()
	if currentListStale(time.Time{}, now, time.Hour) {
		t.Fatal("unknown last success must not count as stale")
	}
	if currentListStale(now.Add(-30*time.Minute), now, time.Hour) {
		t.Fatal("fresh list reported stale")
	}
	if !currentListStale(now.Add(-2*time.Hour), now, time.Hour) {
		t.Fatal("old list not reported stale")
	}
}

// fakeCCGServer serves the single CiliumCIDRGroup endpoint the synchronizer
// uses (get, create, update) so the real dynamic client can be exercised.
type fakeCCGServer struct {
	mu  sync.Mutex
	obj map[string]any
	rv  int
}

func (f *fakeCCGServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	notFound := func() {
		w.WriteHeader(http.StatusNotFound)
		_ = json.NewEncoder(w).Encode(map[string]any{"kind": "Status", "apiVersion": "v1", "status": "Failure", "reason": "NotFound", "code": 404})
	}
	switch r.Method {
	case http.MethodGet:
		if f.obj == nil {
			notFound()
			return
		}
		_ = json.NewEncoder(w).Encode(f.obj)
	case http.MethodPost, http.MethodPut:
		var obj map[string]any
		if err := json.NewDecoder(r.Body).Decode(&obj); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		f.rv++
		obj["metadata"].(map[string]any)["resourceVersion"] = fmt.Sprint(f.rv)
		f.obj = obj
		_ = json.NewEncoder(w).Encode(obj)
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func (f *fakeCCGServer) entries(t *testing.T) int {
	t.Helper()
	f.mu.Lock()
	defer f.mu.Unlock()
	u := &unstructured.Unstructured{Object: f.obj}
	cidrs, _, _ := unstructured.NestedStringSlice(u.Object, "spec", "externalCIDRs")
	return len(cidrs)
}

// shrinkScenario prepares a managed group of 200 entries whose last success
// was lastSuccessAge ago, and a feed that now returns 50 entries (a 75%
// shrink, above the 50% guard).
func shrinkScenario(t *testing.T, lastSuccessAge time.Duration) (*App, *fakeCCGServer, *atomic.Int32) {
	t.Helper()
	var feedCalls atomic.Int32
	var feedBody strings.Builder
	for i := 1; i <= 50; i++ {
		fmt.Fprintf(&feedBody, "45.33.32.%d\n", i)
	}
	feedSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		feedCalls.Add(1)
		w.Header().Set("Content-Type", "text/plain")
		_, _ = w.Write([]byte(feedBody.String()))
	}))
	t.Cleanup(feedSrv.Close)

	last := time.Now().Add(-lastSuccessAge).UTC()
	previous := make([]any, 0, 200)
	for i := 0; i < 200; i++ {
		previous = append(previous, fmt.Sprintf("45.33.33.%d/32", i))
	}
	ccgSrv := &fakeCCGServer{rv: 1, obj: map[string]any{
		"apiVersion": "cilium.io/v2",
		"kind":       "CiliumCIDRGroup",
		"metadata": map[string]any{
			"name":            "abuseipdb",
			"resourceVersion": "1",
			"labels":          map[string]any{managedByLabel: managedByName},
			"annotations":     map[string]any{annotationLastOK: last.Format(time.RFC3339)},
		},
		"spec": map[string]any{"externalCIDRs": previous},
	}}
	kube := httptest.NewServer(ccgSrv)
	t.Cleanup(kube.Close)
	dyn, err := dynamic.NewForConfig(&rest.Config{Host: kube.URL})
	if err != nil {
		t.Fatalf("dynamic client: %v", err)
	}

	dir := t.TempDir()
	logger := discardLogger()
	app := &App{
		cfg: &Config{
			CIDRGroupName:    "abuseipdb",
			ExceptionsFile:   filepath.Join(dir, "exceptions.txt"),
			ProtectedFile:    filepath.Join(dir, "protected.txt"),
			MaxStaleAge:      24 * time.Hour,
			StaleBehavior:    staleBehaviorFailOpen,
			MinEntries:       1,
			MaxShrinkPercent: 50,
		},
		log:         logger,
		feed:        &FeedClient{apiKey: "k", limit: 100, http: feedSrv.Client(), log: logger, endpoint: feedSrv.URL},
		ccg:         &CIDRGroupClient{client: dyn, log: logger},
		lastSuccess: last,
	}
	return app, ccgSrv, &feedCalls
}

func TestShrinkGuardRejectsWhileCurrentListIsFresh(t *testing.T) {
	app, ccg, _ := shrinkScenario(t, 2*time.Hour)
	if err := app.syncOnce(context.Background()); err == nil || !strings.Contains(err.Error(), "shrank") {
		t.Fatalf("want shrink-guard rejection, got %v", err)
	}
	if got := ccg.entries(t); got != 200 {
		t.Fatalf("group has %d entries, want the 200 kept", got)
	}
}

func TestShrinkGuardBypassedWhenCurrentListIsStale(t *testing.T) {
	app, ccg, feedCalls := shrinkScenario(t, 25*time.Hour)
	if err := app.syncOnce(context.Background()); err != nil {
		t.Fatalf("syncOnce: %v", err)
	}
	if got := ccg.entries(t); got != 50 {
		t.Fatalf("group has %d entries, want the fresh 50 applied (not cleared, not kept)", got)
	}
	if feedCalls.Load() != 1 {
		t.Fatalf("feed calls = %d, want 1", feedCalls.Load())
	}
	if time.Since(app.lastSuccess) > time.Minute {
		t.Fatal("lastSuccess not refreshed by the accepted sync")
	}
}

// failingGets answers the first n GET requests with 503 and then delegates.
type failingGets struct {
	next http.Handler
	n    atomic.Int32
	seen atomic.Int32
}

func (f *failingGets) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet && f.seen.Add(1) <= f.n.Load() {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusServiceUnavailable)
		_ = json.NewEncoder(w).Encode(map[string]any{"kind": "Status", "apiVersion": "v1", "status": "Failure", "reason": "ServiceUnavailable", "code": 503})
		return
	}
	f.next.ServeHTTP(w, r)
}

// syncScenario is a managed group of 50 entries and a feed returning the same
// 50, with the apiserver failing the first failGets GET requests.
func syncScenario(t *testing.T, failGets int32) (*App, *failingGets, *atomic.Int32) {
	t.Helper()
	var feedCalls atomic.Int32
	var feedBody strings.Builder
	previous := make([]any, 0, 50)
	for i := 1; i <= 50; i++ {
		fmt.Fprintf(&feedBody, "45.33.32.%d\n", i)
		previous = append(previous, fmt.Sprintf("45.33.32.%d/32", i))
	}
	feedSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		feedCalls.Add(1)
		w.Header().Set("Content-Type", "text/plain")
		_, _ = w.Write([]byte(feedBody.String()))
	}))
	t.Cleanup(feedSrv.Close)

	ccg := &fakeCCGServer{rv: 1, obj: map[string]any{
		"apiVersion": "cilium.io/v2",
		"kind":       "CiliumCIDRGroup",
		"metadata": map[string]any{
			"name":            "abuseipdb",
			"resourceVersion": "1",
			"labels":          map[string]any{managedByLabel: managedByName},
		},
		"spec": map[string]any{"externalCIDRs": previous},
	}}
	flaky := &failingGets{next: ccg}
	flaky.n.Store(failGets)
	kube := httptest.NewServer(flaky)
	t.Cleanup(kube.Close)
	dyn, err := dynamic.NewForConfig(&rest.Config{Host: kube.URL})
	if err != nil {
		t.Fatalf("dynamic client: %v", err)
	}
	dir := t.TempDir()
	logger := discardLogger()
	app := &App{
		cfg: &Config{
			CIDRGroupName:    "abuseipdb",
			ExceptionsFile:   filepath.Join(dir, "exceptions.txt"),
			ProtectedFile:    filepath.Join(dir, "protected.txt"),
			MaxStaleAge:      24 * time.Hour,
			StaleBehavior:    staleBehaviorRetain,
			MinEntries:       1,
			MaxShrinkPercent: 50,
		},
		log:  logger,
		feed: &FeedClient{apiKey: "k", limit: 100, http: feedSrv.Client(), log: logger, endpoint: feedSrv.URL, retryBase: time.Millisecond},
		ccg:  &CIDRGroupClient{client: dyn, log: logger, retryBase: time.Millisecond},
	}
	return app, flaky, &feedCalls
}

// The feed call spends daily quota; it must not be made when the current group
// cannot be read, because the downloaded list could not be applied.
func TestSyncSkipsFeedWhenGroupUnreadable(t *testing.T) {
	app, flaky, feedCalls := syncScenario(t, 1000)
	if err := app.syncOnce(context.Background()); err == nil {
		t.Fatal("expected the sync to fail while the apiserver is unavailable")
	}
	if got := feedCalls.Load(); got != 0 {
		t.Fatalf("feed was called %d times with an unreadable CIDR group, want 0", got)
	}
	if got := flaky.seen.Load(); got != cidrGroupGetAttempts {
		t.Fatalf("CIDR group GETs = %d, want %d (bounded retry)", got, cidrGroupGetAttempts)
	}
}

func TestSyncRetriesTransientGroupReadError(t *testing.T) {
	app, _, feedCalls := syncScenario(t, 1)
	if err := app.syncOnce(context.Background()); err != nil {
		t.Fatalf("sync after one transient apiserver error: %v", err)
	}
	if got := feedCalls.Load(); got != 1 {
		t.Fatalf("feed calls = %d, want 1", got)
	}
}
