require "minitest/autorun"
require "tempfile"
require_relative "validate-dashboards"

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

  def test_actual_evidence_panels_are_lazy_and_do_not_rewrite_lines
    path = File.expand_path("../../../monitoring/logging/grafana-provisioning.yaml", __dir__)
    documents = YAML.load_stream(File.read(path)).compact
    evidence_count = 0
    documents.each do |document|
      document.fetch("data", {}).each do |key, value|
        next unless key.end_with?(".json")
        dashboard = JSON.parse(value)
        row = dashboard["panels"].find { |item| item["title"] == "Raw JSON evidence" }
        refute_nil row, "#{key} needs an evidence row"
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
    path = File.expand_path("../../../monitoring/logging/grafana-provisioning.yaml", __dir__)
    YAML.load_stream(File.read(path)).compact.each do |document|
      document.fetch("data", {}).each do |key, value|
        next unless key.end_with?(".json")
        row = JSON.parse(value)["panels"].find { |item| item["title"] == "Raw JSON evidence" }
        row["panels"].each do |raw|
          query = raw["targets"].first["expr"].gsub("$application", "dashboard-validation").gsub("$pod", "dashboard-validation-waf")
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
  end
end
