require "test_helper"

# 主设计 8.4 的原话：「四个状态色必须在两个主题下【分别】做对比度验证，
# 不能只把亮色主题反转」。
#
# 如果这条只靠某个人某一次算过一遍、然后在文档里写"验过了"，它和纸面承诺
# 没有区别——下一个调色的人不会知道自己把某个状态色调到了 3.9:1，而色觉
# 正常的人在自己的显示器上也未必看得出来。所以这里直接解析样式表里的两套
# 调色板、按 WCAG 公式算，改坏了这条测试会红。
class ColorContrastTest < ActiveSupport::TestCase
  STYLESHEET = Rails.root.join("app/assets/stylesheets/application.css")

  # WCAG 2.1 对正文（<18pt 且非粗体大字）的 AA 要求。状态徽章是 0.85rem，
  # 属于正文档次，不能用 3:1 那档大字标准。
  AA_NORMAL_TEXT = 4.5

  # 每一对都是【实际会同时出现在屏幕上】的前景/背景组合，不是随便两个变量。
  PAIRS = [
    %w[--ink --surface],
    %w[--ink-muted --surface],
    %w[--drift-ink --drift-bg],
    %w[--unhealthy-ink --unhealthy-bg],
    %w[--unreachable-ink --unreachable-bg],
    %w[--ok-ink --ok-bg],
    %w[--unknown-ink --unknown-bg],
    %w[--output-ink --output-bg],

    # 操作层（登录、接入、操作区）的组合。这一层此前没有任何样式，
    # 补齐时引入的颜色同样要过 AA，否则"补齐视觉"会变成"引入一批没人验过的颜色"。
    %w[--action --surface],          # 正文里的链接
    %w[--action-ink --action-fill],  # 主要动作按钮上的字（填充色与链接色是两个值）
    %w[--btn-ink --btn-bg],          # 普通动作按钮上的字
    %w[--danger-ink --btn-bg],       # 危险动作按钮上的字（白底红字，不填充）
    %w[--field-ink --field-bg],      # 输入框里的字
    %w[--ink --card-bg],             # 认证卡片上的正文
    %w[--ink --card-raised],         # primary 区块面板上的正文
    %w[--ink-muted --card-raised]    # primary 区块面板上的次要文本
  ].freeze

  # WCAG 2.1 的 1.4.11（非文本对比）。站标是图形而不是文字，受的是这一档，
  # 不是上面那档 4.5:1——把图形按文本标准去卡会在深色下逼出一个惨白的标记。
  # 但它也【不能没有标准】：标记在深色标签栏或深色顶栏里糊成一团，跟一段
  # 读不出的文字是同一种失败。
  AA_GRAPHIC = 3.0

  # 站标内部实际相邻的两对：白牌压在墨底上，金绳压在墨底上。
  GRAPHIC_PAIRS = [
    %w[--mark-on --mark-tile],
    %w[--mark-gold --mark-tile]
  ].freeze

  test "浅色主题下每一对前景背景都达到 WCAG AA" do
    assert_all_pairs_pass palette(:light), "浅色"
  end

  test "深色主题下每一对前景背景都达到 WCAG AA" do
    assert_all_pairs_pass palette(:dark), "深色"
  end

  test "浅色主题下站标的图形元素达到 WCAG 非文本对比" do
    assert_all_graphic_pairs_pass palette(:light), "浅色"
  end

  test "深色主题下站标的图形元素达到 WCAG 非文本对比" do
    assert_all_graphic_pairs_pass palette(:dark), "深色"
  end

  test "深色主题不是把浅色主题原样照搬" do
    light = palette(:light)
    dark  = palette(:dark)

    assert_equal light.keys.sort, dark.keys.sort,
                 "两套调色板必须定义同一组变量，否则深色下会有变量回落到浅色值"
    refute_equal light, dark
  end

  test "与主题无关的 token 不会被深色块重定义" do
    # 文件里三个 :root 块按出现顺序是：浅色调色板、深色 @media、与主题无关的
    # token（排版/形状）。第三块【排在深色块之后】，所以同名 token 一旦两边都
    # 写，后出现的第三块会把深色值覆盖掉——深色模式静默失效，没有任何测试会红。
    # 判据很简单：第三块里的 token 名，不许出现在深色块里。
    blocks = STYLESHEET.read.scan(/:root\s*\{(.*?)\}/m).flatten
    assert_equal 3, blocks.length, "样式表里应该正好有三个 :root 块"

    dark_block, neutral_block = blocks[1], blocks[2]

    dark_names    = dark_block.scan(/(--[\w-]+):/).flatten
    neutral_names = neutral_block.scan(/(--[\w-]+):/).flatten
    clobbered     = neutral_names & dark_names

    assert_empty clobbered,
                 "这些 token 同时定义在「与主题无关」的块和深色块里，深色值会被" \
                 "后出现的那块覆盖掉：#{clobbered.join(', ')}。主题相关的 token " \
                 "请放进两个调色板块。"
  end

  private
    # => { "--surface" => "#fafaf8", ... }
    def palette(theme)
      css = STYLESHEET.read
      block = case theme
      when :light then css[/\A.*?:root\s*\{(.*?)\}/m, 1]
      when :dark  then css[/@media\s*\(prefers-color-scheme:\s*dark\).*?:root\s*\{(.*?)\}/m, 1]
      end

      assert block.present?, "样式表里找不到#{theme}主题的 :root 块"
      block.scan(/(--[\w-]+):\s*(#[0-9a-fA-F]{6})/).to_h
    end

    def assert_all_pairs_pass(colors, theme_name)
      PAIRS.each do |fg_var, bg_var|
        fg = colors.fetch(fg_var) { flunk "#{theme_name}主题缺少变量 #{fg_var}" }
        bg = colors.fetch(bg_var) { flunk "#{theme_name}主题缺少变量 #{bg_var}" }
        ratio = contrast_ratio(fg, bg)

        assert_operator ratio, :>=, AA_NORMAL_TEXT,
                        "#{theme_name}主题：#{fg_var}(#{fg}) 配 #{bg_var}(#{bg}) 只有 " \
                        "#{ratio.round(2)}:1，低于 AA 要求的 #{AA_NORMAL_TEXT}:1"
      end
    end

    def assert_all_graphic_pairs_pass(colors, theme_name)
      GRAPHIC_PAIRS.each do |fg_var, bg_var|
        fg = colors.fetch(fg_var) { flunk "#{theme_name}主题缺少变量 #{fg_var}" }
        bg = colors.fetch(bg_var) { flunk "#{theme_name}主题缺少变量 #{bg_var}" }
        ratio = contrast_ratio(fg, bg)

        assert_operator ratio, :>=, AA_GRAPHIC,
                        "#{theme_name}主题：站标的 #{fg_var}(#{fg}) 压在 #{bg_var}(#{bg}) 上只有 " \
                        "#{ratio.round(2)}:1，低于非文本对比要求的 #{AA_GRAPHIC}:1"
      end
    end

    def contrast_ratio(fg, bg)
      lighter, darker = [ relative_luminance(fg), relative_luminance(bg) ].minmax.reverse
      (lighter + 0.05) / (darker + 0.05)
    end

    # WCAG 2.1 的相对亮度定义
    def relative_luminance(hex)
      r, g, b = hex.delete("#").scan(/../).map { |part| linearize(part.to_i(16) / 255.0) }
      (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
    end

    def linearize(channel)
      channel <= 0.03928 ? channel / 12.92 : (((channel + 0.055) / 1.055)**2.4)
    end
end
