require "test_helper"

class SessionTest < ActiveSupport::TestCase
  setup { @user = users(:one) }

  test "a session created without a lifetime gets the short one, never forever" do
    session = @user.sessions.create!
    assert_in_delta Session::UNREMEMBERED_FOR.from_now, session.expires_at, 5
  end

  test "usable_by_id rejects expired sessions" do
    session = @user.sessions.create!(expires_at: 1.second.ago)
    assert_nil Session.usable_by_id(session.id)
  end

  test "usable_by_id rejects sessions of deactivated users" do
    session = @user.sessions.create!
    @user.update_columns(deactivated_at: Time.current)
    assert_nil Session.usable_by_id(session.id)
  end

  test "usable_by_id returns a live session" do
    session = @user.sessions.create!
    assert_equal session, Session.usable_by_id(session.id)
  end
end
