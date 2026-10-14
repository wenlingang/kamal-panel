require "test_helper"

class DurationHelperTest < ActionView::TestCase
  include ApplicationHelper

  test "short runs stay in milliseconds, longer ones read in seconds and minutes" do
    I18n.with_locale(:"zh-CN") do
      assert_equal "380 毫秒", duration_text(380)
      assert_equal "3.0 秒", duration_text(3014)
      assert_equal "59.9 秒", duration_text(59_940)
      assert_equal "1 分 5 秒", duration_text(65_000)
    end

    I18n.with_locale(:en) do
      assert_equal "380 ms", duration_text(380)
      assert_equal "3.0 s", duration_text(3014)
      assert_equal "1 min 5 s", duration_text(65_000)
    end
  end

  test "no duration yet renders a dash" do
    assert_equal "—", duration_text(nil)
  end
end
