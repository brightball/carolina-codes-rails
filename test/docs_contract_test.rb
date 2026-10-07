# frozen_string_literal: true

require "test_helper"

# Reads the shipped docs and version files under the repo root (not fixtures)
# and asserts the polyglot contract, decision record, and agent memory stay
# aligned with the locked Ruby and Rails versions.
class DocsContractTest < ActiveSupport::TestCase
  DOC_NAMES = %w[AGENTS.md README.md MEMORY.md DECISIONS.md].freeze

  test "README states the ruby-version and the locked Rails version" do
    readme = read_root("README.md")
    ruby_version = ruby_version_from(read_root(".ruby-version"))
    rails_version = rails_version_from(read_root("Gemfile.lock"))

    assert_includes readme, ruby_version
    assert_includes readme, rails_version
    assert_match(/bootsnap/i, readme)
    assert_match(/YJIT/, readme)
    refute_match(/CRaC/i, readme)
    assert_match(/Brakeman/, readme)
    assert_match(/bundler-audit/, readme)
    assert_match(/RuboCop/, readme)
    assert_match(/gitleaks/, readme)
  end

  test "AGENTS.md keeps the polyglot contract and points at decision memory" do
    agents = read_root("AGENTS.md")

    assert_match(/v1_/, agents)
    assert_match(/Ash/, agents)
    assert_match(/never query Ash|do not query Ash|Never query Ash/i, agents)
    assert_match(/register/i, agents)
    assert_match(/keep serving|still serve/i, agents)
    assert_match(%r{/health}, agents)
    assert_match(/does not touch the database/i, agents)
    assert_match(%r{bin/ci|pre-commit}, agents)
    assert_includes agents, "MEMORY.md"
    assert_includes agents, "DECISIONS.md"
  end

  test "DECISIONS.md records background registration and pg against v1 views" do
    decisions = read_root("DECISIONS.md")

    assert_match(/background/i, decisions)
    assert_match(/regist/i, decisions)
    assert_match(/v1_\*/, decisions)
    assert_match(/\bpg\b/, decisions)
    assert_match(/Ash/, decisions)
  end

  test "MEMORY.md is curated and is not a copy of AGENTS.md" do
    memory = read_root("MEMORY.md")
    agents = read_root("AGENTS.md")

    refute_empty memory.strip
    refute_equal agents, memory
  end

  test "docs do not contain the Rails master key" do
    key_path = Rails.root.join("config/master.key")
    return unless key_path.file? && key_path.readable?

    secret = File.read(key_path).strip
    return if secret.empty?

    DOC_NAMES.each do |name|
      body = read_root(name)
      refute body.include?(secret), "#{name} must not contain config/master.key"
    end
  end

  private

  def read_root(name)
    File.read(Rails.root.join(name))
  end

  # .ruby-version is "ruby-4.0.6" (rbenv/mise). The version string is the release.
  def ruby_version_from(text)
    version = text.strip[/\d+\.\d+\.\d+/]
    assert version, ".ruby-version must contain a Ruby version"
    version
  end

  # Resolved spec line in Gemfile.lock, not the Gemfile constraint.
  def rails_version_from(lock)
    match = lock.match(/^\s{4}rails \(([0-9][^)]*)\)\s*$/)
    assert match, "Gemfile.lock must resolve a rails version"
    match[1]
  end
end
