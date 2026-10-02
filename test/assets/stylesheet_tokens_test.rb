require "test_helper"

# 这套视觉语言的失效方式是可预见的：下一个功能照着旁边的写法，又写死一个
# font-size、又抄一段 px，尺度就这样一行一行长回去。每次只多一行，人在
# review 里数不出来，所以让测试来数。
#
# 白名单里只该剩永久例外。往里加一行，必须在旁边写清它为什么不能是 token。
class StylesheetTokensTest < ActiveSupport::TestCase
  # 字面量守卫（offenders）扫全部样式表：propshaft 下任何人都能再加一个
  # .css 文件，只盯 application.css 会对新文件完全不设防。
  STYLESHEETS = Dir[Rails.root.join("app/assets/stylesheets/*.css")].sort.map { |path| Pathname.new(path) }.freeze

  # 排版尺度测试（third_root_block）只看这一个文件：它是唯一定义 token 的
  # 文件，token 的定义天然是字面量，不该被自己的守卫扫到。
  STYLESHEET = Rails.root.join("app/assets/stylesheets/application.css")

  TOKENIZED_PROPERTIES = %w[font-size box-shadow border-radius].freeze

  # 每加一行都必须在这里写清「它为什么不能是 token」。
  ALLOWED = [
    # code 要跟着父级字号缩放（表格里的等宽字比该行正文小一档），
    # 换成 rem 会让它在小字环境里反而变大。这是永久例外。
    "font-size: 0.875em"
  ].freeze

  # :root 之外允许出现的 px，四类（spec §5 修订后的表）：
  #   1. 描边宽度——边框是分隔符不是内容，字号变大不该让分隔线变粗
  #   2. 媒体查询断点——断点量的是设备，不是内容尺度（由 px_offenders_in 整段剔除）
  #   3. 站标几何——必须匹配那张 24 画布
  #   4. .visually-hidden 的裁剪——是一个隐藏技巧的固定配方，不是可见尺寸
  # 往这里加一行之前，先确认它属于上面四类中的哪一类，并在行尾注明。
  PX_ALLOWED = [
    "border: 1px solid transparent",              # 1
    "border: 1px solid var(--btn-rule)",          # 1
    "border: 1px solid var(--drift-rule)",        # 1
    "border: 1px solid var(--field-rule)",        # 1
    "border: 1px solid var(--output-rule)",       # 1
    "border: 1px solid var(--rule)",              # 1
    "border-bottom: 1px solid var(--rule)",       # 1
    "border-top: 1px solid var(--rule)",          # 1
    "outline: 2px solid var(--field-focus)",      # 1
    "outline: 2px solid transparent",             # 1 高对比度模式的兜底描边
    "outline-offset: 2px",                        # 1
    "height: 1px",                                # 4 .visually-hidden
    "width: 1px",                                 # 4 .visually-hidden
    "margin: -1px",                               # 4 .visually-hidden
    "transform-origin: 12px 16.6px",              # 3 站标
    "transform: translateY(-3.4px)"               # 3 站标
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


  test ":root 之外不出现 px 字面量" do
    extra = px_offenders - PX_ALLOWED

    assert_empty extra,
                 "这些声明在 :root 之外写死了 px（spec §5）。px 不跟随 rem 缩放轴——用户调大字号时它们不动，层级在缩放后塌掉。改用 rem 或 token；确属四类例外之一的，加进 PX_ALLOWED 并注明类别：\n#{extra.join("\n")}"
  end

  test "px 白名单里没有已经清理干净的条目" do
    stale = PX_ALLOWED - px_offenders

    assert_empty stale,
                 "这些 px 已经不在样式表里了，请从 PX_ALLOWED 里删掉：\n#{stale.join("\n")}"
  end

  private
    # => ["font-size: 0.9375rem", "border-radius: 3px", ...]
    def offenders
      STYLESHEETS.flat_map { |path| offenders_in(path) }.uniq.sort
    end

    def offenders_in(path)
      css = path.read.gsub(%r{/\*.*?\*/}m, "")

      # 剥掉【全部】 :root 块：这张样式表里有浅色调色板、深色调色板（在
      # @media 里）、排版与形状 token 三个 :root 块，token 的定义本身当然
      # 是字面值，不该被算作违规。
      css = css.gsub(/:root\s*\{.*?\}/m, "")

      css.scan(/(#{Regexp.union(TOKENIZED_PROPERTIES)})\s*:\s*([^;}]+)/)
         .reject { |_property, value| tokenized?(value.strip) }
         .map { |property, value| "#{property}: #{value.strip}" }
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

    def px_offenders
      STYLESHEETS.flat_map { |path| px_offenders_in(path) }.uniq.sort
    end

    def px_offenders_in(path)
      css = path.read.gsub(%r{/\*.*?\*/}m, "")

      css = css.gsub(/:root\s*\{.*?\}/m, "")

      # 媒体查询的条件部分不算——断点量的是设备，不是内容尺度
      css = css.gsub(/@media[^{]*\{/, "{")

      css.scan(/([\w-]+)\s*:\s*([^;{}]*\d+(?:\.\d+)?px[^;{}]*)/)
         .map { |property, value| "#{property}: #{value.strip}" }
    end

  # 文件里第三个 :root 块：与主题无关的排版/形状 token（第一个是浅色调色板，
  # 第二个是深色 @media 里那个）。
end
