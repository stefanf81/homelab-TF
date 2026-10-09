#!/usr/bin/env ruby
# Structural checks are offline; LOKI_URL additionally enables real LogQL parsing.
require "json"
require "yaml"
require "net/http"
require "uri"
require_relative "validate-loki-version"

module DashboardValidation
  # Match Grafana's bare, braced/field/formatted, and legacy interpolation forms.
  VARIABLE_REFERENCE = /\$(\w+)|\[\[(\w+?)(?::(\w+))?\]\]|\$\{(\w+)(?:\.([^:^}]+))?(?::([^}]+))?\}/
  BUILTIN_VALUES = {
    "__interval" => "5m", "__interval_ms" => "300000",
    "__range" => "6h", "__range_ms" => "21600000", "__range_s" => "21600",
    "__from" => "1704067200000", "__to" => "1704088800000",
    "__timezone" => "UTC", "__dashboard" => "validation", "__org" => "1", "__user" => "validation"
  }.freeze
  PROMETHEUS_BUILTINS = %w[__rate_interval __rate_interval_ms].freeze

  def self.reference_names(expression)
    expression.scan(VARIABLE_REFERENCE).map do |bare, legacy, _format, braced, _field, _braced_format|
      bare || legacy || braced
    end.uniq
  end

  def self.reference_errors(expression, names, datasource)
    # Go-template locals are not dashboard variables; Grafana leaves unknown
    # local names untouched. Track declarations, including range's two locals.
    locals = expression.scan(/\{\{(.*?)\}\}/m).flat_map do |body|
      body.first.scan(/((?:\$\w+\s*,\s*)*\$\w+)\s*:=/).flat_map { |declaration| declaration.first.scan(/\$(\w+)/).flatten }
    end
    supported = names + BUILTIN_VALUES.keys + locals
    supported += PROMETHEUS_BUILTINS if datasource == "prometheus"
    reference_names(expression).filter_map do |name|
      "undefined dashboard variable $#{name}" unless supported.include?(name)
    end
  end

  def self.label_values_selector(query)
    match = /\Alabel_values\s*\((.*)\)\s*\z/m.match(query.strip)
    raise "expected label_values(label) or label_values({selector}, label)" unless match
    arguments = []
    start = 0
    quote = nil
    escaped = false
    stack = []
    closing = { "}" => "{", "]" => "[", ")" => "(" }
    # Split only on unquoted, top-level commas. Matcher values may contain
    # commas, braces, escaped quotes, or raw backtick strings.
    match[1].each_char.with_index do |character, index|
      if quote
        if escaped
          escaped = false
        elsif character == "\\" && quote == '"'
          escaped = true
        elsif character == quote
          quote = nil
        end
      elsif ['"', "`"].include?(character)
        quote = character
      elsif ["{", "[", "("].include?(character)
        stack << character
      elsif closing.key?(character)
        raise "unbalanced selector delimiters" unless stack.pop == closing[character]
      elsif character == "," && stack.empty?
        arguments << match[1][start...index].strip
        start = index + 1
      end
    end
    raise "unterminated selector string or delimiter" if quote || !stack.empty?
    arguments << match[1][start..].strip
    unless [1, 2].include?(arguments.length) && arguments.last.match?(/\A[a-zA-Z_]\w*\z/)
      raise "label_values requires a label name and at most one selector"
    end
    return nil if arguments.length == 1
    selector = arguments.first
    raise "label_values selector must be enclosed in braces" unless selector.start_with?("{") && selector.end_with?("}")
    selector
  end

  def self.check(dashboard)
    errors = []
    ids = {}
    queries = []
    errors << "missing dashboard uid" unless dashboard["uid"].is_a?(String) && !dashboard["uid"].empty?
    errors << "missing dashboard title" unless dashboard["title"].is_a?(String) && !dashboard["title"].empty?

    variables = dashboard.dig("templating", "list") || []
    unless variables.is_a?(Array)
      errors << "templating.list must be an array"
      variables = []
    end
    names = []
    variables.each do |variable|
      name = variable.is_a?(Hash) ? variable["name"] : nil
      unless name.is_a?(String) && name.match?(/\A\w+\z/)
        errors << "template variable must have a nonempty identifier"
        next
      end
      errors << "duplicate template variable #{name}" if names.include?(name)
      names << name
    end
    variables.each do |variable|
      next unless variable.is_a?(Hash) && variable["type"] == "query"
      context = "variable #{variable['name'].inspect}"
      datasource = variable["datasource"] || dashboard["datasource"]
      type = datasource.is_a?(Hash) ? datasource["type"] : nil
      query = variable["query"]
      query = query["query"] if query.is_a?(Hash)
      unless query.is_a?(String) && !query.strip.empty?
        errors << "#{context}: missing variable query"
        next
      end
      errors.concat(reference_errors(query, names, type).map { |error| "#{context}: #{error}" })
      next unless type == "loki"
      begin
        selector = label_values_selector(query)
        queries << ["#{context} selector", selector] if selector
      rescue ArgumentError, RuntimeError => error
        errors << "#{context}: #{error.message}"
      end
    end

    visit = lambda do |panels|
      unless panels.is_a?(Array)
        errors << "panels must be an array"
        next
      end
      rectangles = []
      panels.each do |panel|
        unless panel.is_a?(Hash)
          errors << "panel must be an object"
          next
        end
        id = panel["id"]
        context = "panel #{id.inspect} (#{panel['title']})"
        if id.is_a?(Integer) && id.positive?
          errors << "#{context}: duplicate panel id" if ids.key?(id)
          ids[id] = true
        else
          errors << "#{context}: id must be a positive integer"
        end

        grid = panel["gridPos"]
        if grid.is_a?(Hash) && %w[x y w h].all? { |key| grid[key].is_a?(Integer) } &&
           grid["x"] >= 0 && grid["y"] >= 0 && grid["w"].positive? && grid["h"].positive? &&
           grid["x"] + grid["w"] <= 24
          rectangles.each do |other_context, other|
            overlap = grid["x"] < other["x"] + other["w"] && other["x"] < grid["x"] + grid["w"] &&
                      grid["y"] < other["y"] + other["h"] && other["y"] < grid["y"] + grid["h"]
            errors << "#{context}: grid overlaps #{other_context}" if overlap
          end
          rectangles << [context, grid]
        else
          errors << "#{context}: invalid gridPos (positive size, nonnegative position, 24-column width required)"
        end

        targets = panel.fetch("targets", [])
        unless targets.is_a?(Array)
          errors << "#{context}: targets must be an array"
          next
        end
        refs = {}
        targets.each do |target|
          unless target.is_a?(Hash)
            errors << "#{context}: target must be an object"
            next
          end
          ref = target["refId"]
          target_context = "#{context} target #{ref.inspect}"
          if ref.is_a?(String) && !ref.empty?
            errors << "#{target_context}: duplicate refId" if refs.key?(ref)
            refs[ref] = true
          else
            errors << "#{target_context}: missing refId"
          end
          expression = target["expr"]
          unless expression.is_a?(String) && !expression.strip.empty?
            errors << "#{target_context}: missing query expression"
            next
          end
          datasource = target["datasource"] || panel["datasource"] || dashboard["datasource"]
          type = datasource.is_a?(Hash) ? datasource["type"] : nil
          unless %w[loki prometheus].include?(type)
            errors << "#{target_context}: expected an explicit Loki or Prometheus datasource"
            next
          end
          errors.concat(reference_errors(expression, names, type).map { |error| "#{target_context}: #{error}" })
          if type == "loki"
            errors << "#{target_context}: use queryType, not instant/range flags, for Loki" if target.key?("instant") || target.key?("range")
            mode = target.fetch("queryType", "range")
            errors << "#{target_context}: invalid Loki queryType" unless %w[instant range].include?(mode)
            references = reference_names(expression)
            if references.include?("__range") && mode != "instant"
              errors << "#{target_context}: selected-range summaries must be instant queries"
            end
            if panel["type"] == "logs" && mode != "range"
              errors << "#{target_context}: log panels must use range queries"
            end
            if references.include?("__interval")
              unless panel["interval"].is_a?(String) && panel["interval"].match?(/\A[1-9]\d*(?:ms|s|m|h|d|w)\z/)
                errors << "#{target_context}: $__interval requires a positive panel minimum interval"
              end
              unless panel["maxDataPoints"].is_a?(Integer) && panel["maxDataPoints"].positive?
                errors << "#{target_context}: $__interval requires a positive maxDataPoints budget"
              end
            end
            queries << [target_context, expression]
          elsif target.key?("queryType")
            errors << "#{target_context}: queryType is a Loki option, not a Prometheus option"
          end
        end
        # Collapsed rows have their own layout. Their child coordinates can
        # overlap later top-level panels; Grafana shifts those on expansion.
        visit.call(panel["panels"]) if panel.key?("panels")
      end
    end
    visit.call(dashboard["panels"])
    [errors, queries]
  end

  def self.get(base_url, path, params = {})
    uri = URI.join(base_url, path)
    uri.query = URI.encode_www_form(params) unless params.empty?
    # The validation server is local; do not route it through an environment proxy.
    http = Net::HTTP.new(uri.host, uri.port, nil)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 2
    http.read_timeout = 10
    http.get(uri.request_uri)
  end

  def self.wait_for_loki(url)
    60.times do
      begin
        return if get(url, "/ready").is_a?(Net::HTTPSuccess)
      rescue SystemCallError, IOError, Timeout::Error
        # A newly started validation container may not be listening yet.
      end
      sleep 1
    end
    raise "validation Loki did not become ready at #{url}"
  end

  def self.parse_query(url, expression)
    # References are checked separately. Dashboard filter variables remain
    # valid quoted matcher content; built-ins use representative parser values.
    query = expression.gsub(VARIABLE_REFERENCE) do |reference|
      name = Regexp.last_match[1] || Regexp.last_match[2] || Regexp.last_match[4]
      BUILTIN_VALUES.fetch(name, reference)
    end
    response = get(url, "/loki/api/v1/format_query", "query" => query)
    payload = JSON.parse(response.body)
    return nil if response.is_a?(Net::HTTPSuccess) && payload["status"] == "success"

    "LogQL rejected: #{payload['error'] || response.body}"
  rescue JSON::ParserError
    "LogQL parser returned HTTP #{response.code}: #{response.body}"
  end

  def self.parse_queries(url, queries)
    errors = []
    queries.each do |context, expression|
      begin
        failure = parse_query(url, expression)
      rescue SystemCallError, IOError, Timeout::Error => error
        # Fail once with the affected query's context; do not retry all other
        # targets against an unavailable validation server.
        raise "#{context}: validation Loki transport failure at #{url}: #{error.class}: #{error.message}"
      end
      errors << "#{context}: #{failure}" if failure
    end
    errors
  end

  def self.run(path, url = nil)
    dashboards = YAML.load_stream(File.read(path)).compact.select do |document|
      document["kind"] == "ConfigMap" && document.dig("metadata", "labels", "grafana_dashboard") == "1"
    end.flat_map do |document|
      document.fetch("data", {}).filter_map do |key, value|
        next unless key.end_with?(".json")
        ["#{document.dig('metadata', 'name')}/#{key}", JSON.parse(value)]
      end
    end
    raise "no dashboard JSON found in #{path}" if dashboards.empty?

    errors = []
    uids = {}
    pending = []
    dashboards.each do |name, dashboard|
      unless dashboard.is_a?(Hash)
        errors << "#{name}: dashboard must be an object"
        next
      end
      uid = dashboard["uid"]
      if uid.is_a?(String) && !uid.empty?
        errors << "#{name}: duplicate dashboard uid #{uid.inspect}" if uids.key?(uid)
        uids[uid] = true
      end
      failures, queries = check(dashboard)
      errors.concat(failures.map { |failure| "#{name}: #{failure}" })
      pending.concat(queries.map { |context, expression| ["#{name}: #{context}", expression] })
    end
    if errors.empty? && url
      wait_for_loki(url)
      if ENV["EXPECTED_LOKI_VERSION"]
        actual = LokiVersionValidation.check_runtime(url, ENV.fetch("EXPECTED_LOKI_VERSION"),
                                                     allow_mismatch: ENV["ALLOW_LOKI_VERSION_MISMATCH"] == "1")
        puts "  OK validation Loki runtime version #{actual}"
      end
      errors.concat(parse_queries(url, pending))
    end
    raise errors.join("\n") unless errors.empty?

    puts "  OK #{dashboards.length} dashboards; structure/references checked#{url ? "; #{pending.length} Loki expressions parsed (targets and variable selectors)" : " (LogQL parsing requires LOKI_URL)"}"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    raise "usage: #{File.basename(__FILE__)} <grafana-provisioning.yaml>" unless ARGV.length == 1
    DashboardValidation.run(ARGV.first, ENV["LOKI_URL"])
  rescue StandardError => error
    warn error.message
    exit 1
  end
end
