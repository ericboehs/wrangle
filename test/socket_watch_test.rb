# frozen_string_literal: true

require_relative "test_helper"

# A session server that nobody can reach must notice and leave, and when it leaves it must not take
# a successor's socket or pid file with it.
class SocketWatchTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("wrangle-socket-watch")
    @path = File.join(@directory, "s.sock")
    @watch = Wrangle::SocketWatch.new(@path, interval: 0.01)
  end

  def teardown
    @watch.release
    FileUtils.remove_entry(@directory)
  end

  def test_binds_an_owner_only_socket
    assert File.socket?(@path)
    assert_equal 0o600, File.stat(@path).mode & 0o777
  end

  def test_hands_over_a_waiting_client
    UNIXSocket.open(@path) do
      client = @watch.accept
      refute_nil client
      client.close
    end
  end

  def test_gives_up_once_the_socket_file_is_deleted
    File.delete(@path)

    assert_nil @watch.accept
    refute @watch.ours?
  end

  def test_gives_up_once_another_server_is_bound_at_the_path
    File.delete(@path)
    successor = UNIXServer.new(@path)

    assert_nil @watch.accept
  ensure
    successor&.close
  end

  def test_release_removes_its_own_socket_and_pid_file
    File.write("#{@path}.pid", "#{Process.pid}\n")

    @watch.release

    refute_path_exists @path
    refute_path_exists "#{@path}.pid"
  end

  def test_release_leaves_a_successors_socket_and_pid_file_alone
    File.delete(@path)
    successor = UNIXServer.new(@path)
    File.write("#{@path}.pid", "#{Process.pid + 1}\n")

    @watch.release

    assert File.socket?(@path)
    assert_path_exists "#{@path}.pid"
  ensure
    successor&.close
  end

  def test_release_survives_a_pid_file_it_cannot_read
    Dir.mkdir("#{@path}.pid")

    assert_nil @watch.release
    assert_path_exists "#{@path}.pid"
  end
end
