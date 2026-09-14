require "test_helper"

# 「docker ps 通了但输出读不懂」和「机器失联」是两回事，逐主机文案不能共用。
#
# 这个判断此前写在 _host_table.html.erb 里，靠 include?("输出无法解析") 匹配
# 采集器产出的那句散文——两个文件各存一份同样的五个字，谁改了谁那份，另一边
# 会静默退化成「失联」。现在短语只有一个出处（采集器的常量），判断在这里做，
# 视图只读一个布尔值。
class ManagedAppStatusUnparseableTest < ActiveSupport::TestCase
  setup do
    @managed_app = ManagedApp.create!(name: "blog",
                                      config_yaml: file_fixture("simple_deploy.yml").read,
                                      destination: "production")
    @host = @managed_app.cached_app_hosts.first
  end

  test "采集器产出的解析失败错误被认出来" do
    observe(error: Collectors::ContainerCollector.unparseable_output_error(3))

    assert row[:unparseable_output]
  end

  test "普通的失联错误不算解析失败" do
    observe(error: "Net::SSH::ConnectionTimeout")

    refute row[:unparseable_output]
  end

  test "没有错误时不算解析失败" do
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
