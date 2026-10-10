require "minitest/autorun"
require "tempfile"
require "fileutils"
require "tmpdir"
require_relative "validate-dashboards"
require_relative "validate-dashboard-provisioning"

class DashboardValidationTest < Minitest::Test
  def panel(id, y = 0)
    {
      "id" => id, "title" => "Count", "type" => "timeseries",
      "gridPos" => { "x" => 0, "y" => y, "w" => 12, "h" => 8 },
      "datasource" => { "type" => "loki", "uid" => "loki" },
      "interval" => "5m", "maxDataPoints" => 300,
      "targets" => [{ "refId" => "A", "expr" => 'sum(count_over_time({job="test"}[$__interval]))' }]
    }
  end

  def errors(panels, variables = [])
    DashboardValidation.check("uid" => "test", "title" => "Test", "panels" => panels,
                              "templating" => { "list" => variables }).first
  end

  def variable(name, query)
    { "name" => name, "type" => "query", "query" => query,
      "datasource" => { "type" => "loki", "uid" => "loki" } }
  end

  def with_yaml_documents(*documents)
    Tempfile.create(["dashboard-validation-", ".yaml"]) do |file|
      documents.each { |document| file.write(YAML.dump(document)) }
      file.flush
      yield file.path
    end
  end

  def with_temp_dashboard(dashboard)
    Tempfile.create(["dashboard-", ".json"]) do |file|
      file.write(JSON.generate(dashboard))
      file.flush
      yield file.path
    end
  end

  def provisioning_tree(name = "fixture")
    { name: name, kustomization: "tree", dashboards: "tree/dashboards" }
  end

  def provisioning_source(name, dashboard)
    { path: "/fixtures/#{name}", name: name, dashboard: dashboard }
  end

  def provisioning_dashboard(uid)
    { "uid" => uid, "title" => uid, "panels" => [] }
  end

  def provisioning_configmap(name:, key:, dashboard:, folder: "Security", namespace: "monitoring",
                             labels: { "grafana_dashboard" => "1" }, data: {})
    {
      "apiVersion" => "v1", "kind" => "ConfigMap",
      "metadata" => { "name" => name, "namespace" => namespace, "labels" => labels,
                      "annotations" => { "grafana_folder" => folder } },
      "data" => { key => JSON.generate(dashboard) }.merge(data)
    }
  end

  def with_kustomize_fixture(resources)
    Dir.mktmpdir("dashboard-provisioning-") do |directory|
      FileUtils.mkdir_p(File.join(directory, "tree", "dashboards"))
      File.write(File.join(directory, "tree", "dashboards", "fixture.json"),
                 JSON.generate(provisioning_dashboard("fixture")))
      File.write(File.join(directory, "tree", "dashboards", "kustomization.yaml"), <<~YAML)
        apiVersion: kustomize.config.k8s.io/v1beta1
        kind: Kustomization
        namespace: monitoring
        configMapGenerator:
          - name: fixture-dashboard
            files:
              - fixture.json
            options:
              disableNameSuffixHash: true
              annotations:
                grafana_folder: Fixture
              labels:
                grafana_dashboard: "1"
      YAML
      File.write(File.join(directory, "tree", "other.yaml"), <<~YAML)
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: other
          namespace: monitoring
      YAML
      File.write(File.join(directory, "tree", "kustomization.yaml"),
                 "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n" +
                 resources.map { |resource| "  - #{resource}\n" }.join)
      yield directory
    end
  end

  # Keep these small transport stubs independent of optional Minitest mock gems.
  def with_method_stub(receiver, name, replacement)
    original = receiver.method(name)
    receiver.define_singleton_method(name, &replacement)
    yield
  ensure
    receiver.define_singleton_method(name, original)
  end

  def test_rejects_unknown_variables_in_targets_and_chained_variable_queries
    invalid = panel(1)
    invalid["targets"][0]["expr"] = 'sum(count_over_time({application=~"$applcation"}[$__interval]))'
    variables = [variable("application", 'label_values({job="coraza-waf"}, application)'),
                 variable("pod", 'label_values({application=~"${applcation:regex}"}, pod)')]
    failures = errors([invalid], variables)
    assert_equal 2, failures.count { |error| error.include?("undefined dashboard variable $applcation") }
    assert failures.any? { |error| error.include?('variable "pod"') }
    assert failures.any? { |error| error.include?("panel 1") }
  end

  def test_accepts_grafana_reference_forms_and_go_template_locals
    expression = '$application ${application} ${application:regex} [[application]] [[application:regex]] ${__user.login} $__interval'
    assert_empty DashboardValidation.reference_errors(expression, ["application"], "loki")
    expression = '{{ $suffix := .application }}{{ range $index, $item := .items }}{{ printf "%s" $suffix }}{{ $index }}{{ $item }}{{ end }}'
    assert_empty DashboardValidation.reference_errors(expression, [], "loki")
    assert_empty DashboardValidation.reference_errors('$__rate_interval', [], "prometheus")
    assert_equal ["undefined dashboard variable $__intrval"], DashboardValidation.reference_errors('$__intrval', [], "loki")
  end

  def test_label_values_splitter_preserves_quoted_commas_delimiters_and_escapes
    selector = %q({job="coraza,waf", note="escaped \"quote\", brace } and comma ,", application=~"${application:regex}"})
    assert_equal selector, DashboardValidation.label_values_selector("label_values(#{selector}, pod)")
    selector = '{note=`comma , and brace }`, job="coraza-waf"}'
    assert_equal selector, DashboardValidation.label_values_selector("label_values(#{selector}, pod)")
    assert_nil DashboardValidation.label_values_selector("label_values(application)")
  end

  def test_rejects_malformed_label_values_wrappers
    ['label_values({job="waf"}, pod', 'label_values({job="waf}, pod)',
     'label_values({job="waf"}, pod, extra)', 'label_values({job="waf"}, )'].each do |query|
      assert_raises(RuntimeError) { DashboardValidation.label_values_selector(query) }
    end
    assert errors([], [variable("application", 'label_values({job="waf"}, )')]).any? { |error|
      error.include?('variable "application"') && error.include?("label_values")
    }
  end

  def test_collects_variable_selectors_for_real_parser_validation
    selector = '{job="coraza-waf", application=~"$application"}'
    variables = [variable("application", 'label_values({job="coraza-waf"}, application)'),
                 variable("pod", { "query" => "label_values(#{selector}, pod)" })]
    failures, queries = DashboardValidation.check("uid" => "test", "title" => "Test", "panels" => [],
                                                  "templating" => { "list" => variables })
    assert_empty failures
    assert_equal [selector], queries.select { |context, _expression| context.include?('variable "pod"') }.map(&:last)
    assert_equal 2, queries.length
  end

  def test_missing_panel_ids_and_target_refs_do_not_produce_duplicate_errors
    first = panel(1)
    second = panel(2, 8)
    [first, second].each { |item| item.delete("id") }
    first["targets"] = [{ "expr" => "up" }, { "expr" => "up" }]
    failures = errors([first, second])
    assert_equal 2, failures.count { |error| error.include?("id must be a positive integer") }
    assert_equal 2, failures.count { |error| error.include?("missing refId") }
    refute failures.any? { |error| error.include?("duplicate") }
  end

  def test_missing_dashboard_uids_do_not_produce_duplicate_errors
    documents = 2.times.map do |index|
      { "kind" => "ConfigMap", "metadata" => { "name" => "test-#{index}", "labels" => { "grafana_dashboard" => "1" } },
        "data" => { "test.json" => JSON.generate("title" => "Test", "panels" => []) } }
    end
    with_yaml_documents(*documents) do |path|
      error = assert_raises(RuntimeError) { DashboardValidation.run(path) }
      assert_equal 2, error.message.scan("missing dashboard uid").length
      refute_includes error.message, "duplicate dashboard uid"
    end
  end

  def test_json_inputs_are_loaded_from_bare_files
    with_temp_dashboard("uid" => "json-uid", "title" => "JSON", "panels" => []) do |path|
      out, = capture_io { DashboardValidation.run([path]) }
      assert_includes out, "1 dashboards"
    end
  end

  def test_multiple_paths_detect_cross_file_duplicate_uids
    with_temp_dashboard("uid" => "dup-uid", "title" => "One", "panels" => []) do |first|
      with_temp_dashboard("uid" => "dup-uid", "title" => "Two", "panels" => []) do |second|
        error = assert_raises(RuntimeError) { DashboardValidation.run([first, second]) }
        assert_includes error.message, "duplicate dashboard uid \"dup-uid\""
      end
    end
  end

  def test_transport_failure_has_query_context_and_stops_after_first_request
    calls = 0
    context = 'taskflow-waf-dashboard/taskflow-waf.json: panel 7 target "A"'
    transport = lambda do |*_arguments|
      calls += 1
      raise Errno::ECONNREFUSED, "fixture server unavailable"
    end
    with_method_stub(DashboardValidation, :get, transport) do
      error = assert_raises(RuntimeError) do
        DashboardValidation.parse_queries("http://127.0.0.1:3100", [[context, '{job="test"}'], ["second query", '{job="other"}']])
      end
      assert_includes error.message, context
      assert_includes error.message, "transport failure"
      assert_equal 1, calls
    end
  end

  def test_chart_version_changes_resolve_the_corresponding_app_version
    index = { "entries" => { "loki" => [{ "version" => "18.13.7", "appVersion" => "3.7.8" },
                                          { "version" => "18.14.0", "appVersion" => "3.8.0" }] } }
    assert_equal "3.7.8", LokiVersionValidation.app_version(index, "loki", "18.13.7")
    assert_equal "3.8.0", LokiVersionValidation.app_version(index, "loki", "18.14.0")
    assert_raises(RuntimeError) { LokiVersionValidation.app_version(index, "loki", "unknown") }
    index["entries"]["loki"].first.delete("appVersion")
    assert_raises(RuntimeError) { LokiVersionValidation.app_version(index, "loki", "18.13.7") }
  end

  def test_release_repository_resolution_and_explicit_image_tag
    release = { "kind" => "HelmRelease", "metadata" => { "name" => "loki", "namespace" => "monitoring" },
                "spec" => { "chart" => { "spec" => { "chart" => "loki", "version" => "18.13.7",
                                                    "sourceRef" => { "kind" => "HelmRepository", "name" => "grafana" } } } } }
    repository = { "kind" => "HelmRepository", "metadata" => { "name" => "grafana", "namespace" => "monitoring" },
                   "spec" => { "url" => "https://example.test/charts" } }
    index = YAML.dump("entries" => { "loki" => [{ "version" => "18.13.7", "appVersion" => "3.7.8" }] })
    requested = []
    with_method_stub(LokiVersionValidation, :get, ->(url) { requested << url; index }) do
      with_yaml_documents(release) do |release_path|
        with_yaml_documents(repository) do |repo_path|
          assert_equal "3.7.8", LokiVersionValidation.deployment_version(release_path, repo_path)
        end
      end
      release["spec"]["values"] = { "loki" => { "image" => { "tag" => "3.8.0" } } }
      with_yaml_documents(release) do |release_path|
        with_yaml_documents(repository) do |repo_path|
          assert_equal "3.8.0", LokiVersionValidation.deployment_version(release_path, repo_path)
        end
      end
    end
    assert_equal ["https://example.test/charts/index.yaml"], requested
  end

  def test_runtime_version_mismatch_requires_explicit_migration_override
    with_method_stub(LokiVersionValidation, :get, ->(_url, **_options) { JSON.generate("version" => "3.7.8") }) do
      assert_equal "3.7.8", LokiVersionValidation.check_runtime("http://127.0.0.1:3100", "v3.7.8")
      error = assert_raises(RuntimeError) { LokiVersionValidation.check_runtime("http://127.0.0.1:3100", "3.8.0") }
      assert_includes error.message, "does not match deployed version 3.8.0"
      _out, err = capture_io do
        assert_equal "3.7.8", LokiVersionValidation.check_runtime("http://127.0.0.1:3100", "3.8.0", allow_mismatch: true)
      end
      assert_includes err, "Migration override"
    end
  end

  def test_rejects_duplicate_ids_inside_collapsed_rows
    child = panel(1, 1)
    row = { "id" => 2, "title" => "Detail", "type" => "row", "collapsed" => true,
            "gridPos" => { "x" => 0, "y" => 0, "w" => 24, "h" => 1 }, "panels" => [child] }
    assert errors([row, panel(1, 1)]).any? { |error| error.include?("duplicate panel id") }
  end

  def test_collapsed_row_children_do_not_overlap_top_level_layout
    row = { "id" => 1, "title" => "Detail", "type" => "row", "collapsed" => true,
            "gridPos" => { "x" => 0, "y" => 0, "w" => 24, "h" => 1 }, "panels" => [panel(2, 1)] }
    assert_empty errors([row, panel(3, 1)])
  end

  def test_rejects_sibling_overlap_and_out_of_bounds
    assert errors([panel(1), panel(2, 7)]).any? { |error| error.include?("grid overlaps") }
    invalid = panel(3)
    invalid["gridPos"]["x"] = 20
    assert errors([invalid]).any? { |error| error.include?("invalid gridPos") }
  end

  def test_rejects_legacy_loki_instant_flag_and_duplicate_targets
    invalid = panel(1)
    invalid["targets"][0]["instant"] = true
    invalid["targets"] << invalid["targets"][0].dup
    failures = errors([invalid])
    assert failures.any? { |error| error.include?("use queryType") }
    assert failures.any? { |error| error.include?("duplicate refId") }
  end

  def test_rejects_range_summary_even_when_query_type_is_omitted
    invalid = panel(1)
    invalid["targets"][0]["expr"] = 'sum(count_over_time({job="test"}[$__range]))'
    assert errors([invalid]).any? { |error| error.include?("summaries must be instant") }
    invalid["targets"][0]["expr"] = 'sum(count_over_time({job="test"}[${__range:raw}]))'
    assert errors([invalid]).any? { |error| error.include?("summaries must be instant") }
  end

  def test_requires_interval_and_point_budget_but_accepts_latency_resolution
    invalid = panel(1)
    invalid.delete("interval")
    invalid.delete("maxDataPoints")
    assert_equal 2, errors([invalid]).length
    invalid["targets"][0]["expr"] = 'sum(count_over_time({job="test"}[${__interval:raw}]))'
    assert_equal 2, errors([invalid]).length
    latency = panel(2)
    latency["interval"] = "1m"
    assert_empty errors([latency])
  end

  def test_allows_prometheus_instant_flags_but_not_loki_query_type
    prometheus = panel(1)
    prometheus["datasource"]["type"] = "prometheus"
    prometheus["targets"][0] = { "refId" => "A", "expr" => "up", "instant" => true, "range" => false }
    assert_empty errors([prometheus])
    prometheus["targets"][0]["queryType"] = "instant"
    assert errors([prometheus]).any? { |error| error.include?("not a Prometheus option") }
  end

  def waf_dashboard_files
    Dir[File.expand_path("../../../monitoring/logging/dashboards/taskflow-*.json", __dir__)].sort
  end

  def test_actual_evidence_panels_are_lazy_and_do_not_rewrite_lines
    files = waf_dashboard_files
    assert_equal 3, files.length
    evidence_count = 0
    files.each do |file|
      dashboard = JSON.parse(File.read(file))
      row = dashboard["panels"].find { |item| item["title"] == "Raw JSON evidence" }
      refute_nil row, "#{File.basename(file)} needs an evidence row"
      assert_equal true, row["collapsed"]
      row["panels"].each do |raw|
        evidence_count += 1
        assert_equal "logs", raw["type"]
        raw["targets"].each do |target|
          assert_equal "range", target["queryType"]
          assert_equal 100, target["maxLines"]
          refute_match(/\|\s*(?:line_format|unpack)\b/, target["expr"])
        end
      end
    end
    assert_equal 4, evidence_count
  end

  def test_real_parser_rejects_invalid_logql_with_balanced_delimiters
    url = ENV["LOKI_URL"]
    skip "LOKI_URL required for parser integration" unless url
    assert_nil DashboardValidation.parse_query(url, 'sum(count_over_time({job="test"}[$__range]))')
    refute_nil DashboardValidation.parse_query(url, 'sum(count_over_time({job="test"}[5m])) + invalid()')
    # Structurally valid label_values wrappers still need LogQL parsing to
    # detect missing commas between matcher expressions.
    selector = DashboardValidation.label_values_selector('label_values({job="test" application="backend"}, application)')
    refute_nil DashboardValidation.parse_query(url, selector)
    assert_nil DashboardValidation.parse_query(url, 'sum(count_over_time({job="test"}[${__range:raw}]))')
  end

  def test_raw_queries_preserve_stored_json_and_exclude_unrelated_records
    url = ENV["LOKI_URL"]
    skip "LOKI_URL required for evidence integration" unless url
    access = lambda do |uri, status, ip, zone = nil|
      record = { "msg" => "handled request", "request" => { "uri" => uri, "method" => "GET" },
                 "status" => status, "client_ip" => ip, "extra_evidence" => "preserve this field" }
      record["rate_limit_zone"] = zone if zone
      record["resp_headers"] = { "Retry-After" => ["60"] } if zone
      JSON.generate(record)
    end
    audit = JSON.generate("transaction" => { "client_ip" => "198.51.100.1" },
                          "messages" => [{ "error_message" => "fixture detection" }],
                          "extra_evidence" => "preserve this field")
    limiter = access.call("/api/v1/auth/login", 429, "198.51.100.1", "authentication")
    upstream = access.call("/api/upstream", 429, "198.51.100.2")
    identity = access.call("/", 200, "10.42.0.17")
    probe = access.call("/waf-healthz", 200, "10.42.0.18")
    timestamp = (Time.now.to_r * 1_000_000_000).to_i
    labels = { "job" => "coraza-waf", "container" => "waf",
               "application" => "dashboard-validation", "pod" => "dashboard-validation-waf" }
    values = [audit, limiter, upstream, identity, probe].each_with_index.map do |line, index|
      [(timestamp + index).to_s, line]
    end
    # A different application must not leak through the evidence panel filter.
    payload = { "streams" => [{ "stream" => labels, "values" => values },
                              { "stream" => labels.merge("application" => "other-application"),
                                "values" => [[timestamp.to_s, limiter]] }] }
    uri = URI.join(url, "/loki/api/v1/push")
    http = Net::HTTP.new(uri.host, uri.port, nil)
    http.open_timeout = 2
    http.read_timeout = 10
    pushed = http.post(uri.request_uri, JSON.generate(payload), "Content-Type" => "application/json")
    assert_equal "204", pushed.code, pushed.body

    expected = {
      "Raw WAF detection records" => [audit],
      "Raw access records" => [limiter, upstream, identity],
      "Raw rate-limited access records" => [limiter],
      "Raw pod-CIDR identity records" => [identity]
    }
    waf_dashboard_files.each do |file|
      row = JSON.parse(File.read(file))["panels"].find { |item| item["title"] == "Raw JSON evidence" }
      row["panels"].each do |raw|
        query = raw["targets"].first["expr"].gsub("$application", "dashboard-validation").gsub("$pod", "dashboard-validation-waf").gsub("$client_ip", ".*")
        response = DashboardValidation.get(url, "/loki/api/v1/query_range",
                                           "query" => query, "start" => (timestamp - 60_000_000_000).to_s,
                                           "end" => (timestamp + 1_000_000_000).to_s, "limit" => "100")
        assert_equal "200", response.code, response.body
        lines = JSON.parse(response.body).fetch("data").fetch("result").flat_map do |stream|
          stream.fetch("values").map(&:last)
        end
        assert_equal expected.fetch(raw["title"]).sort, lines.sort, raw["title"]
      end
    end
  end

  FIXTURE_APPLICATION = "dashboard-fixture-app"

  def fixture_dashboard(name)
    JSON.parse(File.read(File.expand_path("../../../monitoring/logging/dashboards/#{name}.json", __dir__)))
  end

  def fixture_panel_expr(dashboard, id, ref = "A")
    panel = dashboard["panels"].find { |p| p["id"] == id } ||
            dashboard["panels"].flat_map { |p| p["panels"] || [] }.find { |p| p["id"] == id }
    raise "panel #{id} missing" unless panel
    panel["targets"].find { |t| t["refId"] == ref }.fetch("expr")
  end

  def fixture_query(dashboard, id, replacements)
    replacements.reduce(fixture_panel_expr(dashboard, id)) { |expr, (key, value)| expr.gsub(key, value) }
  end

  def fixture_base_query
    { "$__range" => "1h", "$__interval" => "1m", "$application" => FIXTURE_APPLICATION, "$pod" => ".*" }
  end

  def instant_vector(url, expr, context)
    response = DashboardValidation.get(url, "/loki/api/v1/query", "query" => expr)
    parsed = JSON.parse(response.body)
    raise "#{context}: query failed: #{parsed['error']}" unless parsed["status"] == "success"
    parsed.dig("data", "result").to_h do |row|
      [row["metric"].reject { |key, _| key == "__name__" }, row.dig("value", 1).to_f]
    end
  rescue JSON::ParserError
    raise "#{context}: non-JSON response: #{response.body[0, 200]}"
  end

  def push_access_fixtures(url)
    base_ts = Time.now.to_i * 1_000_000_000
    sequence = 0
    lines = []
    add = lambda do |client_ip, status, uri, zone, user_agent, with_ua: true|
      sequence += 1
      record = {
        "level" => "info", "msg" => "handled request", "seq" => sequence,
        "request" => { "method" => "GET", "host" => "www.jokelab.dev", "uri" => uri,
                       "headers" => with_ua ? { "User-Agent" => [user_agent] } : {} },
        "status" => status, "client_ip" => client_ip, "duration" => 0.001
      }
      record["rate_limit_zone"] = zone if zone
      lines << [(base_ts + sequence * 1000).to_s, JSON.generate(record)]
    end
    120.times { add.call("198.51.100.10", 429, "/j2ee.zip", "general", "scan-bot/1.0") }
    2.times { add.call("198.51.100.10", 200, "/api/v1/appointments", nil, "scan-bot/1.0") }
    add.call("198.51.100.10", 403, "/login.php", nil, "scan-bot/1.0")
    3.times { add.call("198.51.100.20", 429, "/other", nil, nil, with_ua: false) }
    sequence += 1
    audit = {
      "msg" => "audit", "seq" => sequence,
      "transaction" => { "client_ip" => "198.51.100.10", "is_interrupted" => true,
                         "request" => { "method" => "GET", "uri" => "/j2ee.zip" } },
      "messages" => [{ "error_message" => "fixture" }]
    }
    lines << [(base_ts + sequence * 1000).to_s, JSON.generate(audit)]
    sequence += 1
    lines << [(base_ts + sequence * 1000).to_s, '{"msg":"handled request","status":429']

    labels = { "job" => "coraza-waf", "container" => "waf",
               "application" => FIXTURE_APPLICATION, "pod" => "dashboard-fixture-waf" }
    payload = { "streams" => [{ "stream" => labels, "values" => lines }] }
    uri = URI.join(url, "/loki/api/v1/push")
    http = Net::HTTP.new(uri.host, uri.port, nil)
    http.open_timeout = 2
    http.read_timeout = 10
    pushed = http.post(uri.request_uri, JSON.generate(payload), "Content-Type" => "application/json")
    assert_equal "204", pushed.code, pushed.body
  end

  def test_dashboard_queries_with_fixtures
    url = ENV["LOKI_URL"]
    skip "LOKI_URL required for fixture query integration" unless url
    push_access_fixtures(url)

    rate = fixture_dashboard("taskflow-rate-limits")
    access = fixture_dashboard("taskflow-access-logs")
    waf = fixture_dashboard("taskflow-waf")

    totals = instant_vector(url, fixture_query(rate, 101, fixture_base_query.merge("$client_ip" => ".*")), "rate-limits total")
    assert_equal 126.0, totals.fetch({}), "totals must exclude the malformed record via the __error__ guard"

    only_a = instant_vector(url, fixture_query(rate, 101, fixture_base_query.merge("$client_ip" => "198.51.100.10")), "rate-limits total filtered")
    assert_equal 123.0, only_a.fetch({})

    statuses = instant_vector(url, fixture_query(rate, 20, fixture_base_query.merge("$client_ip" => ".*")), "status breakdown")
    assert_equal 2.0, statuses.fetch({ "status" => "200" })
    assert_equal 1.0, statuses.fetch({ "status" => "403" })
    assert_equal 123.0, statuses.fetch({ "status" => "429" })

    zones = instant_vector(url, fixture_query(rate, 21, fixture_base_query.merge("$client_ip" => ".*")), "zone breakdown")
    assert_equal 120.0, zones.values.sum, "only zone-carrying 429s count as Caddy rejections"

    categories = instant_vector(url, fixture_query(rate, 22, fixture_base_query.merge("$client_ip" => ".*")), "path categories")
    assert_equal 120.0, categories.fetch({ "category" => "Archive/backup" })
    assert_equal 3.0, categories.fetch({ "category" => "Other" })

    agents = instant_vector(url, fixture_query(rate, 23, fixture_base_query.merge("$client_ip" => ".*")), "user agents")
    assert_equal 120.0, agents.fetch({ "user_agent" => "scan-bot/1.0" })
    assert_equal 3.0, agents.fetch({ "user_agent" => "(missing)" })

    access_status = instant_vector(url, fixture_query(access, 3, fixture_base_query.merge("$client_ip" => "198.51.100.20")), "access status filtered")
    assert_equal 3.0, access_status.fetch({ "status" => "429" })

    waf_ips = instant_vector(url, fixture_query(waf, 6, fixture_base_query.merge("$client_ip" => "198.51.100.10")), "waf source IPs")
    assert_equal 1.0, waf_ips.fetch({ "client_ip" => "198.51.100.10" })

    raw_expr = fixture_query(access, 10, fixture_base_query.merge("$client_ip" => ".*"))
    response = DashboardValidation.get(url, "/loki/api/v1/query_range",
                                       "query" => raw_expr,
                                       "start" => ((Time.now.to_i - 3600).to_s + "000000000"),
                                       "end" => ((Time.now.to_i + 1).to_s + "000000000"),
                                       "limit" => "100")
    parsed = JSON.parse(response.body)
    assert_equal "success", parsed["status"], parsed["error"]
    entries = parsed.dig("data", "result").sum { |stream| stream["values"].length }
    assert_equal 100, entries, "evidence panels display at most 100 records while totals count all matches"
  end

  def test_provisioning_accepts_matching_render
    source = provisioning_source("one.json", provisioning_dashboard("one"))
    configmap = provisioning_configmap(name: "one-dashboard", key: "one.json", dashboard: source.fetch(:dashboard))
    assert_empty DashboardProvisioningValidation.check([source], [configmap], "fixture")
  end

  def test_provisioning_rejects_unprovisioned_sources
    source = provisioning_source("one.json", provisioning_dashboard("one"))
    failures = DashboardProvisioningValidation.check([source], [], "fixture")
    assert failures.any? { |error| error.include?("one.json") && error.include?("not provisioned") }
  end

  def test_provisioning_rejects_content_drift_and_wrong_namespace
    source = provisioning_source("one.json", provisioning_dashboard("one"))
    configmap = provisioning_configmap(name: "one-dashboard", key: "one.json",
                                       dashboard: provisioning_dashboard("drifted"), namespace: "default")
    failures = DashboardProvisioningValidation.check([source], [configmap], "fixture")
    assert failures.any? { |error| error.include?("does not match") }
    assert failures.any? { |error| error.include?("monitoring namespace") }
  end

  def test_provisioning_rejects_missing_label_bundled_json_and_stray_dashboards
    source = provisioning_source("one.json", provisioning_dashboard("one"))
    unlabeled = provisioning_configmap(name: "one-dashboard", key: "one.json",
                                       dashboard: source.fetch(:dashboard), labels: {})
    assert DashboardProvisioningValidation.check([source], [unlabeled], "fixture").any? { |error|
      error.include?("not provisioned")
    }

    bundled = provisioning_configmap(name: "one-dashboard", key: "one.json",
                                     dashboard: source.fetch(:dashboard), data: { "extra.json" => "{}" })
    assert DashboardProvisioningValidation.check([source], [bundled], "fixture").any? { |error|
      error.include?("exactly one dashboard JSON entry")
    }

    stray = provisioning_configmap(name: "stray", key: "stray.json", dashboard: provisioning_dashboard("stray"))
    assert DashboardProvisioningValidation.check([source], [stray], "fixture").any? { |error|
      error.include?("no source file provides it")
    }
  end

  def test_provisioning_rejects_invalid_folder_annotations
    source = provisioning_source("one.json", provisioning_dashboard("one"))
    ["", " Security", "/Security", "../Security", "Security/", "Security\\Nested"].each do |folder|
      configmap = provisioning_configmap(name: "one-dashboard", key: "one.json",
                                         dashboard: source.fetch(:dashboard), folder: folder)
      assert DashboardProvisioningValidation.check([source], [configmap], "fixture").any? { |error|
        error.include?("grafana_folder")
      }, "expected #{folder.inspect} to be rejected"
    end
    nested = provisioning_configmap(name: "one-dashboard", key: "one.json",
                                    dashboard: source.fetch(:dashboard), folder: "Security/Nested")
    assert_empty DashboardProvisioningValidation.check([source], [nested], "fixture")
  end

  def test_provisioning_rejects_duplicate_rendering
    source = provisioning_source("one.json", provisioning_dashboard("one"))
    first = provisioning_configmap(name: "a-dashboard", key: "one.json", dashboard: source.fetch(:dashboard))
    second = provisioning_configmap(name: "b-dashboard", key: "one.json", dashboard: source.fetch(:dashboard))
    assert DashboardProvisioningValidation.check([source], [first, second], "fixture").any? { |error|
      error.include?("more than once")
    }
  end

  def test_provisioning_integration_passes_when_dashboards_directory_is_wired
    with_kustomize_fixture(["dashboards", "other.yaml"]) do |directory|
      out, = capture_io { DashboardProvisioningValidation.run(directory, [provisioning_tree]) }
      assert_includes out, "1 dashboards"
    end
  end

  def test_provisioning_integration_fails_when_parent_omits_dashboards
    with_kustomize_fixture(["other.yaml"]) do |directory|
      error = assert_raises(RuntimeError) { DashboardProvisioningValidation.run(directory, [provisioning_tree]) }
      assert_includes error.message, "fixture.json"
      assert_includes error.message, "not provisioned"
    end
  end

  def test_provisioning_reports_kustomize_failures
    with_kustomize_fixture(["missing.yaml"]) do |directory|
      error = assert_raises(RuntimeError) { DashboardProvisioningValidation.run(directory, [provisioning_tree]) }
      assert_includes error.message, "kubectl kustomize failed"
    end
  end
end
