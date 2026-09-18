# frozen_string_literal: true

require "fileutils"
require "json"
require "socket"

require_relative "safari"

module Wrangle
  # A Safari session that outlives a single command.
  #
  # An agent working through a shell gets one process per command, but a browser session is only
  # useful if it persists between them. This holds one `Wrangle::Safari` open behind a Unix socket so
  # `observe`, `act`, and `act` again are three commands against the same window.
  #
  # Everything it returns is shaped for a reader who has to decide what to do next: what changed, what
  # is now available, and — when something failed — whether the failure is worth retrying.
  class SessionServer
    DEFAULT_CONFIDENCE = 0.5
    STEADY_POLL = 0.05
    STEADY_BUDGET = 0.2
    SOFT_SETTLE = 0.6
    MAX_SOFT = 1
    SPIN_ALLOWANCE = 3
    RECONSIDER = %i[unsure soft_done absent].freeze
    # Acting wrongly costs one action, which the next step can usually undo. Declaring BLOCKED throws
    # away every remaining leg, and no later step can recover it — so lowering --min-confidence to
    # help an underconfident click must not also make it easier to abandon the run.
    BLOCKED_FLOOR = 0.6
    # "Not there" is the one conclusion that time can refute. A control that has not rendered yet
    # becomes a control that has, and inside a plan the next leg starts milliseconds after the last
    # one finished — Amazon's filter sidebar hydrates well after its results do. So wait longer and
    # look again before believing a page is a dead end: two further looks with a widening pause,
    # against the one an ordinary low-confidence decision gets.
    BLOCKED_RELOOKS = 3
    # Settling a churning page and waiting for a control to arrive are different kinds of patience.
    # Amazon's filter sidebar has taken over two seconds after its results were already interactive,
    # which is far longer than any settle should block a step for.
    BLOCKED_CEILING = 2.5
    DEFAULT_LEG_STEPS = 8
    STEADY_CEILING = 1.2
    MAX_MISSES = 4
    SETTLE_POLL = 0.3
    STABLE_ROUNDS = 2
    # A click that navigates changes nothing for the first few hundred milliseconds. Without a floor,
    # two identical reads arrive before the browser has begun and the page is declared settled, which
    # reports a working action as "nothing changed" — worse than saying nothing at all.
    QUIET_FLOOR = 1.5

    def self.socket_path(name)
      File.join(ENV["WRANGLE_HOME"] || File.join(Dir.home, ".wrangle"), "#{name}.sock")
    end

    def self.run(socket_path, options)
      new(socket_path, options).run
    end

    # `session` is injectable so the protocol, the diffing, and the refusal shapes can be tested
    # against a fake bridge instead of a browser.
    def initialize(socket_path, options, session: nil, jev: nil)
      @socket_path = socket_path
      @options = options
      @session = session
      @jev = jev
      @page = nil
      @acted = 0
      @history = []
    end

    def run
      FileUtils.mkdir_p(File.dirname(@socket_path))
      FileUtils.rm_f(@socket_path)
      @session ||= start_session
      serve(UNIXServer.new(@socket_path))
    ensure
      shutdown
    end

    private

    def mcp? = @options["backend"].to_s == "mcp"

    def start_session
      if @options["window_id"]
        raise ArgumentError, "The MCP backend cannot attach to an existing window" if mcp?

        Safari.attach(window_id: @options["window_id"], display: @options["display"])
      else
        Safari.open(@options.fetch("url"),
                    display: @options["display"], bounds: @options["bounds"],
                    **(mcp? ? { bridge: McpBridge.new } : {}))
      end
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
    end

    def parse(line)
      JSON.parse(line)
    rescue JSON::ParserError
      { "op" => "bad" }
    end

    def dispatch(request)
      { "ok" => true, "value" => handle(request) }
    rescue Wrangle::Error => e
      refusal(e.class.name.split("::").last, e.message, terminal: e.is_a?(ScopeLost) || e.is_a?(DeliveryUnknown))
    rescue ArgumentError => e
      refusal("ArgumentError", e.message, terminal: false)
    rescue StandardError => e
      # A bug is still a reply. The client is blocked on a socket read, so a server that dies here
      # hangs the caller forever instead of telling it anything — the session is suspect afterwards,
      # so this is terminal, but it is reported rather than silently fatal.
      refusal(e.class.name, "internal error: #{e.message} (#{e.backtrace&.first})", terminal: true)
    end

    def handle(request)
      case request["op"]
      when "status" then status
      when "observe" then observe(request["settle"].to_f)
      when "act" then act(request)
      when "text" then { "text" => fresh_text(request) }
      when "decide" then decide(request)
      when "run" then run_goal(request)
      when "close" then { "closing" => true }
      else raise ArgumentError, "Unknown op #{request["op"].inspect}"
      end
    end

    # A refusal says what to do about itself. `retryable` is the difference between "look again" and
    # "this session is over", which is the single most useful bit for whoever is deciding next.
    def refusal(name, message, terminal:)
      {
        "ok" => false, "class" => name, "error" => message, "terminal" => terminal,
        "retryable" => !terminal,
        "hint" => if terminal
                    "This session cannot continue. Start a new one."
                  else
                    "Run `wrangle observe` and choose an action from the fresh list."
                  end
      }
    end

    def status
      {
        "pid" => Process.pid, "backend" => @options["backend"] || "jxa",
        "window_id" => @session.window_id, "mode" => @session.mode,
        "owned" => @session.owned?, "url" => @session.expected_url, "actions_taken" => @acted,
        "observed" => !@page.nil?
      }
    end

    def current
      @page || (@page = @session.observe)
    end

    # Reading text off a cached observation silently reports the page as it was before the last
    # navigation finished. Text is always read fresh.
    def fresh_text(request)
      settle = request["settle"].to_f
      @page = settle.positive? ? settled(settle, @page) : @session.observe
      @page["text"]
    end

    def observe(settle)
      before = @page
      @page = settle.positive? ? settled(settle, before) : @session.observe
      describe(before, @page)
    end

    # Poll until the page stops changing, rather than sleeping a guessed number of seconds. Stability
    # only counts once the page has moved, or once the floor has passed with it sitting still.
    # When the caller has told us what they are waiting for, wait for exactly that and stop. Waiting
    # for a page to go quiet is a proxy; waiting for the text you need is the real thing, and a busy
    # page like a results list may never go quiet at all.
    def settled(timeout, baseline, expect = nil)
      page = @session.observe
      return page if arrived?(page, expect)

      deadline = now + timeout
      floor = now + [QUIET_FLOOR, timeout].min
      stable = 0
      moved = departed?(baseline, page)
      until now >= deadline || (stable >= STABLE_ROUNDS && (moved || now >= floor))
        sleep SETTLE_POLL
        nxt = @session.observe
        stable = nxt["fingerprint"] == page["fingerprint"] ? stable + 1 : 0
        moved ||= departed?(baseline, nxt)
        page = nxt
        break if arrived?(page, expect)
      end
      page
    end

    def arrived?(page, expect)
      !expect.nil? && page["text"].match?(expect)
    end

    def departed?(baseline, page)
      !baseline.nil? && baseline["fingerprint"] != page["fingerprint"]
    end

    def act(request)
      raise ArgumentError, "Observe before acting" unless @page

      action = chosen(request["ref"])
      before = @page
      @session.act(action, @page, text: request["text"])
      @acted += 1
      @page = settled(request.fetch("settle", 3).to_f, before, request["expect"])
      describe(before, @page).merge("executed" => label(action), "kind" => action["kind"])
    end

    def chosen(ref)
      available = @page["actions"]
      unless ref.is_a?(Integer) && ref.positive? && ref <= available.size
        raise ArgumentError, "No action ##{ref.inspect} in the last observation; it offered #{available.size}"
      end

      available[ref - 1]
    end

    def describe(before, after)
      {
        "url" => after["url"], "title" => after["title"],
        "fingerprint" => after["fingerprint"][0, 12],
        "scroll" => after["scroll"], "text_chars" => after["text"].length,
        "actions" => after["actions"].each_with_index.map { |action, index| compact(action, index) },
        "changed" => change(before, after)
      }
    end

    def compact(action, index)
      {
        "ref" => index + 1, "kind" => action["kind"], "role" => action["role"],
        "label" => label(action), "value" => presence(action["value"])
      }.compact
    end

    # The whole point of the interactive mode: after an action, say what actually moved. An agent that
    # can see "nothing changed" can course-correct; one that only gets a page dump has to guess.
    def change(before, after)
      return nil unless before

      old = before["actions"].map { |action| label(action) }
      new = after["actions"].map { |action| label(action) }
      {
        "same_page" => before["fingerprint"] == after["fingerprint"],
        "url_changed" => before["url"] != after["url"],
        "text_delta" => after["text"].length - before["text"].length,
        "scroll_delta" => after["scroll"]["y"] - before["scroll"]["y"],
        "appeared" => (new - old).uniq.first(20),
        "disappeared" => (old - new).uniq.first(20)
      }
    end

    def label(action) = action["label"].to_s

    # --- deciding ----------------------------------------------------------------------------

    def decider(request)
      Decider.new(goal: request.fetch("goal"))
    end

    def jev(request)
      @jev ||= Jev.from_env(endpoint: request["endpoint"], model: request["model"])
    end

    # Proposes, and does nothing else. Acting on the proposal is a separate, explicit request.
    def decide(request)
      page = current
      chooser = decider(request)
      started = now
      questions = chooser.questions(page)
      answer = jev(request).ask(state: chooser.state(page, @history), questions: questions)
      choice = chooser.resolve(answer, page)

      { "operation" => choice.operation, "action" => choice.label, "kind" => choice.action&.fetch("kind"),
        "confidence" => choice.confidence, "target_confidence" => choice.target_confidence,
        "decided_in_ms" => ((now - started) * 1000).round, "executed" => false,
        "model" => answer["model"], "input_tokens" => answer.dig("usage", "input_tokens"),
        "choice" => choice }
    end

    # No fixed pause anywhere. Waiting is an operation the model can choose when a control is missing
    # or results are still loading, so a page that updates instantly costs nothing.
    def run_goal(request)
      raise ArgumentError, "run needs execute: true to touch the page" unless request["execute"]

      expect = request["expect"] && Regexp.new(request["expect"], Regexp::IGNORECASE)
      plan = Array(request["plan"]).filter_map { |goal| presence(goal) }
      plan = [request["goal"]] if plan.empty?
      summarise(request, run_plan(request, plan, expect), expect)
    end

    # One CLI call, several sub-goals. Each leg runs to its own DONE and the next begins, so the
    # caller is not paid a full model turn for every handoff — on a form that was ten round trips to
    # the calling agent, which dwarfed the decisions themselves. A leg that does not reach DONE ends
    # the plan: the later legs assume the earlier ones happened, so guessing past a failure is how a
    # run types a date into a passenger field.
    def run_plan(request, plan, expect)
      budget = (request["steps"] || 20).to_i
      leg_cap = (request["leg_steps"] || DEFAULT_LEG_STEPS).to_i
      steps = []
      plan.each_with_index do |goal, index|
        remaining = budget - steps.count { |step| step["operation"] != "GOAL" }
        break if remaining <= 0

        steps << { "operation" => "GOAL", "action" => goal, "confidence" => 0.0, "index" => index + 1 } if plan.size > 1
        leg = run_leg(request.merge("goal" => goal), [remaining, leg_cap].min, expect)
        steps.concat(leg)
        break unless leg.last&.fetch("operation", nil) == "DONE"
      end
      steps
    end

    # The budget counts work done, not attempts made. A stale retry or a second look at a
    # half-rendered page is overhead, and charging it to the leg means a form that churns a little
    # runs out of allowance before it finishes — while a separate spin cap still stops a loop that is
    # making no progress at all.
    def run_leg(request, budget, expect)
      steps = []
      tally = { missed: 0, soft: 0, done: 0 }
      spins = 0
      while tally[:done] < budget && spins < budget * SPIN_ALLOWANCE
        spins += 1
        outcome = attempt(request, steps, tally)
        break if outcome == :stale && tally[:missed] >= MAX_MISSES
        next if outcome == :stale

        # Low confidence often means the page was half-rendered when Jev looked — an autocomplete list
        # that had not arrived yet reads as ambiguity. A second decision costs ~350ms; handing back to
        # the calling agent costs a full model turn, measured at 5-6s. Spend the cheap one first.
        if RECONSIDER.include?(outcome)
          looks = outcome == :absent ? BLOCKED_RELOOKS : MAX_SOFT
          break if tally[:soft] >= looks

          waited = patience(outcome, tally[:soft])
          tally[:soft] += 1
          steps.push(looked_again(steps.pop, tally[:soft], waited))
          steady(waited)
          next
        end
        break if outcome == :stop

        tally.merge!(soft: 0, missed: 0, done: tally[:done] + 1)
        break if expect && @page["text"].match?(expect)
        break if stalled?
      end
      steps
    end

    # A stale page means the decision was made about a page that no longer exists. The freshness check
    # fires before any input, so nothing was delivered and deciding again is safe. This is the one
    # retry Wrangle allows itself, and only because no mutation happened.
    def attempt(request, steps, tally)
      # Start impatient. A long poll on every step is what makes a run feel like it is stalling, and a
      # page that streams content in never goes still anyway. When the page proves it is churning
      # faster than a decision can be made, back off instead of spinning — an animating menu will
      # invalidate the target forever at a fixed retry rate.
      began = now
      steady(backoff(request.fetch("steady", STEADY_BUDGET).to_f, tally[:missed]))
      step = decide(request)
      steps << step.except("choice")
      advance(step, request, steps.last, began, tally)
    rescue StalePage
      tally[:missed] += 1
      steps << missed_step(tally[:missed], began)
      :stale
    end

    # A decision about a page that is still rendering is a decision thrown away: Jev answers in
    # ~350ms, and the freshness check then rejects it. Autocomplete menus and calendars settle in far
    # less than that, so a couple of cheap observations cost much less than the wasted call they avoid.
    # This is a budget, not a floor — a page that is already still returns immediately after one poll.
    def steady(budget)
      return @page unless budget.positive?

      deadline = now + budget
      loop do
        before = @page["fingerprint"]
        sleep(STEADY_POLL)
        @page = @session.observe
        return @page if @page["fingerprint"] == before || now >= deadline
      end
    end

    # Jev reports how sure it is, and a low number is information, not noise. Executing a 5%-confidence
    # target is how a run ends up typing the origin into a multi-city field.
    def backoff(base, missed) = missed.zero? ? base : [base * (2**missed), STEADY_CEILING].min

    def missed_step(missed, began)
      @page = @session.observe
      { "operation" => "RESTALE", "confidence" => 0.0, "step_ms" => ((now - began) * 1000).round,
        "action" => "The page moved while deciding; looked again (#{missed})" }
    end

    def advance(step, request, record, began, tally = { done: 1 })
      choice = step.fetch("choice")
      # Stopping gets the floor too, but DONE and BLOCKED are not symmetric. Inside a plan an uncertain
      # DONE is cheap to be wrong about — the next leg simply does the work that was not done — while
      # an uncertain BLOCKED abandons every remaining leg. So look again at both, then let DONE
      # through and make BLOCKED earn a handoff.
      if choice.stop?
        return :absent if unconfirmed_blocked?(choice, request, record, tally)
        return :stop unless weak?(choice, request)
        return :absent if choice.operation == "BLOCKED" && unsure?(choice, request, record)

        return :soft_done
      end
      return :unsure if unsure?(choice, request, record)

      text, wanted = text_for(choice, request)
      if wanted
        record.merge!("operation" => "HANDOFF", "action" => wanted)
        return :stop
      end
      before = @page
      @session.act(choice.action, @page, text: text)
      @acted += 1
      @page = @session.observe
      record.merge!("executed" => true, "text" => text, "step_ms" => ((now - began) * 1000).round,
                    "page_changed" => before["fingerprint"] != @page["fingerprint"])
      @history << { "action" => choice.label, "kind" => choice.action["kind"], "text" => text,
                    "page_changed" => record["page_changed"] }
      :go
    end

    # Jev reports how sure it is, and a low number is information, not noise. Below the floor Wrangle
    # stops and hands the page back to whoever called it, saying what it was torn between.
    # A second look is not free and it is not nothing: it explains both the pause and why the run
    # ended up where it did, so it belongs in the transcript rather than being quietly discarded.
    def looked_again(step, look, waited)
      { "operation" => "RELOOK", "confidence" => step["confidence"],
        "action" => "#{step["operation"] == "HANDOFF" ? step["action"][/\A[^;]+/] : "Not sure yet"}; " \
                    "waited #{(waited * 1000).round}ms and looked again (#{look})" }
    end

    def floor_for(choice, request)
      base = (request["min_confidence"] || DEFAULT_CONFIDENCE).to_f
      choice.operation == "BLOCKED" ? [base, BLOCKED_FLOOR].max : base
    end

    def weak?(choice, request)
      confidence(choice) < floor_for(choice, request)
    end

    def confidence(choice) = [choice.confidence, choice.target_confidence].compact.min.to_f

    # Settling a churning page and waiting for a control to arrive are different kinds of patience,
    # so they get different ceilings.
    def patience(outcome, soft)
      [SOFT_SETTLE * (2**soft), outcome == :absent ? BLOCKED_CEILING : STEADY_CEILING].min
    end

    # A leg begins the instant the one before it ends, and the action that ended it may have started a
    # navigation. So the first decisions of a leg are looking at the previous page as often as not,
    # and "the control is not here" is exactly what a half-loaded document looks like.
    #
    # Confidence cannot gate this. Looking again at a page whose sidebar still has not arrived makes
    # the model surer of the absence, not less — 43% then 76%, both wrong. What makes a BLOCKED cheap
    # to disbelieve is that the leg has not done anything yet: there is nothing to undo, and nothing
    # to lose but the wait.
    def fresh_leg?(tally) = tally[:done].zero? && tally[:soft].to_i < BLOCKED_RELOOKS

    def unconfirmed_blocked?(choice, request, record, tally)
      return false unless choice.operation == "BLOCKED" && fresh_leg?(tally)

      unsure?(choice, request, record, force: true)
    end

    def unsure?(choice, request, record, force: false)
      return false unless force || weak?(choice, request)

      weakest = confidence(choice)
      reason = if force && !weak?(choice, request)
                 "#{choice.label.inspect} on a leg that has not acted yet (#{(weakest * 100).round}% sure)"
               else
                 "Not sure enough to act (#{(weakest * 100).round}% on #{choice.label.inspect})"
               end
      record.merge!("operation" => "HANDOFF", "confidence" => weakest,
                    "action" => "#{reason}; look at the page and choose")
      true
    end

    # Jev chooses; it never writes. The value comes from the caller, and when the caller has not
    # supplied one the run stops and asks. The agent driving Wrangle is already a language model, so
    # the "small model that types" is whoever is reading this output — no second key, no extra hop.
    def text_for(choice, request)
      return [nil, nil] unless choice.action["kind"] == "fill"

      label = choice.label.downcase
      _, literal = (request["literals"] || {}).find { |key, _| label.include?(key.to_s.downcase) }
      return [literal, nil] if literal

      [nil, "needs text for #{choice.label.inspect}; re-run with --literal #{label.split(/[^a-z]/).first}=VALUE"]
    end

    # Three actions in a row that changed nothing is not progress, whatever the model believes — and
    # neither is clicking the same control three times while the page shuffles underneath. Both are
    # the same failure: the run is circling, and a human or the calling model should look at it.
    def stalled?
      recent = @history.last(3)
      return false unless recent.length == 3

      recent.none? { |entry| entry["page_changed"] || entry["kind"] == "wait" } ||
        (recent.map { |entry| entry["action"] }.uniq.one? && recent.none? { |e| e["kind"] == "wait" })
    end

    def summarise(request, steps, expect)
      if steps.last&.fetch("operation", nil) == "RESTALE"
        steps << { "operation" => "HANDOFF", "confidence" => 0.0,
                   "action" => "The page kept moving faster than a decision could be made; look at " \
                               "it yourself and act by ref" }
      end
      proven = expect ? fresh_text(request).match?(expect) : nil
      { "goal" => request["goal"], "legs" => Array(request["plan"]).length,
        "steps" => steps, "stopped" => steps.last&.fetch("operation", nil),
        "expected" => expect&.source, "proven" => proven }
    end

    def presence(value) = value.nil? || value.to_s.empty? ? nil : value.to_s

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def shutdown
      begin
        @session&.close
      rescue Wrangle::Error
        nil # A poisoned session refuses to close its window. That refusal is the correct outcome.
      end
      FileUtils.rm_f(@socket_path) if @socket_path
    end
  end

  # Talks to a SessionServer over its socket. One request, one reply, one connection.
  class SessionClient
    def initialize(socket_path)
      @socket_path = socket_path
    end

    def running?
      File.socket?(@socket_path) && begin
        call("status")
        true
      rescue Wrangle::Error
        false
      end
    end

    def call(op, **params)
      socket = UNIXSocket.new(@socket_path)
      socket.puts(JSON.generate(params.merge(op: op)))
      reply = socket.gets
      raise BridgeError, "The wrangle session closed without replying" unless reply

      JSON.parse(reply)
    rescue Errno::ENOENT, Errno::ECONNREFUSED
      raise BridgeError, "No wrangle session at #{@socket_path}. Start one with `wrangle open <url>`."
    ensure
      socket&.close
    end
  end
end
