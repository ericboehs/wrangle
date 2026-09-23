# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require "time"

module Wrangle
  # Safe, stdlib-only lifecycle management for disposable Tart acceptance VMs.
  module TartAcceptance
    REPORT_SCHEMA = "wrangle.tart-lifecycle.v1"
    DEFAULT_IMAGE = "ghcr.io/cirruslabs/macos-tahoe-base:latest"
    DEFAULT_BASE = "wrangle-tahoe-base"
    DEFAULT_PROVISIONED = "wrangle-provisioned-base"
    DEFAULT_VM = "wrangle-acceptance"
    DEFAULT_LOG_ROOT = File.expand_path("~/.wrangle/tart")
    NAME = /\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}\z/

    class LifecycleError < StandardError; end

    class Shell
      Result = Data.define(:stdout, :stderr, :success)

      def call(*argv)
        stdout, stderr, status = Open3.capture3(*argv)
        Result.new(stdout:, stderr:, success: status.success?)
      rescue Errno::ENOENT
        Result.new(stdout: "", stderr: "missing executable", success: false)
      end

      def spawn(*argv, log:)
        FileUtils.mkdir_p(File.dirname(log), mode: 0o700)
        File.open(log, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
          Process.spawn(*argv, out: file, err: file, pgroup: true)
        end
      end

      def alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      end
    end

    class Manager
      def initialize(shell: Shell.new, tart: ENV.fetch("TART_BIN", "tart"), log_root: DEFAULT_LOG_ROOT,
                     sleeper: Kernel.method(:sleep), monotonic: nil, wall_clock: nil)
        @shell = shell
        @tart = tart
        @log_root = log_root
        @sleeper = sleeper
        @monotonic = monotonic || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @wall_clock = wall_clock || -> { Time.now.utc }
      end

      def status(name: DEFAULT_VM)
        validate_name!(name)
        vm = find(name)
        report("status", vm ? safe_vm(vm) : { "name" => name, "state" => "absent", "running" => false })
      end

      def bootstrap(source: DEFAULT_IMAGE, name: DEFAULT_BASE, cpu: 8, memory: 16_384,
                    display: "1440x900")
        validate_name!(name)
        raise LifecycleError, "Tart image source is required" if source.to_s.empty?
        raise LifecycleError, "VM #{name.inspect} already exists" if find(name)

        cpu = positive_integer(cpu, "CPU")
        memory = positive_integer(memory, "memory")
        raise LifecycleError, "Display size is required" if display.to_s.empty?

        clone_with_settings(source, name, "--cpu", cpu.to_s, "--memory", memory.to_s,
                            "--display", display.to_s, "--display-refit")
        report("bootstrap", safe_vm(find!(name)))
      end

      def clone(source: DEFAULT_PROVISIONED, name: DEFAULT_VM)
        validate_name!(source)
        validate_name!(name)
        raise LifecycleError, "Source VM #{source.inspect} is not available" unless find(source)
        raise LifecycleError, "VM #{name.inspect} already exists" if find(name)

        clone_with_settings(source, name, "--random-mac", "--random-serial")
        report("clone", safe_vm(find!(name)).merge("source_vm" => source))
      end

      def snapshot(source: DEFAULT_VM, target: DEFAULT_PROVISIONED)
        validate_name!(source)
        validate_name!(target)
        source_vm = find!(source)
        raise LifecycleError, "Stop #{source.inspect} before preserving it" if source_vm["Running"] == true
        raise LifecycleError, "VM #{target.inspect} already exists" if find(target)

        clone_with_settings(source, target, "--random-mac", "--random-serial")
        report("snapshot", safe_vm(find!(target)).merge("source_vm" => source))
      end

      def start(name: DEFAULT_VM, headless: false, timeout: 60)
        validate_name!(name)
        vm = find!(name)
        return report("start", safe_vm(vm).merge("changed" => false)) if vm["Running"] == true

        log = File.join(@log_root, "#{name}.log")
        argv = [@tart, "run"]
        argv << "--no-graphics" if headless
        argv << name
        pid = begin
          @shell.spawn(*argv, log:)
        rescue SystemCallError
          raise LifecycleError, "Could not start Tart"
        end
        wait_for(name, timeout:, desired: true, pid:)
        report("start", safe_vm(find!(name)).merge("changed" => true, "headless" => headless,
                                                   "log" => log))
      end

      def stop(name: DEFAULT_VM, timeout: 60)
        validate_name!(name)
        vm = find!(name)
        return report("stop", safe_vm(vm).merge("changed" => false)) unless vm["Running"] == true

        seconds = positive_integer(timeout, "timeout")
        run!("stop", name, "--timeout", seconds.to_s)
        wait_for(name, timeout: seconds + 5, desired: false)
        report("stop", safe_vm(find!(name)).merge("changed" => true))
      end

      def reset(source: DEFAULT_PROVISIONED, name: DEFAULT_VM, replace: false, timeout: 60)
        validate_name!(source)
        validate_name!(name)
        raise LifecycleError, "Reset requires --replace" unless replace
        if [DEFAULT_BASE, DEFAULT_PROVISIONED, source].include?(name)
          raise LifecycleError, "Refusing to replace a protected base VM"
        end
        raise LifecycleError, "Source VM #{source.inspect} is not available" unless find(source)

        stop(name:, timeout:) if find(name)&.fetch("Running", false)
        run!("delete", name) if find(name)
        clone(source:, name:).merge("command" => "reset")
      end

      private

      def inventory
        result = @shell.call(@tart, "list", "--format", "json")
        raise LifecycleError, "Could not list Tart VMs" unless result.success

        parsed = JSON.parse(result.stdout)
        raise LifecycleError, "Tart returned an invalid inventory" unless parsed.is_a?(Array)

        parsed
      rescue JSON::ParserError
        raise LifecycleError, "Tart returned invalid JSON"
      end

      def find(name) = inventory.find { |vm| vm["Name"] == name }

      def find!(name)
        find(name) || raise(LifecycleError, "VM #{name.inspect} is not available")
      end

      def run!(*arguments)
        result = @shell.call(@tart, *arguments)
        return result.stdout if result.success

        raise LifecycleError, "Tart #{arguments.first} failed"
      end

      def clone_with_settings(source, name, *settings)
        created = false
        run!("clone", source, name)
        created = true
        run!("set", name, *settings)
      rescue LifecycleError => e
        if created
          cleanup = @shell.call(@tart, "delete", name)
          raise LifecycleError, "Tart clone cleanup failed" unless cleanup.success
        end
        raise e
      end

      def wait_for(name, timeout:, desired:, pid: nil)
        deadline = @monotonic.call + positive_integer(timeout, "timeout")
        loop do
          vm = find(name)
          return if vm && vm["Running"] == desired
          raise LifecycleError, "Tart run exited before #{name.inspect} started" if pid && !@shell.alive?(pid)
          raise LifecycleError, "Timed out waiting for #{name.inspect}" if @monotonic.call >= deadline

          @sleeper.call(0.25)
        end
      end

      def validate_name!(name)
        raise LifecycleError, "Invalid Tart VM name" unless name.is_a?(String) && name.match?(NAME)
      end

      def positive_integer(value, label)
        parsed = Integer(value)
        raise LifecycleError, "#{label} must be positive" unless parsed.positive?

        parsed
      rescue ArgumentError, TypeError
        raise LifecycleError, "#{label} must be positive"
      end

      def safe_vm(record)
        {
          "name" => record["Name"].to_s,
          "state" => record["State"].to_s,
          "running" => record["Running"] == true,
          "source" => record["Source"].to_s,
          "disk_gb" => record["Disk"].to_i,
          "size_gb" => record["Size"].to_i
        }
      end

      def report(command, vm_record)
        { "schema" => REPORT_SCHEMA, "at" => @wall_clock.call.iso8601, "command" => command, "vm" => vm_record }
      end
    end

    class CLI
      def self.run(argv, out: $stdout, err: $stderr, manager: Manager.new)
        command = argv.shift unless %w[-h --help].include?(argv.first)
        options = parse(argv, out)
        return 0 if options == :help
        raise LifecycleError, "Choose a lifecycle command" if command.to_s.empty?
        raise LifecycleError, "Unexpected arguments: #{argv.join(" ")}" unless argv.empty?

        report = dispatch(manager, command, options)
        out.puts JSON.pretty_generate(report)
        0
      rescue LifecycleError, OptionParser::ParseError => e
        err.puts "Tart acceptance: #{e.message}"
        2
      rescue Interrupt
        err.puts "Tart acceptance: interrupted"
        130
      end

      # OptionParser necessarily writes every supported option into a shared result hash.
      # rubocop:disable Metrics/AbcSize
      def self.parse(argv, out)
        options = {
          name: DEFAULT_VM, source: nil, target: DEFAULT_PROVISIONED,
          timeout: 60, cpu: 8, memory: 16_384, display: "1440x900", headless: false, replace: false
        }
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: tart_vm COMMAND [options]"
          opts.separator "Commands: status, bootstrap, clone, snapshot, start, stop, reset"
          opts.on("--name NAME", "working VM name") { |value| options[:name] = value }
          opts.on("--source NAME", "source VM or OCI image") { |value| options[:source] = value }
          opts.on("--target NAME", "snapshot target VM") { |value| options[:target] = value }
          opts.on("--timeout SECONDS", Integer) { |value| options[:timeout] = value }
          opts.on("--cpu COUNT", Integer) { |value| options[:cpu] = value }
          opts.on("--memory MIB", Integer) { |value| options[:memory] = value }
          opts.on("--display SIZE") { |value| options[:display] = value }
          opts.on("--headless", "start without a GUI") { options[:headless] = true }
          opts.on("--replace", "explicitly authorize replacement for reset") { options[:replace] = true }
          opts.on("-h", "--help") do
            out.puts opts
            return :help
          end
        end
        parser.parse!(argv)
        options
      end
      private_class_method :parse
      # rubocop:enable Metrics/AbcSize

      # Dispatch keeps CLI defaults and keyword mapping visible in one bounded place.
      # rubocop:disable Metrics/AbcSize
      def self.dispatch(manager, command, options)
        case command
        when "status" then manager.status(name: options[:name])
        when "bootstrap"
          manager.bootstrap(source: options[:source] || DEFAULT_IMAGE,
                            name: options[:name] == DEFAULT_VM ? DEFAULT_BASE : options[:name],
                            cpu: options[:cpu], memory: options[:memory], display: options[:display])
        when "clone" then manager.clone(source: options[:source] || DEFAULT_PROVISIONED, name: options[:name])
        when "snapshot" then manager.snapshot(source: options[:name], target: options[:target])
        when "start" then manager.start(name: options[:name], headless: options[:headless], timeout: options[:timeout])
        when "stop" then manager.stop(name: options[:name], timeout: options[:timeout])
        when "reset"
          manager.reset(source: options[:source] || DEFAULT_PROVISIONED, name: options[:name],
                        replace: options[:replace],
                        timeout: options[:timeout])
        else raise LifecycleError, "Unknown lifecycle command #{command.inspect}"
        end
      end
      private_class_method :dispatch
      # rubocop:enable Metrics/AbcSize
    end
  end
end
