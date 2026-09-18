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
    # code 要跟着父级字号缩放（表格里的等宽字比该行正文小一档），
    # 换成 rem 会让它在小字环境里反而变大。这是永久例外。
    "font-size: 0.875em"
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

  test "三级区块都定义了，且 quiet 级确实做了减法" do
    css = STYLESHEET.read

    %w[.tier-primary .tier-standard .tier-quiet .rule-gold].each do |klass|
      assert_match(/^#{Regexp.escape(klass)}\b/, css,
                   "样式表里找不到 #{klass}——三级区块是第 2、3 批的前提")
    end

    quiet = css[/\.tier-quiet \.panel\s*\{(.*?)\}/m, 1]
    assert quiet.present?, "找不到 .tier-quiet .panel 的定义"

    # quiet 是这套分级里唯一做减法的一档：它必须把卡片的三样外观都卸掉，
    # 否则它就只是一个「字小一点的 standard」，腾不出注意力。
    assert_match(/box-shadow:\s*none/, quiet, "quiet 级必须去掉阴影")
    assert_match(/border:\s*none/, quiet, "quiet 级必须去掉边框")
    assert_match(/background:\s*transparent/, quiet, "quiet 级必须去掉背景")

    primary = css[/\.tier-primary \.panel\s*\{(.*?)\}/m, 1]
    assert_match(/var\(--lift-raised\)/, primary, "primary 级要用 --lift-raised")
  end

  private
    # => ["font-size: 0.9375rem", "border-radius: 3px", ...]
    def offenders
      css = STYLESHEET.read.gsub(%r{/\*.*?\*/}m, "")

      # 剥掉【全部】 :root 块，不是只剥第一个：这张样式表有三个——浅色调色板
      # (8-73)、深色调色板 (75-140)、排版与形状 token (144-155)。token 的定义
      # 本身当然是字面值，不该被算作违规。
      css = css.gsub(/:root\s*\{.*?\}/m, "")

      css.scan(/(#{Regexp.union(TOKENIZED_PROPERTIES)})\s*:\s*([^;}]+)/)
         .reject { |_property, value| tokenized?(value.strip) }
         .map { |property, value| "#{property}: #{value.strip}" }
         .uniq
         .sort
    end

    # 整个值都必须由 var(--…) 与分隔符构成。只看开头是不够的——
    # `box-shadow: var(--lift), 0 0 0 2px red` 是 var 打头却混着字面量，
    # 旧写法会放行它，等于守卫在最容易出错的那种写法上失效。
    #
    # "0" 与 "none" 是【卸掉】一个样式，不是设定一个尺寸——quiet 级要把卡片的
    # 圆角和阴影归零，那不该被当成「写死了字面量」。
    def tokenized?(value)
      return true if %w[inherit initial unset none 0].include?(value)

      value.gsub(/var\(--[\w-]+\)/, "").gsub(/[\s,]/, "").empty?
    end
end
