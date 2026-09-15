# frozen_string_literal: true

require "test_helper"
require "yaml"

# Reads the shipped precommit config and Gitea workflow (not fixtures) and
# asserts the five-check / one-job-per-check / gitleaks-by-name wiring.
class CiWiringTest < ActiveSupport::TestCase
  CHECKS = {
    "test" => [ "bin/rails test", /\bbin\/rails test\b/ ],
    "sast" => [ "brakeman", /\bbrakeman\b/ ],
    "audit" => [ "bundler-audit", /\bbundler-audit\b/ ],
    "gitleaks" => [ "gitleaks", /\bgitleaks\b/ ],
    "style" => [ "rubocop", /\brubocop\b/ ]
  }.freeze

  test "precommit config lists all five checks and invokes gitleaks by name" do
    precommit_path = Rails.root.join(".pre-commit-config.yaml")
    ci_path = Rails.root.join("config/ci.rb")
    hook_path = Rails.root.join(".githooks/pre-commit")

    precommit_src = File.read(precommit_path)
    ci_src = File.read(ci_path)
    hook_src = File.read(hook_path)

    config = YAML.safe_load(precommit_src, permitted_classes: [], aliases: true)
    hooks = Array(config.fetch("repos")).flat_map { |repo| Array(repo["hooks"]) }
    entries = hooks.map { |hook| hook.fetch("entry") }.join("\n")
    ids = hooks.map { |hook| hook.fetch("id") }

    CHECKS.each do |name, (_label, pattern)|
      assert_match pattern, entries, "pre-commit entries must include #{name}"
      assert_match pattern, ci_src, "config/ci.rb must include #{name}"
      assert_match pattern, hook_src, ".githooks/pre-commit must include #{name}"
    end

    assert_includes ids, "gitleaks"
    assert_match(/\bgitleaks\b/, entries)
    assert_match(/\bgitleaks\b/, ci_src)
    refute_match(/\becho\b/, entries)
  end

  test "gitea workflow has exactly one job per check and no combined all-checks job" do
    path = Rails.root.join(".gitea/workflows/precommit.yml")
    src = File.read(path)
    workflow = YAML.safe_load(src, permitted_classes: [], aliases: true)
    jobs = workflow.fetch("jobs")
    refute_empty jobs, "workflow must declare jobs"

    CHECKS.each do |name, (_label, pattern)|
      matching = jobs.select { |_job_name, job| job_runs?(job, pattern) }.keys
      assert_equal 1, matching.size,
        "exactly one Gitea job must run #{name} (#{pattern.inspect}), got #{matching.inspect}"
    end

    jobs.each do |job_name, job|
      runs = job_run_scripts(job)
      refute combined_all_checks?(runs),
        "job #{job_name.inspect} must not be a combined all-checks command: #{runs.inspect}"
      uses = Array(job["steps"]).filter_map { |step| step["uses"] if step.is_a?(Hash) }
      refute uses.any? { |action| action.to_s.include?("actions/checkout") },
        "job #{job_name.inspect} must clone with the job token, not actions/checkout"
    end

    assert_match(/\bgitleaks\b/, src)
  end

  private

  def job_run_scripts(job)
    Array(job["steps"]).filter_map { |step| step["run"] if step.is_a?(Hash) }
  end

  def job_runs?(job, pattern)
    job_run_scripts(job).any? { |script| script.match?(pattern) }
  end

  def combined_all_checks?(runs)
    runs.any? do |script|
      CHECKS.all? { |_name, (_label, pattern)| script.match?(pattern) }
    end
  end
end
