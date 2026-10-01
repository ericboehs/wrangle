# frozen_string_literal: true

require "digest"
require "uri"

module Wrangle
  # A stored procedure is an ordered plan of sub-goals for one app or host.
  #
  # It is never a scrape. Selectors, coordinates, prices, and page text are rejected, and a loaded
  # skill can only change the words of the next goal. The live observation still decides what may
  # be pressed.
  class UiSkill
    SCHEMA = "wrangle.ui-skill.v1"
    ID = /\A[a-z0-9][a-z0-9-]{0,63}\z/
    MAX_LEGS = 6
    MAX_LEG = 240
    MAX_STOP = 240
    MAX_TITLE = 80
    MAX_SUMMARY = 200
    MAX_TERMS = 12
    MAX_SURFACES = 8
    MAX_SURFACE = 80
    LIVE_REMINDER = "Live page state is authoritative; remembered availability and prices are not."
    DEFAULT_STOP = "The requested outcome is visible on the current page. Recheck live values; " \
                   "remembered prices and availability are not evidence."
    BROWSERS = %w[safari chrome firefox arc brave edge].freeze
    STOPWORDS = %w[a an the to for from of in on at and or with without my your please just then this that].freeze
    SECRET = /(?:password|passcode|api[_-]?key|secret|token)\s*[:=]\s*\S+/i
    SOURCES = %w[teach manual].freeze
    TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/

    attr_reader :id, :version, :title, :summary, :apps, :hosts, :goal_terms, :legs, :stop,
                :source, :taught_at, :fingerprint, :wrangle_version

    def self.from_h(data) = new(SkillSchema.normalize(data))

    def self.build(**attributes) = from_h(document(attributes))

    def self.document(attributes)
      {
        "schema" => SCHEMA, "id" => attributes.fetch(:id), "version" => attributes.fetch(:version),
        "title" => attributes.fetch(:title), "summary" => attributes.fetch(:summary),
        "match" => {
          "apps" => attributes.fetch(:apps, []), "hosts" => attributes.fetch(:hosts, []),
          "goal_terms" => attributes.fetch(:goal_terms, [])
        },
        "legs" => attributes.fetch(:legs), "stop" => attributes[:stop],
        "source" => attributes.fetch(:source, "teach"), "taught_at" => attributes[:taught_at],
        "fingerprint" => attributes[:fingerprint], "wrangle" => attributes[:wrangle] || VERSION
      }.compact
    end

    def initialize(attributes)
      @id = attributes.fetch(:id)
      @version = attributes.fetch(:version)
      @title = attributes.fetch(:title)
      @summary = attributes.fetch(:summary)
      @apps = attributes.fetch(:apps).freeze
      @hosts = attributes.fetch(:hosts).freeze
      @goal_terms = attributes.fetch(:goal_terms).freeze
      @legs = attributes.fetch(:legs).freeze
      @stop = attributes[:stop]
      @source = attributes.fetch(:source)
      @taught_at = attributes[:taught_at]
      @fingerprint = attributes[:fingerprint]
      @wrangle_version = attributes[:wrangle_version]
      freeze
    end

    def to_h
      {
        "schema" => SCHEMA, "id" => id, "version" => version, "title" => title, "summary" => summary,
        "match" => { "apps" => apps, "hosts" => hosts, "goal_terms" => goal_terms },
        "legs" => legs, "stop" => stop, "source" => source, "taught_at" => taught_at,
        "fingerprint" => fingerprint, "wrangle" => wrangle_version
      }.compact
    end

    def plan_for(goal)
      bound = legs.map { |leg| "#{leg} Overall goal: #{goal}. #{LIVE_REMINDER}" }
      bound[-1] = "#{bound[-1]} Stop only when: #{stop}" if stop
      bound
    end

    def choice_label
      surface = (hosts + apps).first(3).join(", ")
      "#{title}: #{summary} [#{surface}]"[0, 180]
    end

    def surface_match?(app:, host:)
      return false if apps.empty? && hosts.empty?
      return false unless declared_app_ok?(app) && declared_host_ok?(host)

      app_hit?(app) || host_hit?(host)
    end

    def weak_for?(goal)
      return false if exact_fingerprint?(goal)
      return true if terms_miss?(goal)

      browser_only? && overlap(goal).zero?
    end

    def overlap(goal)
      wanted = goal_terms.map(&:downcase)
      wanted = self.class.tokens(title) if wanted.empty?
      return 0.0 if wanted.empty?

      (wanted & self.class.tokens(goal)).length.to_f / wanted.length
    end

    def exact_fingerprint?(goal)
      !fingerprint.to_s.empty? && fingerprint == self.class.fingerprint(goal)
    end

    def self.derive_id(app:, host:, goal:)
      fp = fingerprint(goal)
      "#{id_surface(app, host)[0, 51].delete_suffix("-")}-#{fp}"
    end

    def self.id_surface(app, host)
      raw = host.to_s.empty? ? app.to_s.downcase : normalize_host(host).tr(".", "-")
      cleaned = raw.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-")
      cleaned.empty? ? "app" : cleaned
    end

    def self.fingerprint(goal) = Digest::SHA256.hexdigest(tokens(goal).sort.join("\n"))[0, 12]

    def self.tokens(text)
      text.to_s.downcase.scan(/[a-z0-9]+/).reject { |token| token.length < 3 || STOPWORDS.include?(token) }.uniq
    end

    def self.clip(text, limit)
      cleaned = text.to_s.gsub(/[\r\n\t]+/, " ").strip
      return cleaned if cleaned.length <= limit

      "#{cleaned[0, limit - 1]}…"
    end

    def self.host_of(url)
      return nil if url.to_s.empty?

      URI.parse(url).host&.downcase
    rescue URI::InvalidURIError
      nil
    end

    def self.host_match?(declared, observed)
      left = normalize_host(declared)
      right = normalize_host(observed)
      return false if left.empty? || right.empty?

      # The page may be a subdomain of the skill's host. The reverse would apply a narrower
      # recipe to the apex site, which is a different procedure.
      left == right || right.end_with?(".#{left}")
    end

    def self.normalize_host(host)
      host.to_s.downcase.strip.delete_prefix("www.").delete_suffix(".")
    end

    def self.browser_app?(app)
      token = app.to_s.downcase
      BROWSERS.any? { |name| token == name || token.include?(name) }
    end

    private

    def declared_app_ok?(app) = apps.empty? || app_hit?(app)
    def declared_host_ok?(host) = hosts.empty? || (!host.to_s.empty? && host_hit?(host))
    def app_hit?(app) = apps.any? { |name| name.casecmp?(app.to_s) }
    def host_hit?(host) = hosts.any? { |declared| self.class.host_match?(declared, host) }
    def terms_miss?(goal) = goal_terms.any? && !goal_terms.map(&:downcase).intersect?(self.class.tokens(goal))
    def browser_only? = hosts.empty? && apps.any? && apps.all? { |app| self.class.browser_app?(app) }
  end

  # The only door a skill document gets through. Unknown fields are rejected rather than ignored,
  # because a scrape hidden beside the plan would otherwise ride along into the next run.
  module SkillSchema
    ALLOWED = %w[schema id version title summary match legs stop source taught_at fingerprint wrangle].freeze
    MATCH_ALLOWED = %w[apps hosts goal_terms].freeze

    module_function

    def normalize(data)
      hash = hash!(data)
      reject_unknown!(hash)
      reject_secret!(hash)
      attributes(hash).tap { |attrs| require_surface!(attrs) }
    end

    def hash!(data)
      raise SkillInvalid, "A skill must be a JSON object" unless data.is_a?(Hash)
      raise SkillInvalid, "Unsupported skill schema" unless data["schema"] == UiSkill::SCHEMA

      data
    end

    def reject_unknown!(data)
      unknown = data.keys.map(&:to_s) - ALLOWED
      raise SkillInvalid, "Unknown skill fields: #{unknown.join(", ")}" if unknown.any?

      match = data["match"]
      return if match.nil?

      raise SkillInvalid, "Skill match must be an object" unless match.is_a?(Hash)

      extra = match.keys.map(&:to_s) - MATCH_ALLOWED
      raise SkillInvalid, "Unknown match fields: #{extra.join(", ")}" if extra.any?
    end

    def reject_secret!(data)
      text = [data["title"], data["summary"], data["stop"], Array(data["legs"]),
              data.dig("match", "goal_terms")].flatten.join("\n")
      return unless text.match?(UiSkill::SECRET)

      raise SkillInvalid, "Refusing to store a skill that contains a secret assignment"
    end

    def attributes(data)
      {
        id: identity(data), version: version(data), title: text!(data, "title", 1, UiSkill::MAX_TITLE),
        summary: text!(data, "summary", 1, UiSkill::MAX_SUMMARY), apps: surfaces(data, "apps"),
        hosts: surfaces(data, "hosts"), goal_terms: terms(data), legs: legs(data),
        stop: optional_text(data, "stop", UiSkill::MAX_STOP), source: source(data),
        taught_at: taught_at(data), fingerprint: fingerprint(data),
        wrangle_version: optional_text(data, "wrangle", 20)
      }
    end

    def identity(data)
      id = data["id"].to_s
      raise SkillInvalid, "Skill id must be a short lowercase token" unless id.match?(UiSkill::ID)

      id
    end

    def version(data)
      number = data["version"]
      return number if number.is_a?(Integer) && number >= 1

      raise SkillInvalid, "Skill version must be a positive integer"
    end

    def text!(data, key, min, max)
      value = line(data[key])
      return value if value.length.between?(min, max)

      raise SkillInvalid, "Skill #{key} must be #{min}-#{max} characters"
    end

    def optional_text(data, key, max)
      return nil if data[key].nil?

      value = line(data[key])
      raise SkillInvalid, "Skill #{key} is too long" if value.length > max

      value.empty? ? nil : value
    end

    def line(value)
      raise SkillInvalid, "Skill text must be a string" unless value.is_a?(String)

      value.gsub(/[\r\n\t]+/, " ").strip
    end

    def surfaces(data, key)
      values = data.dig("match", key)
      return [] if values.nil?
      raise SkillInvalid, "Skill #{key} must be a list" unless values.is_a?(Array)
      raise SkillInvalid, "Skill #{key} has too many entries" if values.length > UiSkill::MAX_SURFACES

      values.map { |value| surface!(value, key) }
    end

    def surface!(value, key)
      raise SkillInvalid, "Skill #{key} entries must be strings" unless value.is_a?(String)

      cleaned = key == "hosts" ? UiSkill.normalize_host(value) : value.strip
      return cleaned if !cleaned.empty? && cleaned.length <= UiSkill::MAX_SURFACE

      raise SkillInvalid, "Skill #{key} entries must be short"
    end

    def terms(data)
      values = data.dig("match", "goal_terms")
      return [] if values.nil?
      raise SkillInvalid, "Skill goal_terms must be a list" unless values.is_a?(Array)
      raise SkillInvalid, "Skill goal_terms has too many entries" if values.length > UiSkill::MAX_TERMS

      values.map { |value| term!(value) }.uniq
    end

    def term!(value)
      raise SkillInvalid, "Skill goal terms must be strings" unless value.is_a?(String)

      term = value.downcase.strip
      return term if term.match?(/\A[a-z0-9]{3,40}\z/)

      raise SkillInvalid, "Skill goal terms must be short tokens"
    end

    def legs(data)
      values = data["legs"]
      unless values.is_a?(Array) && values.length.between?(1, UiSkill::MAX_LEGS)
        raise SkillInvalid, "A skill needs 1-#{UiSkill::MAX_LEGS} procedure legs"
      end

      values.map { |value| leg!(value) }
    end

    def leg!(value)
      text = line(value)
      return text if text.length.between?(1, UiSkill::MAX_LEG)

      raise SkillInvalid, "A skill leg must be 1-#{UiSkill::MAX_LEG} characters"
    end

    def source(data)
      value = data["source"] || "teach"
      return value if value.is_a?(String) && UiSkill::SOURCES.include?(value)

      raise SkillInvalid, "Unknown skill source"
    end

    def taught_at(data)
      value = data["taught_at"]
      return nil if value.nil?
      return value if value.is_a?(String) && value.match?(UiSkill::TIMESTAMP)

      raise SkillInvalid, "taught_at must be an ISO-8601 timestamp"
    end

    def fingerprint(data)
      value = data["fingerprint"]
      return nil if value.nil?
      return value if value.is_a?(String) && value.match?(/\A[0-9a-f]{12}\z/)

      raise SkillInvalid, "fingerprint must be 12 hex characters"
    end

    def require_surface!(attrs)
      return if attrs[:apps].any? || attrs[:hosts].any?

      raise SkillInvalid, "A skill must name an app or a host"
    end
  end
end
