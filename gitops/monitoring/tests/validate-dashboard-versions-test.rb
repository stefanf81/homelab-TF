require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "validate-dashboard-versions"

# Offline tests for validate-dashboard-versions.rb: registry and index requests
# are stubbed; the real pins are checked by running the script itself.
class DashboardVersionValidationTest < Minitest::Test
  V = DashboardVersionValidation
  COMPONENTS = [
    { name: "Kyverno", labels: ["Kyverno"], source: { kind: "oci", path: "kyverno.yaml" } },
    { name: "Falco", labels: ["Falco"], source: { kind: "oci", path: "falco.yaml" } },
    { name: "cert-manager", labels: ["cert-manager"], source: { kind: "oci", path: "cert-manager.yaml" } },
    { name: "VictoriaMetrics", labels: ["VictoriaMetrics", "VMSingle"], source: { kind: "helm" } }
  ].freeze
  DEPLOYED = {
    "Kyverno" => { app: "1.20.0", chart: "3.10.0" },
    "Falco" => { app: "0.45.2", chart: "9.2.2" },
    "cert-manager" => { app: "1.21.3", chart: "1.21.3" },
    "VictoriaMetrics" => { app: "1.156.0", chart: "0.98.1" }
  }.freeze

  def with_method_stub(receiver, name, replacement)
    original = receiver.method(name)
    receiver.define_singleton_method(name, &replacement)
    yield
  ensure
    receiver.define_singleton_method(name, original)
  end

  def with_docs(files)
    Dir.mktmpdir("dashboard-versions-") do |root|
      files.each do |path, content|
        FileUtils.mkdir_p(File.dirname(File.join(root, path)))
        File.write(File.join(root, path), content)
      end
      yield root
    end
  end

  def scan(text)
    with_docs("docs/SOURCE.md" => text) { |root| V.mentions(root, COMPONENTS, ["docs/*.md"]) }
  end

  def check(text)
    V.compare(scan(text), DEPLOYED)
  end

  def test_parses_app_chart_and_chart_only_mentions
    found = scan(<<~TEXT)
      Checked against Kyverno v1.20.0 (`pkg/metrics`). Kyverno 1.20 exports no info metric.
      Adapted for Falco 0.45.2 (chart 9.2.2, modern eBPF); the Falco chart 9.2.2 dashboard.
      VMSingle version (VictoriaMetrics v1.156.0, stack chart 0.98.1).
    TEXT
    got = found.map { |m| [m.component, m.version, m.chart, m.line] }
    assert_equal [["Kyverno", "1.20.0", nil, 1], ["Kyverno", "1.20", nil, 1],
                  ["Falco", "0.45.2", "9.2.2", 2], ["Falco", nil, "9.2.2", 2],
                  ["VictoriaMetrics", "1.156.0", "0.98.1", 3]], got
  end

  def test_minor_mismatch_fails_with_location_and_deployed_version
    failures, = check("Names checked against Kyverno v1.19.2.\nKyverno 1.19 exports no info metric.\n")
    assert_equal 2, failures.length
    assert_match(%r{\Adocs/SOURCE\.md:1: "Kyverno v1\.19\.2" names 1\.19\.2, but the repository deploys Kyverno 1\.20\.0 \(chart 3\.10\.0\)},
                 failures[0])
    assert_match(/docs\/SOURCE\.md:2: "Kyverno 1\.19" names 1\.19,/, failures[1])
  end

  def test_patch_drift_is_a_note_not_a_failure
    failures, notes = check("checked against cert-manager v1.21.2 and Falco 0.45.1 (chart 9.2.1).\n")
    assert_empty failures
    assert_equal 3, notes.length
    assert(notes.all? { |note| note.include?("patch drift, allowed") })
  end

  def test_chart_minor_mismatch_fails_even_when_the_app_matches
    failures, = check("Falco 0.45.2 (chart 9.3.0, modern eBPF)\n")
    assert_equal 1, failures.length
    assert_includes failures.first, "names chart 9.3.0"
  end

  def test_chart_only_mention_is_not_read_as_an_app_version
    failures, notes = check("the Falco chart 9.2.2 ships the dashboard\n")
    assert_empty failures
    assert_empty notes
  end

  def test_ignores_unrelated_versions_and_label_substrings
    found = scan(<<~TEXT)
      exporter 0.3.1, Grafana 13.2.x, NSA 1.0, CIS 1.23, a flat 4.75 ms line,
      my-cert-manager 1.0.0, kyverno_policy 1.19.0 and Falcon 9.9.9.
    TEXT
    assert_empty found
  end

  def test_versions_in_dashboard_json_strings_are_found_per_line
    dashboard = JSON.pretty_generate("panels" => [{ "description" => "Kyverno 1.20 exports no info metric." },
                                                  { "options" => { "content" => "Checked against\nKyverno v1.19.2." } }])
    found = with_docs("dash/x.json" => dashboard) { |root| V.mentions(root, COMPONENTS, ["dash/*.json"]) }
    assert_equal [["1.20", 4], ["1.19.2", 8]], found.map { |m| [m.version, m.line] }
  end

  def oci_repository(tag: "3.10.0", digest: "sha256:#{'a' * 64}")
    YAML.dump("apiVersion" => "source.toolkit.fluxcd.io/v1", "kind" => "OCIRepository",
              "metadata" => { "name" => "kyverno" },
              "spec" => { "url" => "oci://ghcr.io/kyverno/charts/kyverno", "ref" => { "tag" => tag, "digest" => digest } })
  end

  def test_oci_pin_reads_app_version_at_the_pinned_digest
    with_docs("kyverno.yaml" => oci_repository) do |root|
      calls = []
      stub = lambda do |url, reference, digest|
        calls << [url, reference, digest]
        { "version" => "3.10.0", "appVersion" => "v1.20.0" }
      end
      with_method_stub(V, :oci_chart_metadata, stub) do
        assert_equal({ chart: "3.10.0", app: "1.20.0" }, V.oci_pin(File.join(root, "kyverno.yaml")))
      end
      assert_equal [["oci://ghcr.io/kyverno/charts/kyverno", "sha256:#{'a' * 64}", "sha256:#{'a' * 64}"]], calls
    end
  end

  def test_oci_pin_rejects_a_digest_that_is_another_chart_version
    with_docs("kyverno.yaml" => oci_repository) do |root|
      with_method_stub(V, :oci_chart_metadata, ->(*) { { "version" => "3.9.2", "appVersion" => "v1.19.2" } }) do
        error = assert_raises(RuntimeError) { V.oci_pin(File.join(root, "kyverno.yaml")) }
        assert_includes error.message, "is chart 3.9.2, not the pinned tag 3.10.0"
      end
    end
  end

  Response = Struct.new(:code, :body, :headers) do
    def [](key) = headers[key.downcase]
    def is_a?(klass) = klass == Net::HTTPSuccess ? code == "200" : super
  end

  def test_oci_metadata_uses_an_anonymous_token_and_verifies_digests
    config = JSON.generate("name" => "kyverno", "version" => "3.10.0", "appVersion" => "v1.20.0")
    config_digest = "sha256:#{Digest::SHA256.hexdigest(config)}"
    manifest = JSON.generate("config" => { "mediaType" => "application/vnd.cncf.helm.config.v1+json", "digest" => config_digest })
    manifest_digest = "sha256:#{Digest::SHA256.hexdigest(manifest)}"
    challenge = 'Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:kyverno/charts/kyverno:pull"'
    seen = []
    stub = lambda do |url, accept: nil, token: nil, redirects: 5|
      seen << [url, token]
      case url
      when %r{/manifests/} then token ? Response.new("200", manifest, {}) : Response.new("401", "", { "www-authenticate" => challenge })
      when %r{/token\?} then Response.new("200", JSON.generate("token" => "anon"), {})
      when %r{/blobs/} then Response.new("200", config, {})
      else flunk "unexpected request #{url}"
      end
    end
    with_method_stub(V, :request, stub) do
      metadata = V.oci_chart_metadata("oci://ghcr.io/kyverno/charts/kyverno", manifest_digest, manifest_digest)
      assert_equal "v1.20.0", metadata["appVersion"]
      error = assert_raises(RuntimeError) do
        V.oci_chart_metadata("oci://ghcr.io/kyverno/charts/kyverno", manifest_digest, "sha256:#{'0' * 64}")
      end
      assert_includes error.message, "does not match"
    end
    assert_equal ["https://ghcr.io/token?service=ghcr.io&scope=repository%3Akyverno%2Fcharts%2Fkyverno%3Apull", nil], seen[1]
    assert_equal "anon", seen[3].last
  end

  def test_helm_pin_reads_app_version_from_the_repository_index
    release = YAML.dump("apiVersion" => "helm.toolkit.fluxcd.io/v2", "kind" => "HelmRelease",
                        "metadata" => { "name" => "alloy", "namespace" => "monitoring" },
                        "spec" => { "chart" => { "spec" => { "chart" => "alloy", "version" => "1.16.0",
                                                             "sourceRef" => { "kind" => "HelmRepository", "name" => "grafana" } } } })
    repositories = YAML.dump("kind" => "HelmRepository", "metadata" => { "name" => "grafana", "namespace" => "monitoring" },
                             "spec" => { "url" => "https://grafana.github.io/helm-charts" })
    index = YAML.dump("entries" => { "alloy" => [{ "version" => "1.16.0", "appVersion" => "v1.22.0" },
                                                 { "version" => "1.15.0", "appVersion" => "v1.21.3" }] })
    with_docs("release.yaml" => release, "repositories.yaml" => repositories) do |root|
      urls = []
      with_method_stub(LokiVersionValidation, :get, ->(url, **) { urls << url; index }) do
        assert_equal({ chart: "1.16.0", app: "1.22.0" },
                     V.helm_pin(File.join(root, "release.yaml"), File.join(root, "repositories.yaml")))
      end
      assert_equal ["https://grafana.github.io/helm-charts/index.yaml"], urls
    end
  end

  def test_run_reports_every_failure_together
    with_docs("docs/SOURCE.md" => "Kyverno v1.19.2 and VictoriaMetrics v1.155.0 (stack chart 0.97.0)\n") do |root|
      with_method_stub(V, :deployed, ->(_root, component) { DEPLOYED.fetch(component[:name]) }) do
        error = assert_raises(RuntimeError) { V.run(root, COMPONENTS, ["docs/*.md"]) }
        assert_equal 3, error.message.lines.length
      end
    end
  end
end
