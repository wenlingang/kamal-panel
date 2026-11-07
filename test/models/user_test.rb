require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "deactivating sets a timestamp and destroys existing sessions" do
    user = User.create!(email_address: "gone@example.com", password: "secret123456", role: "ops")
    user.sessions.create!

    user.deactivate!

    assert_predicate user, :deactivated?
    assert_equal 0, user.sessions.count, "Deactivation must kick out signed-in sessions immediately, otherwise it only takes effect after the cookie expires"
  end

  # normalizes runs before validation, so the "same email" differing in case or whitespace must be
  # blocked too.
  test "the same email with different casing counts as a duplicate" do
    User.create!(email_address: "dup@example.com", password: "secret123456", role: "ops")

    refute_predicate User.new(email_address: " DUP@EXAMPLE.COM ", password: "secret123456"), :valid?
  end
end
