# 一行代表【一次部署尝试】，不是一条上报（spec 03 第 3 节）。
#
# pre-deploy 上报建行填 started_at，post-deploy 上报补同一行的 succeeded_at。
# 配不上就建一行只有 succeeded_at 的——丢包与乱序都要有归宿，不能静默丢弃。
class DeployEvent < ApplicationRecord
  belongs_to :managed_app

  # 只需盖住"容器起来后被下一轮轮询看到"这一小段。
  UNOBSERVED_AFTER = 90.seconds
  # 要盖住一次正常部署的全长（构建 + 健康检查）。与上面量级不同，
  # 合成同一个常量会让其中一个必然误报。
  UNFINISHED_AFTER = 15.minutes

  # inferred 是从 Observation 推断出来的（子设计 05）：面板只知道"版本变了"，
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

  # Kamal 的真实时序是「容器先 running → 健康检查 → 切流量 → post-deploy
  # hook 才上报成功」，而 Reconciler 只要轮询看到 running 就回填
  # observed_at——所以 observed_at 常态性地【早于】succeeded_at，
  # observation_delay 是负数才是常态，不是异常，不能夹成 0 抹掉（那样会
  # 把"这次到底有没有真的延迟过"这条唯一的痕迹抹掉）。这里按符号给两种
  # 说法，别在视图里堆三目。
  def observation_delay_text
    # 推断事件根本没有上报，"延迟"无从谈起——succeeded_at 与 observed_at 都是
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
