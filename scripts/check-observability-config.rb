# Regression checks for the cluster's telemetry and security noise filters.
# Run with: ruby scripts/check-observability-config.rb
require 'minitest/autorun'
require 'yaml'

class ObservabilityConfigTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def values(path)
    YAML.load_file(File.join(ROOT, path)).fetch('spec').fetch('values')
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
      assert_equal 'ValidatingPolicy', policy['kind']
      assert_includes policy.dig('spec', 'validationActions'), 'Deny'
    end
  end
end
