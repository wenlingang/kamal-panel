# 一条不可变的观测快照（spec 5.2）。
#
# 只追加，绝不 UPDATE。这样「14:32 running → 14:35 unhealthy」
# 天然可查，且 UI 能诚实显示数据年龄。
class Observation < ApplicationRecord
  include LatestPerHost

  belongs_to :managed_app

  validates :host, presence: true
  validates :observed_at, presence: true

  # 已持久化的记录一律只读——从模型层堵死误改
  def readonly?
    persisted?
  end

  def self.last_observed_at_for(managed_app)
    where(managed_app: managed_app).maximum(:observed_at)
  end
end
