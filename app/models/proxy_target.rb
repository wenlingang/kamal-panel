# A snapshot of the kamal-proxy routing table. Append-only, like Observation.
class ProxyTarget < ApplicationRecord
  include LatestPerHost

  belongs_to :managed_app

  def readonly?
    persisted?
  end
end
