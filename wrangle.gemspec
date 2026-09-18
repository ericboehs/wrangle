# frozen_string_literal: true

require_relative "lib/wrangle/version"

Gem::Specification.new do |spec|
  spec.name = "wrangle"
  spec.version = Wrangle::VERSION
  spec.authors = ["Eric Boehs"]
  spec.email = ["ericboehs@gmail.com"]

  spec.summary = "Hand one Safari window to a program, and no more than that."
  spec.description = <<~TEXT
    Wrangle drives an ordinary Safari window through Apple Events: no automation session, no
    extension, no native helper. The window stays a real one you can see, keep, and take back.
    Scope is the safety boundary - one window id, one tab position, one expected URL, one document
    epoch - and losing any of them ends the session rather than starting a search for a substitute.
  TEXT
  spec.homepage = "https://github.com/ericboehs/wrangle"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "lib/wrangle/js/*.js", "exe/*", "README.md", "LICENSE.txt", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = ["wrangle"]
  spec.require_paths = ["lib"]

  # No runtime dependencies. Everything Wrangle needs ships with Ruby.
end
