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
    # Body text and secondary text on every surface they sit on
    %w[--ink --panel],
    %w[--ink --canvas],
    %w[--ink-muted --panel],
    %w[--ink-muted --canvas],
    %w[--ink-muted --panel-sunken],   # table headers
    %w[--ink --panel-hover],          # a hovered table row

    # Links and actions
    %w[--signal --panel],             # links in body text
    %w[--signal --canvas],            # links outside panels (breadcrumbs, filter clear)
    %w[--signal-ink --signal-fill],   # text on the primary button
    %w[--signal-ink --signal-fill-hover],
    %w[--signal-tint-ink --signal-tint], # the current view toggle, the "running" status bar
    %w[--btn-ink --btn-bg],
    %w[--btn-ink --btn-hover],
    %w[--danger-ink --btn-bg],        # a danger button: red text, no fill
    %w[--danger-ink --danger-tint],   # a hovered danger button
    %w[--field-ink --field-bg],

    # Status badges, banners, the run status bar
    %w[--ok-ink --ok-bg],
    %w[--drift-ink --drift-bg],
    %w[--unhealthy-ink --unhealthy-bg],
    %w[--unreachable-ink --unreachable-bg],
    %w[--unknown-ink --unknown-bg],
    # The summary strip colours a non-zero count with its status ink, on the panel
    %w[--ok-ink --panel],
    %w[--drift-ink --panel],
    %w[--unhealthy-ink --panel],
    %w[--unreachable-ink --panel],

    # Terminal output
    %w[--output-ink --output-bg],
    %w[--output-muted --output-bg],
    # Log viewer: level colours, the keyword highlight, host tags
    %w[--log-error --output-bg],
    %w[--log-warn --output-bg],
    %w[--log-mark-ink --log-mark-bg],
    %w[--log-host-0 --output-bg],
    %w[--log-host-1 --output-bg],
    %w[--log-host-2 --output-bg],
    %w[--log-host-3 --output-bg],
    %w[--log-host-4 --output-bg],
    %w[--log-host-5 --output-bg],

    # Sidebar
    %w[--side-ink --side-bg],
    %w[--side-ink --side-hover],
    %w[--side-muted --side-bg],
    %w[--side-current-ink --side-current-bg],
    %w[--side-current-ink --side-bg], # the brand name and the user's name
    %w[--side-muted --side-hover],    # the account menu's email, labels and role
    %w[--side-current-ink --side-current-bg],
    %w[--side-bg --side-accent]       # the account avatar's initial
  ].freeze

  # WCAG 2.1 1.4.11 (non-text contrast). Graphics and state markers, not text, so this
  # tier rather than 4.5:1 — but not without a standard: a mark that blurs into the
  # sidebar, or a heartbeat cell that vanishes into its panel, is the same failure as
  # unreadable text.
  AA_GRAPHIC = 3.0

  GRAPHIC_PAIRS = [
    # The logo: plate and cord on the tile, and the tile against the graphite sidebar
    %w[--mark-on --mark-tile],
    %w[--mark-gold --mark-tile],
    %w[--mark-tile --side-bg],

    # Heartbeat cells and card status edges, on the panel they sit on
    %w[--ok-edge --panel],
    %w[--drift-edge --panel],
    %w[--unhealthy-edge --panel],
    %w[--unreachable-edge --panel],

    # Focus rings and current-item markers
    %w[--focus --panel],
    %w[--focus --canvas],
    %w[--side-accent --side-bg],
    %w[--signal-fill --canvas], # the current tab's underline, the active summary read-out

    # Metrics chart lines and legend swatches, on the panel
    %w[--chart-1 --panel],
    %w[--chart-2 --panel],
    %w[--chart-3 --panel],
    %w[--chart-4 --panel],
    %w[--chart-5 --panel],
    %w[--chart-6 --panel]
  ].freeze

  test "every foreground/background pair in the light theme meets WCAG AA" do
    assert_all_pairs_pass palette(:light), "light"
  end

  test "every foreground/background pair in the dark theme meets WCAG AA" do
    assert_all_pairs_pass palette(:dark), "dark"
  end

  test "logo graphic elements in the light theme meet WCAG non-text contrast" do
    assert_all_graphic_pairs_pass palette(:light), "light"
  end

  test "logo graphic elements in the dark theme meet WCAG non-text contrast" do
    assert_all_graphic_pairs_pass palette(:dark), "dark"
  end

  # The tests above go through palette(), which only recognizes six-digit hex; tokens
  # written as rgba() (--ring, --shadow-md and the like) fall outside its regex, so
  # forgetting one on either side would not turn anything red. This one compares only
  # the set of variable names.
  test "both palettes must define the same set of variable names" do
    assert_equal palette_names(:light), palette_names(:dark),
                 "The light and dark blocks must define the same variable names, otherwise some token silently " \
                 "keeps its light value in dark mode (e.g. shadows written as rgba()/hsl() are not covered by the palette() assertions above)"
  end

  test "theme-independent tokens are not redefined by the dark block" do
    # The three :root blocks in the file are, in order: light palette, dark @media,
    # theme-independent tokens (typography/shape). The third block [comes after the dark
    # block], so if a same-named token is written in both, the later third block overrides
    # the dark value: dark mode silently breaks and no test goes red.
    # The criterion is simple: a token name in the third block must not appear in the dark block.
    blocks = STYLESHEET.read.scan(/:root\s*\{(.*?)\}/m).flatten
    assert_equal 3, blocks.length, "the stylesheet should have exactly three :root blocks"

    dark_block, neutral_block = blocks[1], blocks[2]

    dark_names    = dark_block.scan(/(--[\w-]+):/).flatten
    neutral_names = neutral_block.scan(/(--[\w-]+):/).flatten
    clobbered     = neutral_names & dark_names

    assert_empty clobbered,
                 "These tokens are defined in both the theme-independent block and the dark block; the dark values will be " \
                 "overridden by the later block: #{clobbered.join(', ')}. Put theme-dependent tokens " \
                 "in the two palette blocks instead."
  end

  private
    # => { "--surface" => "#fafaf8", ... }
    def palette(theme)
      css = STYLESHEET.read
      block = case theme
      when :light then css[/\A.*?:root\s*\{(.*?)\}/m, 1]
      when :dark  then css[/@media\s*\(prefers-color-scheme:\s*dark\).*?:root\s*\{(.*?)\}/m, 1]
      end

      assert block.present?, "could not find the :root block for the #{theme} theme in the stylesheet"
      block.scan(/(--[\w-]+):\s*(#[0-9a-fA-F]{6})/).to_h
    end

    # => ["--action", "--brand", ...]  (any value format; rgba()/hsl() count too)
    def palette_names(theme)
      css = STYLESHEET.read
      block = case theme
      when :light then css[/\A.*?:root\s*\{(.*?)\}/m, 1]
      when :dark  then css[/@media\s*\(prefers-color-scheme:\s*dark\).*?:root\s*\{(.*?)\}/m, 1]
      end

      assert block.present?, "could not find the :root block for the #{theme} theme in the stylesheet"
      block.scan(/(--[\w-]+):/).flatten.sort
    end

    def assert_all_pairs_pass(colors, theme_name)
      PAIRS.each do |fg_var, bg_var|
        fg = colors.fetch(fg_var) { flunk "#{theme_name} theme is missing variable #{fg_var}" }
        bg = colors.fetch(bg_var) { flunk "#{theme_name} theme is missing variable #{bg_var}" }
        ratio = contrast_ratio(fg, bg)

        assert_operator ratio, :>=, AA_NORMAL_TEXT,
                        "#{theme_name} theme: #{fg_var}(#{fg}) on #{bg_var}(#{bg}) is only " \
                        "#{ratio.round(2)}:1, below the AA requirement of #{AA_NORMAL_TEXT}:1"
      end
    end

    def assert_all_graphic_pairs_pass(colors, theme_name)
      GRAPHIC_PAIRS.each do |fg_var, bg_var|
        fg = colors.fetch(fg_var) { flunk "#{theme_name} theme is missing variable #{fg_var}" }
        bg = colors.fetch(bg_var) { flunk "#{theme_name} theme is missing variable #{bg_var}" }
        ratio = contrast_ratio(fg, bg)

        assert_operator ratio, :>=, AA_GRAPHIC,
                        "#{theme_name} theme: graphic #{fg_var}(#{fg}) on #{bg_var}(#{bg}) is only " \
                        "#{ratio.round(2)}:1, below the non-text contrast requirement of #{AA_GRAPHIC}:1"
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
