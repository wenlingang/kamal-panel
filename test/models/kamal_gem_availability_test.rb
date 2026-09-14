require "test_helper"

class KamalGemAvailabilityTest < ActiveSupport::TestCase
  test "kamal gem 可以在应用进程内加载" do
    require "kamal"
    assert defined?(Kamal::Configuration)
  end

  # 兼容矩阵（CI 里设 KAMAL_VERSION，见 .github/workflows/ci.yml）是【故意】跑在
  # 基线以下的旧版本上的，为的是发现真实的行为不兼容。这条下限断言在那种情形下
  # 必然失败，且失败不携带任何新信息——留着只会在矩阵结果里制造一条恒定的假信号，
  # 把真正值得看的失败淹掉。所以只在没有显式指定版本时才断言下限。
  test "kamal 版本不低于 2.12（本项目的验证基线）" do
    skip "兼容矩阵在跑 KAMAL_VERSION=#{ENV['KAMAL_VERSION']}，本条只约束默认版本" if ENV["KAMAL_VERSION"].present?

    require "kamal"
    assert_operator Gem::Version.new(Kamal::VERSION), :>=, Gem::Version.new("2.12.0"),
      "本项目依赖 v2.12.0 中确认的 Kamal 内部行为，见 spec 第 4 节"
  end
end
