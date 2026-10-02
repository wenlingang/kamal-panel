# kamal-proxy 路由表的快照。与 Observation 一样只追加。
class ProxyTarget < ApplicationRecord
  include LatestPerHost

  belongs_to :managed_app

  def readonly?
    persisted?
  end
end
