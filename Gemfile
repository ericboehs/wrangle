# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# Wrangle has no runtime dependencies, and its development set is deliberately just as small:
# minitest and rake ship with Ruby, so a checkout needs no native extensions and no compiler.
group :development do
  gem "minitest"
  gem "rake"

  # Optional. RuboCop needs a native json build, which is more than a checkout should require.
  # Install it yourself if you want it; the Rakefile adds the task only when it is present.
  # gem "rubocop", require: false
end
