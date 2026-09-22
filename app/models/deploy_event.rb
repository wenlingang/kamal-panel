# 一行代表【一次部署尝试】，不是一条上报（spec 03 第 3 节）。
class DeployEvent < ApplicationRecord
  belongs_to :managed_app

  # 只需盖住"容器起来后被下一轮轮询看到"这一小段。
  UNOBSERVED_AFTER = 90.seconds
  # 要盖住一次正常部署的全长（构建 + 健康检查）。
  # 合成同一个常量会让其中一个必然误报。
  UNFINISHED_AFTER = 15.minutes

  # 给不出 performer / command，也看不见失败的部署。
  SOURCES = %w[hook inferred].freeze

  validates :version, presence: true
  validates :source, inclusion: { in: SOURCES }

  scope :recent_first, -> { order(created_at: :desc) }

  # 面板真正确认过这一版跑起来了，与"上报说成功了"是两回事。
  def observed? = observed_at.present?

  def observation_delay
    return nil unless observed_at && succeeded_at

    observed_at - succeeded_at
  end

  def observation_delay_text
    # 收敛时刻，算出来的 0 秒是个没有含义的数字。
    return I18n.t("deploy_events.observed_by_panel") if source == "inferred"

    return nil unless observed?
    return I18n.t("deploy_events.unverified") unless succeeded_at

    delay = observation_delay
    return I18n.t("deploy_events.observed_before_report") if delay.nil? || delay <= 0

    I18n.t("deploy_events.delayed_seconds", seconds: delay.round)
  end

  # 两类事实混在同一张表里，读的人必须一眼看出哪行是机器说的、哪行是面板推的。
  def source_text
    I18n.t(source == "inferred" ? "deploy_events.inferred" : "deploy_events.hook_reported")
  end
end
