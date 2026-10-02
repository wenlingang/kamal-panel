require "test_helper"

# The way this visual language fails is predictable: the next feature copies the style next to it
# and hardcodes another font-size, copies another px value, and the scale creeps back one line at a
# time. Each time it is only one line, which a human can't count in review, so let a test count.
#
# The allowlist should only keep permanent exceptions. Adding a line requires writing next to it why
# it cannot be a token.
class StylesheetTokensTest < ActiveSupport::TestCase
  # The literal guard (offenders) scans all stylesheets: under propshaft anyone can add
  # another .css file, and watching only application.css would leave new files unguarded.
  STYLESHEETS = Dir[Rails.root.join("app/assets/stylesheets/*.css")].sort.map { |path| Pathname.new(path) }.freeze

  # The type-scale test (third_root_block) looks at this one file only: it is the only
  # file that defines tokens, and token definitions are literals by nature, so its own
  # guard should not catch them.
  STYLESHEET = Rails.root.join("app/assets/stylesheets/application.css")

  TOKENIZED_PROPERTIES = %w[font-size box-shadow border-radius].freeze

  # Every added line must say here "why it cannot be a token".
  ALLOWED = [
    # code must scale with the parent's font size (monospace in a table is one step
    # smaller than that row's body text); switching to rem would make it larger in
    # small-text contexts instead. This is a permanent exception.
    "font-size: 0.875em"
  ].freeze

  # px allowed outside :root, four categories (the table after the spec §5 revision):
  #   1. Stroke width: a border is a separator, not content; a larger font size should not thicken dividers
  #   2. Media query breakpoints: a breakpoint measures the device, not the content scale (px_offenders_in strips the whole clause)
  #   3. Logo geometry: must match that 24 canvas
  #   4. .visually-hidden clipping: a fixed recipe for hiding, not a visible size
  # Before adding a line here, confirm which of the four categories it belongs to, and note it at
  # the end of the line.
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
    "outline: 2px solid transparent",             # 1 fallback outline for high-contrast mode
    "outline-offset: 2px",                        # 1
    "height: 1px",                                # 4 .visually-hidden
    "width: 1px",                                 # 4 .visually-hidden
    "margin: -1px",                               # 4 .visually-hidden
    "transform-origin: 12px 16.6px",              # 3 logo
    "transform: translateY(-3.4px)"               # 3 logo
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

      # Strip [all] :root blocks: this stylesheet has three :root blocks (light palette,
      # dark palette inside @media, typography and shape tokens), and the token
      # definitions are of course literal values, so they must not count as violations.
      css = css.gsub(/:root\s*\{.*?\}/m, "")

      css.scan(/(#{Regexp.union(TOKENIZED_PROPERTIES)})\s*:\s*([^;}]+)/)
         .reject { |_property, value| tokenized?(value.strip) }
         .map { |property, value| "#{property}: #{value.strip}" }
    end

    # The whole value must consist of var(--…) and separators. Checking only the start is
    # not enough: `box-shadow: var(--lift), 0 0 0 2px red` starts with var but mixes in a
    # literal, which the old logic let through, meaning the guard failed on exactly the
    # form most prone to error.
    #
    # "0" and "none" [remove] a style rather than set a size: the quiet tier zeroes the
    # card's radius and shadow, and that must not be treated as "hardcoded a literal".
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

      # The condition part of a media query doesn't count: a breakpoint measures the device, not the
      # content scale
      css = css.gsub(/@media[^{]*\{/, "{")

      css.scan(/([\w-]+)\s*:\s*([^;{}]*\d+(?:\.\d+)?px[^;{}]*)/)
         .map { |property, value| "#{property}: #{value.strip}" }
    end

  # The third :root block in the file: theme-independent typography/shape tokens (the
  # first is the light palette, the second the one inside the dark @media).
end
