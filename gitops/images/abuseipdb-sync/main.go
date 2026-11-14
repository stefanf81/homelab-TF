package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	"k8s.io/client-go/dynamic"
)

var version = "dev"

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: logLevel(envString("LOG_LEVEL", "info"))}))
	slog.SetDefault(logger)

	cfg, err := LoadConfig()
	if err != nil {
		logger.Error("invalid configuration", "error", err)
		os.Exit(1)
	}

	restConfig, err := buildRestConfig()
	if err != nil {
		logger.Error("cannot build Kubernetes client configuration", "error", err)
		os.Exit(1)
	}
	dyn, err := dynamic.NewForConfig(restConfig)
	if err != nil {
		logger.Error("cannot create Kubernetes dynamic client", "error", err)
		os.Exit(1)
	}

	app := &App{
		cfg: cfg,
		log: logger,
		feed: &FeedClient{
			apiKey:            cfg.APIKey,
			limit:             cfg.Limit,
			confidenceMinimum: cfg.ConfidenceMinimum,
			http:              &http.Client{Timeout: cfg.HTTPTimeout},
			log:               logger,
		},
		ccg: &CIDRGroupClient{client: dyn, log: logger},
	}
	if cfg.CloudflareEnabled {
		app.cf = NewCloudflareClient(cfg, &http.Client{Timeout: cfg.HTTPTimeout}, logger)
	}
	if cfg.FirewallLogEnabled {
		app.firewall = NewFirewallCollector(cfg, &http.Client{Timeout: cfg.HTTPTimeout}, logger)
	}
	metricBuildInfo.WithLabelValues(version).Set(1)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Serve /healthz and /metrics before the startup work below: a slow
	// Kubernetes or Cloudflare call there (a bulk operation can take minutes)
	// must not fail the liveness probe and restart the pod mid-operation.
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})

	srv := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	serverErr := make(chan error, 1)
	go func() {
		logger.Info("metrics server listening", "address", cfg.ListenAddr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serverErr <- err
		}
	}()

	// Recover the last successful synchronization timestamp from the CIDR
	// group so feed age reporting survives pod restarts and avoids burning the
	// daily AbuseIPDB blacklist quota on routine rollouts or node reboots.
	var initialDelay time.Duration
	if state, err := app.ccg.Get(ctx, cfg.CIDRGroupName); err != nil {
		logger.Warn("cannot read existing CiliumCIDRGroup at startup", "error", err)
	} else {
		if state.Exists && !state.ManagedByUs {
			logger.Warn("existing CiliumCIDRGroup is not managed by abuseipdb-sync; synchronization will refuse to overwrite it",
				"name", cfg.CIDRGroupName)
		}
		now := time.Now()
		app.mu.Lock()
		app.lastSuccess = state.LastSuccess
		app.cfLastSuccess = state.CloudflareLastSuccess
		app.mu.Unlock()
		app.restoreSuccessMetrics(now)
		initialDelay = initialSyncDelay(now, state, cfg.SyncInterval, cfg.MinEntries, cfg.CloudflareEnabled)
		if state.LastSuccess.IsZero() {
			logger.Info("no previous successful synchronization recorded",
				"name", cfg.CIDRGroupName, "exists", state.Exists, "entries", len(state.Prefixes))
		} else {
			logger.Info("recovered previous synchronization state",
				"name", cfg.CIDRGroupName, "exists", state.Exists, "entries", len(state.Prefixes), "last_success", state.LastSuccess.UTC().Format(time.RFC3339))
		}
		if state.Exists {
			metricEntries.Set(float64(len(state.Prefixes)))
		}
		// If startup will defer the AbuseIPDB fetch, still enforce any newly
		// added exceptions/protected CIDRs against the existing group right away
		// (zero API quota spent).
		if initialDelay > 0 && state.Exists && state.ManagedByUs {
			app.applyStartupFilters(ctx, state)
		}
		// No stale-feed enforcement here: when a sink is older than the sync
		// interval the first synchronization runs immediately and either
		// refreshes both sinks or applies the stale behavior on failure, so a
		// pod that was down for a long time does not empty the sinks only to
		// refill them seconds later. Otherwise the per-minute reporter
		// enforces it.
	}

	go app.reportFeedAge(ctx)
	if app.firewall != nil {
		go app.firewall.Run(ctx)
	}

	logger.Info("synchronizer ready",
		"interval", cfg.SyncInterval.String(),
		"initial_delay", initialDelay.Round(time.Second).String(),
		"group", cfg.CIDRGroupName,
		"limit", cfg.Limit,
		"confidence_minimum", cfg.ConfidenceMinimum,
		"max_stale_age", cfg.MaxStaleAge.String(),
		"stale_behavior", cfg.StaleBehavior,
		"cloudflare_enabled", cfg.CloudflareEnabled)
	if initialDelay > 0 {
		logger.Info("skipping immediate startup fetch; existing CiliumCIDRGroup is still within sync interval",
			"next_sync_in", initialDelay.Round(time.Second).String())
		timer := time.NewTimer(initialDelay)
		select {
		case <-ctx.Done():
			timer.Stop()
			shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			_ = srv.Shutdown(shutdownCtx)
			cancel()
			logger.Info("shutting down")
			return
		case err := <-serverErr:
			timer.Stop()
			logger.Error("metrics server failed", "error", err)
			os.Exit(1)
		case <-timer.C:
		}
	}
	app.syncWithLogging(ctx)

	ticker := time.NewTicker(cfg.SyncInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			_ = srv.Shutdown(shutdownCtx)
			cancel()
			logger.Info("shutting down")
			return
		case err := <-serverErr:
			logger.Error("metrics server failed", "error", err)
			os.Exit(1)
		case <-ticker.C:
			app.syncWithLogging(ctx)
		}
	}
}

type App struct {
	cfg      *Config
	log      *slog.Logger
	feed     *FeedClient
	ccg      *CIDRGroupClient
	cf       *CloudflareClient
	firewall *FirewallCollector

	// opMu serializes every operation that writes a sink (synchronization,
	// startup filter pruning and stale fail-open clearing). CloudflareClient
	// is not goroutine-safe, and a fail-open clear racing a recovering sync
	// could otherwise empty a sink right after the sync refilled it.
	opMu sync.Mutex

	mu             sync.Mutex
	lastSuccess    time.Time
	cfLastSuccess  time.Time
	staleCleared   bool
	staleCFCleared bool
	staleLogged    bool
	staleCFLogged  bool
	// Retry spacing for a failing fail-open clear, per sink.
	ciliumClearRetry clearBackoff
	cfClearRetry     clearBackoff
}

const (
	staleClearRetryBase = time.Minute
	staleClearRetryMax  = 30 * time.Minute
)

// clearBackoff spaces out retries of a failing fail-open clear (1m, 2m, 4m, …
// capped at 30m) instead of retrying on every one-minute reporter tick.
// Guarded by App.mu.
type clearBackoff struct {
	failures int
	next     time.Time
}

func (b *clearBackoff) ready(now time.Time) bool { return !now.Before(b.next) }

func (b *clearBackoff) failed(now time.Time) time.Duration {
	b.failures++
	d := staleClearRetryBase
	for i := 1; i < b.failures && d < staleClearRetryMax; i++ {
		d *= 2
	}
	if d > staleClearRetryMax {
		d = staleClearRetryMax
	}
	b.next = now.Add(d)
	return d
}

func (b *clearBackoff) reset() { *b = clearBackoff{} }

// initialSyncDelay returns how long startup should wait before fetching the
// AbuseIPDB blacklist. When a valid, non-undersized CiliumCIDRGroup already
// exists within the configured sync interval (and Cloudflare is not newly
// enabled without a previous push), waiting preserves the 5/day Individual API
// quota across pod rollouts and node reboots. With Cloudflare enabled the
// older of the two sinks decides, so a restart that fixes a failing edge sink
// (for example a rotated token) syncs right away instead of waiting out the
// Cilium sink's interval.
func initialSyncDelay(now time.Time, state *GroupState, syncInterval time.Duration, minEntries int, cfEnabled bool) time.Duration {
	if state == nil || !state.Exists || state.LastSuccess.IsZero() {
		return 0
	}
	if minEntries > 0 && len(state.Prefixes) < minEntries {
		return 0
	}
	if cfEnabled && state.CloudflareLastSuccess.IsZero() {
		return 0
	}
	oldest := state.LastSuccess
	if cfEnabled && state.CloudflareLastSuccess.Before(oldest) {
		oldest = state.CloudflareLastSuccess
	}
	age := now.Sub(oldest)
	if age < 0 {
		return syncInterval
	}
	if age >= syncInterval {
		return 0
	}
	return syncInterval - age
}

// applyStartupFilters subtracts any newly configured Protected/Exceptions CIDRs
// from the recovered CiliumCIDRGroup (and Cloudflare IP list) immediately on
// startup without spending an AbuseIPDB blacklist API call.
func (a *App) applyStartupFilters(ctx context.Context, state *GroupState) {
	a.opMu.Lock()
	defer a.opMu.Unlock()
	if err := a.reloadFilters(); err != nil {
		a.log.Warn("startup filter check skipped: cannot reload filter lists", "error", err)
		return
	}
	kept, protectedRemoved := FilterOverlaps(state.Prefixes, a.cfg.Protected)
	kept, exceptionsRemoved := FilterOverlaps(kept, a.cfg.Exceptions)
	if protectedRemoved == 0 && exceptionsRemoved == 0 {
		return
	}
	filtered := SortDedup(kept)
	if _, err := a.ccg.Apply(ctx, a.cfg.CIDRGroupName, filtered, time.Time{}, time.Time{}); err != nil {
		a.log.Error("startup filter prune failed on CiliumCIDRGroup", "error", err)
		return
	}
	metricEntries.Set(float64(len(filtered)))
	if a.cf != nil {
		if entries, _, err := a.cf.Sync(ctx, filtered); err != nil {
			a.log.Error("startup filter prune failed on Cloudflare IP list", "error", err)
		} else {
			metricCloudflareEntries.Set(float64(entries))
		}
	}
	a.log.Info("pruned newly excluded/protected entries from existing denylist at startup",
		"exceptions_removed", exceptionsRemoved,
		"protected_removed", protectedRemoved,
		"remaining", len(filtered))
}

func (a *App) syncWithLogging(ctx context.Context) {
	a.opMu.Lock()
	defer a.opMu.Unlock()
	if err := a.syncOnce(ctx); err != nil {
		a.log.Error("synchronization failed", "error", err)
	}
}

func (a *App) syncOnce(ctx context.Context) error {
	start := time.Now()
	a.log.Info("synchronization started")

	// The filter lists are mounted from a ConfigMap and may change without a
	// pod restart; re-read them on every cycle so Git edits apply immediately.
	if err := a.reloadFilters(); err != nil {
		return a.failSync(ctx, "validation", err, "cannot reload exception/protected filter lists")
	}

	body, status, err := a.feed.Fetch(ctx)
	metricLastHTTPStatus.Set(float64(status))
	if err != nil {
		return a.failSync(ctx, errorReason(err), err, fmt.Sprintf("feed download failed (status %d)", status))
	}

	prefixes, invalid, err := ParseBlacklist(body)
	if err != nil {
		metricInvalidEntries.Add(float64(invalid))
		return a.failSync(ctx, "parse", fmt.Errorf("%w (%d invalid lines)", err, invalid), "feed validation failed; keeping last known good list")
	}

	kept, protectedRemoved := FilterOverlaps(prefixes, a.cfg.Protected)
	kept, exceptionsRemoved := FilterOverlaps(kept, a.cfg.Exceptions)
	desired := SortDedup(kept)

	if len(desired) < a.cfg.MinEntries {
		return a.failSync(ctx, "validation",
			fmt.Errorf("validated list has %d entries, below ABUSEIPDB_MIN_ENTRIES=%d", len(desired), a.cfg.MinEntries),
			"validated feed too small; keeping last known good list")
	}

	state, err := a.ccg.Get(ctx, a.cfg.CIDRGroupName)
	if err != nil {
		return a.failSync(ctx, "kube", err, "cannot read current CiliumCIDRGroup")
	}
	if state.Exists && shrinkRejected(len(state.Prefixes), len(desired), a.cfg.MaxShrinkPercent) {
		a.mu.Lock()
		last := a.lastSuccess
		a.mu.Unlock()
		if !currentListStale(last, time.Now(), a.cfg.MaxStaleAge) {
			return a.failSync(ctx, "validation",
				fmt.Errorf("validated list shrank from %d to %d entries (max shrink %d%%); keeping last known good list",
					len(state.Prefixes), len(desired), a.cfg.MaxShrinkPercent),
				"feed shrink guard triggered")
		}
		// The list the guard protects is older than MAX_STALE_AGE: fail-open
		// would empty it and retain would keep rejecting a legitimate shrink
		// forever. A fresh list that passed every other check is better
		// than either.
		a.log.Warn("shrink guard bypassed: the current list is stale, applying the smaller validated list",
			"previous", len(state.Prefixes), "next", len(desired),
			"max_shrink_percent", a.cfg.MaxShrinkPercent, "last_success", last.UTC().Format(time.RFC3339))
	}

	now := time.Now().UTC()

	// --- Cilium sink (primary, in-cluster enforcement) ----------------------
	ciliumOK := true
	result, err := a.ccg.Apply(ctx, a.cfg.CIDRGroupName, desired, now, time.Time{})
	if err != nil {
		ciliumOK = false
		metricSyncErrors.WithLabelValues("kube").Inc()
		a.log.Error("Cilium sink update failed; keeping previous CiliumCIDRGroup", "error", err)
	} else {
		a.mu.Lock()
		a.lastSuccess = now
		a.staleCleared = false
		a.staleLogged = false
		a.ciliumClearRetry.reset()
		a.mu.Unlock()
		metricEntries.Set(float64(len(desired)))
		metricEntriesAdded.Set(float64(result.Added))
		metricEntriesRemoved.Set(float64(result.Removed))
		// Timestamp and age follow the Cilium sink, like the persisted
		// last-success annotation and the stale-feed logic; the Cloudflare
		// sink has its own gauges and sync_success covers both sinks.
		metricLastSuccess.Set(float64(now.Unix()))
		metricFeedAge.Set(0)
		metricFeedStale.Set(0)
	}

	// --- Cloudflare edge sink (optional, sees real client IPs) --------------
	cloudflareOK := true
	if a.cf != nil {
		entries, changed, cfErr := a.cf.Sync(ctx, desired)
		if cfErr != nil {
			cloudflareOK = false
			reason := cfErrorReason(cfErr)
			metricCloudflareSyncSuccess.Set(0)
			metricCloudflareSyncErrors.WithLabelValues(reason).Inc()
			a.log.Error("Cloudflare sink update failed; edge list unchanged", "error", cfErr, "reason", reason)
		} else {
			a.mu.Lock()
			a.cfLastSuccess = now
			a.staleCFCleared = false
			a.staleCFLogged = false
			a.cfClearRetry.reset()
			a.mu.Unlock()
			metricCloudflareEntries.Set(float64(entries))
			metricCloudflareSyncSuccess.Set(1)
			metricCloudflareLastSuccess.Set(float64(now.Unix()))
			metricCloudflareFeedAge.Set(0)
			metricCloudflareFeedStale.Set(0)
			metricCloudflareBulkOperationPending.Set(0)
			if err := a.ccg.MergeAnnotations(ctx, a.cfg.CIDRGroupName, map[string]string{
				annotationCloudflareOK: now.UTC().Format(time.RFC3339),
			}); err != nil {
				a.log.Warn("cannot persist Cloudflare last-success annotation", "error", err)
			}
			a.log.Info("Cloudflare edge sink updated", "entries", entries, "changed", changed)
		}
	}

	metricExceptionsRemoved.Set(float64(exceptionsRemoved))
	metricProtectedRemoved.Set(float64(protectedRemoved))
	metricSyncDuration.Set(time.Since(start).Seconds())

	if !ciliumOK || !cloudflareOK {
		metricSyncSuccess.Set(0)
		a.updateStaleness(ctx)
		return fmt.Errorf("synchronization completed with sink errors (cilium_ok=%t cloudflare_ok=%t)", ciliumOK, cloudflareOK)
	}

	metricSyncSuccess.Set(1)

	a.log.Info("synchronization completed",
		"entries", len(desired),
		"added", result.Added,
		"removed", result.Removed,
		"exceptions_removed", exceptionsRemoved,
		"protected_removed", protectedRemoved,
		"changed", result.Changed,
		"created", result.Created,
		"duration", time.Since(start).String())
	return nil
}

// restoreSuccessMetrics republishes the last-success times recovered from the
// CiliumCIDRGroup annotations, so the timestamp and age gauges survive a pod
// restart even when the first synchronization afterwards fails (for example
// because the daily AbuseIPDB quota is spent). Zero times stay unexported.
func (a *App) restoreSuccessMetrics(now time.Time) {
	a.mu.Lock()
	last := a.lastSuccess
	cfLast := a.cfLastSuccess
	maxStale := a.cfg.MaxStaleAge
	cfEnabled := a.cf != nil
	a.mu.Unlock()

	if !last.IsZero() {
		age := now.Sub(last)
		metricLastSuccess.Set(float64(last.Unix()))
		metricFeedAge.Set(age.Seconds())
		metricFeedStale.Set(boolGauge(age > maxStale))
	}
	if cfEnabled && !cfLast.IsZero() {
		age := now.Sub(cfLast)
		metricCloudflareLastSuccess.Set(float64(cfLast.Unix()))
		metricCloudflareFeedAge.Set(age.Seconds())
		metricCloudflareFeedStale.Set(boolGauge(age > maxStale))
	}
}

func boolGauge(b bool) float64 {
	if b {
		return 1
	}
	return 0
}

// reloadFilters re-reads the Git-managed exception and protected-range files.
// An invalid list is a hard error: the synchronization keeps the last known
// good CIDR group rather than applying a partially parsed filter.
func (a *App) reloadFilters() error {
	protected, err := loadPrefixList(a.cfg.ProtectedFile)
	if err != nil {
		return fmt.Errorf("protected CIDRs %s: %w", a.cfg.ProtectedFile, err)
	}
	exceptions, err := loadPrefixList(a.cfg.ExceptionsFile)
	if err != nil {
		return fmt.Errorf("trusted exceptions %s: %w", a.cfg.ExceptionsFile, err)
	}
	defaults, err := ParseFilterList([]byte(strings.Join(defaultProtectedCIDRs, "\n")))
	if err != nil {
		return fmt.Errorf("built-in protected CIDRs: %w", err)
	}
	cfg := *a.cfg
	cfg.Protected = SortDedup(append(defaults, protected...))
	cfg.Exceptions = SortDedup(exceptions)
	a.mu.Lock()
	a.cfg = &cfg
	a.mu.Unlock()
	return nil
}

func (a *App) failSync(ctx context.Context, reason string, err error, msg string) error {
	metricSyncSuccess.Set(0)
	metricSyncErrors.WithLabelValues(reason).Inc()
	a.log.Error(msg, "error", err, "reason", reason)
	a.updateStaleness(ctx)
	return err
}

// updateStaleness tracks feed age and applies the documented stale-feed
// behavior independently for each sink. Fail-open clears the sink so very old
// reputation data is not enforced indefinitely; retain keeps the last known
// good list instead.
func (a *App) updateStaleness(ctx context.Context) {
	a.updateCiliumStaleness(ctx)
	a.updateCloudflareStaleness(ctx)
}

func (a *App) updateCiliumStaleness(ctx context.Context) {
	a.mu.Lock()
	last := a.lastSuccess
	alreadyCleared := a.staleCleared
	alreadyLogged := a.staleLogged
	cfg := a.cfg
	a.mu.Unlock()

	if last.IsZero() {
		return
	}
	age := time.Since(last)
	metricFeedAge.Set(age.Seconds())
	if age <= cfg.MaxStaleAge {
		metricFeedStale.Set(0)
		if alreadyLogged {
			a.mu.Lock()
			a.staleLogged = false
			a.mu.Unlock()
		}
		return
	}
	metricFeedStale.Set(1)
	if !alreadyLogged {
		a.log.Error("reputation feed is stale",
			"sink", "cilium",
			"age", age.String(),
			"max_stale_age", cfg.MaxStaleAge.String(),
			"behavior", cfg.StaleBehavior)
		a.mu.Lock()
		a.staleLogged = true
		a.mu.Unlock()
	}

	if cfg.StaleBehavior != staleBehaviorFailOpen || alreadyCleared {
		return
	}
	now := time.Now()
	a.mu.Lock()
	ready := a.ciliumClearRetry.ready(now)
	a.mu.Unlock()
	if !ready {
		return
	}
	result, err := a.ccg.Apply(ctx, cfg.CIDRGroupName, nil, time.Time{}, now.UTC())
	if err != nil {
		a.mu.Lock()
		retryIn := a.ciliumClearRetry.failed(now)
		a.mu.Unlock()
		a.log.Error("stale fail-open: cannot clear CiliumCIDRGroup", "error", err, "retry_in", retryIn.String())
		return
	}
	a.mu.Lock()
	a.staleCleared = true
	a.ciliumClearRetry.reset()
	a.mu.Unlock()
	metricEntries.Set(0)
	a.log.Warn("stale fail-open: cleared CiliumCIDRGroup so no address is denied on very old data",
		"group", cfg.CIDRGroupName, "changed", result.Changed)
}

func (a *App) updateCloudflareStaleness(ctx context.Context) {
	if a.cf == nil {
		return
	}
	a.mu.Lock()
	last := a.cfLastSuccess
	alreadyCleared := a.staleCFCleared
	alreadyLogged := a.staleCFLogged
	cfg := a.cfg
	a.mu.Unlock()

	if last.IsZero() {
		return
	}
	age := time.Since(last)
	metricCloudflareFeedAge.Set(age.Seconds())
	if age <= cfg.MaxStaleAge {
		metricCloudflareFeedStale.Set(0)
		if alreadyLogged {
			a.mu.Lock()
			a.staleCFLogged = false
			a.mu.Unlock()
		}
		return
	}
	metricCloudflareFeedStale.Set(1)
	if !alreadyLogged {
		a.log.Error("reputation feed is stale",
			"sink", "cloudflare",
			"age", age.String(),
			"max_stale_age", cfg.MaxStaleAge.String(),
			"behavior", cfg.StaleBehavior)
		a.mu.Lock()
		a.staleCFLogged = true
		a.mu.Unlock()
	}

	if cfg.StaleBehavior != staleBehaviorFailOpen || alreadyCleared {
		return
	}
	now := time.Now()
	a.mu.Lock()
	ready := a.cfClearRetry.ready(now)
	a.mu.Unlock()
	if !ready {
		return
	}
	if _, _, err := a.cf.Sync(ctx, nil); err != nil {
		a.mu.Lock()
		retryIn := a.cfClearRetry.failed(now)
		a.mu.Unlock()
		a.log.Error("stale fail-open: cannot clear Cloudflare IP list", "error", err, "retry_in", retryIn.String())
		return
	}
	a.mu.Lock()
	a.staleCFCleared = true
	a.cfClearRetry.reset()
	a.mu.Unlock()
	metricCloudflareEntries.Set(0)
	a.log.Warn("stale fail-open: cleared Cloudflare IP list so no address is blocked on very old data")
}

func (a *App) reportFeedAge(ctx context.Context) {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			a.staleTick(ctx)
		}
	}
}

// staleTick updates the feed-age gauges and enforces fail-open clearing
// within one minute of crossing MaxStaleAge instead of waiting up to
// SyncInterval. It skips the tick while a synchronization (or startup
// pruning) holds opMu: that operation either refreshes the sinks or applies
// the stale behavior itself, and the next tick catches up.
func (a *App) staleTick(ctx context.Context) {
	if !a.opMu.TryLock() {
		return
	}
	defer a.opMu.Unlock()
	a.updateStaleness(ctx)
}

// currentListStale reports whether the last successful Cilium push is older
// than maxStale. An unknown last success is not treated as stale, so the
// shrink guard still protects a group whose annotation is missing.
func currentListStale(lastSuccess, now time.Time, maxStale time.Duration) bool {
	return !lastSuccess.IsZero() && now.Sub(lastSuccess) > maxStale
}

func logLevel(s string) slog.Level {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "debug":
		return slog.LevelDebug
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}
