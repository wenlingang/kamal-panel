ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "test_helpers/session_test_helper"
require "support/fake_host_helper"
require "support/http_stub"
require "support/tls_test_server"

module ActiveSupport
  class TestCase
    # Deliberately not enabling parallelize. The fake host (test/support/fake_host_helper.rb)
    # is global state shared across tests: two containers, one docker daemon.
    # ExecutionLayerTest's reset_all! wipes all containers on the nodes, so once the number
    # of parallel workers exceeds Rails' automatic parallelization threshold, several
    # workers would clear/write the same set of containers at once, producing intermittent
    # failures that look entirely unrelated.
    # Do not turn parallelism back on until the fake host supports per-worker namespace isolation.

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Runs the block with these collection settings (deep-merged over config/collection.yml).
    def with_collection_settings(overrides)
      previous = CollectionSettings.current
      CollectionSettings.current = CollectionSettings.new(CollectionSettings.defaults.deep_merge(overrides.deep_stringify_keys))
      yield
    ensure
      CollectionSettings.current = previous
    end
  end
end

# Tests that need a real SSH connection inherit from this base class.
# It guarantees the fake host is ready and empties the containers before each test.
class ExecutionLayerTest < ActiveSupport::TestCase
  setup do
    FakeHost.ensure_ready!
    FakeHost.reset_all!
  end
end
