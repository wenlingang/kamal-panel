# 角色、人员与授权 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把两档全局角色换成 admin / developer / ops 三档，引入"人 ↔ 应用"成员关系，把授权判断收拢到一层 policy，并补上 ops 赖以成立的新能力：查看服务日志。

**Architecture:** 权限由两个维度合成——全站角色（`users.role`）回答"你是谁"，`app_memberships` 回答"这是谁的应用"，后者只对 developer 生效。所有授权判断收口到 `app/policies/` 下的普通 Ruby 对象，控制器与视图问同一个方法。动作类不再声明角色，只声明 `mutating?`，由 policy 解释。

**Tech Stack:** Rails 8.1、SQLite、Minitest（`bin/rails test`）、RuboCop（`bin/rubocop`，rails-omakase）、ERB 视图、Turbo。无新增 gem。

**Spec:** `docs/superpowers/specs/2026-09-11-kamal-panel-roles-and-people-design.md`

## 前置条件

**先把 `10-overview-filter` 合回 main，再从 main 切出执行分支。** 那条分支引入了
`RefreshesController` 及其测试，而本计划的能力矩阵（spec §3）把 `refreshes#create`
列为三档角色都可用——基线里没有它，Task 4 就少覆盖一个控制器，而合并时必然冲突。

```bash
git checkout main && git merge --no-ff --no-commit 10-overview-filter && git commit --no-edit
git checkout -b 11-roles-and-people-impl
```

（`--no-ff --no-commit` 分两步是必要的：本仓库里 `git merge --no-ff` 单独用会被
快进掉，留下直线历史。）

## Global Constraints

- 角色集合恰好三档：`ROLES = %w[admin developer ops]`。旧值 `viewer` / `operator`
  必须从代码与数据里彻底消失，不留兼容层。
- `app_memberships` 表上**不允许有角色列**。它只回答"这个人能动哪几个应用"。
- admin 与 ops **永远不进** `app_memberships`。
- 可见性不按成员关系收窄：总览、应用详情、部署历史、审计页对三档角色都是全站。
  只有"动得了"受成员关系约束。
- 不提供删除用户，只提供停用（`users.deactivated_at`）。
- 授权规则只有一处定义：控制器与视图必须调用同一个 policy 方法。
- 所有面向用户的文案为中文。提交信息为中文，格式沿用本仓库：
  `feat: 做了什么——此前是什么样`。
- 每个 Task 结束时 `bin/rails test` 与 `bin/rubocop` 都必须全绿才提交。

---

### Task 1: 三档角色与数据迁移

**Files:**
- Modify: `app/models/user.rb`
- Modify: `db/seeds.rb:11-20`
- Modify: `test/fixtures/users.yml`
- Create: `db/migrate/<timestamp>_change_user_roles_to_three_tier.rb`
- Test: `test/models/user_test.rb`

**Interfaces:**
- Produces: `User::ROLES == %w[admin developer ops]`；谓词 `User#admin?` /
  `User#developer?` / `User#ops?`（返回 `true`/`false`）。后续所有 Task 都依赖它们。
- Produces: fixture `users(:one)` = ops、`users(:two)` = admin、`users(:three)` = developer。

- [ ] **Step 1: 写失败的测试**

在 `test/models/user_test.rb` 末尾（`end` 之前）追加：

```ruby
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

  # 迁移之后库里不该再有任何落在 ROLES 之外的角色。测试库由 fixtures 建立，
  # 所以这条同时钉住了 fixtures 有没有跟着改。
  test "库里没有任何角色落在 ROLES 之外" do
    assert_empty User.where.not(role: User::ROLES).pluck(:email_address)
  end
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `bin/rails test test/models/user_test.rb`
Expected: FAIL —— `Expected: ["admin", "developer", "ops"] Actual: ["viewer", "operator"]`

- [ ] **Step 3: 改 `app/models/user.rb`**

把 `ROLES` 与两个谓词整体替换成：

```ruby
class User < ApplicationRecord
  ROLES = %w[admin developer ops].freeze

  has_secure_password
  has_many :sessions, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :role, inclusion: { in: ROLES }

  def admin?     = role == "admin"
  def developer? = role == "developer"
  def ops?       = role == "ops"
end
```

- [ ] **Step 4: 生成并写迁移**

Run: `bin/rails generate migration ChangeUserRolesToThreeTier`

把生成的文件内容替换成：

```ruby
class ChangeUserRolesToThreeTier < ActiveRecord::Migration[8.1]
  # 一次性改值，不留兼容层。用 execute 而不是 User.update_all：迁移不该依赖
  # 模型当下的样子（ROLES 已经在同一个提交里变了，模型校验会跟数据打架）。
  def up
    execute "UPDATE users SET role = 'admin' WHERE role = 'operator'"
    execute "UPDATE users SET role = 'ops'   WHERE role = 'viewer'"
    # 默认值的含义是「没指定角色时给什么」，三档里权限最小的是 ops。
    change_column_default :users, :role, from: "viewer", to: "ops"
  end

  def down
    execute "UPDATE users SET role = 'operator' WHERE role = 'admin'"
    execute "UPDATE users SET role = 'viewer'   WHERE role = 'ops'"
    # developer 在旧模型里没有对应档位。回滚只能把它降到最小权限，
    # 而不是悄悄升成 operator。
    execute "UPDATE users SET role = 'viewer'   WHERE role = 'developer'"
    change_column_default :users, :role, from: "ops", to: "viewer"
  end
end
```

- [ ] **Step 5: 改 fixtures**

`test/fixtures/users.yml` 整体替换成：

```yaml
<% password_digest = BCrypt::Password.create("password") %>

one:
  email_address: one@example.com
  password_digest: <%= password_digest %>
  role: ops

two:
  email_address: two@example.com
  password_digest: <%= password_digest %>
  role: admin

three:
  email_address: three@example.com
  password_digest: <%= password_digest %>
  role: developer
```

- [ ] **Step 6: 改 seeds**

`db/seeds.rb` 第 11-20 行，把注释与角色一起改：

```ruby
# 首个 admin 由环境变量注入，避免出现「默认密码」这种东西。
if (email = ENV["KAMAL_PANEL_ADMIN_EMAIL"]).present?
  password = ENV.fetch("KAMAL_PANEL_ADMIN_PASSWORD")
  User.find_or_create_by!(email_address: email) do |user|
    user.password = password
    user.role = "admin"
  end
  puts "已创建 admin: #{email}"
end
```

- [ ] **Step 7: 跑迁移并跑全套测试**

Run: `bin/rails db:migrate && bin/rails test`

Expected: `test/models/user_test.rb` 全绿。**其他控制器测试会大面积变红**——它们
还在调 `require_operator!`（Task 4 才删）。这一步只需确认失败原因全部是
`undefined method 'operator?'`，不是别的。把这些红留给 Task 4 修，不要在这里
临时打补丁。

- [ ] **Step 8: 让现有控制器不炸——最小改动**

`app/controllers/application_controller.rb` 里把 `require_operator!` 临时改成认
admin（Task 4 会把这个方法整个删掉）：

```ruby
    def require_operator!
      # 过渡期：Task 4 会用 require_permission! 取代它。
      return if Current.user&.admin?

      redirect_to root_path, alert: "该操作需要 admin 权限"
    end
```

`app/helpers/authorization_helper.rb` 同理：

```ruby
module AuthorizationHelper
  def operator_only(&block)
    capture(&block) if Current.user&.admin?
  end
end
```

- [ ] **Step 9: 跑全套测试与 rubocop**

Run: `bin/rails test && bin/rubocop`
Expected: 全绿。若有测试断言 `"该操作需要 operator 权限"` 这句文案，改成 admin 版本。

- [ ] **Step 10: 提交**

```bash
git add app/models/user.rb db/migrate db/schema.rb db/seeds.rb test/fixtures/users.yml \
        test/models/user_test.rb app/controllers/application_controller.rb \
        app/helpers/authorization_helper.rb
git commit -m "feat: 角色换成 admin/developer/ops 三档——此前只有 viewer/operator，多团队之后中间没有档位

给 operator 就能动所有人的应用，不给就连自己的都重启不了。三档是引入
「哪些应用是你的」这个新维度的前提（成员表在下一步）。

迁移一次性改值不留兼容层：旧值在 ROLES 里彻底消失，残留会被 inclusion
当场拦下，而不是悄悄变成哪一档都不是因而处处判假。回滚时 developer 降到
viewer 而不是升成 operator——回滚不该悄悄放大权限。"
```

---

### Task 2: 停用用户

**Files:**
- Modify: `app/models/user.rb`
- Modify: `app/controllers/concerns/authentication.rb:19-27`
- Create: `db/migrate/<timestamp>_add_deactivated_at_to_users.rb`
- Test: `test/models/user_test.rb`, `test/controllers/sessions_controller_test.rb`

**Interfaces:**
- Consumes: Task 1 的 `User::ROLES` 与谓词。
- Produces: `User#deactivated?`、`User#deactivate!`、`User#reactivate!`；
  `User.active` scope。Task 8 的人员界面依赖它们。

- [ ] **Step 1: 写失败的测试**

`test/models/user_test.rb` 追加：

```ruby
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
```

`test/controllers/sessions_controller_test.rb` 追加：

```ruby
  test "停用的用户无法登录" do
    user = User.create!(email_address: "gone@example.com", password: "secret123456", role: "ops")
    user.deactivate!

    post session_path, params: { email_address: "gone@example.com", password: "secret123456" }

    assert_redirected_to new_session_path
    assert_equal "邮箱地址或密码不正确。", flash[:alert],
      "不要告诉对方「这个账号被停用了」——那等于向未认证的人确认这个邮箱存在"
  end

  test "已登录的用户被停用后，下一次请求就失效" do
    user = User.create!(email_address: "gone@example.com", password: "secret123456", role: "ops")
    sign_in_as user
    get root_path
    assert_response :success

    user.deactivate!

    get root_path
    assert_redirected_to new_session_path
  end
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `bin/rails test test/models/user_test.rb test/controllers/sessions_controller_test.rb`
Expected: FAIL —— `undefined method 'deactivate!'`

- [ ] **Step 3: 生成并写迁移**

Run: `bin/rails generate migration AddDeactivatedAtToUsers`

```ruby
class AddDeactivatedAtToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :deactivated_at, :datetime
  end
end
```

- [ ] **Step 4: 实现模型部分**

`app/models/user.rb` 在谓词下面加：

```ruby
  scope :active, -> { where(deactivated_at: nil) }

  def deactivated? = deactivated_at.present?

  # 停用必须连带销毁会话：只写时间戳的话，已经登录的人要等到 cookie 过期
  # 才真的被挡在外面，而停用的场合（离职、权限收回）恰恰是最等不起的。
  def deactivate!
    transaction do
      update!(deactivated_at: Time.current)
      sessions.destroy_all
    end
  end

  def reactivate! = update!(deactivated_at: nil)
```

- [ ] **Step 5: 登录与会话恢复都要挡住停用用户**

`app/controllers/concerns/authentication.rb`，把 `resume_session` 与
`find_session_by_cookie` 换成：

```ruby
    def resume_session
      Current.session ||= find_session_by_cookie
    end

    # 停用的判断放在这里而不是只放登录：只挡登录的话，停用之前就已经拿到
    # cookie 的人会一直有效到 cookie 过期。每次请求都问一遍，停用才是即时的。
    def find_session_by_cookie
      return nil unless cookies.signed[:session_id]

      session = Session.find_by(id: cookies.signed[:session_id])
      return nil if session.nil? || session.user.deactivated?

      session
    end
```

`app/controllers/sessions_controller.rb` 的 `create`：

```ruby
  def create
    user = User.authenticate_by(params.permit(:email_address, :password))

    # 停用的账号与密码错误给同一句话：区别对待等于向未认证的人确认这个邮箱存在。
    if user && !user.deactivated?
      start_new_session_for user
      redirect_to after_authentication_url
    else
      redirect_to new_session_path, alert: "邮箱地址或密码不正确。"
    end
  end
```

- [ ] **Step 6: 跑测试**

Run: `bin/rails db:migrate && bin/rails test test/models/user_test.rb test/controllers/sessions_controller_test.rb`
Expected: PASS

- [ ] **Step 7: 全套 + rubocop**

Run: `bin/rails test && bin/rubocop`
Expected: 全绿

- [ ] **Step 8: 提交**

```bash
git add app/models/user.rb app/controllers/concerns/authentication.rb \
        app/controllers/sessions_controller.rb db/migrate db/schema.rb \
        test/models/user_test.rb test/controllers/sessions_controller_test.rb
git commit -m "feat: 用户可以停用——此前只能删，而删不掉

audit_logs.user_id 是 null:false 带外键，删用户要么被外键拒绝，要么连带
删审计；而审计不可删除是这个仓库既有的规矩。所以人员管理不提供删除，
只提供停用。

停用在每次请求恢复会话时判断，不只在登录时判断：只挡登录的话，停用之前
已经拿到 cookie 的人会一直有效到 cookie 过期，而停用的场合最等不起。
登录失败的文案与密码错误完全相同——区别对待等于向未认证的人确认邮箱存在。"
```

---

### Task 3: 应用成员关系

**Files:**
- Create: `app/models/app_membership.rb`
- Modify: `app/models/user.rb`, `app/models/managed_app.rb:12` 附近的关联区
- Create: `db/migrate/<timestamp>_create_app_memberships.rb`
- Test: `test/models/app_membership_test.rb`

**Interfaces:**
- Consumes: Task 1 的角色。
- Produces: `ManagedApp#members`（`User` 的集合）、`ManagedApp#member_ids`、
  `User#managed_apps`。Task 4 的 `ManagedAppPolicy#member?` 依赖 `member_ids`。

- [ ] **Step 1: 写失败的测试**

Create `test/models/app_membership_test.rb`:

```ruby
require "test_helper"

class AppMembershipTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog",
                              config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    @user = users(:three) # developer
  end

  test "成员关系双向可读" do
    AppMembership.create!(user: @user, managed_app: @app)

    assert_includes @app.members, @user
    assert_includes @user.managed_apps, @app
    assert_includes @app.member_ids, @user.id
  end

  test "同一个人在同一个应用上不能重复成为成员" do
    AppMembership.create!(user: @user, managed_app: @app)

    assert_raises(ActiveRecord::RecordNotUnique) do
      AppMembership.insert!({ user_id: @user.id, managed_app_id: @app.id, created_at: Time.current })
    end
  end

  test "应用被删时成员行跟着消失" do
    AppMembership.create!(user: @user, managed_app: @app)

    @app.destroy

    assert_equal 0, AppMembership.where(managed_app_id: @app.id).count
  end

  test "用户被停用不影响成员行——停用不是删除" do
    AppMembership.create!(user: @user, managed_app: @app)

    @user.deactivate!

    assert_includes @app.reload.members, @user
  end
end
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `bin/rails test test/models/app_membership_test.rb`
Expected: FAIL —— `uninitialized constant AppMembership`

- [ ] **Step 3: 生成并写迁移**

Run: `bin/rails generate migration CreateAppMemberships`

```ruby
class CreateAppMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :app_memberships do |t|
      t.references :user, null: false, foreign_key: true
      t.references :managed_app, null: false, foreign_key: true
      t.datetime :created_at, null: false
    end

    # 唯一索引而不是只靠模型校验：成员关系是授权的输入，重复行会让
    # 「这个人是不是成员」这个问题在不同查询下给出不同答案。
    add_index :app_memberships, [ :user_id, :managed_app_id ], unique: true
  end
end
```

- [ ] **Step 4: 写模型与关联**

Create `app/models/app_membership.rb`:

```ruby
# 「这个人能动哪几个应用」。只对 developer 生效——admin 与 ops 的权限来自
# 全站角色，永远不进这张表（往里加只会制造「有两个地方决定 admin 能不能动
# 这个应用」的假象）。
#
# 这张表上【没有角色列】，也不该有：加一列 role 就等于把模型变成「每个应用
# 上各自一个角色」，那是设计 11 第 1.1 节明确否掉的方案。真要那样改，是一次
# 显式的模型变更，不该由谁往这张表上悄悄加一列来完成。
class AppMembership < ApplicationRecord
  belongs_to :user
  belongs_to :managed_app
end
```

`app/models/user.rb` 在 `has_many :sessions` 下面加：

```ruby
  has_many :app_memberships, dependent: :destroy
  has_many :managed_apps, through: :app_memberships
```

`app/models/managed_app.rb` 在 `belongs_to :ssh_credential` 附近加：

```ruby
  has_many :app_memberships, dependent: :destroy
  has_many :members, through: :app_memberships, source: :user
```

- [ ] **Step 5: 跑测试**

Run: `bin/rails db:migrate && bin/rails test test/models/app_membership_test.rb`
Expected: PASS

- [ ] **Step 6: 全套 + rubocop**

Run: `bin/rails test && bin/rubocop`
Expected: 全绿

- [ ] **Step 7: 提交**

```bash
git add app/models/app_membership.rb app/models/user.rb app/models/managed_app.rb \
        db/migrate db/schema.rb test/models/app_membership_test.rb
git commit -m "feat: 人与应用的成员关系——权限的第二个维度

三档角色回答「你是谁」，这张表回答「这是谁的应用」。只对 developer 生效。

表上没有角色列，也不该有：加一列 role 就等于变成被否掉的 per-app 角色模型。
唯一索引不是可有可无的洁癖——成员关系是授权的输入，重复行会让「这个人是不是
成员」在不同查询下给出不同答案。"
```

---

### Task 4: policy 层（承重项）

**Files:**
- Create: `app/policies/managed_app_policy.rb`, `app/policies/user_policy.rb`
- Modify: `app/controllers/application_controller.rb`
- Modify: `app/helpers/authorization_helper.rb`
- Modify: `app/controllers/managed_apps_controller.rb:2`,
  `app/controllers/hook_tokens_controller.rb:2`,
  `app/controllers/actions_controller.rb:2-16`
- Modify: `app/views/overviews/show.html.erb`, `app/views/managed_apps/index.html.erb`,
  `app/views/managed_apps/show.html.erb`, `app/views/managed_apps/_deploy_reporting.html.erb`
- Test: `test/policies/managed_app_policy_test.rb`, `test/policies/user_policy_test.rb`,
  `test/controllers/managed_apps_controller_test.rb`, `test/controllers/actions_controller_test.rb`

**Interfaces:**
- Consumes: Task 1 的谓词、Task 3 的 `ManagedApp#member_ids`。
- Produces:
  - `ManagedAppPolicy.new(user, managed_app_or_nil)` → `#show?`、`#act?`、
    `#view_logs?`、`#regenerate_hook_token?`、`#manage_members?`、`#create_app?`、
    `#run?(action_class)`
  - `UserPolicy.new(user, subject_or_nil)` → `#manage?`
  - `ApplicationController#policy_for(record_or_class)` → policy 实例
  - `ApplicationController.authorize(capability, on:, only:)` 类宏（Task 5 的结构
    性测试读 `authorization_rules`）
  - 视图帮助器 `allowed_to(capability, record_or_class, &block)`

- [ ] **Step 1: 写失败的 policy 测试**

Create `test/policies/managed_app_policy_test.rb`:

```ruby
require "test_helper"

class ManagedAppPolicyTest < ActiveSupport::TestCase
  setup do
    @mine = ManagedApp.create!(name: "mine",
                               config_yaml: file_fixture("simple_deploy.yml").read,
                               destination: "production")
    @theirs = ManagedApp.create!(name: "theirs",
                                 config_yaml: file_fixture("simple_deploy.yml").read,
                                 destination: "production")

    @admin     = users(:two)
    @developer = users(:three)
    @ops       = users(:one)

    AppMembership.create!(user: @developer, managed_app: @mine)
  end

  def policy(user, app) = ManagedAppPolicy.new(user, app)

  test "看：三档角色都能看任何应用" do
    [ @admin, @developer, @ops ].each do |user|
      assert_predicate policy(user, @theirs), :show?
    end
  end

  test "动：admin 对任何应用都能动" do
    assert_predicate policy(@admin, @mine), :act?
    assert_predicate policy(@admin, @theirs), :act?
  end

  test "动：developer 只能动名下的应用" do
    assert_predicate policy(@developer, @mine), :act?
    refute_predicate policy(@developer, @theirs), :act?
  end

  test "动：ops 一个都不能动，哪怕被错误地加成了成员" do
    AppMembership.create!(user: @ops, managed_app: @mine)

    refute_predicate policy(@ops, @mine), :act?,
      "ops 的权限来自全站角色，成员行不该给它额外的动作权限"
  end

  test "日志：ops 全站可看，developer 只看名下，admin 全站" do
    assert_predicate policy(@ops, @theirs), :view_logs?
    assert_predicate policy(@admin, @theirs), :view_logs?
    assert_predicate policy(@developer, @mine), :view_logs?
    refute_predicate policy(@developer, @theirs), :view_logs?
  end

  test "重生成上报 token 与动作同权" do
    assert_predicate policy(@developer, @mine), :regenerate_hook_token?
    refute_predicate policy(@developer, @theirs), :regenerate_hook_token?
    refute_predicate policy(@ops, @mine), :regenerate_hook_token?
  end

  test "接入应用与管理成员是 admin 独占" do
    assert_predicate policy(@admin, nil), :create_app?
    refute_predicate policy(@developer, nil), :create_app?
    refute_predicate policy(@ops, nil), :create_app?

    assert_predicate policy(@admin, @mine), :manage_members?
    refute_predicate policy(@developer, @mine), :manage_members?
  end
end
```

Create `test/policies/user_policy_test.rb`:

```ruby
require "test_helper"

class UserPolicyTest < ActiveSupport::TestCase
  test "只有 admin 能管人" do
    assert_predicate UserPolicy.new(users(:two), nil), :manage?
    refute_predicate UserPolicy.new(users(:three), nil), :manage?
    refute_predicate UserPolicy.new(users(:one), nil), :manage?
  end
end
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `bin/rails test test/policies`
Expected: FAIL —— `uninitialized constant ManagedAppPolicy`

- [ ] **Step 3: 写两个 policy**

Create `app/policies/managed_app_policy.rb`:

```ruby
# 围绕某个应用的权限。暴露的是【能力】而不是角色——调用方永远不该问
# 「这个人是不是 admin」，只问「这个人能不能做这件事」。角色与成员关系
# 怎么合成能力，只在这一个文件里回答。
#
# managed_app 允许为 nil：接入新应用时还没有应用可谈，而 create_app? 本来
# 也不看具体是哪个应用。
class ManagedAppPolicy
  def initialize(user, managed_app = nil)
    @user = user
    @managed_app = managed_app
  end

  # 可见性不按成员关系收窄（设计 11 第 3.1 节）：总览的价值在于一屏看全，
  # 版本漂移这类问题常常是跨应用比较才看得出来的。看得见与动得了是两件事。
  def show? = true

  def act? = user.admin? || (user.developer? && member?)

  def view_logs? = act? || user.ops?

  def regenerate_hook_token? = act?

  def create_app?     = user.admin?
  def manage_members? = user.admin?

  # 动作类只声明自己会不会改变线上状态，由这里解释谁能执行。角色字符串
  # 一旦写回动作类，授权规则就同时活在两个地方了。
  def run?(action_class) = action_class.mutating? ? act? : view_logs?

  private
    attr_reader :user, :managed_app

    def member? = managed_app.present? && managed_app.member_ids.include?(user.id)
end
```

Create `app/policies/user_policy.rb`:

```ruby
# 人员管理。逻辑简单到只有一行，但它存在的意义不是逻辑复杂，而是让
# 「谁能管人」这句话有一个唯一的落点——否则它会以 Current.user.admin?
# 的形式散落在控制器、视图和测试里。
class UserPolicy
  def initialize(user, subject = nil)
    @user = user
    @subject = subject
  end

  def manage? = user.admin?

  private
    attr_reader :user, :subject
end
```

- [ ] **Step 4: 跑 policy 测试**

Run: `bin/rails test test/policies`
Expected: PASS

- [ ] **Step 5: 在 ApplicationController 上接出授权入口**

`app/controllers/application_controller.rb` 整体替换成：

```ruby
class ApplicationController < ActionController::Base
  include Authentication
  allow_browser versions: :modern

  stale_when_importmap_changes

  POLICIES = { ManagedApp => ManagedAppPolicy, User => UserPolicy }.freeze

  # 声明式授权。用类宏而不是直接写 before_action，是为了让「这个动作要求什么
  # 权限」成为可读取的数据（authorization_rules）——Task 5 的结构性测试靠它
  # 发现漏挂过滤器的动作，而漏挂是这类重构最典型、且不会让任何别的测试变红
  # 的事故。
  class_attribute :authorization_rules, default: [], instance_writer: false

  def self.authorize(capability, on:, only:)
    self.authorization_rules = authorization_rules + [ { capability:, on:, only: Array(only) } ]
    before_action(only: only) { require_permission!(capability, on) }
  end

  helper_method :policy_for

  private
    def policy_for(record)
      klass = record.is_a?(Class) ? record : record.class
      POLICIES.fetch(klass).new(Current.user, record.is_a?(Class) ? nil : record)
    end

    def require_permission!(capability, record)
      return if policy_for(record).public_send("#{capability}?")

      redirect_to root_path, alert: "没有权限执行该操作"
    end
end
```

- [ ] **Step 6: 换掉视图帮助器**

`app/helpers/authorization_helper.rb` 整体替换成：

```ruby
module AuthorizationHelper
  # 视图里看得见的按钮，和控制器放行的动作，必须是同一句话算出来的——
  # 这个帮助器调的就是控制器调的那个 policy 方法。此前 operator_only 与
  # require_operator! 各自独立判断同一件事，两处一致纯属巧合。
  def allowed_to(capability, record, &block)
    capture(&block) if policy_for(record).public_send("#{capability}?")
  end
end
```

- [ ] **Step 7: 改三个控制器**

`app/controllers/managed_apps_controller.rb` 第 2 行：

```ruby
  authorize :create_app, on: ManagedApp, only: %i[ new create ]
```

`app/controllers/hook_tokens_controller.rb`：

```ruby
class HookTokensController < ApplicationController
  def create
    app = ManagedApp.find(params[:managed_app_id])
    require_permission!(:regenerate_hook_token, app)
    return if performed?

    token = app.regenerate_hook_token!

    redirect_to app, flash: { hook_token: token }
  end
end
```

> 这里不能用类宏：权限取决于 `params[:managed_app_id]` 指向的那个应用，而类宏
> 在 `before_action` 里拿不到它。写成先查应用、再判权限、`performed?` 为真就
> 返回。下面的 `ActionsController` 同理。

`app/controllers/actions_controller.rb` 的 `create`，把首行的
`before_action :require_operator!, only: :create` 删掉，方法体开头改成：

```ruby
  def create
    app = ManagedApp.find(params[:managed_app_id])
    action_class = Actions::Base.find(params[:name])

    unless ManagedAppPolicy.new(Current.user, app).run?(action_class)
      return redirect_to app, alert: "没有权限执行该操作"
    end

    if action_class.confirm_by_name? && params[:confirm_name] != app.name
      return redirect_to app, alert: "确认失败：请手输应用名"
    end
```

（其余部分不动。）

- [ ] **Step 8: 改四处视图**

`app/views/overviews/show.html.erb` 与 `app/views/managed_apps/index.html.erb`：

```erb
  <%= allowed_to(:create_app, ManagedApp) do %>
    <%= link_to "接入一个应用", new_managed_app_path, class: "btn-primary" %>
  <% end %>
```

`app/views/managed_apps/show.html.erb` 的两处 `operator_only`（强制解锁块、操作
区块）都换成：

```erb
    <%= allowed_to(:act, @managed_app) do %>
```

`app/views/managed_apps/_deploy_reporting.html.erb` 那一处：

```erb
<%= allowed_to(:regenerate_hook_token, managed_app) do %>
```

- [ ] **Step 9: 删掉旧入口**

`app/controllers/application_controller.rb` 里已经没有 `require_operator!`
（Step 5 整体替换时就删了）。确认全仓库不再有引用：

Run: `grep -rn "require_operator!\|operator_only\|operator?\|viewer?" app/ test/`
Expected: 无输出。有输出就是漏改，改完再往下。

- [ ] **Step 10: 补控制器测试**

`test/controllers/managed_apps_controller_test.rb` 追加：

```ruby
  test "developer 不能接入新应用" do
    sign_in_as users(:three)

    get new_managed_app_path

    assert_redirected_to root_path
    assert_equal "没有权限执行该操作", flash[:alert]
  end
```

`test/controllers/actions_controller_test.rb` 追加：

```ruby
  test "developer 能对名下应用发起动作" do
    AppMembership.create!(user: users(:three), managed_app: @managed_app)
    sign_in_as users(:three)

    post managed_app_actions_path(@managed_app), params: { name: "start" }

    assert_equal 1, AuditLog.where(managed_app: @managed_app).count
  end

  test "developer 不能对别人的应用发起动作" do
    sign_in_as users(:three)

    post managed_app_actions_path(@managed_app), params: { name: "start" }

    assert_redirected_to managed_app_path(@managed_app)
    assert_equal "没有权限执行该操作", flash[:alert]
    assert_equal 0, AuditLog.where(managed_app: @managed_app).count,
      "被拒的动作绝不能留下审计记录——那会让审计里出现从未发生过的操作"
  end

  test "ops 不能发起任何会改变线上状态的动作" do
    sign_in_as users(:one)

    post managed_app_actions_path(@managed_app), params: { name: "start" }

    assert_redirected_to managed_app_path(@managed_app)
    assert_equal 0, AuditLog.where(managed_app: @managed_app).count
  end
```

> `@managed_app` 用该测试文件 setup 里已有的那个；若变量名不同，照搬现有名字。

`test/controllers/refreshes_controller_test.rb` 里那两条注释写着 `# operator` /
`# viewer` 的用例改成新角色，并补一条——**手动刷新对三档角色都开放**，它是读动作：
不取部署锁、不写审计、不改变线上任何状态，只是让一次本来就会自动发生的采集提前。
它没有、也不该有授权过滤器，所以要有一条测试说明这是有意的：

```ruby
  test "三档角色都能手动刷新——它是读动作" do
    [ users(:one), users(:two), users(:three) ].each do |user|
      sign_in_as user

      assert_enqueued_with(job: PollManagedAppJob) do
        post managed_app_refreshes_path(@managed_app)
      end
    end
  end
```

- [ ] **Step 11: 跑全套 + rubocop**

Run: `bin/rails test && bin/rubocop`
Expected: 全绿

- [ ] **Step 12: 提交**

```bash
git add app/policies app/controllers app/helpers/authorization_helper.rb app/views test/policies test/controllers
git commit -m "feat: 授权收拢成 policy 对象——此前同一条规则活在控制器与视图两个地方

require_operator! 与 operator_only 各自独立判断 Current.user.operator?，
两处一致纯属巧合。三档角色加上「developer 只能动名下应用」之后，这种写法
必然漂移成「按钮还在但点下去被拒」，或者更糟：按钮没了，接口却还放行。
本仓库已经吃过一次同构的亏（_grid 的渲染侧与轮询侧对解析失败判断不一致）。

policy 暴露的是能力不是角色，调用方永远不问「这个人是不是 admin」。
授权用类宏声明而不是直写 before_action，是为了让「这个动作要求什么权限」
成为可读取的数据——下一步的结构性测试靠它发现漏挂过滤器的动作。"
```

---

### Task 5: 钉住「别漏挂授权」

**Files:**
- Create: `test/controllers/authorization_coverage_test.rb`

**Interfaces:**
- Consumes: Task 4 的 `ApplicationController.authorization_rules`。

- [ ] **Step 1: 写测试**

Create `test/controllers/authorization_coverage_test.rb`:

```ruby
require "test_helper"

# 漏挂一个授权过滤器是这类重构最典型的事故，而它【不会让任何别的测试变红】
# ——那个动作照常工作，只是对谁都工作。这条测试是唯一能在 CI 里抓住它的东西。
#
# 这里的清单是人写的、故意写死的：它表达的是「这些动作必须被授权」这个意图，
# 而不是从代码里反推出来的事实。从代码反推的测试只会永远为真。
class AuthorizationCoverageTest < ActiveSupport::TestCase
  DECLARATIVE = {
    "ManagedAppsController" => %w[new create]
  }.freeze

  # 权限取决于 URL 里那个应用的动作没法用类宏声明（before_action 拿不到
  # params 指向的记录），它们在方法体里判断。这里列出它们，并在下面用一条
  # 源码断言确认那句判断还在——比"什么都不检查"强，比假装它们也是声明式的诚实。
  INLINE = {
    "app/controllers/actions_controller.rb"     => "ManagedAppPolicy.new(Current.user, app).run?",
    "app/controllers/hook_tokens_controller.rb" => "require_permission!(:regenerate_hook_token, app)"
  }.freeze

  test "声明式授权的控制器动作一个都不能漏" do
    DECLARATIVE.each do |controller_name, actions|
      controller = controller_name.constantize
      covered = controller.authorization_rules.flat_map { |rule| rule[:only] }.map(&:to_s)

      actions.each do |action|
        assert_includes covered, action,
          "#{controller_name}##{action} 没有声明授权规则——它现在对任何登录用户都开放"
      end
    end
  end

  test "行内授权的控制器里那句判断还在" do
    INLINE.each do |path, needle|
      source = Rails.root.join(path).read

      assert_includes source, needle,
        "#{path} 里的授权判断不见了——这个动作现在对任何登录用户都开放"
    end
  end
end
```

- [ ] **Step 2: 跑测试**

Run: `bin/rails test test/controllers/authorization_coverage_test.rb`
Expected: PASS（Task 4 已经把规则都挂上了）

- [ ] **Step 3: 验证这条测试真的会红**

临时把 `app/controllers/managed_apps_controller.rb` 第 2 行的 `authorize` 注释掉，
重跑上面那条命令。

Expected: FAIL —— `ManagedAppsController#new 没有声明授权规则`

**然后把注释去掉，重跑确认回到 PASS。** 一条从没红过的测试不算数。

- [ ] **Step 4: 提交**

```bash
git add test/controllers/authorization_coverage_test.rb
git commit -m "test: 钉住漏挂授权这类事故——它不会让任何别的测试变红

漏挂一个 before_action，那个动作照常工作，只是对谁都工作。整套测试仍然全绿。
清单是人写死的，表达的是意图而不是从代码反推的事实——反推的测试永远为真。"
```

---

### Task 6: 查看服务日志

**Files:**
- Create: `app/services/actions/logs.rb`
- Modify: `app/services/actions/base.rb:10-24`
- Modify: `app/views/managed_apps/show.html.erb`（操作区）
- Test: `test/services/actions/logs_test.rb`, `test/controllers/actions_controller_test.rb`

**Interfaces:**
- Consumes: Task 4 的 `ManagedAppPolicy#run?`。
- Produces: `Actions::Base.mutating?`（默认 `true`）、`Actions::Logs.mutating?`
  （`false`）、registry 中的 `"logs"` 键。

- [ ] **Step 1: 写失败的测试**

Create `test/services/actions/logs_test.rb`:

```ruby
require "test_helper"

class Actions::LogsTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog",
                              config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  test "在封闭动作集里" do
    assert_equal Actions::Logs, Actions::Base.find("logs")
  end

  test "不取部署锁——看日志不改变线上状态，不该跟一次正在进行的部署抢锁" do
    refute_predicate Actions::Logs, :requires_lock?
  end

  test "不是改变线上状态的动作" do
    refute_predicate Actions::Logs, :mutating?
  end

  test "其余动作默认都是改变线上状态的" do
    (Actions::Base.all - [ Actions::Logs ]).each do |klass|
      assert_predicate klass, :mutating?, "#{klass} 必须显式表态自己会不会改线上状态"
    end
  end

  test "命令是 kamal app logs，带行数上限" do
    assert_equal [ "app", "logs", "--lines", "200" ], Actions::Logs.new(@app).cli_args
  end
end
```

`test/controllers/actions_controller_test.rb` 追加：

```ruby
  test "ops 能看日志——这是它唯一能发起的动作" do
    sign_in_as users(:one)

    post managed_app_actions_path(@managed_app), params: { name: "logs" }

    log = AuditLog.where(managed_app: @managed_app).sole
    assert_equal "logs", log.action_name
    assert_redirected_to managed_app_action_path(@managed_app, log)
  end

  test "developer 不能看别人应用的日志" do
    sign_in_as users(:three)

    post managed_app_actions_path(@managed_app), params: { name: "logs" }

    assert_equal "没有权限执行该操作", flash[:alert]
  end
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `bin/rails test test/services/actions/logs_test.rb`
Expected: FAIL —— `未知动作："logs"`

- [ ] **Step 3: 实现**

Create `app/services/actions/logs.rb`:

```ruby
module Actions
  # 看日志。与其余五个动作的结构性差别只有一条：它不改变线上状态，因此
  # 不取部署锁——一次正在进行的部署不该因为有人在看日志而被挡住，反过来
  # 也一样。
  #
  # 仍然写审计：谁在什么时候看了哪个应用的日志，本身就是该留痕的事。
  class Logs < Base
    LINES = 200

    def self.requires_lock? = false
    def self.mutating?      = false

    def cli_args = [ "app", "logs", "--lines", LINES.to_s ]
  end
end
```

`app/services/actions/base.rb`：registry 加一行，并把 `required_role` 换成
`mutating?`：

```ruby
    def self.registry
      {
        "restart"      => Actions::Restart,
        "stop"         => Actions::Stop,
        "start"        => Actions::Start,
        "rollback"     => Actions::Rollback,
        "force_unlock" => Actions::ForceUnlock,
        "logs"         => Actions::Logs
      }
    end
```

```ruby
    # 动作只声明自己会不会改变线上状态；谁能执行由 ManagedAppPolicy#run? 解释。
    # 此前这里是 `def self.required_role = "operator"`——把角色字符串写在动作类
    # 上，等于让授权规则同时活在动作层和控制器层两个地方。
    def self.mutating? = true
```

（删掉原来的 `def self.required_role = "operator"` 那一行。）

- [ ] **Step 4: 跑测试**

Run: `bin/rails test test/services/actions/logs_test.rb test/controllers/actions_controller_test.rb`
Expected: PASS

- [ ] **Step 5: 在详情页加入口**

`app/views/managed_apps/show.html.erb`：日志按钮**不能**放在现有的
`allowed_to(:act, ...)` 操作区里——那个区块整体对 ops 不可见，而 ops 恰恰要能看
日志。在「各机器状态」那一节的 `section-head` 里，紧挨"立即刷新"按钮加：

```erb
    <%= allowed_to(:view_logs, @managed_app) do %>
      <%= button_to "查看日志", managed_app_actions_path(@managed_app),
                    method: :post, params: { name: "logs" }, class: "btn-quiet" %>
    <% end %>
```

- [ ] **Step 6: 全套 + rubocop**

Run: `bin/rails test && bin/rubocop`
Expected: 全绿

- [ ] **Step 7: 提交**

```bash
git add app/services/actions test/services/actions/logs_test.rb \
        app/views/managed_apps/show.html.erb test/controllers/actions_controller_test.rb
git commit -m "feat: 查看服务日志——此前面板没有任何地方能看应用的日志

ops 这个角色赖以成立的能力：它不能动线上，但要能看日志。

与其余五个动作唯一的结构性差别是不取部署锁——看日志不改变线上状态，
一次正在进行的部署不该因为有人在看日志而被挡住。仍然写审计。

按钮不放在操作区里：那个区块整体对 ops 不可见，而 ops 恰恰是最需要它的人。

顺带删掉 Actions::Base.required_role。角色字符串写在动作类上，就是把授权
规则埋回第二个地方；现在动作只声明 mutating?，由 policy 解释。"
```

---

### Task 7: 审计要记得下权限变更

**Files:**
- Create: `db/migrate/<timestamp>_allow_site_wide_audit_logs.rb`
- Modify: `app/models/audit_log.rb`
- Modify: `app/views/audit_logs/index.html.erb`
- Modify: `app/controllers/audit_logs_controller.rb`
- Test: `test/models/audit_log_test.rb`, `test/controllers/audit_logs_controller_test.rb`

**Interfaces:**
- Produces: `AuditLog.record_access!(user:, action_name:, target_user: nil, managed_app: nil)`
  —— 写一条【已完成】的记录（`result: "success"`，`finished_at` 当场写上）。
  Task 8 的人员管理全程用它。

- [ ] **Step 1: 写失败的测试**

`test/models/audit_log_test.rb` 追加：

```ruby
  test "权限变更记成不属于任何应用的一条审计" do
    log = AuditLog.record_access!(user: users(:two), action_name: "user.update_role",
                                  target_user: users(:one))

    assert_nil log.managed_app
    assert_equal users(:one), log.target_user
    assert_equal "success", log.result
    assert_not_nil log.finished_at, "权限变更是当场完成的，不该留在 pending"
  end

  test "成员变更同时带应用与被操作的人" do
    app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                             destination: "production")

    log = AuditLog.record_access!(user: users(:two), action_name: "app.add_member",
                                  target_user: users(:three), managed_app: app)

    assert_equal app, log.managed_app
    assert_equal users(:three), log.target_user
  end

  test "权限变更的记录一样删不掉" do
    log = AuditLog.record_access!(user: users(:two), action_name: "user.deactivate",
                                  target_user: users(:one))

    assert_raises(ActiveRecord::ReadOnlyRecord) { log.destroy }
  end
```

`test/controllers/audit_logs_controller_test.rb` 追加：

```ruby
  test "审计页能显示不属于任何应用的记录" do
    AuditLog.record_access!(user: users(:two), action_name: "user.deactivate",
                            target_user: users(:one))
    sign_in_as users(:two)

    get audit_logs_path

    assert_response :success
    assert_select "td", text: "user.deactivate"
    assert_select "td", text: /全站/
  end
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `bin/rails test test/models/audit_log_test.rb`
Expected: FAIL —— `undefined method 'record_access!'`

- [ ] **Step 3: 迁移**

Run: `bin/rails generate migration AllowSiteWideAuditLogs`

```ruby
class AllowSiteWideAuditLogs < ActiveRecord::Migration[8.1]
  def change
    # 「改某人的角色」「停用某人」不属于任何应用。分成两张表意味着让事后查
    # 事故的人自己在脑子里做归并排序——而「谁在部署前五分钟把自己加进了这个
    # 应用」恰恰是最需要两类事件挨在一起才看得出来的。
    change_column_null :audit_logs, :managed_app_id, true

    add_reference :audit_logs, :target_user, null: true,
                  foreign_key: { to_table: :users }
  end
end
```

- [ ] **Step 4: 改模型**

`app/models/audit_log.rb` 顶部两行关联改成：

```ruby
  belongs_to :user
  # 权限变更不属于任何应用（见迁移 AllowSiteWideAuditLogs）。
  belongs_to :managed_app, optional: true
  # 被操作的人。动作类审计没有这个值，人员类审计必有。
  belongs_to :target_user, class_name: "User", optional: true
```

在 `self.start!` 下面加：

```ruby
  # 权限变更是当场完成的，没有「执行中」这个阶段——所以它不像 start! 那样
  # 留一条 pending 等 finish! 来收尾，而是直接写成已完成。
  # managed_app 与 managed_app_id 两个都收：成员变更时调用方手上只有 id
  # （来自表单勾选），为了凑出记录再查一次应用是白花的一次查询。
  def self.record_access!(user:, action_name:, target_user: nil,
                          managed_app: nil, managed_app_id: nil)
    create!(user:, action_name:, target_user:, managed_app:, managed_app_id:, hosts: [],
            result: "success", created_at: Time.current, finished_at: Time.current)
  end
```

- [ ] **Step 5: 改审计页**

`app/controllers/audit_logs_controller.rb`：

```ruby
class AuditLogsController < ApplicationController
  def index
    @audit_logs = AuditLog.includes(:user, :managed_app, :target_user)
                          .order(created_at: :desc).limit(200)
  end
end
```

`app/views/audit_logs/index.html.erb` 的表头与"应用""目标版本"两列改成：

```erb
    <tr><th>时间</th><th>操作人</th><th>应用</th><th>动作</th><th>对象</th><th>结果</th><th>耗时</th></tr>
```

```erb
        <td><%= log.managed_app&.name || "全站" %></td>
        <td><%= log.action_name %></td>
        <td><%= log.target_user&.email_address || log.target_version || "—" %></td>
```

> 「目标版本」与「被操作的人」合成一列而不是各占一列：这两者永远不会同时出现
> （动作类审计有版本没有人，人员类审计有人没有版本），拆成两列会让表格里永远
> 有一半是空的。

- [ ] **Step 6: 跑测试**

Run: `bin/rails db:migrate && bin/rails test test/models/audit_log_test.rb test/controllers/audit_logs_controller_test.rb`
Expected: PASS

- [ ] **Step 7: 全套 + rubocop**

Run: `bin/rails test && bin/rubocop`
Expected: 全绿

- [ ] **Step 8: 提交**

```bash
git add db/migrate db/schema.rb app/models/audit_log.rb app/controllers/audit_logs_controller.rb \
        app/views/audit_logs/index.html.erb test/models/audit_log_test.rb \
        test/controllers/audit_logs_controller_test.rb
git commit -m "feat: 审计容得下权限变更——此前 managed_app_id 是 null:false，改角色这类事根本记不进去

权限变更是这个系统里最该留痕的一类事件，而它不属于任何应用。

不另起一张表：审计的价值在于一条时间线。分成两张表等于让事后查事故的人
自己做归并排序——而「谁在部署前五分钟把自己加进了这个应用」恰恰是最需要
两类事件挨在一起才看得出来的。

代价是审计页要处理 managed_app 为 nil 的行，明确接受。"
```

---

### Task 8: 人员管理界面

**Files:**
- Create: `app/controllers/users_controller.rb`
- Create: `app/views/users/index.html.erb`, `app/views/users/new.html.erb`,
  `app/views/users/edit.html.erb`
- Modify: `config/routes.rb`
- Modify: `app/views/layouts/application.html.erb`（导航加入口）
- Modify: `app/views/managed_apps/show.html.erb`（只读成员列表）
- Test: `test/controllers/users_controller_test.rb`

**Interfaces:**
- Consumes: Task 2 的 `deactivate!` / `reactivate!` / `User.active`、Task 3 的
  `AppMembership`、Task 4 的 `UserPolicy` 与 `authorize` 宏、Task 7 的
  `AuditLog.record_access!`。

- [ ] **Step 1: 写失败的测试**

Create `test/controllers/users_controller_test.rb`:

```ruby
require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @app = ManagedApp.create!(name: "blog",
                              config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
  end

  test "非 admin 一个动作都进不去" do
    [ users(:one), users(:three) ].each do |user|
      sign_in_as user

      get users_path
      assert_redirected_to root_path
      assert_equal "没有权限执行该操作", flash[:alert]
    end
  end

  test "未登录进不去" do
    get users_path
    assert_redirected_to new_session_path
  end

  test "admin 能看到人员列表" do
    sign_in_as users(:two)

    get users_path

    assert_response :success
    assert_select "td", text: "one@example.com"
  end

  # admin 不该知道别人的密码。新建用户只填邮箱与角色，密码由对方通过
  # 现有的找回密码流程自己设置。
  test "新建用户不设密码，发一封设置密码的邮件" do
    sign_in_as users(:two)

    assert_difference -> { User.count }, 1 do
      assert_enqueued_emails 1 do
        post users_path, params: { user: { email_address: "new@example.com", role: "developer" } }
      end
    end

    created = User.find_by(email_address: "new@example.com")
    assert_equal "developer", created.role
  end

  test "新建用户写审计" do
    sign_in_as users(:two)

    post users_path, params: { user: { email_address: "new@example.com", role: "ops" } }

    log = AuditLog.where(action_name: "user.create").sole
    assert_equal users(:two), log.user
    assert_equal "new@example.com", log.target_user.email_address
  end

  test "改角色写审计" do
    sign_in_as users(:two)

    patch user_path(users(:one)), params: { user: { role: "developer" } }

    assert_equal "developer", users(:one).reload.role
    assert_equal 1, AuditLog.where(action_name: "user.update_role").count
  end

  test "指派成员：勾选应用即成为该应用的成员，并写审计" do
    sign_in_as users(:two)

    patch user_path(users(:three)), params: { user: { role: "developer" },
                                              managed_app_ids: [ @app.id ] }

    assert_includes @app.reload.members, users(:three)
    log = AuditLog.where(action_name: "app.add_member").sole
    assert_equal @app, log.managed_app
    assert_equal users(:three), log.target_user
  end

  test "取消勾选即解除成员关系，并写审计" do
    AppMembership.create!(user: users(:three), managed_app: @app)
    sign_in_as users(:two)

    patch user_path(users(:three)), params: { user: { role: "developer" }, managed_app_ids: [] }

    refute_includes @app.reload.members, users(:three)
    assert_equal 1, AuditLog.where(action_name: "app.remove_member").count
  end

  test "停用与启用都写审计" do
    sign_in_as users(:two)

    post deactivate_user_path(users(:one))
    assert_predicate users(:one).reload, :deactivated?

    post reactivate_user_path(users(:one))
    refute_predicate users(:one).reload, :deactivated?

    assert_equal 1, AuditLog.where(action_name: "user.deactivate").count
    assert_equal 1, AuditLog.where(action_name: "user.reactivate").count
  end

  # 把最后一个 admin 停用或降级，面板就再也没有人能管人、管凭据、接入应用了
  # ——而恢复它需要去服务器上开 rails console。这是一个单向的死局，必须在
  # 发生之前拦住。
  test "不能停用最后一个 admin" do
    sign_in_as users(:two)

    post deactivate_user_path(users(:two))

    refute_predicate users(:two).reload, :deactivated?
    assert_equal "不能停用最后一个 admin", flash[:alert]
  end

  test "不能把最后一个 admin 降级" do
    sign_in_as users(:two)

    patch user_path(users(:two)), params: { user: { role: "ops" } }

    assert_equal "admin", users(:two).reload.role
    assert_equal "不能降级最后一个 admin", flash[:alert]
  end
end
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `bin/rails test test/controllers/users_controller_test.rb`
Expected: FAIL —— `undefined local variable or method 'users_path'`

- [ ] **Step 3: 路由**

`config/routes.rb`，在 `resources :audit_logs` 那一行下面加：

```ruby
  # 人员管理。没有 destroy：用户只能停用不能删除（audit_logs.user_id 带外键，
  # 而审计不可删除）。
  resources :users, only: [ :index, :new, :create, :edit, :update ] do
    post :deactivate, on: :member
    post :reactivate, on: :member
  end
```

- [ ] **Step 4: 控制器**

Create `app/controllers/users_controller.rb`:

```ruby
class UsersController < ApplicationController
  authorize :manage, on: User, only: %i[ index new create edit update deactivate reactivate ]

  before_action :set_user, only: %i[ edit update deactivate reactivate ]

  def index
    @users = User.order(:email_address)
  end

  def new
    @user = User.new(role: "ops")
  end

  # admin 不设置别人的密码：只填邮箱与角色，密码由对方通过现有的找回密码
  # 流程自己设置。新造一套「邀请」机制只是多一条要维护的认证路径，而认证
  # 路径是这个应用最不该有第二条的地方。
  def create
    @user = User.new(user_params)
    @user.password = SecureRandom.hex(32)

    if @user.save
      AuditLog.record_access!(user: Current.user, action_name: "user.create", target_user: @user)
      PasswordsMailer.reset(@user).deliver_later
      redirect_to users_path, notice: "已创建 #{@user.email_address}，设置密码的邮件已发出。"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @managed_apps = ManagedApp.order(:name)
  end

  def update
    new_role = user_params[:role]

    if demoting_last_admin?(new_role)
      return redirect_to edit_user_path(@user), alert: "不能降级最后一个 admin"
    end

    role_changed = new_role.present? && new_role != @user.role

    if @user.update(user_params)
      AuditLog.record_access!(user: Current.user, action_name: "user.update_role",
                              target_user: @user) if role_changed
      sync_memberships
      redirect_to users_path, notice: "已更新 #{@user.email_address}"
    else
      @managed_apps = ManagedApp.order(:name)
      render :edit, status: :unprocessable_entity
    end
  end

  def deactivate
    if last_admin?(@user)
      return redirect_to users_path, alert: "不能停用最后一个 admin"
    end

    @user.deactivate!
    AuditLog.record_access!(user: Current.user, action_name: "user.deactivate", target_user: @user)
    redirect_to users_path, notice: "已停用 #{@user.email_address}"
  end

  def reactivate
    @user.reactivate!
    AuditLog.record_access!(user: Current.user, action_name: "user.reactivate", target_user: @user)
    redirect_to users_path, notice: "已启用 #{@user.email_address}"
  end

  private
    def set_user = @user = User.find(params[:id])

    def user_params = params.expect(user: [ :email_address, :role ])

    # 成员关系的写入口只有这一处（设计 11 第 5.2 节）：应用详情页只读展示。
    # 两处都能编辑意味着两套表单、两条写路径，以及它们迟早不一致。
    def sync_memberships
      wanted = Array(params[:managed_app_ids]).map(&:to_i)
      current = @user.managed_app_ids

      (wanted - current).each do |app_id|
        AppMembership.create!(user: @user, managed_app_id: app_id)
        AuditLog.record_access!(user: Current.user, action_name: "app.add_member",
                                target_user: @user, managed_app_id: app_id)
      end

      (current - wanted).each do |app_id|
        AppMembership.where(user: @user, managed_app_id: app_id).destroy_all
        AuditLog.record_access!(user: Current.user, action_name: "app.remove_member",
                                target_user: @user, managed_app_id: app_id)
      end
    end

    # 面板一旦没有 admin，就再也没有人能管人、管凭据、接入应用——恢复它需要
    # 去服务器上开 rails console。这是单向的死局，必须在发生之前拦住。
    def last_admin?(user)
      user.admin? && User.active.where(role: "admin").where.not(id: user.id).none?
    end

    def demoting_last_admin?(new_role)
      new_role.present? && new_role != "admin" && last_admin?(@user)
    end
end
```

> `sync_memberships` 传的是 `managed_app_id:`——Task 7 的 `record_access!` 已经
> 同时收 `managed_app:` 与 `managed_app_id:` 两个参数，正是为了这里：调用方手上
> 只有表单勾选来的 id，为了凑出记录再查一次应用是白花的一次查询。

- [ ] **Step 5: 三个视图**

Create `app/views/users/index.html.erb`:

```erb
<div class="page-head">
  <div class="page-title">
    <h1>人员</h1>
    <p class="page-sub">谁能登录这个面板、各自是什么角色、能动哪几个应用。</p>
  </div>
  <%= link_to "添加成员", new_user_path, class: "btn-primary" %>
</div>

<section class="section">
  <div class="panel">
    <table>
      <thead>
        <tr><th>邮箱</th><th>角色</th><th>名下应用</th><th>状态</th><th></th></tr>
      </thead>
      <tbody>
        <% @users.each do |user| %>
          <tr>
            <td><%= link_to user.email_address, edit_user_path(user) %></td>
            <td><%= t("roles.#{user.role}") %></td>
            <td>
              <%# admin 与 ops 的权限来自全站角色，不靠成员表——这里如实说明，
                  免得有人以为给 admin 加成员才是完整配置。 %>
              <% if user.developer? %>
                <%= user.managed_apps.map(&:name).join("、").presence || "（还没有）" %>
              <% else %>
                全站
              <% end %>
            </td>
            <td><%= user.deactivated? ? "已停用" : "正常" %></td>
            <td>
              <% if user.deactivated? %>
                <%= button_to "启用", reactivate_user_path(user), method: :post, class: "btn-quiet" %>
              <% else %>
                <%= button_to "停用", deactivate_user_path(user), method: :post, class: "btn-quiet" %>
              <% end %>
            </td>
          </tr>
        <% end %>
      </tbody>
    </table>
  </div>
</section>
```

Create `app/views/users/new.html.erb`:

```erb
<div class="page-head">
  <div class="page-title">
    <h1>添加成员</h1>
    <p class="page-sub">只填邮箱与角色。密码由对方通过邮件里的链接自己设置——你不该知道别人的密码。</p>
  </div>
</div>

<section class="section">
  <div class="panel">
    <%= form_with model: @user do |form| %>
      <%= render "shared/errors", record: @user %>

      <div>
        <%= form.label :email_address, "邮箱地址" %>
        <%= form.email_field :email_address, autocomplete: "off" %>
      </div>

      <div>
        <%= form.label :role, "角色" %>
        <%= form.select :role, User::ROLES.map { |r| [ t("roles.#{r}"), r ] } %>
        <p class="hint">
          admin 管全站；developer 只能动名下的应用；ops 全站只读，外加看日志。
        </p>
      </div>

      <%= form.submit "创建并发送设置密码邮件", class: "btn-primary" %>
    <% end %>
  </div>
</section>
```

> 若仓库里没有 `shared/_errors` 这个 partial，照搬 `managed_apps/new.html.erb`
> 里现有的错误展示写法，不要新造。

Create `app/views/users/edit.html.erb`:

```erb
<div class="page-head">
  <div class="page-title">
    <h1><%= @user.email_address %></h1>
    <p class="page-sub">改角色，或者指派他能动哪几个应用。</p>
  </div>
</div>

<section class="section">
  <div class="panel">
    <%= form_with model: @user, method: :patch do |form| %>
      <div>
        <%= form.label :role, "角色" %>
        <%= form.select :role, User::ROLES.map { |r| [ t("roles.#{r}"), r ] } %>
      </div>

      <fieldset>
        <legend>名下应用</legend>
        <p class="hint">
          只对 developer 生效。admin 与 ops 的权限来自全站角色，勾选对他们没有任何作用。
        </p>
        <% @managed_apps.each do |app| %>
          <label>
            <%= check_box_tag "managed_app_ids[]", app.id,
                              @user.managed_app_ids.include?(app.id), id: "app_#{app.id}" %>
            <%= app.name %>
          </label>
        <% end %>
        <%# 全不勾时浏览器不会提交任何 managed_app_ids，控制器就看不出「清空」
            与「没动过」的区别。这个隐藏字段保证参数一定存在。 %>
        <%= hidden_field_tag "managed_app_ids[]", "" %>
      </fieldset>

      <%= form.submit "保存", class: "btn-primary" %>
    <% end %>
  </div>
</section>
```

> 隐藏字段会带来一个空字符串，`Array(params[:managed_app_ids]).map(&:to_i)` 会把
> 它变成 `0`，而不存在 id 为 0 的应用——`(wanted - current)` 里的 0 会让
> `AppMembership.create!` 抛外键错误。**在 `sync_memberships` 里把它滤掉：**
> `wanted = Array(params[:managed_app_ids]).map(&:to_i).reject(&:zero?)`。

- [ ] **Step 6: 角色译名与导航入口**

`config/locales/zh-CN.yml` 顶层加：

```yaml
  roles:
    admin: 超管
    developer: 开发者
    ops: 运维
```

`app/views/layouts/application.html.erb` 导航里，在"审计"之后加：

```erb
          <%= allowed_to(:manage, User) do %>
            <%= link_to "人员", users_path, class: ("is-current" if current_page?(users_path)) %>
          <% end %>
```

- [ ] **Step 7: 应用详情页的只读成员列表**

`app/views/managed_apps/show.html.erb`，在「基本信息」那个 `panel` 的 `dl` 里加一行：

```erb
        <dt>能动这个应用的人</dt>
        <dd>
          <%# 只读。成员关系的写入口只有人员页一处（设计 11 第 5.2 节）。 %>
          <%= @managed_app.members.map(&:email_address).join("、").presence || "（只有 admin）" %>
        </dd>
```

- [ ] **Step 8: 跑测试**

Run: `bin/rails test test/controllers/users_controller_test.rb`
Expected: PASS

- [ ] **Step 9: 全套 + rubocop**

Run: `bin/rails test && bin/rubocop`
Expected: 全绿

- [ ] **Step 10: 提交**

```bash
git add app/controllers/users_controller.rb app/views/users app/models/audit_log.rb \
        config/routes.rb config/locales/zh-CN.yml app/views/layouts/application.html.erb \
        app/views/managed_apps/show.html.erb test/controllers/users_controller_test.rb
git commit -m "feat: 人员管理——此前加人只能去服务器上开 rails console

admin 不设置别人的密码：只填邮箱与角色，密码由对方通过现有的找回密码流程
自己设置。新造一套邀请机制只是多一条要维护的认证路径，而认证路径是这个应用
最不该有第二条的地方。

成员关系的写入口只有这一处，应用详情页只读展示。两处都能编辑意味着两套表单、
两条写路径，以及它们迟早不一致。

拦住「停用/降级最后一个 admin」：那之后再没有人能管人、管凭据、接入应用，
恢复它要去服务器上开 console。这是单向的死局。

每一次权限变更都写审计。"
```

---

## 收尾

- [ ] **跑一遍完整验证**

Run: `bin/rails test && bin/rubocop && bin/brakeman --no-pager`
Expected: 测试全绿、rubocop 无告警、brakeman 无新增告警。

- [ ] **人工验一遍三档角色**

启动 `bin/rails server`，用三个账号各登录一次，确认：

1. ops 看得到全部应用，看得到"查看日志"按钮，看不到重启/启动/强制解锁。
2. developer 在名下应用上看得到操作按钮，在别人的应用上看不到；直接 POST
   `/apps/<别人的应用>/actions` 会被拒并且**不留审计**。
3. admin 看得到"人员"导航，另外两档看不到。

- [ ] **合回 main**

```bash
git checkout main
git merge --no-ff --no-commit 11-roles-and-people-impl
git commit --no-edit
```
