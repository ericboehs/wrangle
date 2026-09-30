# frozen_string_literal: true

require_relative "test_helper"

class ScopeRegistryTest < Minitest::Test
  Scope = Struct.new(:id, :root, :pid, :process_instance)

  def setup
    @directory = Dir.mktmpdir("wrangle-scopes")
    @registry = Wrangle::ScopeRegistry.new(root: @directory)
    @scope = Scope.new("scope-1", "w-1", 42, "proc-42")
  end

  def teardown
    FileUtils.remove_entry(@directory) if File.directory?(@directory)
  end

  def test_exclusive_lease_blocks_an_overlapping_live_session
    lease = @registry.acquire(@scope)

    assert_equal "exclusive", lease.mode
    assert_equal 0o600, File.stat(lease.path).mode & 0o777
    assert_raises(Wrangle::ScopeBusy) { @registry.acquire(@scope) }

    @registry.release(lease)
    refute File.exist?(lease.path)
  end

  def test_cooperative_mode_does_not_claim_exclusive_ownership
    lease = @registry.acquire(@scope, mode: "cooperative")

    assert_equal "cooperative", lease.mode
    assert_nil lease.path
    @registry.release(lease)
    @registry.release(nil)
    assert_empty Dir.children(@directory)
  end

  def test_dead_owner_is_reclaimed_without_deleting_the_new_lease
    old = @registry.acquire(@scope)
    payload = JSON.parse(File.read(old.path)).merge("pid" => 99_999_999)
    File.write(old.path, JSON.generate(payload))

    replacement = @registry.acquire(@scope)
    refute_equal old.token, replacement.token
    @registry.release(old)
    assert File.exist?(replacement.path)
    @registry.release(replacement)
    refute File.exist?(replacement.path)
  end

  def test_invalid_dead_owner_metadata_is_reclaimed
    old = @registry.acquire(@scope)
    payload = JSON.parse(File.read(old.path)).merge("pid" => "not-a-pid")
    File.write(old.path, JSON.generate(payload))

    replacement = @registry.acquire(@scope)
    refute_equal old.token, replacement.token
    @registry.release(replacement)
  end

  def test_durable_dispatch_marker_blocks_reentry_until_a_known_receipt_clears_it
    dispatch = @registry.begin_dispatch(
      @scope, proposal_id: "proposal-1", revision: "revision-1", operation: "PRESS"
    )
    payload = JSON.parse(File.read(dispatch.path))

    assert_equal 0o600, File.stat(dispatch.path).mode & 0o777
    assert_equal "PRESS", payload["operation"]
    refute payload.key?("text")
    error = assert_raises(Wrangle::DeliveryUnknown) { @registry.acquire(@scope) }
    assert_match(/may have been delivered/, error.message)

    @registry.finish_dispatch(dispatch)
    refute File.exist?(dispatch.path)
    lease = @registry.acquire(@scope)
    @registry.release(lease)
  end

  def test_dispatch_marker_is_never_reclaimed_from_a_dead_owner_or_bad_metadata
    dispatch = @registry.begin_dispatch(
      @scope, proposal_id: "proposal-1", revision: "revision-1", operation: "PRESS"
    )
    payload = JSON.parse(File.read(dispatch.path)).merge("pid" => 99_999_999)
    File.write(dispatch.path, JSON.generate(payload))

    assert_raises(Wrangle::DeliveryUnknown) { @registry.acquire(@scope, mode: "cooperative") }

    File.write(dispatch.path, "not json")
    assert_raises(Wrangle::DeliveryUnknown) { @registry.acquire(@scope) }
  end

  def test_dispatch_marker_requires_its_original_token_and_valid_file_to_clear
    assert_nil @registry.finish_dispatch(nil)
    dispatch = @registry.begin_dispatch(
      @scope, proposal_id: "proposal-1", revision: "revision-1", operation: "PRESS"
    )
    wrong = Wrangle::ScopeRegistry::Dispatch.new(path: dispatch.path, token: "wrong")

    assert_raises(Wrangle::DeliveryUnknown) { @registry.finish_dispatch(wrong) }
    assert File.exist?(dispatch.path)

    File.write(dispatch.path, "not json")
    assert_raises(Wrangle::DeliveryUnknown) { @registry.finish_dispatch(dispatch) }
  end

  def test_dispatch_symlink_fails_closed
    dispatch = @registry.begin_dispatch(
      @scope, proposal_id: "proposal-1", revision: "revision-1", operation: "PRESS"
    )
    File.unlink(dispatch.path)
    File.symlink(File.join(@directory, "missing"), dispatch.path)

    assert_raises(Wrangle::DeliveryUnknown) { @registry.acquire(@scope) }
    assert_raises(Wrangle::DeliveryUnknown) { @registry.finish_dispatch(dispatch) }
  end

  def test_unreadable_or_non_regular_lease_fails_closed
    lease = @registry.acquire(@scope)
    File.write(lease.path, "not json")
    error = assert_raises(Wrangle::ScopeBusy) { @registry.acquire(@scope) }
    assert_match(/unreadable/, error.message)

    File.unlink(lease.path)
    Dir.mkdir(lease.path)
    assert_raises(Wrangle::ScopeBusy) { @registry.acquire(@scope) }
  end

  def test_validates_mode_and_hardens_registry_directory
    assert_equal 0o700, File.stat(@directory).mode & 0o777
    assert_raises(ArgumentError) { @registry.acquire(@scope, mode: "wishful") }
  end
end
