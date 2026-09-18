# frozen_string_literal: true

# Coverage, without a coverage gem.
#
# Ruby measures lines and branches itself, and Wrangle's whole claim is that everything it needs
# ships with Ruby — a dependency added to check that claim would be a strange way to keep it.
#
# Loaded from test_helper before anything else, so `Coverage.start` runs before the library is
# required and so this `at_exit` registers before Minitest's and therefore runs after it.
#
# Not named coverage.rb: rake puts test/ on the load path, so `require "coverage"` would find this
# file instead of the standard library's, return false because it is already loading, and leave the
# constant undefined.
require "coverage"

Coverage.start(lines: true, branches: true)

module CoverageReport
  ROOT = File.expand_path("..", __dir__)
  # exe/wrangle is exercised by running it, in a subprocess, which is the only honest way to test a
  # command-line tool's exit codes. That coverage lands in another process and cannot be seen here.
  TARGET = "lib/"

  # A line with no code on it is not a line anyone can miss.
  def self.lines(result)
    relevant = result[:lines].compact
    [relevant.count(&:positive?), relevant.length]
  end

  # Ruby reports a branch as a parent (the `if`, the `case`, the `&.`) and the arms under it. The
  # arms are what a test can miss: an `else` nobody ever took is the bug this is looking for.
  def self.branches(result)
    arms = result[:branches].values.flat_map(&:values)
    [arms.count(&:positive?), arms.length]
  end

  def self.missed_lines(file, result)
    result[:lines].each_with_index.filter_map { |hits, i| i + 1 if hits&.zero? }
  end

  def self.missed_branches(file, result)
    result[:branches].flat_map do |(kind, _, line, *), arms|
      arms.filter_map { |(arm, _, arm_line, *), hits| "#{line}:#{kind}/#{arm}" if hits.zero? && arm_line }
    end
  end

  def self.report
    files = Coverage.result.select { |file, _| file.start_with?(File.join(ROOT, TARGET)) }
    return if files.empty?

    rows = files.map { |file, result| row(file, result) }.sort_by { |r| [r[:line_pct], r[:branch_pct]] }
    print_table(rows)
    totals(rows)
  end

  def self.row(file, result)
    covered_lines, total_lines = lines(result)
    covered_arms, total_arms = branches(result)
    { name: file.delete_prefix("#{ROOT}/"), covered_lines:, total_lines:, covered_arms:, total_arms:,
      line_pct: pct(covered_lines, total_lines), branch_pct: pct(covered_arms, total_arms),
      missed_lines: missed_lines(file, result), missed_branches: missed_branches(file, result) }
  end

  def self.pct(covered, total) = total.zero? ? 100.0 : (covered * 100.0 / total)

  def self.print_table(rows)
    warn "\n#{"file".ljust(34)}#{"lines".rjust(14)}#{"branches".rjust(14)}"
    rows.each do |r|
      line = "#{r[:covered_lines]}/#{r[:total_lines]} #{format("%5.1f", r[:line_pct])}%"
      branch = "#{r[:covered_arms]}/#{r[:total_arms]} #{format("%5.1f", r[:branch_pct])}%"
      warn "#{r[:name].delete_prefix("lib/wrangle/").ljust(34)}#{line.rjust(14)}#{branch.rjust(14)}"
    end
  end

  def self.totals(rows)
    covered_lines = rows.sum { _1[:covered_lines] }
    total_lines = rows.sum { _1[:total_lines] }
    covered_arms = rows.sum { _1[:covered_arms] }
    total_arms = rows.sum { _1[:total_arms] }
    line_pct = pct(covered_lines, total_lines)
    branch_pct = pct(covered_arms, total_arms)
    warn format("\n%-34s%8d/%-5d%8d/%-5d", "TOTAL", covered_lines, total_lines, covered_arms, total_arms)
    warn format("%-34s%13.2f%%%13.2f%%", "", line_pct, branch_pct)
    detail(rows) if ENV["COVERAGE_DETAIL"]
    enforce(line_pct, branch_pct)
  end

  def self.detail(rows)
    rows.each do |r|
      next if r[:missed_lines].empty? && r[:missed_branches].empty?

      warn "\n#{r[:name]}"
      warn "  lines:    #{r[:missed_lines].join(", ")}" unless r[:missed_lines].empty?
      warn "  branches: #{r[:missed_branches].join(", ")}" unless r[:missed_branches].empty?
    end
  end

  # A floor that does not fail the build is a number on a screen.
  def self.enforce(line_pct, branch_pct)
    floor = Float(ENV["COVERAGE_FLOOR"] || 95)
    return if line_pct >= floor && branch_pct >= floor

    warn "\ncoverage below #{floor}%: lines #{format("%.2f", line_pct)}%, " \
         "branches #{format("%.2f", branch_pct)}%"
    exit 1 if ENV["COVERAGE_ENFORCE"]
  end
end

at_exit { CoverageReport.report }
