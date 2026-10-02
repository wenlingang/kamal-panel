require "test_helper"

# "docker ps worked but the output can't be understood" and "the machine is unreachable" are two
# different things, and per-host copy can't be shared.
#
# This decision used to live in _host_table.html.erb, matching on include?("输出无法解析") against the
# prose the collector produces -- two files each kept a copy of the same five characters, and
# whoever changed theirs left the other side silently degrading to "unreachable". Now the phrase has
# a single source (the collector's constant), the decision is made here, and the view only reads a
# boolean.
class ManagedAppStatusUnparseableTest < ActiveSupport::TestCase
  setup do
    @managed_app = ManagedApp.create!(name: "blog",
                                      config_yaml: file_fixture("simple_deploy.yml").read,
                                      destination: "production")
    @host = @managed_app.cached_app_hosts.first
  end

  test "recognizes the parse-failure error produced by the collector" do
    observe(error: Collectors::ContainerCollector.unparseable_output_error(3))

    assert row[:unparseable_output]
  end

  test "an ordinary unreachable error is not a parse failure" do
    observe(error: "Net::SSH::ConnectionTimeout")

    refute row[:unparseable_output]
  end

  test "no error is not a parse failure" do
    observe(error: nil, reachable: true)

    refute row[:unparseable_output]
  end

  private
    def observe(error:, reachable: false)
      Observation.create!(managed_app: @managed_app, host: @host, reachable: reachable,
                          error: error, observed_at: Time.current)
    end

    def row
      ManagedAppStatus.new(@managed_app).last_known_rows.find { |r| r[:host] == @host }
    end
end
