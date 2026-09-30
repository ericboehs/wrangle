# frozen_string_literal: true

require "fileutils"
require "json"
require "socket"

require_relative "desktop_dispatch"
require_relative "desktop_effect"
require_relative "desktop_session_autonomy"
require_relative "desktop_policy"
require_relative "desktop_progressive_observation"
require_relative "desktop_proposal"
require_relative "event_log"
require_relative "macos_driver"
require_relative "provider_factory"
require_relative "scope_registry"
require_relative "session_server"
require_relative "tart_guest_driver"

module Wrangle
  # Holds one exact macOS root window across short-lived CLI invocations.
  class DesktopSessionServer
    include DesktopDispatch
    include DesktopProgressiveObservation
    include DesktopSessionAutonomy

    PROPOSAL_TTL = DesktopProposal::TTL

    def self.run(socket_path, options) = new(socket_path, options).run

    def initialize(socket_path, options, driver: nil, scope: nil, policy: DesktopPolicy.new,
                   registry: nil, log: nil, provider: nil, guest_driver_class: TartGuestDriver)
      @socket_path = socket_path
      @options = options
      @driver = driver
      @scope = scope
      @policy = policy
      @registry = registry
      @log = log
      @provider = provider
      @guest_driver_class = guest_driver_class
      @autonomy = DesktopAutonomy.new(provider) if provider
      @observation = nil
      @view = nil
      @full_observation = false
      @proposals = {}
      @runs = {}
      @actions = 0
      @poisoned = nil
    end

    def run
      FileUtils.mkdir_p(File.dirname(@socket_path))
      FileUtils.rm_f(@socket_path)
      start_runtime(log_session: File.basename(@socket_path, ".sock"))
      serve(UNIXServer.new(@socket_path))
    ensure
      shutdown
    end

    def run_task(request)
      start_runtime(log_session: "task")
      autonomous_task(request)
    ensure
      shutdown
    end

    private

    def start_runtime(log_session:)
      @driver ||= configured_driver
      @scope ||= @driver.attach(window_id: @options.fetch("window_id"), app: @options.fetch("app"))
      @registry ||= ScopeRegistry.new
      @lease = @registry.acquire(@scope, mode: @options.fetch("concurrency", "exclusive"))
      @provider ||= ProviderFactory.build(@options) if @options["provider"]
      @autonomy ||= DesktopAutonomy.new(@provider) if @provider
      @log ||= EventLog.new(session: log_session)
      fields = {
        "scope_id" => @scope.id, "driver" => @options.fetch("driver", "macos"),
        "concurrency" => @lease.mode
      }
      @log.record("attach", fields)
    end

    def configured_driver
      name = @options.fetch("driver", "macos")
      return MacOSDriver.new if name == "macos"
      raise ConfigurationError, "Unknown desktop driver" unless name == "tart_guest"

      helper = @options.fetch("guest_helper", TartGuestDriver::DEFAULT_HELPER)
      @guest_driver_class.new(vm_name: @options.fetch("vm"), guest_app: @options.fetch("app"), guest_helper: helper)
    end

    def serve(server)
      File.chmod(0o600, @socket_path)
      loop do
        client = server.accept
        line = client.gets
        next client.close unless line

        request = parse(line)
        client.puts(JSON.generate(dispatch(request)))
        client.close
        break if request["op"] == "close"
      end
    ensure
      server.close
    end

    def parse(line)
      JSON.parse(line)
    rescue JSON::ParserError
      { "op" => "bad" }
    end

    def dispatch(request)
      { "ok" => true, "value" => handle(request) }
    rescue Wrangle::Error => e
      terminal = e.is_a?(ScopeLost) || e.is_a?(DeliveryUnknown) || e.is_a?(DriverUnavailable) ||
                 (e.is_a?(DriverRefusal) && e.delivery_unknown?)
      log_refusal(request, e)
      refusal(e.class.name.split("::").last, e.message, terminal:)
    rescue ArgumentError => e
      log_refusal(request, e)
      refusal("ArgumentError", e.message, terminal: false)
    rescue StandardError => e
      log_refusal(request, e)
      refusal(e.class.name, "internal error: #{e.message} (#{e.backtrace&.first})", terminal: true)
    end

    def handle(request)
      case request["op"]
      when "status" then status
      when "observe" then observe
      when "drill" then drill(request)
      when "inspect" then current
      when "preview" then request["goal"] ? autonomous_preview(request) : preview(request)
      when "execute" then execute(request)
      when "continue" then continue_run(request)
      when "close"
        { "closing" => true, "root_preserved" => true,
          "message" => "Wrangle released control; the application window remains open" }
      else raise ArgumentError, "Unknown op #{request["op"].inspect}"
      end
    end

    def status
      {
        "pid" => Process.pid, "driver" => @options.fetch("driver", "macos"), "scope_id" => @scope.id,
        "root" => @scope.root, "app" => @scope.app, "owned" => false,
        "read_only" => @options["driver"] == "tart_guest",
        "observed" => !@observation.nil?, "actions_taken" => @actions,
        "pending_proposals" => @proposals.length, "poisoned" => !@poisoned.nil?,
        "concurrency" => @lease&.mode || @options.fetch("concurrency", "exclusive"),
        "provider" => @autonomy&.status
      }
    end

    def observe
      ensure_usable!
      started = monotonic
      before = @observation
      @observation = @driver.observe(@scope)
      @view = nil
      @full_observation = false
      value = compact(@observation, before)
      @log&.record(
        "observe", "scope_id" => @scope.id, "revision" => @observation["revision"],
                   "complete" => @observation["complete"], "candidates" => @observation["candidates"].length,
                   "ambiguous_actions" => @observation.dig("coverage", "ambiguous_action_count"),
                   "changed" => !value["changed"].nil?, "elapsed_ms" => elapsed_ms(started)
      )
      value
    end

    def drill(request)
      ensure_usable!
      previous = current
      target = candidate(request["ref"])
      raise ArgumentError, "DRILL was not offered for this action" unless target["operations"].include?("DRILL")
      unless DesktopObservation.action_unambiguous?(@observation["candidates"], target, "DRILL")
        raise ArgumentError, "DRILL target matches multiple visible candidates"
      end

      started = monotonic
      view = { ref: target["ref"], snapshot_id: previous.fetch("snapshot_id") }
      @observation = @driver.drill(@scope, **view)
      @view = view
      @full_observation = false
      @proposals.clear
      value = compact(@observation, previous)
      @log&.record(
        "drill", "scope_id" => @scope.id, "revision" => @observation["revision"],
                 "complete" => @observation["complete"], "candidates" => @observation["candidates"].length,
                 "ambiguous_actions" => @observation.dig("coverage", "ambiguous_action_count"),
                 "elapsed_ms" => elapsed_ms(started)
      )
      value
    end

    def current
      raise ArgumentError, "Observe before inspecting" unless @observation

      @observation
    end

    def preview(request)
      ensure_usable!
      current
      if @observation.dig("coverage", "truncated")
        raise PartialObservation, "Observation has unresolved branches; DRILL before proposing an action"
      end

      proposal = DesktopProposal.build(
        scope: @scope, observation: @observation, request:, policy: @policy, created_at: monotonic
      )
      @proposals[proposal["id"]] = proposal
      log_preview(proposal)
      DesktopProposal.compact(proposal)
    end

    def execute(request)
      ensure_usable!
      proposal = proposal_for(request["proposal_id"])
      proposal["attempt_started"] = monotonic
      expired = expire(proposal)
      return record_run_receipt(proposal, expired) if expired

      if proposal.dig("provider", "qualified") == false
        @proposals.delete(proposal["id"])
        denied = receipt(proposal, "refused", "not_applicable", "provider_not_qualified")
        return record_run_receipt(proposal, denied)
      end
      if proposal.dig("policy", "consequential") && request["approve"] != true
        denied = receipt(proposal, "refused", "not_applicable", "approval_required")
        return record_run_receipt(proposal, denied)
      end

      fresh = fresh_observation
      return record_run_receipt(proposal, refuse_stale(proposal, fresh)) if fresh["revision"] != proposal["revision"]

      record_run_receipt(proposal, deliver_proposal(proposal, fresh))
    end

    def proposal_for(id)
      proposal = @proposals[id]
      raise ArgumentError, "Unknown or consumed proposal" unless proposal

      raise ScopeLost, "The proposal belongs to another scope" unless proposal["scope_id"] == @scope.id

      proposal
    end

    def expire(proposal)
      return nil unless monotonic - proposal["created_at"] > PROPOSAL_TTL

      @proposals.delete(proposal["id"])
      receipt(proposal, "not_delivered", "not_applicable", "proposal_expired")
    end

    def refuse_stale(proposal, fresh)
      @observation = fresh
      @proposals.delete(proposal["id"])
      receipt(proposal, "not_delivered", "not_applicable", "stale_observation")
    end

    def revalidated_candidate!(proposal, fresh)
      action_candidate = fresh["candidates"][proposal["number"] - 1]
      if same_candidate?(proposal["candidate"], action_candidate) &&
         DesktopObservation.action_unambiguous?(fresh["candidates"], action_candidate, proposal["operation"])
        return action_candidate
      end

      @proposals.delete(proposal["id"])
      @poisoned = ScopeLost.new("The proposed desktop target became ambiguous during revalidation")
      raise @poisoned
    end

    def same_candidate?(before, after)
      return false unless after

      before.except("ref") == after.except("ref")
    end

    def candidate(index) = DesktopProposal.candidate(@observation, index)

    def log_preview(proposal)
      @log&.record(
        "preview", "proposal_id" => proposal["id"], "scope_id" => @scope.id,
                   "revision" => proposal["revision"], "operation" => proposal["operation"],
                   "classification" => proposal.dig("policy", "classification"),
                   "consequential" => proposal.dig("policy", "consequential")
      )
    end

    def observe_after_dispatch
      [fresh_observation, nil]
    rescue Error => e
      @poisoned = e if e.is_a?(ScopeLost)
      [nil, "#{e.class.name.split("::").last}: #{e.message}"]
    end

    def receipt(proposal, dispatch, effect, reason = nil, after: nil, verification_error: nil, durable: false)
      value = {
        "schema" => "wrangle.receipt.v1", "proposal_id" => proposal["id"],
        "dispatch" => dispatch, "effect" => effect, "reason" => reason,
        "scope_id" => @scope.id, "before_revision" => proposal["revision"],
        "after_revision" => after&.fetch("revision", nil), "verification_error" => verification_error,
        "terminal" => dispatch == "delivery_unknown" || !@poisoned.nil?
      }.compact
      @log&.record(
        "execute", value.slice("proposal_id", "scope_id", "dispatch", "effect", "reason",
                               "before_revision", "after_revision", "terminal")
                        .merge("elapsed_ms" => elapsed_ms(proposal["attempt_started"])),
        durable:
      )
      value
    end

    def ensure_usable!
      raise @poisoned if @poisoned
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def elapsed_ms(started) = started && ((monotonic - started) * 1000).round(1)

    def compact(observation, before)
      candidates = observation["candidates"].each_with_index.map do |candidate, index|
        candidate.slice("role", "label", "value", "states", "operations", "children_count")
                 .merge("ref" => index + 1)
      end
      {
        "schema" => observation["schema"], "driver" => @options.fetch("driver", "macos"),
        "read_only" => @options["driver"] == "tart_guest",
        "scope" => observation["scope"].slice("id", "root", "app"),
        "revision" => observation["revision"], "complete" => observation["complete"],
        "coverage" => observation["coverage"], "candidates" => candidates,
        "ambiguous_actions" => observation["ambiguous_actions"],
        "changed" => changed(before, observation)
      }
    end

    def changed(before, after)
      return nil unless before

      old = before["candidates"].map { |candidate| identity(candidate) }
      new = after["candidates"].map { |candidate| identity(candidate) }
      { "same" => before["revision"] == after["revision"],
        "appeared" => (new - old).first(20), "disappeared" => (old - new).first(20) }
    end

    def identity(candidate) = "#{candidate["role"]}:#{candidate["label"]}"

    def refusal(name, message, terminal:)
      { "ok" => false, "class" => name, "error" => message, "terminal" => terminal,
        "retryable" => !terminal,
        "hint" => terminal ? "This scope cannot continue. Attach again." : "Observe again." }
    end

    def log_refusal(request, error)
      @log&.record("refusal", "operation" => request["op"], "class" => error.class.name.split("::").last)
    end

    def shutdown
      @log&.record("close", "scope_id" => @scope&.id, "actions_taken" => @actions)
      @registry&.release(@lease)
      @driver&.close
      return unless @socket_path

      FileUtils.rm_f(@socket_path)
      FileUtils.rm_f("#{@socket_path}.pid")
    end
  end
end
