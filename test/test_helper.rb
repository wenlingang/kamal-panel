ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "test_helpers/session_test_helper"
require "support/fake_host_helper"

module ActiveSupport
  class TestCase
    # 刻意不启用 parallelize。fake host（test/support/fake_host_helper.rb）是
    # 跨测试共享的全局状态：两台容器、一份 docker daemon 各一个。
    # ExecutionLayerTest 的 reset_all! 会把节点上的容器全部清空，
    # 一旦并行 worker 数超过 Rails 的自动并行阈值，多个 worker 会同时
    # 清空/写入同一批容器，产生看起来毫无关联的间歇性失败。
    # 在 fake host 支持按 worker 命名空间隔离之前，请勿重新打开并行。

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end

# 需要真实 SSH 的测试继承这个基类。
# 它保证 fake host 就绪，并在每个测试前清空容器。
class ExecutionLayerTest < ActiveSupport::TestCase
  setup do
    FakeHost.ensure_ready!
    FakeHost.reset_all!
  end
end
