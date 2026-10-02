# frozen_string_literal: true

require "fileutils"
require "json"

require_relative "ui_skill"

module Wrangle
  # User-local procedure files. One bad file is skipped so it cannot take down a task, and nothing
  # is read from outside the store directory.
  class SkillStore
    MAX_FILES = 200
    MAX_BYTES = 16 * 1024
    FILE_NAME = /\A[a-z0-9][a-z0-9-]*\.json\z/

    attr_reader :dir, :skipped

    def self.default = new(dir: dir_from)

    def self.dir_from(env = ENV, home = Dir.home)
      env["WRANGLE_SKILLS_DIR"] || File.join(home, ".config", "wrangle", "skills")
    end

    def initialize(dir:)
      @dir = dir
      @skipped = []
    end

    def any? = paths.any?
    def none? = !any?

    def load
      @skipped = []
      paths.filter_map { |path| read_one(path) }
    end

    def find(id)
      return nil unless id.to_s.match?(UiSkill::ID)

      path = File.join(@dir, "#{id}.json")
      return nil unless File.exist?(path)

      read_one(path)
    end

    def save(skill)
      ensure_dir
      path = safe_path(skill.id)
      write_private(path, "#{JSON.pretty_generate(skill.to_h)}\n")
      path
    end

    private

    def paths
      return [] unless File.directory?(@dir)

      Dir.children(@dir).grep(FILE_NAME).sort.first(MAX_FILES).map { |name| File.join(@dir, name) }
    end

    def read_one(path)
      return skip(path, "symlink") if File.symlink?(path)
      return skip(path, "not a file") unless File.file?(path)
      return skip(path, "outside store") unless inside?(path)
      return skip(path, "too large") if File.size(path) > MAX_BYTES

      skill = UiSkill.from_h(JSON.parse(File.read(path)))
      return skip(path, "id mismatch") unless File.basename(path, ".json") == skill.id

      skill
    rescue JSON::ParserError
      skip(path, "invalid json")
    rescue SkillInvalid => e
      skip(path, e.message)
    end

    def skip(path, reason)
      @skipped << { "file" => File.basename(path), "reason" => reason }
      nil
    end

    def inside?(path)
      root = File.realpath(@dir)
      File.realpath(path).start_with?("#{root}#{File::SEPARATOR}")
    end

    def ensure_dir
      FileUtils.mkdir_p(@dir, mode: 0o700)
      File.chmod(0o700, @dir)
    end

    def safe_path(id)
      raise SkillInvalid, "Skill id must be a short lowercase token" unless id.to_s.match?(UiSkill::ID)

      # The id is a token, so the filename cannot leave the store. A second path check would only
      # repeat that rule.
      File.join(@dir, "#{id}.json")
    end

    def write_private(path, payload)
      temp = File.join(@dir, ".#{File.basename(path, ".json")}.#{Process.pid}.tmp")
      File.write(temp, payload, perm: 0o600)
      File.chmod(0o600, temp)
      File.rename(temp, path)
      File.chmod(0o600, path)
    ensure
      FileUtils.rm_f(temp) if temp && File.exist?(temp)
    end
  end
end
