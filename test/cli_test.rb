# frozen_string_literal: true

require "test_helper"

# The CLI is the whole interface — an agent is meant to drive Safari by shell command rather than by
# writing Ruby against these classes — so the parts of it that need no Safari to answer are worth
# holding still. `--version` shipped broken: the subcommand existed, the flag everyone actually types
# did not, and nothing noticed until the built gem was run by hand.
class CliTest < Minitest::Test
  EXE = File.expand_path("../exe/wrangle", __dir__)
  LIB = File.expand_path("../lib", __dir__)

  def run_cli(*argv)
    out = IO.popen([RbConfig.ruby, "-I", LIB, EXE, *argv], err: %i[child out], &:read)
    [out, $CHILD_STATUS.exitstatus]
  end

  def test_every_spelling_of_version_prints_the_version_and_exits_clean
    ["version", "--version", "-v"].each do |spelling|
      out, status = run_cli(spelling)

      assert_equal Wrangle::VERSION, out.strip, "`wrangle #{spelling}` did not print the version"
      assert_equal 0, status
    end
  end

  def test_the_version_is_the_one_the_gem_would_ship
    assert_match(/\A\d+\.\d+\.\d+/, Wrangle::VERSION)
  end

  def test_help_is_offered_for_every_spelling_and_for_no_command_at_all
    [[], ["help"], ["-h"], ["--help"]].each do |argv|
      out, status = run_cli(*argv)

      assert_match(/hand one Safari window to a program/, out)
      assert_equal 0, status, "`wrangle #{argv.join(" ")}` should not be an error"
    end
  end

  # Usage that names neither the flag nor the exit codes leaves the reader to find both by accident.
  def test_help_documents_the_flags_and_exit_codes_it_promises
    out, = run_cli("--help")

    assert_match(/--version/, out)
    assert_match(/Exit codes: 0 ok, 2 usage, 3 stale/, out)
  end

  def test_an_unknown_command_says_so_and_exits_usage
    out, status = run_cli("teleport")

    assert_match(/unknown command: teleport/, out)
    assert_equal 2, status
  end
end
