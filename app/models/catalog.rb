# frozen_string_literal: true

require "json"
require "net/http"
require "pg"
require "thread"
require "uri"

# SQL against PostgreSQL v1_* views only. No Active Record / Ash tables.
class Catalog
  LANGUAGE = "Ruby"
  FRAMEWORK = "Rails"
  API_VERSION = "0.2.0"
  CREATED_YEAR = 2026
  SCHEMA_VERSION = 1

  ENDPOINTS = [
    { "method" => "GET", "path" => "/", "query" => [] },
    { "method" => "GET", "path" => "/health", "query" => [] },
    { "method" => "GET", "path" => "/v1/years", "query" => [] },
    { "method" => "GET", "path" => "/v1/speakers", "query" => ["year"] },
    { "method" => "GET", "path" => "/v1/speakers/:slug", "query" => [] },
    { "method" => "GET", "path" => "/v1/speakers/:year/:slug", "query" => [] },
    { "method" => "GET", "path" => "/v1/sponsors", "query" => ["year"] },
    { "method" => "GET", "path" => "/v1/sponsors/:slug", "query" => [] },
    { "method" => "GET", "path" => "/v1/sponsors/:year/:slug", "query" => [] }
  ].freeze

  SPEAKER_COLS =
    "slug, first_name, last_name, name, tagline, bio, company, location, " \
    "photo_path, twitter_url, linkedin_url, website_url, github_url, featured"
  YEAR_SPONSOR_COLS =
    "slug, name, website, logo_path, description, blurb, tier, featured, year, " \
    "twitter_url, linkedin_url, youtube_url, instagram_url, facebook_url"
  SPONSOR_COLS =
    "slug, name, website, logo_path, description, twitter_url, linkedin_url, " \
    "youtube_url, instagram_url, facebook_url"
  TALK_COLS =
    "slug, title, description, format, youtube_id, year, speaker_slug, languages, topics"

  class << self
    attr_accessor :query_fn, :connect_fn
    attr_reader :sql_count, :connect_count

    def reset_counts!
      @sql_count = 0
      @connect_count = 0
    end

    def identity
      {
        "language" => LANGUAGE,
        "language_version" => RUBY_VERSION,
        "api_version" => API_VERSION,
        "framework" => FRAMEWORK,
        "created_year" => CREATED_YEAR,
        "schema_version" => SCHEMA_VERSION,
        "endpoints" => ENDPOINTS
      }
    end

    def years
      query("SELECT year, slug, name, status FROM v1_years ORDER BY year DESC").map { |row| clean(row) }
    end

    def speakers(year = nil)
      if year
        year_speakers(Integer(year))
      else
        query("SELECT #{SPEAKER_COLS} FROM v1_speakers ORDER BY last_name, first_name").map { |row| clean(row) }
      end
    end

    def speaker(slug)
      row = query("SELECT #{SPEAKER_COLS} FROM v1_speakers WHERE slug = $1", [slug]).first
      return nil unless row

      talks = query("SELECT #{TALK_COLS} FROM v1_talks WHERE speaker_slug = $1 ORDER BY year DESC", [slug]).map { |t| clean(t) }
      years_for = query("SELECT DISTINCT year FROM v1_talks WHERE speaker_slug = $1 ORDER BY year DESC", [slug]).map { |r| Integer(r["year"]) }
      clean(row).merge("talks" => talks, "years" => years_for)
    end

    def speaker_for_year(year, slug)
      year = Integer(year)
      row = query("SELECT #{SPEAKER_COLS} FROM v1_speakers WHERE slug = $1", [slug]).first
      return nil unless row

      talks = query(
        "SELECT #{TALK_COLS} FROM v1_talks WHERE speaker_slug = $1 AND year = $2 ORDER BY year DESC",
        [slug, year]
      ).map { |t| clean(t) }
      return :missing_year if talks.empty?

      years_for = query("SELECT DISTINCT year FROM v1_talks WHERE speaker_slug = $1 ORDER BY year DESC", [slug]).map { |r| Integer(r["year"]) }
      clean(row).merge(
        "year" => year,
        "talks" => talks,
        "years" => years_for,
        "other_years" => years_for.reject { |y| y == year },
        "languages" => unique_tags(talks, "languages"),
        "topics" => unique_tags(talks, "topics")
      )
    end

    def sponsors(year = nil)
      if year
        query("SELECT #{YEAR_SPONSOR_COLS} FROM v1_year_sponsors WHERE year = $1 ORDER BY name", [Integer(year)]).map { |row| clean(row) }
      else
        query("SELECT #{SPONSOR_COLS} FROM v1_sponsors ORDER BY name").map { |row| clean(row) }
      end
    end

    def sponsor(slug)
      row = query("SELECT #{SPONSOR_COLS} FROM v1_sponsors WHERE slug = $1", [slug]).first
      return nil unless row

      sponsorships = query("SELECT * FROM v1_sponsorships WHERE sponsor_slug = $1", [slug]).map { |s| clean(s) }
      clean(row).merge("sponsorships" => sponsorships)
    end

    def sponsor_for_year(year, slug)
      year = Integer(year)
      row = query("SELECT #{YEAR_SPONSOR_COLS} FROM v1_year_sponsors WHERE year = $1 AND slug = $2", [year, slug]).first
      return nil unless row

      years_for = query("SELECT DISTINCT year FROM v1_sponsorships WHERE sponsor_slug = $1 ORDER BY year DESC", [slug]).map { |r| Integer(r["year"]) }
      clean(row).merge(
        "years" => years_for,
        "other_years" => years_for.reject { |y| y == year }
      )
    end

    def register_with_elixir
      url = ENV["CAROLINA_URL"]
      token = ENV["POLYGLOT_REGISTER_TOKEN"]
      return if url.nil? || url.empty? || token.nil? || token.empty?

      uri = URI.join(url.end_with?("/") ? url : "#{url}/", "internal/api-endpoints/register")
      port = ENV.fetch("PORT", "4018")
      body = identity.merge(
        "language_version" => RUBY_VERSION,
        "base_url" => ENV.fetch("PUBLIC_BASE_URL", "http://127.0.0.1:#{port}")
      )
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 5
      http.read_timeout = 5
      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{token}"
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body)
      http.request(req)
    rescue StandardError => e
      warn "register: #{e.message}"
    end

    def query(sql, params = [])
      lock.synchronize { @sql_count = (@sql_count || 0) + 1 }
      return query_fn.call(sql, params) if query_fn

      with_connection do |conn|
        result = params.empty? ? conn.exec(sql) : conn.exec_params(sql, params)
        result.map { |row| row }
      end
    end

    # Sized to Puma's RAILS_MAX_THREADS so Phoenix's parallel
    # fetch_home speaker+sponsor GETs each get their own PG connection.
    def pool_size
      Integer(ENV.fetch("RAILS_MAX_THREADS", 3))
    end

    def with_connection
      conn = checkout
      yield conn
    rescue PG::ConnectionBad, PG::UnableToSend
      discard(conn)
      conn = nil
      raise
    ensure
      checkin(conn) if conn
    end

    private

    def lock
      @lock ||= Mutex.new
    end

    def wait
      @wait ||= ConditionVariable.new
    end

    def idle
      @idle ||= []
    end

    def checkout
      if connect_fn
        lock.synchronize { @connect_count = (@connect_count || 0) + 1 }
        return connect_fn.call
      end

      created = false
      lock.synchronize do
        loop do
          return idle.pop unless idle.empty?
          @opened ||= 0
          if @opened < pool_size
            @opened += 1
            @connect_count = (@connect_count || 0) + 1
            created = true
            break
          end
          wait.wait(lock)
        end
      end
      begin
        connect_new
      rescue StandardError
        lock.synchronize do
          @opened = [(@opened || 1) - 1, 0].max
          wait.signal
        end
        raise
      end
    end

    def checkin(conn)
      return if connect_fn

      lock.synchronize do
        idle << conn
        wait.signal
      end
    end

    def discard(conn)
      conn.close rescue nil
      return if connect_fn

      lock.synchronize do
        @opened = [(@opened || 1) - 1, 0].max
        wait.signal
      end
    end

    def connect_new
      url = ENV.fetch("DATABASE_URL", "postgres://postgres:postgres@127.0.0.1:5432/carolina_dev")
      url += (url.include?("?") ? "&" : "?") + "sslmode=disable" unless url.include?("sslmode=")
      PG.connect(url)
    end

    def year_speakers(year)
      speakers = query(
        "SELECT #{SPEAKER_COLS} FROM v1_speakers " \
        "WHERE slug IN (SELECT speaker_slug FROM v1_talks WHERE year = $1) " \
        "ORDER BY last_name, first_name",
        [year]
      )
      attach_year_tags(speakers.map { |row| clean(row) }, year)
    end

    def attach_year_tags(speakers, year)
      return [] if speakers.empty?

      slugs = speakers.map { |s| s["slug"] }
      talks_by = load_talks_for_year(year)
      years_by = load_years_for_slugs(slugs)
      speakers.map do |speaker|
        slug = speaker["slug"]
        talks = Array(talks_by[slug])
        years_for = Array(years_by[slug])
        speaker.merge(
          "year" => year,
          "years" => years_for,
          "other_years" => years_for.reject { |y| y == year },
          "talks" => talks,
          "languages" => unique_tags(talks, "languages"),
          "topics" => unique_tags(talks, "topics")
        )
      end
    end

    def load_talks_for_year(year)
      query("SELECT #{TALK_COLS} FROM v1_talks WHERE year = $1 ORDER BY speaker_slug, year DESC", [year])
        .map { |row| clean(row) }
        .group_by { |talk| talk["speaker_slug"] }
    end

    def load_years_for_slugs(slugs)
      return {} if slugs.empty?

      placeholders = slugs.each_index.map { |i| "$#{i + 1}" }.join(", ")
      rows = query(
        "SELECT DISTINCT speaker_slug, year FROM v1_talks WHERE speaker_slug IN (#{placeholders}) ORDER BY speaker_slug, year DESC",
        slugs
      )
      grouped = {}
      rows.each do |row|
        slug = row["speaker_slug"]
        (grouped[slug] ||= []) << Integer(row["year"])
      end
      grouped
    end

    def unique_tags(talks, key)
      talks.flat_map { |talk| pg_text_array(talk[key]) }.uniq
    end

    def pg_text_array(value)
      case value
      when nil
        []
      when Array
        value.map(&:to_s).reject(&:empty?)
      when String
        stripped = value.strip
        return [] if stripped.empty? || stripped == "{}"
        inner = stripped.start_with?("{") && stripped.end_with?("}") ? stripped[1..-2] : stripped
        inner.split(",").map { |part| part.gsub(/\A"|"\z/, "").strip }.reject(&:empty?)
      else
        Array(value).map(&:to_s).reject(&:empty?)
      end
    end

    def clean(row)
      return nil unless row

      row.each_with_object({}) do |(key, value), acc|
        name = key.to_s
        acc[name] =
          if %w[languages topics].include?(name)
            pg_text_array(value)
          elsif name == "year" && value
            Integer(value)
          elsif name == "featured"
            value == "t" || value == true || value == "true"
          else
            value
          end
      end
    end
  end
end

Catalog.reset_counts!
