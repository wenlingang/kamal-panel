# An immutable observation snapshot (spec 5.2).
class Observation < ApplicationRecord
  include LatestPerHost

  belongs_to :managed_app

  validates :host, presence: true
  validates :observed_at, presence: true

  def readonly?
    persisted?
  end

  def self.last_observed_at_for(managed_app)
    where(managed_app: managed_app).maximum(:observed_at)
  end
end
