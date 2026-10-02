require "test_helper"

# Verbatim from main design §8.4: "The four status colors must have their contrast
# verified under both themes [separately]; it is not enough to just invert the light theme."
#
# If this relied on one person computing it once and writing "verified" in a doc, it
# would be no different from a paper promise: the next person to tune the palette won't
# know they've pushed a status color down to 3.9:1, and people with normal color vision
# won't necessarily notice on their own monitor. So we parse both palettes in the
# stylesheet directly and compute with the WCAG formula; break it and this test goes red.
class ColorContrastTest < ActiveSupport::TestCase
  STYLESHEET = Rails.root.join("app/assets/stylesheets/application.css")

  # WCAG 2.1 AA requirement for body text (<18pt and not bold large text). The status
  # badge is 0.85rem, which is body-text territory, so the 3:1 large-text bar does not apply.
  AA_NORMAL_TEXT = 4.5

  # Every pair is a foreground/background combination that [actually appears on screen
  # together], not two arbitrary variables.
  PAIRS = [
    %w[--ink --surface],
    %w[--ink-muted --surface],
    %w[--drift-ink --drift-bg],
    %w[--unhealthy-ink --unhealthy-bg],
    %w[--unreachable-ink --unreachable-bg],
    %w[--ok-ink --ok-bg],
    %w[--unknown-ink --unknown-bg],
    %w[--output-ink --output-bg],

    # Combinations for the action layer (login, onboarding, action area). This layer had
    # no styling before; colors introduced while filling it in must pass AA too, otherwise
    # "filling in the visuals" becomes "introducing a batch of colors nobody has verified".
    %w[--action --surface],          # links in body text
    %w[--action-ink --action-fill],  # text on the primary action button (fill and link colors differ)
    %w[--btn-ink --btn-bg],          # text on a regular action button
    %w[--danger-ink --btn-bg],       # text on a danger action button (red on white, no fill)
    %w[--field-ink --field-bg],      # text inside input fields
    %w[--ink --card-bg],             # body text on the auth card
    %w[--ink --card-raised],         # body text on the primary section panel
    %w[--ink-muted --card-raised]    # secondary text on the primary section panel
  ].freeze

  # WCAG 2.1 1.4.11 (non-text contrast). The logo is a graphic, not text, so it falls
  # under this tier rather than the 4.5:1 one above; holding a graphic to the text standard
  # would force a glaringly white mark in dark mode. But it [cannot go without a standard]
  # either: a mark that blurs into a dark tab bar or header is the same failure as
  # unreadable text.
  AA_GRAPHIC = 3.0

  # The two adjacent pairs inside the logo: white plate on ink, gold rope on ink.
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

  # The tests above go through palette(), which only recognizes six-digit hex; tokens
  # written as rgba() (--ring, --shadow-md and the like) fall outside its regex, so
  # forgetting one on either side would not turn anything red. This one compares only
  # the set of variable names.
  test "两套调色板的变量名集合必须相等" do
    assert_equal palette_names(:light), palette_names(:dark),
                 "浅色块和深色块必须定义同一组变量名，否则深色下会有 token 静默" \
                 "沿用浅色值（例如 rgba()/hsl() 写的阴影，不受上一条 palette() 断言保护）"
  end

  test "与主题无关的 token 不会被深色块重定义" do
    # The three :root blocks in the file are, in order: light palette, dark @media,
    # theme-independent tokens (typography/shape). The third block [comes after the dark
    # block], so if a same-named token is written in both, the later third block overrides
    # the dark value: dark mode silently breaks and no test goes red.
    # The criterion is simple: a token name in the third block must not appear in the dark block.
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

    # => ["--action", "--brand", ...]  (any value format; rgba()/hsl() count too)
    def palette_names(theme)
      css = STYLESHEET.read
      block = case theme
      when :light then css[/\A.*?:root\s*\{(.*?)\}/m, 1]
      when :dark  then css[/@media\s*\(prefers-color-scheme:\s*dark\).*?:root\s*\{(.*?)\}/m, 1]
      end

      assert block.present?, "样式表里找不到#{theme}主题的 :root 块"
      block.scan(/(--[\w-]+):/).flatten.sort
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

    # WCAG 2.1 definition of relative luminance
    def relative_luminance(hex)
      r, g, b = hex.delete("#").scan(/../).map { |part| linearize(part.to_i(16) / 255.0) }
      (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
    end

    def linearize(channel)
      channel <= 0.03928 ? channel / 12.92 : (((channel + 0.055) / 1.055)**2.4)
    end
end
