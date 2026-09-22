# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "socket"

class PolyglotApiTest < ActionDispatch::IntegrationTest
  def setup
    Catalog.query_fn = nil
    Catalog.connect_fn = nil
    Catalog.reset_counts!
  end

  def teardown
    Catalog.query_fn = nil
    Catalog.connect_fn = nil
    Catalog.reset_pool!
  end

  test "shipped app is Rails not Sinatra" do
    src = File.read(Rails.root.join("config/application.rb"))
    gemfile = File.read(Rails.root.join("Gemfile"))
    gemlock = File.read(Rails.root.join("Gemfile.lock"))
    assert_includes src, "Rails::Application"
    assert_includes gemfile, '"rails"'
    assert_includes gemlock, "rails (8.1.3.1)"
    assert_includes File.read(Rails.root.join(".ruby-version")), "4.0.6"
    refute_includes File.read(Rails.root.join("app/controllers/health_controller.rb")), "Sinatra"
    refute_includes gemfile, "sinatra"
  end

  test "GET /health is ok JSON without SQL or Postgres" do
    get "/health"
    assert_response :success
    assert_equal "ok", json_body["status"]
    refute json_body.key?("data")
    assert_equal 0, Catalog.sql_count
    assert_equal 0, Catalog.connect_count
    assert_polyglot_headers
  end

  test "GET / identity is Ruby and Rails without SQL" do
    get "/"
    assert_response :success
    body = json_body
    assert_equal "Ruby", body["language"]
    assert_equal "Rails", body["framework"]
    refute body.key?("data")
    assert_equal 0, Catalog.sql_count
    assert_equal 0, Catalog.connect_count
    assert_polyglot_headers
  end

  test "list routes wrap data" do
    install_fake_catalog

    get "/v1/years"
    assert_response :success
    assert_kind_of Array, json_body["data"]
    assert_equal 2026, json_body["data"].first["year"]
    assert_polyglot_headers

    get "/v1/speakers"
    assert_response :success
    assert_equal "diana-pham", json_body["data"].first["slug"]
    assert_polyglot_headers

    get "/v1/sponsors"
    assert_response :success
    assert_equal "flywheel", json_body["data"].first["slug"]
    assert_polyglot_headers
  end

  test "year-scoped speakers wrap data and include languages/topics from v1_talks" do
    install_fake_catalog
    Catalog.reset_counts!
    get "/v1/speakers", params: { year: "2026" }
    assert_response :success
    assert_polyglot_headers
    payload = json_body
    assert payload.key?("data")
    assert payload["data"].is_a?(Array)
    refute_empty payload["data"], "year-scoped speakers returned rows"
    row = payload["data"].first
    assert row.key?("languages"), "year-scoped speaker row has languages"
    assert row.key?("topics"), "year-scoped speaker row has topics"
    assert_includes row["languages"], "ruby"
    assert_includes row["topics"], "development"
    assert Catalog.sql_count.positive?, "year-scoped list hits catalog SQL"
  end

  test "year-scoped sponsors wrap data and include tier" do
    install_fake_catalog
    get "/v1/sponsors", params: { year: "2026" }
    assert_response :success
    assert_polyglot_headers
    payload = json_body
    assert payload.key?("data")
    refute_empty payload["data"]
    assert_equal "platinum", payload["data"].first["tier"]
  end

  test "one speaker loads talks and years in fewer than 3 SQL round-trips" do
    install_fake_catalog
    Catalog.reset_counts!
    get "/v1/speakers/diana-pham"
    assert_response :success
    assert_polyglot_headers
    data = json_body.fetch("data")
    assert_equal [ 2026, 2024 ], data["years"]
    assert_equal [ 2026, 2024 ], data["talks"].map { |talk| talk["year"] }
    assert_operator Catalog.sql_count, :>, 0
    assert_operator Catalog.sql_count, :<, 3
  end

  test "one year-scoped speaker loads in fewer than 3 SQL round-trips" do
    install_fake_catalog
    Catalog.reset_counts!
    get "/v1/speakers/2026/diana-pham"
    assert_response :success
    assert_polyglot_headers
    data = json_body.fetch("data")
    assert_equal 2026, data["year"]
    assert_equal [ 2026 ], data["talks"].map { |talk| talk["year"] }
    assert_equal [ 2026, 2024 ], data["years"]
    assert_equal [ 2024 ], data["other_years"]
    assert_equal [ "ruby" ], data["languages"]
    assert_equal [ "development" ], data["topics"]
    assert_operator Catalog.sql_count, :>, 0
    assert_operator Catalog.sql_count, :<, 3
  end

  test "sponsor show wraps data" do
    install_fake_catalog
    get "/v1/sponsors/flywheel"
    assert_response :success
    assert_polyglot_headers
    data = json_body.fetch("data")
    assert_equal "flywheel", data["slug"]
    assert data.key?("sponsorships")
  end

  test "one year-scoped sponsor loads in fewer than 2 SQL round-trips" do
    install_fake_catalog
    Catalog.reset_counts!
    get "/v1/sponsors/2026/flywheel"
    assert_response :success
    assert_polyglot_headers
    data = json_body.fetch("data")
    assert_equal [ 2026, 2024 ], data["years"]
    assert_equal [ 2024 ], data["other_years"]
    assert_equal "platinum", data["tier"]
    refute data.key?("sponsorship_year")
    assert_operator Catalog.sql_count, :>, 0
    assert_operator Catalog.sql_count, :<, 2
  end

  test "unknown speaker and sponsor routes are not_found" do
    install_fake_catalog
    [
      "/v1/speakers/no-such-slug",
      "/v1/speakers/2020/diana-pham",
      "/v1/sponsors/no-such-slug",
      "/v1/sponsors/1999/flywheel"
    ].each do |path|
      get path
      assert_response :not_found, path
      assert_equal "not_found", json_body["error"], path
      assert_polyglot_headers
    end
  end

  test "parallel year-scoped speaker and sponsor lists use distinct pooled connections" do
    ensure_catalog
    skip "postgres unavailable" if Catalog.query_fn

    errors = []
    speakers = nil
    sponsors = nil
    t1 = Thread.new do
      speakers = Catalog.speakers(2026)
    rescue StandardError => e
      errors << e
    end
    t2 = Thread.new do
      sponsors = Catalog.sponsors(2026)
    rescue StandardError => e
      errors << e
    end
    t1.join
    t2.join
    assert_empty errors.map { |e| "#{e.class}: #{e.message}" }
    refute_empty speakers
    assert speakers.first["languages"].is_a?(Array)
    refute_empty sponsors
    assert sponsors.first.key?("tier")
  end

  test "overlapping Catalog.query calls do not share one PG connection" do
    Catalog.reset_pool!
    Catalog.query_fn = nil
    Catalog.connect_fn = -> { PooledStandIn.new }
    Catalog.reset_counts!

    errors = []
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    threads = Array.new(2) do
      Thread.new do
        Catalog.query("SELECT pg_sleep(0.25) AS s")
      rescue StandardError => e
        errors << e
      end
    end
    threads.each(&:join)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_empty errors.map { |e| "#{e.class}: #{e.message}" }
    assert_operator elapsed, :<, 0.45, "expected pooled overlapping queries, elapsed=#{elapsed}"
    assert_equal 2, Catalog.connect_count

    Catalog.query("SELECT 1 AS ok")
    assert_equal 2, Catalog.connect_count, "checked-in connections must be reused"
  ensure
    threads&.each do |thread|
      thread.kill
      thread.join(1)
    end
    Catalog.connect_fn = nil
    Catalog.reset_pool!
  end

  test "registration returns while a peer holds the socket open" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    accepted = Queue.new
    holder = Thread.new do
      client = server.accept
      accepted << client
      sleep 30
    ensure
      client&.close
    end
    previous = {
      "CAROLINA_URL" => ENV["CAROLINA_URL"],
      "POLYGLOT_REGISTER_TOKEN" => ENV["POLYGLOT_REGISTER_TOKEN"]
    }
    ENV["CAROLINA_URL"] = "http://127.0.0.1:#{port}"
    ENV["POLYGLOT_REGISTER_TOKEN"] = "dev"

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    thread = Catalog.register_in_background
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 1

    client = accepted.pop(timeout: 2)
    refute_nil client, "register never connected"
    drain_register_request(client)
    assert thread.alive?
    assert_equal :wait_readable, client.read_nonblock(1, exception: false)
  ensure
    thread&.kill
    thread&.join(1)
    holder&.kill
    holder&.join(1)
    server&.close
    previous&.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end

  test "puma registers after boot and the image stays compiler-free" do
    puma = File.read(Rails.root.join("config/puma.rb"))
    assert_match(/after_booted/, puma)
    assert_match(/register_in_background/, puma)
    assert_match(%r{tcp://\[::\]:}, puma)
    refute_match(/^\s*Catalog\.register_with_elixir\b/, puma)

    init = Rails.root.join("config/initializers/polyglot_register.rb")
    refute File.exist?(init)

    boot = File.read(Rails.root.join("config/boot.rb"))
    assert_match(/RubyVM::YJIT\.enable/, boot)

    fly = File.read(Rails.root.join("fly.toml"))
    assert_match(/internal_port\s*=\s*8080/, fly)
    assert_match(%r{path\s*=\s*"/health"}, fly)
    assert_match(/auto_stop_machines\s*=\s*"stop"/, fly)
    assert_match(/auto_start_machines\s*=\s*true/, fly)
    assert_match(/min_machines_running\s*=\s*0/, fly)
    assert_match(/RUBY_YJIT_ENABLE\s*=\s*"1"/, fly)

    docker = File.read(Rails.root.join("Dockerfile"))
    assert_includes docker, 'CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]'
    assert_includes docker, "RUBY_YJIT_ENABLE=1"
    stages = docker.split(/^FROM /)
    assert_operator stages.size, :>=, 3
    assert_match(/build-essential/, stages[1])
    refute_match(/build-essential/, stages.last)
    refute_match(/\bgcc\b/, stages.last)
    refute_match(/master\.key/, docker)

    ignored = File.read(Rails.root.join(".dockerignore")).lines.map(&:strip)
    %w[.git tmp log test config/master.key .env].each do |entry|
      assert_includes ignored, entry
    end
  end

  test "production environment enables YJIT" do
    probe = <<~'RUBY'
      require "./config/environment"
      $stdout.puts "YJIT_ENABLED=#{RubyVM::YJIT.enabled?}"
    RUBY
    env = ENV.to_h.merge("RAILS_ENV" => "production", "RAILS_LOG_LEVEL" => "error")
    env.delete("RUBY_YJIT_ENABLE")
    rubyopt = env["RUBYOPT"].to_s.gsub("--yjit", "").strip
    rubyopt.empty? ? env.delete("RUBYOPT") : env["RUBYOPT"] = rubyopt
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-e", probe, chdir: Rails.root.to_s)
    assert status.success?, stderr
    assert_includes stdout, "YJIT_ENABLED=true"
  end

  private

  def json_body
    JSON.parse(response.body)
  end

  def assert_polyglot_headers
    assert_equal "Ruby", response.headers["X-Polyglot-Language"]
    assert_equal "Rails", response.headers["X-Polyglot-Framework"]
  end

  def install_fake_catalog
    Catalog.query_fn = lambda do |sql, params|
      fake_catalog_rows(sql, params)
    end
  end

  def ensure_catalog
    Catalog.query("SELECT 1 AS ok")
  rescue StandardError
    Catalog.query_fn = ->(*) { [] }
  end

  # Longer SQL shapes first. The year-speaker list selects v1_speakers with a
  # v1_talks subquery, so the speakers branch has to win over talks.
  def fake_catalog_rows(sql, params)
    if sql.include?("FROM v1_years")
      [ { "year" => "2026", "slug" => "2026", "name" => "2026", "status" => "published" } ]
    elsif sql.include?("v1_year_sponsors") && sql.include?("v1_sponsorships")
      return [] unless Integer(params[0]) == 2026 && params[1] == "flywheel"

      [
        year_sponsor_row.merge("sponsorship_year" => "2026"),
        year_sponsor_row.merge("sponsorship_year" => "2024")
      ]
    elsif sql.include?("FROM v1_year_sponsors")
      [ year_sponsor_row ]
    elsif sql.include?("FROM v1_sponsors WHERE slug")
      return [] unless params[0] == "flywheel"

      [ sponsor_row ]
    elsif sql.include?("FROM v1_sponsors")
      [ sponsor_row ]
    elsif sql.include?("FROM v1_sponsorships")
      [ { "sponsor_slug" => "flywheel", "year" => "2026", "tier" => "platinum" } ]
    elsif sql.include?("FROM v1_speakers WHERE slug =")
      return [] unless params[0] == "diana-pham"

      [ speaker_row ]
    elsif sql.include?("FROM v1_speakers")
      [ speaker_row ]
    elsif sql.include?("DISTINCT speaker_slug, year FROM v1_talks")
      [
        { "speaker_slug" => "diana-pham", "year" => "2026" },
        { "speaker_slug" => "diana-pham", "year" => "2024" }
      ]
    elsif sql.include?("FROM v1_talks WHERE year")
      [ talk_row("2026") ]
    elsif sql.include?("FROM v1_talks WHERE speaker_slug")
      [ talk_row("2026"), talk_row("2024", "older-talk", "{elixir}", "{testing}") ]
    else
      []
    end
  end

  def speaker_row
    {
      "slug" => "diana-pham",
      "first_name" => "Diana",
      "last_name" => "Pham",
      "name" => "Diana Pham",
      "featured" => "t"
    }
  end

  def sponsor_row
    { "slug" => "flywheel", "name" => "Flywheel", "website" => "https://flywheel.example" }
  end

  def year_sponsor_row
    sponsor_row.merge("tier" => "platinum", "year" => "2026", "featured" => "f", "blurb" => "Parts")
  end

  def talk_row(year, slug = "talk-#{year}", languages = "{ruby}", topics = "{development}")
    {
      "slug" => slug,
      "title" => "Talk #{year}",
      "year" => year,
      "speaker_slug" => "diana-pham",
      "languages" => languages,
      "topics" => topics
    }
  end

  def drain_register_request(client)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    saw_request = false
    loop do
      chunk = client.read_nonblock(4096, exception: false)
      case chunk
      when :wait_readable
        return if saw_request

        flunk "register POST did not arrive" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.01
      when nil
        flunk "register connection closed before the peer responded"
      else
        saw_request = true
      end
    end
  end
end

# Blocking stand-in that still goes through Catalog checkout and checkin.
class PooledStandIn
  def exec(_sql)
    sleep 0.25
    []
  end

  def exec_params(_sql, _params)
    exec(nil)
  end

  def close
  end
end
