# frozen_string_literal: true

require "test_helper"
require "json"

class PolyglotApiTest < ActionDispatch::IntegrationTest
  def setup
    Catalog.reset_counts!
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
    assert_includes response.body, '"status"'
    assert_includes response.body, '"ok"'
    body = JSON.parse(response.body)
    assert_equal "ok", body["status"]
    assert_equal 0, Catalog.sql_count
    assert_equal 0, Catalog.connect_count
  end

  test "GET / identity is Ruby and Rails without SQL" do
    get "/"
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "Ruby", body["language"]
    assert_equal "Rails", body["framework"]
    assert_equal 0, Catalog.sql_count
  end

  test "unknown speaker slug returns 404" do
    ensure_catalog
    get "/v1/speakers/no-such-slug"
    assert_response :not_found
    assert_includes response.body, "not_found"
  end

  test "year-scoped speakers wrap data and include languages/topics from v1_talks" do
    ensure_catalog
    Catalog.reset_counts!
    get "/v1/speakers", params: { year: "2026" }
    assert_response :success
    payload = JSON.parse(response.body)
    assert payload.key?("data")
    assert payload["data"].is_a?(Array)
    refute_empty payload["data"], "year-scoped speakers returned rows"
    row = payload["data"].first
    assert row.key?("languages"), "year-scoped speaker row has languages"
    assert row.key?("topics"), "year-scoped speaker row has topics"
    assert row["languages"].is_a?(Array)
    assert row["topics"].is_a?(Array)
    assert Catalog.sql_count.positive?, "year-scoped list hits catalog SQL"
  end

  test "year-scoped sponsors wrap data and include tier" do
    ensure_catalog
    get "/v1/sponsors", params: { year: "2026" }
    assert_response :success
    payload = JSON.parse(response.body)
    assert payload.key?("data")
    refute_empty payload["data"]
    assert payload["data"].first.key?("tier"), "year-scoped sponsor row includes tier"
  end

  private

  def ensure_catalog
    Catalog.query("SELECT 1 AS ok")
  rescue StandardError
    Catalog.connect_fn = -> { raise "fake connect" }
    Catalog.query_fn = lambda do |sql, _params|
      if sql.include?("FROM v1_speakers WHERE slug =")
        []
      elsif sql.include?("FROM v1_speakers")
        [ { "slug" => "diana-pham", "first_name" => "Diana", "last_name" => "Pham", "name" => "Diana Pham" } ]
      elsif sql.include?("FROM v1_talks")
        [ {
          "slug" => "talk",
          "title" => "Talk",
          "speaker_slug" => "diana-pham",
          "year" => "2026",
          "languages" => "{ruby}",
          "topics" => "{development}"
        } ]
      elsif sql.include?("FROM v1_year_sponsors")
        [ { "slug" => "flywheel", "name" => "Flywheel", "tier" => "platinum", "year" => "2026" } ]
      elsif sql.include?("FROM v1_sponsors WHERE slug")
        []
      else
        []
      end
    end
  end
end
