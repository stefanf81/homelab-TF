package main

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

var (
	metricBuildInfo = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "abuseipdb_build_info",
		Help: "Build information for the AbuseIPDB synchronizer.",
	}, []string{"version"})

	metricEntries = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_entries",
		Help: "Number of CIDRs currently published in the CiliumCIDRGroup.",
	})

	metricEntriesAdded = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_entries_added",
		Help: "Number of entries added during the last successful synchronization.",
	})

	metricEntriesRemoved = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_entries_removed",
		Help: "Number of entries removed during the last successful synchronization.",
	})

	metricExceptionsRemoved = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_exceptions_removed",
		Help: "Number of feed entries removed because they overlap a trusted exception.",
	})

	metricProtectedRemoved = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_protected_removed",
		Help: "Number of feed entries removed because they overlap an internal or reserved range.",
	})

	metricInvalidEntries = promauto.NewCounter(prometheus.CounterOpts{
		Name: "abuseipdb_invalid_entries_total",
		Help: "Total number of feed lines rejected as malformed.",
	})

	metricSyncSuccess = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_sync_success",
		Help: "Whether the last synchronization completed successfully (1) or failed (0).",
	})

	metricSyncErrors = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "abuseipdb_sync_errors_total",
		Help: "Total number of failed synchronization attempts by reason.",
	}, []string{"reason"})

	metricSyncDuration = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_sync_duration_seconds",
		Help: "Duration of the last successful synchronization.",
	})

	metricLastHTTPStatus = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_last_http_status",
		Help: "HTTP status code returned by the last AbuseIPDB blacklist request.",
	})

	metricLastSuccess = newLazyGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_last_success_timestamp_seconds",
		Help: "Unix timestamp of the last successful CiliumCIDRGroup update (restored from the group annotation at startup).",
	})

	metricFeedAge = newLazyGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_feed_age_seconds",
		Help: "Seconds since the last successful CiliumCIDRGroup update (restored from the group annotation at startup).",
	})

	metricFeedStale = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_feed_stale",
		Help: "Whether the feed is older than ABUSEIPDB_MAX_STALE_AGE (1) or not (0).",
	})

	metricCloudflareSyncSuccess = newLazyGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_cloudflare_sync_success",
		Help: "Whether the last Cloudflare edge synchronization succeeded (1) or failed (0).",
	})

	metricCloudflareEntries = newLazyGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_cloudflare_entries",
		Help: "Number of entries currently published in the Cloudflare IP list.",
	})

	metricCloudflareLastSuccess = newLazyGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_cloudflare_last_success_timestamp_seconds",
		Help: "Unix timestamp of the last successful Cloudflare edge synchronization (restored from the group annotation at startup).",
	})

	metricCloudflareFeedAge = newLazyGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_cloudflare_feed_age_seconds",
		Help: "Seconds since the last successful Cloudflare edge synchronization (restored from the group annotation at startup).",
	})

	metricCloudflareFeedStale = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_cloudflare_feed_stale",
		Help: "Whether the Cloudflare list is older than ABUSEIPDB_MAX_STALE_AGE (1) or not (0).",
	})

	metricCloudflareSyncErrors = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "abuseipdb_cloudflare_sync_errors_total",
		Help: "Total number of failed Cloudflare edge synchronization attempts by reason.",
	}, []string{"reason"})

	metricCloudflareBulkOperationPending = newLazyGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_cloudflare_bulk_operation_pending",
		Help: "1 while a Cloudflare list bulk operation is awaited, and after the last one failed or timed out until the next successful push; 0 otherwise.",
	})

	metricCloudflareRulePresent = newLazyGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_cloudflare_rule_present",
		Help: "1 when the last push confirmed (creating or re-enabling if needed) the managed Cloudflare WAF custom rule; 0 when that check or repair failed.",
	})

	metricFirewallCollectorSuccess = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "cloudflare_firewall_collector_success",
		Help: "Whether the last Cloudflare Security Events collection succeeded (1) or failed (0).",
	})

	metricFirewallCollectorErrors = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "cloudflare_firewall_collector_errors_total",
		Help: "Total number of failed Cloudflare Security Events collection attempts by reason.",
	}, []string{"reason"})

	metricFirewallEvents = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "cloudflare_firewall_events_total",
		Help: "Total blocked requests collected from Cloudflare Security Events, by action and rule source.",
	}, []string{"action", "source"})

	metricFirewallLastSuccess = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "cloudflare_firewall_last_success_timestamp_seconds",
		Help: "Unix timestamp of the last successful Cloudflare Security Events collection.",
	})

	metricFirewallLastWindowEvents = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "cloudflare_firewall_last_window_events",
		Help: "Number of blocked events collected in the last window.",
	})

	metricFirewallTruncatedWindows = promauto.NewCounter(prometheus.CounterOpts{
		Name: "cloudflare_firewall_truncated_windows_total",
		Help: "Collection windows whose Security Events query returned its full row limit (or exceeded the Loki batch limit), so later events of the window were not collected.",
	})
)

// lazyGauge is an unlabelled gauge that is only exported after its first Set.
// Values that are unknown until a sink was attempted (for example the Cloudflare
// list size right after a restart whose feed download failed) are then absent
// instead of a misleading 0, which dashboards would render as a failure.
type lazyGauge struct {
	vec *prometheus.GaugeVec
}

func newLazyGauge(opts prometheus.GaugeOpts) lazyGauge {
	return lazyGauge{vec: promauto.NewGaugeVec(opts, nil)}
}

func (g lazyGauge) Set(v float64) {
	g.vec.WithLabelValues().Set(v)
}
