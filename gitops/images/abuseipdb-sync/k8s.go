package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/netip"
	"os"
	"path/filepath"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

const (
	managedByLabel         = "app.kubernetes.io/managed-by"
	managedByName          = "abuseipdb-sync"
	annotationLastOK       = "abuseipdb.io/last-success"
	annotationCloudflareOK = "abuseipdb.io/cloudflare-last-success"
	annotationCount        = "abuseipdb.io/entries"
	annotationStale        = "abuseipdb.io/stale-cleared-at"
)

// CiliumCIDRGroup graduated to v2 in Cilium 1.20; v2alpha1 is deprecated.
var ccgGVR = schema.GroupVersionResource{
	Group:    "cilium.io",
	Version:  "v2",
	Resource: "ciliumcidrgroups",
}

type CIDRGroupClient struct {
	client dynamic.Interface
	log    *slog.Logger
}

type GroupState struct {
	Exists                bool
	Prefixes              []netip.Prefix
	LastSuccess           time.Time
	CloudflareLastSuccess time.Time
	ManagedByUs           bool
}

type ApplyResult struct {
	Changed bool
	Added   int
	Removed int
	Created bool
}

// buildRestConfig prefers in-cluster credentials and falls back to a
// kubeconfig for local development and tests.
func buildRestConfig() (*rest.Config, error) {
	if cfg, err := rest.InClusterConfig(); err == nil {
		return cfg, nil
	}
	if kc := os.Getenv("KUBECONFIG"); kc != "" {
		return clientcmd.BuildConfigFromFlags("", kc)
	}
	if home, err := os.UserHomeDir(); err == nil {
		return clientcmd.BuildConfigFromFlags("", filepath.Join(home, ".kube", "config"))
	}
	return nil, errors.New("no in-cluster configuration and no kubeconfig found")
}

func (c *CIDRGroupClient) Get(ctx context.Context, name string) (*GroupState, error) {
	obj, err := c.client.Resource(ccgGVR).Get(ctx, name, metav1.GetOptions{})
	if apierrors.IsNotFound(err) {
		return &GroupState{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("getting CiliumCIDRGroup %q: %w", name, err)
	}
	prefixes, err := parseExternalCIDRs(obj)
	if err != nil {
		return nil, fmt.Errorf("parsing existing CiliumCIDRGroup %q: %w", name, err)
	}
	state := &GroupState{
		Exists:      true,
		Prefixes:    prefixes,
		ManagedByUs: isManagedByUs(obj),
	}
	if ts := obj.GetAnnotations()[annotationLastOK]; ts != "" {
		if t, err := time.Parse(time.RFC3339, ts); err == nil {
			state.LastSuccess = t
		}
	}
	if ts := obj.GetAnnotations()[annotationCloudflareOK]; ts != "" {
		if t, err := time.Parse(time.RFC3339, ts); err == nil {
			state.CloudflareLastSuccess = t
		}
	}
	return state, nil
}

// Apply writes the desired prefix list to the CIDR group in place, never
// deleting and recreating it. A zero successTime preserves the existing
// last-success annotation (used by the fail-open stale path), and a non-zero
// clearTime records that the group was intentionally emptied.
func (c *CIDRGroupClient) Apply(
	ctx context.Context,
	name string,
	prefixes []netip.Prefix,
	successTime time.Time,
	clearTime time.Time,
) (ApplyResult, error) {
	desired := prefixesToStrings(prefixes)

	for attempt := 1; attempt <= 5; attempt++ {
		obj, err := c.client.Resource(ccgGVR).Get(ctx, name, metav1.GetOptions{})
		if err != nil && !apierrors.IsNotFound(err) {
			return ApplyResult{}, fmt.Errorf("getting CiliumCIDRGroup %q: %w", name, err)
		}

		if apierrors.IsNotFound(err) {
			created := c.buildObject(name, desired, successTime, clearTime, "")
			if _, err := c.client.Resource(ccgGVR).Create(ctx, created, metav1.CreateOptions{}); err != nil {
				if apierrors.IsAlreadyExists(err) || apierrors.IsConflict(err) {
					continue
				}
				return ApplyResult{}, fmt.Errorf("creating CiliumCIDRGroup %q: %w", name, err)
			}
			c.log.Info("created CiliumCIDRGroup", "name", name, "entries", len(desired))
			return ApplyResult{Changed: len(desired) > 0, Added: len(desired), Created: true}, nil
		}

		if !isManagedByUs(obj) {
			return ApplyResult{}, fmt.Errorf(
				"CiliumCIDRGroup %q exists but is not managed by %s; refusing to overwrite it",
				name, managedByName)
		}

		current, err := parseExternalCIDRs(obj)
		if err != nil {
			return ApplyResult{}, fmt.Errorf("parsing existing CiliumCIDRGroup %q: %w", name, err)
		}
		added, removed := diffPrefixes(current, prefixes)

		updated := c.buildObject(name, desired, successTime, clearTime, obj.GetResourceVersion())
		mergeAnnotations(updated, obj, successTime)
		if _, err := c.client.Resource(ccgGVR).Update(ctx, updated, metav1.UpdateOptions{}); err != nil {
			if apierrors.IsConflict(err) {
				c.log.Info("CiliumCIDRGroup update conflict, retrying", "name", name, "attempt", attempt)
				time.Sleep(time.Duration(attempt) * 250 * time.Millisecond)
				continue
			}
			return ApplyResult{}, fmt.Errorf("updating CiliumCIDRGroup %q: %w", name, err)
		}
		return ApplyResult{Changed: added > 0 || removed > 0, Added: added, Removed: removed}, nil
	}
	return ApplyResult{}, fmt.Errorf("updating CiliumCIDRGroup %q: too many resourceVersion conflicts", name)
}

func (c *CIDRGroupClient) buildObject(
	name string,
	desired []string,
	successTime time.Time,
	clearTime time.Time,
	resourceVersion string,
) *unstructured.Unstructured {
	cidrs := make([]interface{}, 0, len(desired))
	for _, d := range desired {
		cidrs = append(cidrs, d)
	}
	annotations := map[string]interface{}{
		annotationCount: fmt.Sprintf("%d", len(desired)),
	}
	if !successTime.IsZero() {
		annotations[annotationLastOK] = successTime.UTC().Format(time.RFC3339)
	}
	if !clearTime.IsZero() {
		annotations[annotationStale] = clearTime.UTC().Format(time.RFC3339)
	}
	obj := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "cilium.io/v2",
		"kind":       "CiliumCIDRGroup",
		"metadata": map[string]interface{}{
			"name": name,
			"labels": map[string]interface{}{
				"app.kubernetes.io/name":       "abuseipdb-sync",
				"app.kubernetes.io/component":  "ip-reputation-feed",
				"app.kubernetes.io/part-of":    "infrastructure",
				"app.kubernetes.io/managed-by": managedByName,
				"security-source":              "abuseipdb",
			},
			"annotations": annotations,
		},
		"spec": map[string]interface{}{
			"externalCIDRs": cidrs,
		},
	}}
	if resourceVersion != "" {
		obj.SetResourceVersion(resourceVersion)
	}
	return obj
}

func mergeAnnotations(dst, src *unstructured.Unstructured, successTime time.Time) {
	ann := dst.GetAnnotations()
	if ann == nil {
		ann = map[string]string{}
	}
	existing := src.GetAnnotations()
	if successTime.IsZero() {
		if ts, ok := existing[annotationLastOK]; ok {
			ann[annotationLastOK] = ts
		}
	}
	// The Cloudflare sink success marker is owned by MergeAnnotations; always
	// carry it over so a Cilium update never drops it.
	if ts, ok := existing[annotationCloudflareOK]; ok {
		ann[annotationCloudflareOK] = ts
	}
	dst.SetAnnotations(ann)
}

// MergeAnnotations sets the given annotations on the managed CIDR group,
// preserving all other annotations. It is used to persist per-sink success
// timestamps outside of the list update path.
func (c *CIDRGroupClient) MergeAnnotations(ctx context.Context, name string, annotations map[string]string) error {
	for attempt := 1; attempt <= 5; attempt++ {
		obj, err := c.client.Resource(ccgGVR).Get(ctx, name, metav1.GetOptions{})
		if apierrors.IsNotFound(err) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("getting CiliumCIDRGroup %q: %w", name, err)
		}
		if !isManagedByUs(obj) {
			return fmt.Errorf("CiliumCIDRGroup %q is not managed by %s", name, managedByName)
		}
		ann := obj.GetAnnotations()
		if ann == nil {
			ann = map[string]string{}
		}
		changed := false
		for k, v := range annotations {
			if ann[k] != v {
				ann[k] = v
				changed = true
			}
		}
		if !changed {
			return nil
		}
		obj.SetAnnotations(ann)
		if _, err := c.client.Resource(ccgGVR).Update(ctx, obj, metav1.UpdateOptions{}); err != nil {
			if apierrors.IsConflict(err) {
				continue
			}
			return fmt.Errorf("updating annotations on CiliumCIDRGroup %q: %w", name, err)
		}
		return nil
	}
	return fmt.Errorf("updating annotations on CiliumCIDRGroup %q: too many resourceVersion conflicts", name)
}

func parseExternalCIDRs(obj *unstructured.Unstructured) ([]netip.Prefix, error) {
	raw, found, err := unstructured.NestedStringSlice(obj.Object, "spec", "externalCIDRs")
	if err != nil {
		return nil, err
	}
	if !found {
		return nil, nil
	}
	out := make([]netip.Prefix, 0, len(raw))
	for _, s := range raw {
		p, err := parseEntry(s)
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, nil
}

func isManagedByUs(obj *unstructured.Unstructured) bool {
	return obj.GetLabels()[managedByLabel] == managedByName
}

func diffPrefixes(current, desired []netip.Prefix) (added, removed int) {
	cur := make(map[netip.Prefix]struct{}, len(current))
	for _, p := range current {
		cur[p] = struct{}{}
	}
	des := make(map[netip.Prefix]struct{}, len(desired))
	for _, p := range desired {
		des[p] = struct{}{}
	}
	for p := range des {
		if _, ok := cur[p]; !ok {
			added++
		}
	}
	for p := range cur {
		if _, ok := des[p]; !ok {
			removed++
		}
	}
	return added, removed
}
