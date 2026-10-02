class AppMembership < ApplicationRecord
  belongs_to :user
  belongs_to :managed_app
end
