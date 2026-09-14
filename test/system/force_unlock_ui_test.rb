require "application_system_test_case"

class ForceUnlockUiTest < ApplicationSystemTestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  # 同 role_visibility_test：这里测的是"入口在什么条件下出现"，不是真实读锁，
  # 所以直接把 KamalLock#status 换成固定返回，用完还原。
  def with_lock_status(status)
    original = KamalLock.instance_method(:status)
    KamalLock.define_method(:status) { status }
    yield
  ensure
    KamalLock.define_method(:status, original)
  end

  def sign_in_as_role(role)
    sign_in_as(User.create!(email_address: "#{role}@example.com",
                            password: "secret123456", role: role))
  end

  test "没有锁时不出现强制解锁入口" do
    sign_in_as_role("admin")

    with_lock_status({ locked: false, details: nil, error: nil }) { visit managed_app_path(@app) }

    assert_no_text "强制解锁"
  end

  test "有锁时 admin 能看到强制解锁，ops 看不到" do
    locked = { locked: true, details: "Locked by: ci", error: nil }

    sign_in_as_role("admin")
    with_lock_status(locked) { visit managed_app_path(@app) }
    assert_text "强制解锁"
    assert_selector "input#force_unlock_confirm_name", visible: :all

    sign_in_as_role("ops")
    with_lock_status(locked) { visit managed_app_path(@app) }
    assert_text "部署进行中"
    assert_no_text "强制解锁"
  end
end
