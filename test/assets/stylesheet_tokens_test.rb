require "test_helper"

# 设计 14 §10 的守卫。
#
# 这套视觉语言的失效方式是可预见的：下一个功能照着旁边的写法，又写死一个
# font-size、又抄一段 box-shadow，尺度和分级就这样一行一行长回去。人在 review
# 里数不出这个——它每次只多一行，每一行看起来都无害。
#
# 所以让测试来数。规则很粗暴：两个 :root 定义块【之外】，font-size /
# box-shadow / border-radius 三个属性的值只能是 var(--…)。
#
# 白名单是进度条：它从 15 项开始（第 1 批播种时样式表的实际状况），每个
# 后续任务删掉自己清理掉的那几条。清空之后剩下的唯一一条是 code 的 em，
# 那是永久例外，理由写在它旁边。
class StylesheetTokensTest < ActiveSupport::TestCase
  STYLESHEET = Rails.root.join("app/assets/stylesheets/application.css")

  TOKENIZED_PROPERTIES = %w[font-size box-shadow border-radius].freeze

  # 每加一行都必须在这里写清「它为什么不能是 token」。
  ALLOWED = [
    "border-radius: 3px",
    "border-radius: 50%",
    "border-radius: 8px",
    "font-size: 0.75rem",
    "font-size: 0.8125rem",
    "font-size: 0.875em",
    "font-size: 0.875rem",
    "font-size: 0.9375rem",
    "font-size: 1.0625rem",
    "font-size: 1.25rem",
    "font-size: 1.375rem",
    "font-size: 1.5rem",
    "font-size: 16px",
    "font-size: 1rem",
    "font-size: 2rem"
  ].freeze

  test "白名单之外的声明都用了 token" do
    extra = offenders - ALLOWED

    assert_empty extra,
                 "这些声明写死了字面量，请改用 var(--…)：\n#{extra.join("\n")}"
  end

  test "白名单里没有已经清理干净的条目" do
    stale = ALLOWED - offenders

    assert_empty stale,
                 "这些字面量已经不在样式表里了，请从 ALLOWED 里删掉：\n#{stale.join("\n")}"
  end

  private
    # => ["font-size: 0.9375rem", "border-radius: 3px", ...]
    def offenders
      css = STYLESHEET.read.gsub(%r{/\*.*?\*/}m, "")
      css = css.sub(/:root\s*\{.*?\}/m, "")
      css = css.sub(/@media\s*\(prefers-color-scheme:\s*dark\).*?:root\s*\{.*?\}/m, "")

      css.scan(/(#{Regexp.union(TOKENIZED_PROPERTIES)})\s*:\s*([^;}]+)/)
         .reject { |_property, value| var_or_keyword?(value.strip) }
         .map { |property, value| "#{property}: #{value.strip}" }
         .uniq
         .sort
    end

    # "0" 与 "none" 是【卸掉】一个样式，不是设定一个尺寸——quiet 级要把
    # 卡片的圆角和阴影归零，那不该被当成「写死了字面量」。
    def var_or_keyword?(value)
      value.start_with?("var(") || %w[inherit initial unset none 0].include?(value)
    end
end
