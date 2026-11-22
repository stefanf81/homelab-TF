# Regression checks for the cluster's telemetry and security noise filters.
# Run with: ruby scripts/check-observability-config.rb
require 'minitest/autorun'
require 'yaml'

class ObservabilityConfigTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def values(path)
    YAML.load_file(File.join(ROOT, path)).fetch('spec').fetch('values')
  end

  # The synchronizer must never block a Cloudflare edge address (proxied visitors
  # reach the Gateway from them). Its protected list carries the same snapshot as
  # the WAFs' trusted_proxies; fail when either side changes alone.
  def test_abuseipdb_protects_the_waf_cloudflare_ranges
    waf_ranges = %w[backend frontend].map do |waf|
      caddyfile = YAML.load_stream(File.read(File.join(ROOT, "gitops/apps/taskflow/#{waf}-waf.yaml")))
                      .compact.find { |d| d['kind'] == 'ConfigMap' && d.dig('data', 'Caddyfile') }
                      .dig('data', 'Caddyfile')
      block = caddyfile[/trusted_proxies static (.*?)\n\s*trusted_proxies_strict/m, 1]
      refute_nil block, "#{waf}-waf: trusted_proxies list not found"
      block.scan(%r{[0-9a-f:.]+/\d+}) - ['10.42.0.148/32']
    end
    assert_equal waf_ranges[0].sort, waf_ranges[1].sort, 'the two WAF Cloudflare lists differ'
    files = YAML.load_stream(File.read(File.join(ROOT, 'gitops/platform/abuseipdb/config.yaml')))
                .compact.find { |d| d.dig('metadata', 'name') == 'abuseipdb-sync-files' }
    protected = files.dig('data', 'protected-cidrs.txt').lines.map { |l| l.sub(/#.*/, '').strip }.reject(&:empty?)
    assert_empty waf_ranges[0] - protected, 'Cloudflare ranges missing from abuseipdb protected-cidrs.txt'
    cloudflare_in_protected = protected.select { |c| c.include?('/') && !c.start_with?('10.') } - waf_ranges[0]
    assert_empty cloudflare_in_protected, 'protected-cidrs.txt lists ranges the WAF snapshot does not (update both)'
  end

  def test_apiserver_drops_duplicate_kubelet_metrics_only
    config = values('gitops/monitoring/platform/release.yaml')
    endpoint = config.dig('kubeApiServer', 'vmScrape', 'spec', 'endpoints').first
    rule = endpoint.fetch('metricRelabelConfigs').find { |r| r['regex'] == 'kubelet_.+' }
    refute_nil rule
    assert_equal 'drop', rule['action']
    assert_equal ['__name__'], rule['source_labels']
    pattern = Regexp.new("\\A(?:#{rule.fetch('regex')})\\z")
    %w[kubelet_volume_stats_used_bytes kubelet_volume_stats_capacity_bytes kubelet_running_pods].each do |metric|
      assert_match pattern, metric
    end
    %w[apiserver_request_total apiserver_request_sli_duration_seconds_bucket etcd_request_duration_seconds_count].each do |metric|
      refute_match pattern, metric
    end
    kubelet_rules = config.dig('kubelet', 'vmScrape', 'spec', 'metricRelabelConfigs')
    refute kubelet_rules.any? { |r| r['action'] == 'drop' && Regexp.new("\\A(?:#{r['regex']})\\z").match?('kubelet_volume_stats_used_bytes') }
  end

  def test_falco_exceptions_are_exact_client_tuples_on_one_rule
    config = values('gitops/infrastructure/controllers/falco/release.yaml')
    rules = YAML.safe_load(config.fetch('customRules').fetch('homelab-api-clients.yaml'))
    assert_equal 1, rules.length
    rule = rules.first
    assert_equal 'Contact K8S API Server From Container', rule['rule']
    assert_equal({ 'exceptions' => 'append' }, rule['override'])
    refute rule.key?('enabled')
    exception = rule.fetch('exceptions').first
    assert_equal ['k8s.ns.name', 'container.image.repository', 'proc.exepath'], exception['fields']
    assert_equal ['=', '=', '='], exception['comps']
    clients = exception.fetch('values')
    refute_empty clients
    assert_equal clients.uniq, clients
    clients.each do |ns, image, executable|
      assert_match(/\A[a-z0-9-]+\z/, ns)
      assert_match(/\A[a-z0-9.\/-]+\z/, image)
      assert executable.start_with?('/'), executable
      refute_includes %w[/bin/sh /bin/bash /usr/bin/curl /usr/bin/wget], executable
      # A shell in a trusted image, a foreign image or another namespace must
      # not inherit the controller's API-access exception.
      refute_includes clients, [ns, image, '/bin/sh']
      refute_includes clients, [ns, 'docker.io/library/alpine', executable]
      refute_includes clients, ['untrusted-namespace', image, executable]
    end
  end

  def test_kyverno_exceptions_disabled_without_disabling_policies
    config = values('gitops/infrastructure/controllers/kyverno/release.yaml')
    assert_equal false, config.dig('features', 'policyExceptions', 'enabled')
    assert_equal 'kyverno', config.dig('features', 'policyExceptions', 'namespace')
    assert_equal true, config.dig('features', 'autoUpdateWebhooks', 'enabled')
    Dir.glob(File.join(ROOT, 'gitops/apps/kyverno-policies/*.yaml')).each do |path|
      policy = YAML.load_file(path)
      next if policy['kind'] == 'Kustomization'
      assert_equal 'policies.kyverno.io/v1', policy['apiVersion']
      assert_includes %w[ValidatingPolicy ImageValidatingPolicy], policy['kind'], path
      actions = policy.dig('spec', 'validationActions')
      if policy['kind'] == 'ImageValidatingPolicy'
        # Image verification is rolled out Audit -> Deny (docs/KYVERNO_POLICY_ENGINE.md §8).
        assert_includes [['Audit'], ['Deny']], actions, path
      else
        assert_includes actions, 'Deny', path
      end
    end
  end

  # The TaskFlow image policies trust exactly one signer: the publish workflow of
  # stefanf81/taskflow-enterprise run from main. A regexp identity, another ref or
  # a wider image glob would let other workflows' images through.
  TASKFLOW_SIGNER = {
    'subject' => 'https://github.com/stefanf81/taskflow-enterprise/.github/workflows/pushdockerimage.yml@refs/heads/main',
    'issuer' => 'https://token.actions.githubusercontent.com'
  }.freeze
  TASKFLOW_IMAGE_GLOBS = %w[backend frontend].flat_map do |component|
    ["ghcr.io/stefanf81/taskflow-#{component}:*", "ghcr.io/stefanf81/taskflow-#{component}@*"]
  end.freeze

  def test_taskflow_image_policies_pin_the_release_workflow
    policies = %w[verify-taskflow-images require-taskflow-image-scan].to_h do |name|
      [name, YAML.load_file(File.join(ROOT, "gitops/apps/kyverno-policies/#{name}.yaml"))]
    end
    policies.each do |name, policy|
      spec = policy.fetch('spec')
      assert_equal name, policy.dig('metadata', 'name')
      assert_equal TASKFLOW_IMAGE_GLOBS, spec.fetch('matchImageReferences').map { |m| m.fetch('glob') }, name
      assert_equal ['taskflow'], [spec.dig('matchConstraints', 'namespaceSelector', 'matchLabels', 'kubernetes.io/metadata.name')], name
      # Digest pinning and the "every matched image was verified" check stay on.
      (spec['validationConfigurations'] || {}).each_value { |enabled| refute_equal false, enabled, name }
      spec.fetch('attestors').each do |attestor|
        keyless = attestor.dig('cosign', 'keyless')
        assert_equal [TASKFLOW_SIGNER], keyless.fetch('identities'), "#{name}/#{attestor['name']}"
        assert_equal ['identities'], keyless.keys, "#{name}/#{attestor['name']}: no extra roots"
        refute attestor.dig('cosign', 'ctlog', 'insecureIgnoreTlog'), name
        refute attestor.dig('cosign', 'ctlog', 'insecureIgnoreSCT'), name
      end
    end

    verify = policies.fetch('verify-taskflow-images').fetch('spec')
    scanned = verify.fetch('attestors').find { |a| a['name'] == 'scannedRelease' }
    assert_equal({ 'scan' => 'passed' }, scanned.dig('cosign', 'annotations'))
    assert_equal ['https://slsa.dev/provenance/v1'], verify.fetch('attestations').map { |a| a.dig('intoto', 'type') }
    scan = policies.fetch('require-taskflow-image-scan').fetch('spec')
    assert_equal ['https://cosign.sigstore.dev/attestation/vuln/v1'], scan.fetch('attestations').map { |a| a.dig('intoto', 'type') }
  end

  def documents(path)
    YAML.load_stream(File.read(File.join(ROOT, path))).compact.select { |d| d.is_a?(Hash) }
  end

  def test_taskflow_monitoring_scrapes_allow_only_vmagent_per_port
    docs = documents('gitops/apps/taskflow/namespace-default-deny.yaml')
    refute docs.any? { |d| d.dig('metadata', 'name') == 'allow-monitoring-scrape' },
           'legacy namespace-wide allow-monitoring-scrape must not return'

    expected = {
      'allow-vmagent-to-backend' => ['taskflow-backend', '8080'],
      'allow-vmagent-to-postgres-exporter' => ['postgres-exporter', '9187'],
      'allow-vmagent-to-redis-exporter' => ['redis-exporter', '9121']
    }
    expected.each do |policy_name, (app, port)|
      pol = docs.find { |d| d['kind'] == 'CiliumNetworkPolicy' && d.dig('metadata', 'name') == policy_name }
      refute_nil pol, "missing CiliumNetworkPolicy #{policy_name}"
      assert_equal({ 'app' => app }, pol.dig('spec', 'endpointSelector', 'matchLabels'))
      ingress = pol.dig('spec', 'ingress')
      assert_equal 1, ingress.length
      from = ingress.first.fetch('fromEndpoints')
      assert_equal 1, from.length
      labels = from.first.fetch('matchLabels')
      assert_equal 'monitoring', labels['k8s:io.kubernetes.pod.namespace']
      assert_equal 'vmagent', labels['k8s:app.kubernetes.io/name']
      ports = ingress.first.fetch('toPorts').flat_map { |tp| tp.fetch('ports') }
      assert_equal [{ 'port' => port, 'protocol' => 'TCP' }], ports
      # No L7 HTTP rule on backend:8080 so WAF -> backend stays on eBPF fast path.
      assert ingress.first.fetch('toPorts').none? { |tp| tp.key?('rules') }
    end
  end

  def test_oauth2_proxies_use_distinct_host_only_cookies_and_exact_whitelists
    proxies = {
      'gitops/platform/hubble-ui/release.yaml' => ['__Host-o2p-hubble', 'hubble.${DOMAIN}'],
      'gitops/platform/policy-reporter/oauth2-proxy-release.yaml' => ['__Host-o2p-kyverno', 'kyverno.${DOMAIN}']
    }
    cookie_names = []
    proxies.each do |path, (expected_cookie, expected_host)|
      cfg = values(path).dig('config', 'configFile')
      refute_nil cfg
      refute_match(/^\s*cookie_domains\s*=/, cfg, "#{path} must omit cookie_domains for host-only __Host- cookies")
      assert_match(/^\s*cookie_name\s*=\s*"#{Regexp.escape(expected_cookie)}"\s*$/, cfg)
      assert_match(/^\s*cookie_secure\s*=\s*true\s*$/, cfg)
      assert_match(/^\s*cookie_samesite\s*=\s*"lax"\s*$/, cfg)
      assert_match(/^\s*whitelist_domains\s*=\s*\["#{Regexp.escape(expected_host)}"\]\s*$/, cfg)
      cookie_names << expected_cookie
    end
    assert_equal cookie_names.uniq, cookie_names
  end

  def test_oauth2_proxy_upstreams_are_isolated_on_pod_network
    polr_docs = documents('gitops/platform/policy-reporter/oauth2-proxy-network-policy.yaml')
    polr_deny = polr_docs.find { |d| d['kind'] == 'CiliumNetworkPolicy' && d.dig('metadata', 'name') == 'policy-reporter-ingress-default-deny' }
    refute_nil polr_deny
    assert_equal({}, polr_deny.dig('spec', 'endpointSelector'))

    polr_scrape = polr_docs.find { |d| d['kind'] == 'CiliumNetworkPolicy' && d.dig('metadata', 'name') == 'allow-vmagent-to-policy-reporter' }
    refute_nil polr_scrape
    assert_equal 'vmagent', polr_scrape.dig('spec', 'ingress', 0, 'fromEndpoints', 0, 'matchLabels', 'k8s:app.kubernetes.io/name')

    hubble_ns_docs = documents('gitops/platform/hubble-ui/network-policy.yaml')
    assert hubble_ns_docs.any? { |d| d['kind'] == 'CiliumNetworkPolicy' && d.dig('spec', 'endpointSelector') == {} }

    kube_docs = documents('gitops/infrastructure/configs/cilium/hubble-isolation.yaml')
    ui_pol = kube_docs.find { |d| d.dig('metadata', 'name') == 'restrict-hubble-ui-ingress' }
    relay_pol = kube_docs.find { |d| d.dig('metadata', 'name') == 'restrict-hubble-relay-ingress' }
    refute_nil ui_pol
    refute_nil relay_pol
    assert_equal 'kube-system', ui_pol.dig('metadata', 'namespace')
    assert_equal 'kube-system', relay_pol.dig('metadata', 'namespace')
    assert_equal({ 'k8s-app' => 'hubble-ui' }, ui_pol.dig('spec', 'endpointSelector', 'matchLabels'))
    assert_equal '8081', ui_pol.dig('spec', 'ingress', 0, 'toPorts', 0, 'ports', 0, 'port')
    assert_equal({ 'k8s-app' => 'hubble-relay' }, relay_pol.dig('spec', 'endpointSelector', 'matchLabels'))
    assert_equal '4245', relay_pol.dig('spec', 'ingress', 0, 'toPorts', 0, 'ports', 0, 'port')
  end
end
