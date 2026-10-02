require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "downcases and strips email_address" do
    user = User.new(email_address: " DOWNCASED@EXAMPLE.COM ")
    assert_equal("downcased@example.com", user.email_address)
  end

  # nickname is an optional display name. The six display points share display_name, so the fallback
  # rule is defined only once.
  test "display_name 有昵称时用昵称" do
    user = User.new(email_address: "wang@example.com", nickname: "老王")
    assert_equal "老王", user.display_name
  end

  test "display_name 没有昵称时回落到邮箱" do
    user = User.new(email_address: "lisi@example.com")
    assert_equal "lisi@example.com", user.display_name
  end

  # "Stored an empty string" and "left blank" look identical in the UI, but the former
  # makes anything other than a presence check (e.g. nickname.nil?) behave inconsistently.
  # Normalize both to nil.
  test "只有空白的昵称存成 nil，不是空串" do
    user = User.create!(email_address: "blank@example.com", password: "secret123456",
                        nickname: "   ")
    assert_nil user.reload.nickname
    assert_equal "blank@example.com", user.display_name
  end

  test "昵称两侧的空白被去掉" do
    user = User.new(nickname: "  老王  ")
    assert_equal "老王", user.nickname
  end

  test "昵称过长会被拒" do
    user = User.new(email_address: "long@example.com", password: "secret123456",
                    nickname: "名" * 51)
    refute user.valid?
    assert_predicate user.errors[:nickname], :any?
  end

  test "昵称不要求唯一：两个人可以叫同一个名字" do
    User.create!(email_address: "a1@example.com", password: "secret123456", nickname: "老王")
    other = User.new(email_address: "a2@example.com", password: "secret123456", nickname: "老王")
    assert_predicate other, :valid?
  end

  # locale is nullable: someone who hasn't expressed a preference follows the default, rather than
  # being forced to pick a language at account creation.
  test "没设过 locale 的用户 locale 是 nil" do
    user = User.create!(email_address: "nolocale@example.com", password: "secret123456")
    assert_nil user.locale
  end

  test "接受可用语言" do
    user = User.new(email_address: "l@example.com", password: "secret123456", locale: "en")
    assert_predicate user, :valid?
  end

  # Validate against available_locales rather than SELECTABLE_LOCALES: the latter only governs
  # "whether the switcher lets you pick it", a display decision that changes from batch to batch;
  # whether the database can store it is a separate matter, and rows that already store en shouldn't
  # become invalid just because the UI temporarily doesn't expose English.
  test "拒绝不可用的语言" do
    user = User.new(email_address: "l2@example.com", password: "secret123456", locale: "fr")
    refute_predicate user, :valid?
  end

  test "SELECTABLE_LOCALES 都在 available_locales 里" do
    User::SELECTABLE_LOCALES.each do |locale|
      assert_includes I18n.available_locales.map(&:to_s), locale
    end
  end

  test "默认角色是 ops" do
    user = User.create!(email_address: "a@example.com", password: "secret123456")
    assert user.ops?
    refute user.admin?
  end

  test "admin 角色" do
    user = User.create!(email_address: "b@example.com", password: "secret123456", role: "admin")
    assert user.admin?
    refute user.ops?
  end

  test "拒绝未知角色" do
    user = User.new(email_address: "c@example.com", password: "secret123456", role: "superuser")
    refute user.valid?
  end

  test "角色恰好三档" do
    assert_equal %w[admin developer ops], User::ROLES
  end

  test "三个谓词各自只对自己那一档为真" do
    assert_predicate User.new(role: "admin"), :admin?
    refute_predicate User.new(role: "admin"), :developer?
    refute_predicate User.new(role: "admin"), :ops?

    assert_predicate User.new(role: "developer"), :developer?
    refute_predicate User.new(role: "developer"), :admin?

    assert_predicate User.new(role: "ops"), :ops?
    refute_predicate User.new(role: "ops"), :admin?
  end

  test "旧角色值不再被接受" do
    %w[viewer operator].each do |legacy|
      user = User.new(email_address: "x@example.com", password: "secret123456", role: legacy)
      refute_predicate user, :valid?, "#{legacy} 必须被拒绝，不能悄悄留在库里"
    end
  end

  # After the migration there should be no role left outside ROLES. The test DB is built
  # from fixtures, so this also pins down whether the fixtures were updated accordingly.
  test "库里没有任何角色落在 ROLES 之外" do
    assert_empty User.where.not(role: User::ROLES).pluck(:email_address)
  end

  test "停用会写上时间戳并销毁其现有会话" do
    user = User.create!(email_address: "gone@example.com", password: "secret123456", role: "ops")
    user.sessions.create!

    user.deactivate!

    assert_predicate user, :deactivated?
    assert_equal 0, user.sessions.count, "停用必须立刻踢掉已登录的会话，否则停用要等到 cookie 过期才生效"
  end

  test "启用会清掉时间戳" do
    user = User.create!(email_address: "back@example.com", password: "secret123456", role: "ops")
    user.deactivate!

    user.reactivate!

    refute_predicate user, :deactivated?
  end

  test "active scope 只包含未停用的用户" do
    active = User.create!(email_address: "a@example.com", password: "secret123456", role: "ops")
    gone   = User.create!(email_address: "b@example.com", password: "secret123456", role: "ops")
    gone.deactivate!

    assert_includes User.active, active
    refute_includes User.active, gone
  end

  # Uniqueness used to be backed only by the database index: a duplicate email on the
  # people page is a RecordNotUnique (500), and an empty email could save an account that
  # can never log in, leaving an audit row behind as a bonus.
  test "邮箱不能为空" do
    user = User.new(password: "secret123456", role: "ops")
    refute_predicate user, :valid?
    assert_includes user.errors.attribute_names, :email_address
  end

  test "邮箱不能重复" do
    User.create!(email_address: "dup@example.com", password: "secret123456", role: "ops")
    dup = User.new(email_address: "dup@example.com", password: "secret123456", role: "ops")

    refute_predicate dup, :valid?
    assert_includes dup.errors.attribute_names, :email_address
  end

  # normalizes runs before validation, so the "same email" differing in case or whitespace must be
  # blocked too.
  test "大小写不同的同一个邮箱也算重复" do
    User.create!(email_address: "dup@example.com", password: "secret123456", role: "ops")

    refute_predicate User.new(email_address: " DUP@EXAMPLE.COM ", password: "secret123456"), :valid?
  end
end
