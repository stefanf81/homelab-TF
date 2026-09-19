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

	metricLastSuccess = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_last_success_timestamp_seconds",
		Help: "Unix timestamp of the last successful synchronization.",
	})

	metricFeedAge = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_feed_age_seconds",
		Help: "Age of the last successful synchronization in seconds.",
	})

	metricFeedStale = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_feed_stale",
		Help: "Whether the feed is older than ABUSEIPDB_MAX_STALE_AGE (1) or not (0).",
	})

	metricCloudflareSyncSuccess = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_cloudflare_sync_success",
		Help: "Whether the last Cloudflare edge synchronization succeeded (1) or failed (0).",
	})

	metricCloudflareEntries = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_cloudflare_entries",
		Help: "Number of entries currently published in the Cloudflare IP list.",
	})

	metricCloudflareLastSuccess = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_cloudflare_last_success_timestamp_seconds",
		Help: "Unix timestamp of the last successful Cloudflare edge synchronization.",
	})

	metricCloudflareFeedAge = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_cloudflare_feed_age_seconds",
		Help: "Age of the last successful Cloudflare edge synchronization in seconds.",
	})

	metricCloudflareFeedStale = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_cloudflare_feed_stale",
		Help: "Whether the Cloudflare list is older than ABUSEIPDB_MAX_STALE_AGE (1) or not (0).",
	})

	metricCloudflareSyncErrors = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "abuseipdb_cloudflare_sync_errors_total",
		Help: "Total number of failed Cloudflare edge synchronization attempts by reason.",
	}, []string{"reason"})

	metricCloudflareBulkOperationPending = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_cloudflare_bulk_operation_pending",
		Help: "Whether a Cloudflare list bulk operation is still in progress (1) or not (0).",
	})

	metricCloudflareRulePresent = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "abuseipdb_cloudflare_rule_present",
		Help: "Whether the managed Cloudflare WAF custom rule is present (1) or not (0).",
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
)
