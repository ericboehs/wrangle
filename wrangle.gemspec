# frozen_string_literal: true

require_relative "lib/wrangle/version"

Gem::Specification.new do |spec|
  spec.name = "wrangle"
  spec.version = Wrangle::VERSION
  spec.authors = ["Eric Boehs"]
  spec.email = ["ericboehs@gmail.com"]

  spec.summary = "Scoped, policy-gated computer use for real macOS and Safari windows."
  spec.description = <<~TEXT
    Wrangle gives an agent one exact application window or Safari tab and no more than that. Its
    native macOS driver runs a bounded typed-decision loop with policy, fresh-target validation,
    at-most-once dispatch, and independent effect verification. Safari uses Apple Events for fast
    DOM-grounded actions. Losing scope ends the task rather than searching for a substitute.
  TEXT
  spec.homepage = "https://github.com/ericboehs/wrangle"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  # The Agent Skill ships with the gem. It is the file that teaches an agent to drive the CLI rather
  # than write scripts against it, which is the whole point of installing this, and it is 4KB.
  spec.files = Dir["lib/**/*.rb", "lib/wrangle/*.jsonl", "lib/wrangle/js/*.js", "lib/wrangle/macos/*.swift",
                   "exe/*", "skills/**/*.md", "README.md", "LICENSE.txt", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = ["wrangle"]
  spec.require_paths = ["lib"]

  # No runtime dependencies. Everything Wrangle needs ships with Ruby.
end
