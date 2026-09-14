require "test_helper"

# 防「长回去」。
#
# raise_on_missing_translations（见 config/environments/test.rb）对「根本没调用
# t()」是无感的：一行写死的中文永远查不到 key，也就永远不会触发它。没有这条
# 测试，下一个功能照着旁边的写法又写一行中文进去，而全套测试依然是绿的。
#
# 白名单是这件事的进度条，而且是测试在数、不是人在数：设计 13 的第 2~5 批各自
# 翻完一个版块，就从这里删掉对应的几行。清空之日，这件事做完。
class ViewsHaveNoBareChineseTest < ActiveSupport::TestCase
  CHINESE = /\p{Han}/

  # 设计 13 第 1 批建立本测试时，这些文件里还全是中文字面量。
  # 【只能删，不能加】——往里加一行，意味着有人新写了一页焊死中文的界面。
  UNTRANSLATED_VIEWS = %w[
  ].freeze

  test "白名单之外的视图里没有裸中文" do
    offenders = view_paths_with_chinese - UNTRANSLATED_VIEWS

    assert_empty offenders,
                 "这些视图里有写死的中文，请改用 t()：\n#{offenders.join("\n")}"
  end

  # 白名单会随批次缩短。留着已经翻干净的文件在里面，这条守卫就对那个文件失效了
  # ——而失效是静默的，没有这条断言没人会发现。
  test "白名单里没有已经翻干净的文件" do
    stale = UNTRANSLATED_VIEWS - view_paths_with_chinese

    assert_empty stale,
                 "这些文件已经没有中文了，请从 UNTRANSLATED_VIEWS 里删掉：\n#{stale.join("\n")}"
  end

  private
    def view_paths_with_chinese
      Dir.glob(Rails.root.join("app/views/**/*.erb")).filter_map do |path|
        # 剥掉 ERB 注释再看：这个仓库的中文注释是资产，不是要翻译的文案。
        body = File.read(path).gsub(/<%#.*?%>/m, "")
        next nil unless body.match?(CHINESE)

        Pathname.new(path).relative_path_from(Rails.root).to_s
      end.sort
    end
end
