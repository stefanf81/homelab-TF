package main

import (
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	dto "github.com/prometheus/client_model/go"
)

func collectCount(c prometheus.Collector) int {
	ch := make(chan prometheus.Metric, 8)
	c.Collect(ch)
	close(ch)
	n := 0
	for range ch {
		n++
	}
	return n
}

func lazyValue(t *testing.T, g lazyGauge) float64 {
	t.Helper()
	if collectCount(g.vec) == 0 {
		t.Fatal("gauge is not exported")
	}
	m := &dto.Metric{}
	if err := g.vec.WithLabelValues().Write(m); err != nil {
		t.Fatal(err)
	}
	return m.GetGauge().GetValue()
}

func TestLazyGaugeAbsentUntilSet(t *testing.T) {
	g := lazyGauge{vec: prometheus.NewGaugeVec(prometheus.GaugeOpts{Name: "test_lazy_gauge"}, nil)}
	if n := collectCount(g.vec); n != 0 {
		t.Fatalf("unset lazy gauge exported %d series, want 0", n)
	}
	g.Set(0)
	if got := lazyValue(t, g); got != 0 {
		t.Fatalf("value = %v, want 0", got)
	}
	g.Set(42)
	if n := collectCount(g.vec); n != 1 {
		t.Fatalf("set lazy gauge exported %d series, want 1", n)
	}
	if got := lazyValue(t, g); got != 42 {
		t.Fatalf("value = %v, want 42", got)
	}
}

func TestRestoreSuccessMetrics(t *testing.T) {
	now := time.Date(2026, 10, 20, 12, 0, 0, 0, time.UTC)
	last := now.Add(-2 * time.Hour)
	cfLast := now.Add(-30 * time.Hour)

	app := &App{
		cfg:           &Config{MaxStaleAge: 24 * time.Hour},
		cf:            &CloudflareClient{},
		lastSuccess:   last,
		cfLastSuccess: cfLast,
	}
	app.restoreSuccessMetrics(now)

	if got := lazyValue(t, metricLastSuccess); got != float64(last.Unix()) {
		t.Fatalf("last success = %v, want %v", got, last.Unix())
	}
	if got := lazyValue(t, metricFeedAge); got != (2 * time.Hour).Seconds() {
		t.Fatalf("feed age = %v, want 7200", got)
	}
	if got := lazyValue(t, metricCloudflareLastSuccess); got != float64(cfLast.Unix()) {
		t.Fatalf("cloudflare last success = %v, want %v", got, cfLast.Unix())
	}
	if got := lazyValue(t, metricCloudflareFeedAge); got != (30 * time.Hour).Seconds() {
		t.Fatalf("cloudflare feed age = %v, want 108000", got)
	}
	stale := &dto.Metric{}
	if err := metricCloudflareFeedStale.Write(stale); err != nil {
		t.Fatal(err)
	}
	if stale.GetGauge().GetValue() != 1 {
		t.Fatalf("cloudflare feed stale = %v, want 1", stale.GetGauge().GetValue())
	}
}
