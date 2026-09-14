# 总览页的筛选条件（名称模糊匹配 + 状态）。
#
# 状态这一维不是数据库列，是 ManagedAppStatus 逐个现算的，所以筛选发生在
# 内存里而不是 SQL 里。名称本可以走 SQL LIKE，但控制器无论如何都要把全部
# 应用取出来（PollCadence.mark_viewed! 要标记每一个，见控制器注释），再发
# 一条只拿子集的查询没有意义——两维一起在内存里筛，少一条查询也少一处
# "SQL 筛一半、Ruby 筛一半"的割裂。
class OverviewFilter
  PARSE_ERROR = "parse_error"

  # 下拉的选项集合。ManagedAppStatus 的五档之外多一项"配置无法解析"：
  # 它不是一档 level——在网格里它是另一条独立的行分支
  # （last_poll_error.present?），那种应用连 level 都算不出来（一算就在
  # 渲染阶段再炸一次 ParseError，见 _grid.html.erb 的注释）。但它恰恰是
  # 最该被筛出来的一类，所以在这一层把两者并成同一个维度。
  STATUS_KEYS = (ManagedAppStatus::LEVELS.map(&:to_s) + [ PARSE_ERROR ]).freeze

  # 下拉的 [显示名, 值] 对，调用时才翻译。视图直接喂给 options_for_select。
  def self.options
    STATUS_KEYS.map { |key| [ label_for(key), key ] }
  end

  def self.label_for(key)
    key == PARSE_ERROR ? I18n.t("statuses.parse_error") : ManagedAppStatus.label_for(key)
  end

  attr_reader :q, :status

  def initialize(q: nil, status: nil)
    @q = q.to_s.strip
    # 参数来自 URL，谁都能手改。不认识的状态值当作没有筛选——既不要 500，
    # 也不要给一个"什么都没有"的空页让人以为应用丢了。
    @status = status.to_s.presence_in(STATUS_KEYS)
  end

  def active?
    q.present? || status.present?
  end

  def apply(managed_apps)
    apps = managed_apps
    apps = apps.select { |app| app.name.downcase.include?(q.downcase) } if q.present?
    apps = apps.select { |app| matches_status?(app) } if status

    apps
  end

  private
    def matches_status?(app)
      # 顺序要紧：配置解析不了的应用必须在这里就被分流掉，绝不能落到下面
      # 那行去算 level——一算就抛 ParseError。
      return app.last_poll_error.present? if status == PARSE_ERROR
      return false if app.last_poll_error.present?

      ManagedAppStatus.new(app).level.to_s == status
    end
end
