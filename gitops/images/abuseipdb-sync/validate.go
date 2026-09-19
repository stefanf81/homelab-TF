package main

import (
	"bufio"
	"bytes"
	"fmt"
	"net/netip"
	"sort"
	"strings"
)

// ParseBlacklist parses a plaintext AbuseIPDB blacklist body into canonical
// CIDR prefixes. Blank lines and '#' comment lines are ignored.
//
// The response is treated as untrusted input: every non-blank line must parse
// as an IPv4/IPv6 address or CIDR. If any line fails, an error is returned
// together with the number of invalid lines, and the caller must keep the
// last known good list instead of applying a partial result.
func ParseBlacklist(data []byte) ([]netip.Prefix, int, error) {
	var out []netip.Prefix
	invalid := 0
	var firstErr error

	sc := bufio.NewScanner(bytes.NewReader(data))
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	lineNo := 0
	for sc.Scan() {
		lineNo++
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		p, err := parseEntry(line)
		if err != nil {
			invalid++
			if firstErr == nil {
				firstErr = fmt.Errorf("line %d: %w", lineNo, err)
			}
			continue
		}
		out = append(out, p)
	}
	if err := sc.Err(); err != nil {
		return nil, invalid, fmt.Errorf("reading feed body: %w", err)
	}
	if invalid > 0 {
		return nil, invalid, firstErr
	}
	return out, 0, nil
}

// ParseFilterList parses a Git-managed list of trusted exceptions or protected
// ranges. Unlike the feed parser, comments are allowed anywhere and invalid
// lines are a hard configuration error.
func ParseFilterList(data []byte) ([]netip.Prefix, error) {
	var out []netip.Prefix
	sc := bufio.NewScanner(bytes.NewReader(data))
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	lineNo := 0
	for sc.Scan() {
		lineNo++
		line := sc.Text()
		if idx := strings.IndexByte(line, '#'); idx >= 0 {
			line = line[:idx]
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		p, err := parseEntry(line)
		if err != nil {
			return nil, fmt.Errorf("line %d: %w", lineNo, err)
		}
		out = append(out, p)
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("reading list: %w", err)
	}
	return out, nil
}

func parseEntry(s string) (netip.Prefix, error) {
	if strings.ContainsRune(s, '/') {
		p, err := netip.ParsePrefix(s)
		if err != nil {
			return netip.Prefix{}, fmt.Errorf("invalid CIDR %q: %w", s, err)
		}
		return canonicalPrefix(p), nil
	}
	a, err := netip.ParseAddr(s)
	if err != nil {
		return netip.Prefix{}, fmt.Errorf("invalid IP address %q: %w", s, err)
	}
	return canonicalPrefix(netip.PrefixFrom(a, a.BitLen())), nil
}

// canonicalPrefix canonicalizes a prefix: prefixes that lie entirely within
// the IPv4-mapped IPv6 range (::ffff:0:0/96) are unmapped to IPv4, and every
// prefix is masked to its network address.
//
// The IPv4-mapped /96 block itself is NOT unmapped: doing so would collapse it
// to 0.0.0.0/0 and make it overlap every IPv4 address.
func canonicalPrefix(p netip.Prefix) netip.Prefix {
	addr := p.Addr()
	if addr.Is4In6() && p.Bits() > 96 {
		return netip.PrefixFrom(addr.Unmap(), p.Bits()-96).Masked()
	}
	return p.Masked()
}

// SortDedup removes duplicate prefixes and returns a deterministically sorted
// slice so that list ordering alone never triggers a CIDR group update.
func SortDedup(prefixes []netip.Prefix) []netip.Prefix {
	seen := make(map[netip.Prefix]struct{}, len(prefixes))
	out := make([]netip.Prefix, 0, len(prefixes))
	for _, p := range prefixes {
		if _, ok := seen[p]; ok {
			continue
		}
		seen[p] = struct{}{}
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].String() < out[j].String() })
	return out
}

func prefixesOverlap(a, b netip.Prefix) bool {
	return a.Contains(b.Addr()) || b.Contains(a.Addr())
}

// FilterOverlaps drops every prefix that overlaps (contains or is contained
// by) any filter prefix. Overlap is intentional: an exception must never be
// enforced even partially, and a protected infrastructure range must never be
// included inside a wider reputation entry.
func FilterOverlaps(prefixes, filter []netip.Prefix) (kept []netip.Prefix, removed int) {
	if len(filter) == 0 {
		return prefixes, 0
	}
	for _, p := range prefixes {
		drop := false
		for _, f := range filter {
			if prefixesOverlap(p, f) {
				drop = true
				break
			}
		}
		if drop {
			removed++
			continue
		}
		kept = append(kept, p)
	}
	return kept, removed
}

// shrinkRejected implements the sanity guard against truncated responses: a
// new list that is dramatically smaller than the current one is rejected
// unless it is below a floor where the comparison is not meaningful.
func shrinkRejected(previous, next, maxShrinkPercent int) bool {
	if maxShrinkPercent <= 0 || previous < 100 {
		return false
	}
	return next*100 < previous*(100-maxShrinkPercent)
}

func prefixesToStrings(prefixes []netip.Prefix) []string {
	out := make([]string, 0, len(prefixes))
	for _, p := range prefixes {
		out = append(out, p.String())
	}
	return out
}
