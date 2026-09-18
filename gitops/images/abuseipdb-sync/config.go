package main

import (
	"fmt"
	"net/netip"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var cloudflareRefPattern = regexp.MustCompile(`^[a-z][a-z0-9_]*$`)

const (
	staleBehaviorFailOpen = "fail-open"
	staleBehaviorRetain   = "retain"

	defaultExceptionsFile = "/etc/abuseipdb/exceptions.txt"
	defaultProtectedFile  = "/etc/abuseipdb/protected-cidrs.txt"

	defaultCloudflareListName   = "abuseipdb"
	defaultCloudflareMaxEntries = 10000
	defaultCloudflareRuleRef    = "abuseipdb"
)

// defaultProtectedCIDRs are never accepted from external reputation data,
// regardless of configuration. They cover special-purpose ranges, private
// networks, CGNAT (including Tailscale), loopback, link-local and multicast.
var defaultProtectedCIDRs = []string{
	"0.0.0.0/8",
	"10.0.0.0/8",
	"100.64.0.0/10",
	"127.0.0.0/8",
	"169.254.0.0/16",
	"172.16.0.0/12",
	"192.0.0.0/24",
	"192.0.2.0/24",
	"192.88.99.0/24",
	"192.168.0.0/16",
	"198.18.0.0/15",
	"198.51.100.0/24",
	"203.0.113.0/24",
	"224.0.0.0/4",
	"240.0.0.0/4",
	"::/128",
	"::1/128",
	"::ffff:0:0/96",
	"64:ff9b::/96",
	"100::/64",
	"2001::/23",
	"2001:db8::/32",
	"fc00::/7",
	"fe80::/10",
	"ff00::/8",
}

type Config struct {
	APIKey            string
	Limit             int
	SyncInterval      time.Duration
	ConfidenceMinimum int
	MaxStaleAge       time.Duration
	StaleBehavior     string
	MinEntries        int
	MaxShrinkPercent  int
	CIDRGroupName     string
	HTTPTimeout       time.Duration
	ListenAddr        string
	LogLevel          string

	ExceptionsFile string
	ProtectedFile  string

	CloudflareEnabled    bool
	CloudflareAPIToken   string
	CloudflareAccountID  string
	CloudflareZoneID     string
	CloudflareListName   string
	CloudflareMaxEntries int
	CloudflareRuleRef    string

	Exceptions []netip.Prefix
	Protected  []netip.Prefix
}

func LoadConfig() (*Config, error) {
	cfg := &Config{
		APIKey:              strings.TrimSpace(os.Getenv("ABUSEIPDB_API_KEY")),
		CIDRGroupName:       envString("ABUSEIPDB_CIDRGROUP_NAME", "abuseipdb"),
		StaleBehavior:       envString("ABUSEIPDB_STALE_BEHAVIOR", staleBehaviorFailOpen),
		ListenAddr:          envString("ABUSEIPDB_LISTEN_ADDR", ":8080"),
		LogLevel:            envString("LOG_LEVEL", "info"),
		ExceptionsFile:      envString("ABUSEIPDB_EXCEPTIONS_FILE", defaultExceptionsFile),
		ProtectedFile:       envString("ABUSEIPDB_PROTECTED_FILE", defaultProtectedFile),
		CloudflareAPIToken:  strings.TrimSpace(os.Getenv("CLOUDFLARE_API_TOKEN")),
		CloudflareAccountID: strings.TrimSpace(os.Getenv("CLOUDFLARE_ACCOUNT_ID")),
		CloudflareZoneID:    strings.TrimSpace(os.Getenv("CLOUDFLARE_ZONE_ID")),
		CloudflareListName:  envString("CLOUDFLARE_LIST_NAME", defaultCloudflareListName),
		CloudflareRuleRef:   envString("CLOUDFLARE_RULE_REF", defaultCloudflareRuleRef),
	}

	var err error
	if cfg.CloudflareEnabled, err = envBool("CLOUDFLARE_SYNC_ENABLED", false); err != nil {
		return nil, err
	}
	if cfg.CloudflareMaxEntries, err = envInt("CLOUDFLARE_MAX_ENTRIES", defaultCloudflareMaxEntries); err != nil {
		return nil, err
	}
	if cfg.Limit, err = envInt("ABUSEIPDB_LIMIT", 10000); err != nil {
		return nil, err
	}
	if cfg.ConfidenceMinimum, err = envInt("ABUSEIPDB_CONFIDENCE_MINIMUM", 0); err != nil {
		return nil, err
	}
	if cfg.MinEntries, err = envInt("ABUSEIPDB_MIN_ENTRIES", 1); err != nil {
		return nil, err
	}
	if cfg.MaxShrinkPercent, err = envInt("ABUSEIPDB_MAX_SHRINK_PERCENT", 50); err != nil {
		return nil, err
	}
	if cfg.SyncInterval, err = envDuration("ABUSEIPDB_SYNC_INTERVAL", 6*time.Hour); err != nil {
		return nil, err
	}
	if cfg.MaxStaleAge, err = envDuration("ABUSEIPDB_MAX_STALE_AGE", 24*time.Hour); err != nil {
		return nil, err
	}
	if cfg.HTTPTimeout, err = envDuration("ABUSEIPDB_HTTP_TIMEOUT", 30*time.Second); err != nil {
		return nil, err
	}

	if cfg.APIKey == "" {
		return nil, fmt.Errorf("ABUSEIPDB_API_KEY is empty; populate the SOPS-encrypted Secret before deploying")
	}
	if cfg.Limit < 1 || cfg.Limit > 500000 {
		return nil, fmt.Errorf("ABUSEIPDB_LIMIT must be between 1 and 500000, got %d", cfg.Limit)
	}
	if cfg.ConfidenceMinimum != 0 && (cfg.ConfidenceMinimum < 25 || cfg.ConfidenceMinimum > 100) {
		return nil, fmt.Errorf("ABUSEIPDB_CONFIDENCE_MINIMUM must be between 25 and 100 (subscriber feature below 100), got %d", cfg.ConfidenceMinimum)
	}
	if cfg.SyncInterval < 5*time.Minute {
		return nil, fmt.Errorf("ABUSEIPDB_SYNC_INTERVAL must be at least 5m to respect AbuseIPDB rate limits, got %s", cfg.SyncInterval)
	}
	if cfg.MaxStaleAge <= 0 {
		return nil, fmt.Errorf("ABUSEIPDB_MAX_STALE_AGE must be positive, got %s", cfg.MaxStaleAge)
	}
	if cfg.StaleBehavior != staleBehaviorFailOpen && cfg.StaleBehavior != staleBehaviorRetain {
		return nil, fmt.Errorf("ABUSEIPDB_STALE_BEHAVIOR must be %q or %q, got %q", staleBehaviorFailOpen, staleBehaviorRetain, cfg.StaleBehavior)
	}
	if cfg.MinEntries < 0 {
		return nil, fmt.Errorf("ABUSEIPDB_MIN_ENTRIES must not be negative, got %d", cfg.MinEntries)
	}
	if cfg.MaxShrinkPercent < 0 || cfg.MaxShrinkPercent > 99 {
		return nil, fmt.Errorf("ABUSEIPDB_MAX_SHRINK_PERCENT must be between 0 and 99, got %d", cfg.MaxShrinkPercent)
	}

	if cfg.CloudflareEnabled {
		if cfg.CloudflareAPIToken == "" {
			return nil, fmt.Errorf("CLOUDFLARE_API_TOKEN is empty but CLOUDFLARE_SYNC_ENABLED is true; populate the SOPS-encrypted Secret")
		}
		if cfg.CloudflareAccountID == "" {
			return nil, fmt.Errorf("CLOUDFLARE_ACCOUNT_ID must be set when CLOUDFLARE_SYNC_ENABLED is true")
		}
		if cfg.CloudflareZoneID == "" {
			return nil, fmt.Errorf("CLOUDFLARE_ZONE_ID must be set when CLOUDFLARE_SYNC_ENABLED is true")
		}
		if cfg.CloudflareListName == "" {
			return nil, fmt.Errorf("CLOUDFLARE_LIST_NAME must not be empty")
		}
		if cfg.CloudflareMaxEntries < 1 || cfg.CloudflareMaxEntries > 500000 {
			return nil, fmt.Errorf("CLOUDFLARE_MAX_ENTRIES must be between 1 and 500000, got %d", cfg.CloudflareMaxEntries)
		}
		if !cloudflareRefPattern.MatchString(cfg.CloudflareRuleRef) {
			return nil, fmt.Errorf("CLOUDFLARE_RULE_REF %q must start with a lowercase letter and contain only lowercase letters, numbers and underscores", cfg.CloudflareRuleRef)
		}
	}

	protected, err := loadPrefixList(cfg.ProtectedFile)
	if err != nil {
		return nil, fmt.Errorf("loading protected CIDRs: %w", err)
	}
	defaults, err := ParseFilterList([]byte(strings.Join(defaultProtectedCIDRs, "\n")))
	if err != nil {
		return nil, fmt.Errorf("parsing built-in protected CIDRs: %w", err)
	}
	cfg.Protected = SortDedup(append(defaults, protected...))

	exceptions, err := loadPrefixList(cfg.ExceptionsFile)
	if err != nil {
		return nil, fmt.Errorf("loading trusted exceptions: %w", err)
	}
	cfg.Exceptions = SortDedup(exceptions)

	return cfg, nil
}

// loadPrefixList reads a Git-managed filter file. A missing file is valid and
// yields an empty list so the controller can run before files are mounted.
func loadPrefixList(path string) ([]netip.Prefix, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	return ParseFilterList(data)
}

func envString(name, def string) string {
	if v := strings.TrimSpace(os.Getenv(name)); v != "" {
		return v
	}
	return def
}

func envInt(name string, def int) (int, error) {
	v := strings.TrimSpace(os.Getenv(name))
	if v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("%s: invalid integer %q: %w", name, v, err)
	}
	return n, nil
}

func envDuration(name string, def time.Duration) (time.Duration, error) {
	v := strings.TrimSpace(os.Getenv(name))
	if v == "" {
		return def, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return 0, fmt.Errorf("%s: invalid duration %q: %w", name, v, err)
	}
	return d, nil
}

func envBool(name string, def bool) (bool, error) {
	v := strings.TrimSpace(os.Getenv(name))
	if v == "" {
		return def, nil
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		return false, fmt.Errorf("%s: invalid boolean %q: %w", name, v, err)
	}
	return b, nil
}
