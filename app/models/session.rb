class Session < ApplicationRecord
  # "Remember me": the sign-in lasts this long.
  REMEMBERED_FOR = 30.days
  # Without remember me the cookie ends with the browser, but browsers that restore the last
  # session bring such cookies back; this caps it on the server regardless.
  UNREMEMBERED_FOR = 1.day

  belongs_to :user

  # Anything creating a session without saying how long gets the short lifetime, never "forever".
  attribute :expires_at, :datetime, default: -> { UNREMEMBERED_FOR.from_now }

  def self.lifetime(remember:) = remember ? REMEMBERED_FOR : UNREMEMBERED_FOR

  # The one check every way in (requests, Action Cable) applies to a session found by cookie.
  def self.usable_by_id(id)
    session = find_by(id:)
    session if session && !session.expired? && !session.user.deactivated?
  end

  def expired? = expires_at <= Time.current
end
