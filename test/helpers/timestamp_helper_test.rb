require "test_helper"

class TimestampHelperTest < ActionView::TestCase
  include ApplicationHelper

  test "a full moment uses one format and keeps the exact instant on hover" do
    time = Time.utc(2026, 9, 22, 2, 45, 2)

    html = timestamp(time)

    assert_includes html, ">2026-09-22 02:45</time>"
    assert_includes html, %(title="#{time.iso8601}")
    assert_includes html, %(datetime="#{time.iso8601}")
  end

  test "relative times in Chinese space the number from its unit, like the rest of the UI" do
    I18n.with_locale(:"zh-CN") do
      assert_equal "22 天", time_ago_in_words(22.days.ago)
      assert_equal "约 1 个月", time_ago_in_words(40.days.ago)
    end
  end
end
