# frozen_string_literal: true

require "test_helper"
require "yaml"

# Reads the shipped precommit config and Gitea workflow (not fixtures) and
# asserts the five-check / one-job-per-check / gitleaks-by-name wiring plus
# the prepare-then-restore Gitea graph.
class CiWiringTest < ActiveSupport::TestCase
  CHECKS = {
    "test" => [ "bin/rails test", /\bbin\/rails test\b/ ],
    "sast" => [ "brakeman", /\bbrakeman\b/ ],
    "audit" => [ "bundler-audit", /\bbundler-audit\b/ ],
    "gitleaks" => [ "gitleaks", /\bgitleaks\b/ ],
    "style" => [ "rubocop", /\brubocop\b/ ]
  }.freeze

  PREPARE_ID = "prepare"
  WORKFLOW_PATH = Rails.root.join(".gitea/workflows/precommit.yml")
  GITLEAKS_RELEASE = %r{github\.com/gitleaks/gitleaks/releases}

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
    src = File.read(WORKFLOW_PATH)
    workflow = YAML.safe_load(src, permitted_classes: [], aliases: true)
    jobs = workflow.fetch("jobs")
    refute_empty jobs, "workflow must declare jobs"

    CHECKS.each do |name, (_label, pattern)|
      matching = jobs.select { |job_name, job|
        job_name != PREPARE_ID && job_runs?(job, pattern)
      }.keys
      assert_equal 1, matching.size,
        "exactly one Gitea check job must run #{name} (#{pattern.inspect}), got #{matching.inspect}"
    end

    jobs.each do |job_name, job|
      runs = job_run_scripts(job)
      refute combined_all_checks?(runs),
        "job #{job_name.inspect} must not be a combined all-checks command: #{runs.inspect}"
      uses = job_uses(job)
      refute uses.any? { |action| action.to_s.include?("actions/checkout") },
        "job #{job_name.inspect} must clone with the job token, not actions/checkout"
    end

    assert_match(/\bgitleaks\b/, src)
  end

  test "gitea workflow prepares the workspace once then each check job restores it" do
    src = File.read(WORKFLOW_PATH)
    workflow = YAML.safe_load(src, permitted_classes: [], aliases: true)
    jobs = workflow.fetch("jobs")

    assert jobs.key?(PREPARE_ID), "workflow must declare an initial-stage #{PREPARE_ID} job"
    prepare = jobs.fetch(PREPARE_ID)
    prepare_runs = job_run_scripts(prepare).join("\n")
    prepare_uses = job_uses(prepare)

    assert_empty job_needs(prepare), "initial-stage job must have no needs"
    assert_includes prepare_runs, "GITHUB_SHA", "prepare must clone GITHUB_SHA"
    assert_includes prepare_runs, "x-access-token", "prepare must clone over HTTPS with x-access-token"
    assert_match(/\bgit clone\b/, prepare_runs, "prepare must token-clone")
    refute_match(/--depth\s+1/, prepare_runs,
      "prepare must keep git history so gitleaks git can scan")
    assert_match(/\bbundle install\b/, prepare_runs, "prepare must install gems")
    assert_match(/\bvendor\/bundle\b/, prepare_runs, "prepare must put gems on a path inside the tree")
    assert_match(GITLEAKS_RELEASE, prepare_runs, "prepare must pin-install gitleaks from the release tarball")
    assert_includes prepare_runs, "8.30.1", "prepare must pin gitleaks 8.30.1"
    assert prepare_uses.any? { |used| used.include?("actions/upload-artifact@v3") },
      "prepare must publish the workspace with upload-artifact@v3"
    assert_includes prepare_runs, "prep-workspace", "prepare must pack prep-workspace"
    refute_match(/--exclude=\.?\/?\.git\b/, prepare_runs,
      "prepare must keep .git in the published tarball")
    refute_match(/^\s*git init\b/m, src, "workflow must not git init")

    CHECKS.each_key do |name|
      assert jobs.key?(name), "workflow must keep #{name} as its own job"
      job = jobs.fetch(name)
      runs = job_run_scripts(job).join("\n")
      uses = job_uses(job)

      assert_includes job_needs(job), PREPARE_ID, "job #{name} must need #{PREPARE_ID}"
      assert uses.any? { |used| used.include?("actions/download-artifact@v3") },
        "job #{name} must restore the workspace with download-artifact@v3"
      assert_includes runs, "prep-workspace", "job #{name} must unpack prep-workspace"
      assert_match CHECKS.fetch(name)[1], runs, "job #{name} must run its own check"

      refute_match(/\bgit clone\b/, runs, "job #{name} must not git clone")
      refute_match(/\bbundle install\b/, runs, "job #{name} must not bundle install")
      refute_match(GITLEAKS_RELEASE, runs, "job #{name} must not curl a gitleaks release")
      refute_match(/\bbuild-essential\b/, runs, "job #{name} must not reinstall build-essential")
    end

    assert_match(/\bgitleaks git --verbose\b/, job_run_scripts(jobs.fetch("gitleaks")).join("\n"),
      "gitleaks job must invoke gitleaks by name with git --verbose")
  end

  private

  def job_run_scripts(job)
    Array(job["steps"]).filter_map { |step| step["run"] if step.is_a?(Hash) }
  end

  def job_uses(job)
    Array(job["steps"]).filter_map { |step| step["uses"] if step.is_a?(Hash) }
  end

  def job_needs(job)
    needed = job && job["needs"]
    return [] if needed.nil?

    Array(needed).map(&:to_s)
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
