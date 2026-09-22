# Compile the production boot with YJIT when the process was not already
# started with RUBY_YJIT_ENABLE. Fly and the image set that variable too.
if ENV["RAILS_ENV"] == "production" && defined?(RubyVM::YJIT) && !RubyVM::YJIT.enabled?
  RubyVM::YJIT.enable
end

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup" # Set up gems listed in the Gemfile.
require "bootsnap/setup" # Speed up boot time by caching expensive operations.
