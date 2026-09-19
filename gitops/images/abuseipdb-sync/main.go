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

	// Recover the last successful synchronization timestamp from the CIDR
	// group so feed age reporting survives pod restarts.
	if state, err := app.ccg.Get(ctx, cfg.CIDRGroupName); err != nil {
		logger.Warn("cannot read existing CiliumCIDRGroup at startup", "error", err)
	} else {
		if state.Exists && !state.ManagedByUs {
			logger.Warn("existing CiliumCIDRGroup is not managed by abuseipdb-sync; synchronization will refuse to overwrite it",
				"name", cfg.CIDRGroupName)
		}
		app.mu.Lock()
		app.lastSuccess = state.LastSuccess
		app.cfLastSuccess = state.CloudflareLastSuccess
		app.mu.Unlock()
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
	}

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

	go app.reportFeedAge(ctx)
	if app.firewall != nil {
		go app.firewall.Run(ctx)
	}

	logger.Info("starting initial synchronization",
		"interval", cfg.SyncInterval.String(),
		"group", cfg.CIDRGroupName,
		"limit", cfg.Limit,
		"confidence_minimum", cfg.ConfidenceMinimum,
		"max_stale_age", cfg.MaxStaleAge.String(),
		"stale_behavior", cfg.StaleBehavior,
		"cloudflare_enabled", cfg.CloudflareEnabled)
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

	mu             sync.Mutex
	lastSuccess    time.Time
	cfLastSuccess  time.Time
	staleCleared   bool
	staleCFCleared bool
}

func (a *App) syncWithLogging(ctx context.Context) {
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
		return a.failSync(ctx, "download", err, fmt.Sprintf("feed download failed (status %d)", status))
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
		return a.failSync(ctx, "validation",
			fmt.Errorf("validated list shrank from %d to %d entries (max shrink %d%%); keeping last known good list",
				len(state.Prefixes), len(desired), a.cfg.MaxShrinkPercent),
			"feed shrink guard triggered")
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
		a.mu.Unlock()
		metricEntries.Set(float64(len(desired)))
		metricEntriesAdded.Set(float64(result.Added))
		metricEntriesRemoved.Set(float64(result.Removed))
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
	metricLastSuccess.Set(float64(now.Unix()))
	metricFeedAge.Set(0)
	metricFeedStale.Set(0)

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
	cfg := a.cfg
	a.mu.Unlock()

	if last.IsZero() {
		return
	}
	age := time.Since(last)
	metricFeedAge.Set(age.Seconds())
	if age <= cfg.MaxStaleAge {
		metricFeedStale.Set(0)
		return
	}
	metricFeedStale.Set(1)
	a.log.Error("reputation feed is stale",
		"sink", "cilium",
		"age", age.String(),
		"max_stale_age", cfg.MaxStaleAge.String(),
		"behavior", cfg.StaleBehavior)

	if cfg.StaleBehavior != staleBehaviorFailOpen || alreadyCleared {
		return
	}
	result, err := a.ccg.Apply(ctx, cfg.CIDRGroupName, nil, time.Time{}, time.Now().UTC())
	if err != nil {
		a.log.Error("stale fail-open: cannot clear CiliumCIDRGroup", "error", err)
		return
	}
	a.mu.Lock()
	a.staleCleared = true
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
	cfg := a.cfg
	a.mu.Unlock()

	if last.IsZero() {
		return
	}
	age := time.Since(last)
	metricCloudflareFeedAge.Set(age.Seconds())
	if age <= cfg.MaxStaleAge {
		metricCloudflareFeedStale.Set(0)
		return
	}
	metricCloudflareFeedStale.Set(1)
	a.log.Error("reputation feed is stale",
		"sink", "cloudflare",
		"age", age.String(),
		"max_stale_age", cfg.MaxStaleAge.String(),
		"behavior", cfg.StaleBehavior)

	if cfg.StaleBehavior != staleBehaviorFailOpen || alreadyCleared {
		return
	}
	if _, _, err := a.cf.Sync(ctx, nil); err != nil {
		a.log.Error("stale fail-open: cannot clear Cloudflare IP list", "error", err)
		return
	}
	a.mu.Lock()
	a.staleCFCleared = true
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
			a.mu.Lock()
			last := a.lastSuccess
			cfLast := a.cfLastSuccess
			maxStale := a.cfg.MaxStaleAge
			cfEnabled := a.cf != nil
			a.mu.Unlock()
			if !last.IsZero() {
				age := time.Since(last).Seconds()
				metricFeedAge.Set(age)
				if age > maxStale.Seconds() {
					metricFeedStale.Set(1)
				} else {
					metricFeedStale.Set(0)
				}
			}
			if cfEnabled && !cfLast.IsZero() {
				age := time.Since(cfLast).Seconds()
				metricCloudflareFeedAge.Set(age)
				if age > maxStale.Seconds() {
					metricCloudflareFeedStale.Set(1)
				} else {
					metricCloudflareFeedStale.Set(0)
				}
			}
		}
	}
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
