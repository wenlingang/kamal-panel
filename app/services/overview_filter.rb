# 总览页的筛选条件（名称模糊匹配 + 状态）。
class OverviewFilter
  PARSE_ERROR = "parse_error"

  # 下拉的选项集合。
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
    # 参数来自 URL，谁都能手改。
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
      # 那行去算 level——一算就抛 ParseError。
      return app.last_poll_error.present? if status == PARSE_ERROR
      return false if app.last_poll_error.present?

      ManagedAppStatus.new(app).level.to_s == status
    end
end
