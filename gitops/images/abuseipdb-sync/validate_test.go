package main

import (
	"net/netip"
	"testing"
	"time"
)

func mustPrefix(t *testing.T, s string) netip.Prefix {
	t.Helper()
	p, err := netip.ParsePrefix(s)
	if err != nil {
		t.Fatalf("bad test prefix %q: %v", s, err)
	}
	return p
}

func TestParseBlacklistValid(t *testing.T) {
	body := []byte("1.2.3.4\n2001:db8::1\n\n# comment\n10.0.0.0/8\n::ffff:192.0.2.9\n")
	got, invalid, err := ParseBlacklist(body)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if invalid != 0 {
		t.Fatalf("unexpected invalid count: %d", invalid)
	}
	want := []string{"1.2.3.4/32", "10.0.0.0/8", "192.0.2.9/32", "2001:db8::1/128"}
	got = SortDedup(got)
	if len(got) != len(want) {
		t.Fatalf("want %d prefixes, got %d: %v", len(want), len(got), got)
	}
	for i := range want {
		if got[i].String() != want[i] {
			t.Fatalf("prefix %d: want %s, got %s", i, want[i], got[i])
		}
	}
}

func TestParseBlacklistRejectsMalformed(t *testing.T) {
	body := []byte("1.2.3.4\n<HTML>oops</HTML>\n5.6.7.8\n")
	_, invalid, err := ParseBlacklist(body)
	if err == nil {
		t.Fatal("expected error for malformed line")
	}
	if invalid != 1 {
		t.Fatalf("want 1 invalid line, got %d", invalid)
	}
}

func TestCanonicalPrefixMasking(t *testing.T) {
	got := canonicalPrefix(mustPrefix(t, "10.1.2.3/8"))
	if got.String() != "10.0.0.0/8" {
		t.Fatalf("want 10.0.0.0/8, got %s", got)
	}
}

func TestParseFilterListAllowsComments(t *testing.T) {
	data := []byte(`
# trusted office
203.0.113.10/32  # scanner
2001:db8:abcd::/48
`)
	got, err := ParseFilterList(data)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("want 2 prefixes, got %d: %v", len(got), got)
	}
}

func TestFilterOverlapsException(t *testing.T) {
	entries := []netip.Prefix{
		mustPrefix(t, "203.0.113.10/32"),
		mustPrefix(t, "203.0.113.0/24"),
		mustPrefix(t, "198.51.100.20/32"),
	}
	exceptions := []netip.Prefix{mustPrefix(t, "203.0.113.10/32")}

	kept, removed := FilterOverlaps(entries, exceptions)
	if removed != 2 {
		t.Fatalf("want 2 removed (exact + containing /24), got %d", removed)
	}
	if len(kept) != 1 || kept[0].String() != "198.51.100.20/32" {
		t.Fatalf("unexpected kept list: %v", kept)
	}
}

func TestFilterOverlapsProtectedRange(t *testing.T) {
	entries := []netip.Prefix{
		mustPrefix(t, "10.42.0.5/32"),
		mustPrefix(t, "10.0.0.0/8"),
		mustPrefix(t, "8.8.8.8/32"),
	}
	protected := []netip.Prefix{mustPrefix(t, "10.42.0.0/16")}

	kept, removed := FilterOverlaps(entries, protected)
	if removed != 2 {
		t.Fatalf("want 2 removed, got %d", removed)
	}
	if len(kept) != 1 || kept[0].String() != "8.8.8.8/32" {
		t.Fatalf("unexpected kept list: %v", kept)
	}
}

func TestShrinkGuard(t *testing.T) {
	cases := []struct {
		previous, next, percent int
		want                    bool
	}{
		{0, 0, 50, false},
		{1000, 900, 50, false},
		{1000, 400, 50, true},
		{1000, 500, 50, false},
		{99, 1, 50, false},
		{1000, 1, 0, false},
	}
	for _, c := range cases {
		if got := shrinkRejected(c.previous, c.next, c.percent); got != c.want {
			t.Errorf("shrinkRejected(%d,%d,%d) = %v, want %v", c.previous, c.next, c.percent, got, c.want)
		}
	}
}

func TestSortDedupDeterministic(t *testing.T) {
	a := SortDedup([]netip.Prefix{mustPrefix(t, "9.9.9.9/32"), mustPrefix(t, "1.1.1.1/32"), mustPrefix(t, "1.1.1.1/32")})
	b := SortDedup([]netip.Prefix{mustPrefix(t, "1.1.1.1/32"), mustPrefix(t, "9.9.9.9/32")})
	if len(a) != 2 || len(b) != 2 {
		t.Fatalf("dedup failed: %v %v", a, b)
	}
	for i := range a {
		if a[i] != b[i] {
			t.Fatalf("order differs: %v vs %v", a, b)
		}
	}
}

func TestDefaultProtectedNumericAddresses(t *testing.T) {
	cfg, err := ParseFilterList([]byte("10.0.0.0/8\nfc00::/7\n100.64.0.0/10"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(cfg) != 3 {
		t.Fatalf("want 3 prefixes, got %d", len(cfg))
	}
}

func TestErrorReason(t *testing.T) {
	if got := errorReason(&rateLimitError{retryAfter: time.Minute}); got != "rate_limited" {
		t.Fatalf("want rate_limited, got %s", got)
	}
	if got := errorReason(&httpStatusError{status: 500}); got != "http" {
		t.Fatalf("want http, got %s", got)
	}
}
