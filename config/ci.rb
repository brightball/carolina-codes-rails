# Run using bin/ci

CI.run do
  step "Setup", "bin/setup --skip-server"

  step "Tests: Rails", "bin/rails test"
  step "Security: Brakeman", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"
  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: gitleaks", "gitleaks git --verbose"
  step "Style: RuboCop", "bin/rubocop"
end
