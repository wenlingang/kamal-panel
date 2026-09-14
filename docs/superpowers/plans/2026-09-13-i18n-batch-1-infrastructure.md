# 双语基础设施（设计 13 第 1 批）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立整套语言切换机制与两条防回退的测试守卫，界面文案一行都不翻。

**Architecture:** `users.locale` 存用户偏好；`ApplicationController` 用
`around_action` 按「用户偏好 → `Accept-Language` → 默认」三级决定 `I18n.locale`，
用 `I18n.with_locale` 保证请求结束后还原；切换走一个只改自己的
`LocalesController`，与 admin 独占的人员管理彻底分开。英文界面在本批【不暴露】
——`SELECTABLE_LOCALES` 先只含中文，第 5 批合完再放开。

**Tech Stack:** Rails 8.1、Minitest、`rails-i18n`（已在 Gemfile）、
`config.i18n.available_locales = [ :"zh-CN", :en ]`（已配好）。

**Spec:** `docs/superpowers/specs/2026-09-13-kamal-panel-i18n-design.md`

## Global Constraints

- 默认语言 `:"zh-CN"`，可用语言恰好 `[ :"zh-CN", :en ]`（`config/application.rb:31-33`），本批不新增第三种。
- `config.i18n.fallbacks = [ :en ]` 保持不变。它的后果见 Task 4：缺中文译文会静默退回英文，所以「漏翻」的守卫必须在 `:en` 下跑才有效。
- locale 不进 URL，不加 `default_url_options`。
- 本批不翻译任何界面文案。新写的用户可见文案（只有切换器的两个标签）直接用字面量，第 4 批再收。
- 注释与提交信息用中文，风格对齐仓库既有代码：解释【为什么】与【此前坏在哪】，不复述代码在做什么。
- 每个 Task 结束时 `bin/rubocop` 必须零 offense。
- **spec §5（邮件跟收件人偏好）刻意不在本批**：mailer 模板要到第 4 批才翻，
  在那之前给 mailer 包一层 `I18n.with_locale` 没有任何可观测的效果，也就写不出
  一条会失败的测试。它和 mailer 模板一起做，记在第 4 批。这是本批唯一一处
  没有覆盖到的 spec 章节，写在这里是为了它别从缝里掉下去。

---

### Task 1: `users.locale` 列与校验

**Files:**
- Create: `db/migrate/20260913140000_add_locale_to_users.rb`
- Modify: `app/models/user.rb`
- Test: `test/models/user_test.rb`

**Interfaces:**
- Produces: `User#locale`（`String` 或 `nil`）；`User::SELECTABLE_LOCALES`（`Array<String>`，本批为 `%w[zh-CN]`）。Task 2 读 `user.locale`，Task 3 读 `SELECTABLE_LOCALES`。

- [ ] **Step 1: 写失败的测试**

在 `test/models/user_test.rb` 里，插到 `test "默认角色是 ops" do` 这一行之前：

```ruby
  # locale 可空：没表达过偏好的人跟默认走，而不是在建号时被迫选一次语言。
  test "没设过 locale 的用户 locale 是 nil" do
    user = User.create!(email_address: "nolocale@example.com", password: "secret123456")
    assert_nil user.locale
  end

  test "接受可用语言" do
    user = User.new(email_address: "l@example.com", password: "secret123456", locale: "en")
    assert_predicate user, :valid?
  end

  # 校验按 available_locales 而不是 SELECTABLE_LOCALES：后者只管「切换器上
  # 让不让选」，是个会随批次变的展示决定；数据库里能不能存是另一回事，
  # 不该因为界面暂时不暴露英文，就让已经存着 en 的行变成非法。
  test "拒绝不可用的语言" do
    user = User.new(email_address: "l2@example.com", password: "secret123456", locale: "fr")
    refute_predicate user, :valid?
  end

  test "SELECTABLE_LOCALES 都在 available_locales 里" do
    User::SELECTABLE_LOCALES.each do |locale|
      assert_includes I18n.available_locales.map(&:to_s), locale
    end
  end
```

- [ ] **Step 2: 跑测试确认它红**

Run: `bin/rails test test/models/user_test.rb`
Expected: FAIL，`ActiveModel::UnknownAttributeError: unknown attribute 'locale' for User`

- [ ] **Step 3: 写迁移**

Create `db/migrate/20260913140000_add_locale_to_users.rb`:

```ruby
class AddLocaleToUsers < ActiveRecord::Migration[8.1]
  # 可空。NULL 表示「没表达过偏好」，跟默认语言走——这和「明确选了中文」
  # 是两件事：将来默认语言若改动，前者应该跟着变，后者不该。
  def change
    add_column :users, :locale, :string
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 4: 加校验与常量**

在 `app/models/user.rb` 里，紧跟在 `validates :nickname, ...` 那一行之后加：

```ruby
  # 切换器上让用户选哪几种语言。它比 available_locales 小是【刻意】的：
  # 英文界面要等设计 13 的五批全部翻完才暴露，在那之前机制可测、入口不给。
  # 第 5 批把 "en" 加进来，这个常量就是那次改动的唯一落点。
  SELECTABLE_LOCALES = %w[zh-CN].freeze

  # 按 available_locales 校验，不是按 SELECTABLE_LOCALES——见 UserTest 里
  # 「拒绝不可用的语言」旁边那段注释。
  validates :locale, inclusion: { in: -> (_) { I18n.available_locales.map(&:to_s) } },
                     allow_nil: true
```

- [ ] **Step 5: 跑测试确认它绿**

Run: `bin/rails test test/models/user_test.rb`
Expected: PASS，26 runs 左右，0 failures

- [ ] **Step 6: 跑 rubocop 并提交**

```bash
bin/rubocop app/models/user.rb db/migrate/20260913140000_add_locale_to_users.rb test/models/user_test.rb
git add app/models/user.rb db/migrate/20260913140000_add_locale_to_users.rb db/schema.rb test/models/user_test.rb
git commit -m "feat: users 加 locale 列

可空：NULL 表示「没表达过偏好」，跟默认语言走——这和「明确选了中文」是两
件事，将来默认语言若改动，前者应该跟着变，后者不该。

校验按 available_locales 而不是 SELECTABLE_LOCALES。后者只管切换器上让不让
选，是个会随批次变的展示决定；数据库里能不能存是另一回事，不该因为界面暂时
不暴露英文，就让已经存着 en 的行变成非法。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: 请求级 locale 解析

**Files:**
- Create: `app/controllers/concerns/localization.rb`
- Modify: `app/controllers/application_controller.rb:2`（`include Authentication` 那一行下面）
- Test: `test/controllers/localization_test.rb`

**Interfaces:**
- Consumes: Task 1 的 `User#locale`。
- Produces: `Localization` concern（`around_action :switch_locale`）与**模块函数**
  `Localization.match_accept_language(header) → Symbol | nil`。后者是纯函数，
  不碰请求、不碰 `Current`，因此可以直接喂字符串单测——这是它被抽出来的理由：
  埋在控制器私有方法里的话，只能靠"渲染一个页面看它变没变"来间接验证，而
  `around_action` 会在请求结束时还原 `I18n.locale`，那种间接验证根本立不住。

- [ ] **Step 1: 写失败的测试**

Create `test/controllers/localization_test.rb`:

```ruby
require "test_helper"

# locale 的三级来源：用户偏好 → Accept-Language → 默认。
class LocalizationTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:two)
    # 页面上没有任何地方直接印出当前 locale，所以集成测试断言的是一条【确实
    # 会随 locale 变】的既有文案：审计动作名（设计 12 建的 audit.actions.*）。
    # 断言用户真正看到的东西，而不是内省 I18n.locale——后者在请求结束时已经
    # 被 around_action 还原，请求之后再去读它，读到的永远是默认值。
    AuditLog.record_access!(user: @admin, action_name: "user.deactivate",
                            target_user: users(:one))
  end

  test "登录用户的偏好决定语言" do
    @admin.update!(locale: "en")
    sign_in_as @admin

    get audit_logs_path

    assert_select "td", text: "Deactivate member"
  end

  # 偏好为空时落到第二级。这一条同时证明了请求头确实被读到了——它是
  # match_accept_language 那组单测之外，唯一能证明"接线接对了"的测试。
  test "没设偏好的登录用户跟 Accept-Language 走" do
    @admin.update!(locale: nil)
    sign_in_as @admin

    get audit_logs_path, headers: { "HTTP_ACCEPT_LANGUAGE" => "en-US,en;q=0.9" }

    assert_select "td", text: "Deactivate member"
  end

  test "偏好优先于 Accept-Language" do
    @admin.update!(locale: "zh-CN")
    sign_in_as @admin

    get audit_logs_path, headers: { "HTTP_ACCEPT_LANGUAGE" => "en-US,en;q=0.9" }

    assert_select "td", text: "停用成员"
  end

  test "两级都拿不到时用默认语言" do
    @admin.update!(locale: nil)
    sign_in_as @admin

    get audit_logs_path

    assert_select "td", text: "停用成员"
  end

  # I18n.locale 是线程级全局状态。请求结束不还原的话，同一个线程服务下一个
  # 请求时会带着上一个用户的语言——这种串味在生产里极难复现，必须有测试盯着。
  test "请求结束后 I18n.locale 已还原" do
    @admin.update!(locale: "en")
    sign_in_as @admin

    get audit_logs_path

    assert_equal I18n.default_locale, I18n.locale
  end
end

# 纯函数，单独测。不需要请求、不需要登录，所以可以把各种畸形头部穷举干净。
class LocalizationAcceptLanguageTest < ActiveSupport::TestCase
  def match(header) = Localization.match_accept_language(header)

  test "认出英文" do
    assert_equal :en, match("en-US,en;q=0.9")
  end

  test "任何 zh 变体都算简体中文" do
    assert_equal :"zh-CN", match("zh-CN,zh;q=0.9")
    assert_equal :"zh-CN", match("zh-TW")
    assert_equal :"zh-CN", match("zh")
  end

  test "取第一个认得出的标签，不做权重协商" do
    assert_equal :en, match("fr-FR,fr;q=0.9,en;q=0.8")
  end

  test "一个都认不出时返回 nil，交给调用方回落" do
    assert_nil match("fr-FR,fr;q=0.9")
  end

  test "空头部返回 nil" do
    assert_nil match(nil)
    assert_nil match("")
  end
end
```

- [ ] **Step 2: 跑测试确认它红**

Run: `bin/rails test test/controllers/localization_test.rb`
Expected: FAIL。`LocalizationAcceptLanguageTest` 报
`NameError: uninitialized constant Localization`；`LocalizationTest` 里两条断言
英文的用例报找不到 `Deactivate member`（当前无论如何都渲染中文）。

- [ ] **Step 3: 写 concern**

Create `app/controllers/concerns/localization.rb`:

```ruby
# 每个请求决定一次界面语言。
#
# 用 around_action 而不是 before_action：I18n.locale 是线程级全局状态，
# 请求结束必须还原，否则同一个线程服务下一个请求时会带着上一个用户的语言。
# I18n.with_locale 自带这个还原，包括抛异常那条路径。
module Localization
  extend ActiveSupport::Concern

  included do
    around_action :switch_locale
  end

  # 只做粗匹配：取头部里第一个认得出的语言标签，zh 开头的一律算 zh-CN，
  # 其余看是否恰好在 available_locales 里。不实现 RFC 4647 的权重协商
  # ——两种语言不值得，而一个只有两个分支的判断在测试里穷尽得完。
  #
  # 做成模块函数而不是控制器的私有方法，是为了能直接喂字符串单测：埋在控制器
  # 里的话只能靠"渲染一个页面看它变没变"来间接验证，而 around_action 会在
  # 请求结束时还原 I18n.locale，那种间接验证立不住。
  def self.match_accept_language(header)
    return nil if header.blank?

    available = I18n.available_locales.map(&:to_s)

    header.scan(/[A-Za-z-]{2,}/).each do |tag|
      return :"zh-CN" if tag.downcase.start_with?("zh")
      return tag.to_sym if available.include?(tag)
    end

    nil
  end

  private
    def switch_locale(&) = I18n.with_locale(resolved_locale, &)

    # 三级，从高到低：用户自己的偏好 → 浏览器 → 默认。
    # 未登录页面（登录页、设置密码页）只有第二级可问。
    def resolved_locale
      Current.user&.locale.presence&.to_sym ||
        Localization.match_accept_language(request.env["HTTP_ACCEPT_LANGUAGE"]) ||
        I18n.default_locale
    end
end
```

- [ ] **Step 4: 挂到 ApplicationController**

在 `app/controllers/application_controller.rb` 里，把

```ruby
  include Authentication
```

改成

```ruby
  include Authentication
  # 必须在 Authentication 之后：resolved_locale 要读 Current.user，而
  # Current.session 是 Authentication 的 before_action 设上去的。
  include Localization
```

- [ ] **Step 5: 跑测试确认它绿**

Run: `bin/rails test test/controllers/localization_test.rb`
Expected: PASS，10 runs，0 failures

- [ ] **Step 6: 跑全量确认没碰坏别的**

Run: `bin/rails test`
Expected: PASS，0 failures。（当前基线 510 runs；Task 1 加 4 条、本 Task 加 10 条。）

- [ ] **Step 7: 跑 rubocop 并提交**

```bash
bin/rubocop app/controllers test/controllers/localization_test.rb
git add app/controllers/concerns/localization.rb app/controllers/application_controller.rb test/controllers/localization_test.rb
git commit -m "feat: 每个请求按用户偏好决定界面语言

三级来源：users.locale → Accept-Language → 默认。未登录页面没有「当前用户」，
只有第二级可问。

用 around_action 而不是 before_action：I18n.locale 是线程级全局状态，请求结束
不还原的话，同一个线程服务下一个请求时会带着上一个用户的语言。这种串味在生产
里极难复现，所以有一条测试专门盯着请求结束后 I18n.locale 已还原。

Accept-Language 的解析做成模块函数而不是控制器私有方法，是为了能直接喂字符串
单测。埋在控制器里的话只能靠"渲染一个页面看它变没变"来间接验证，而
around_action 恰恰会在请求结束时把 I18n.locale 还原——那种间接验证立不住。
它只做粗匹配，不实现 RFC 4647 的权重协商：两种语言不值得，而一个只有两个分支
的判断在测试里是穷尽得完的。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: 切换入口

**Files:**
- Create: `app/controllers/locales_controller.rb`
- Modify: `config/routes.rb`（`resource :session` 那一行下面）
- Modify: `app/views/layouts/application.html.erb:53`（`.chrome-user` 那个 div 里）
- Modify: `app/assets/stylesheets/application.css`（`.chrome-user form` 规则之后）
- Test: `test/controllers/locales_controller_test.rb`

**Interfaces:**
- Consumes: Task 1 的 `User::SELECTABLE_LOCALES`；Task 2 已经保证请求期间 `I18n.locale` 正确。
- Produces: 路由 `locale_path`（`PATCH`）。

- [ ] **Step 1: 写失败的测试**

Create `test/controllers/locales_controller_test.rb`:

```ruby
require "test_helper"

# 改自己的界面语言【不是】人员管理。人员管理 admin 独占，语言人人都得能改
# ——把它当成 UsersController#update 的一个字段的话，developer 和 ops 就永远
# 换不了自己的语言，而他们恰恰是人数最多的那部分用户。
class LocalesControllerTest < ActionDispatch::IntegrationTest
  test "任何已登录角色都能改自己的语言" do
    [ users(:one), users(:two), users(:three) ].each do |user|
      sign_in_as user

      patch locale_path, params: { locale: "en" }

      assert_equal "en", user.reload.locale
      sign_out
    end
  end

  test "未登录改不了" do
    patch locale_path, params: { locale: "en" }

    assert_redirected_to new_session_path
  end

  # 没有「帮别人换语言」这条路径：控制器根本不收 user id，所以这里断言的是
  # 多给一个 id 参数也影响不到别人。
  test "只改得了自己" do
    sign_in_as users(:one)

    patch locale_path, params: { locale: "en", user_id: users(:two).id, id: users(:two).id }

    assert_equal "en", users(:one).reload.locale
    assert_nil users(:two).reload.locale
  end

  test "不可用的语言被拒，原来的偏好不变" do
    users(:one).update!(locale: "zh-CN")
    sign_in_as users(:one)

    patch locale_path, params: { locale: "fr" }

    assert_equal "zh-CN", users(:one).reload.locale
  end

  test "改完回到来的那一页" do
    sign_in_as users(:one)

    patch locale_path, params: { locale: "en" }, headers: { "HTTP_REFERER" => users_path }

    assert_redirected_to users_path
  end

  # SELECTABLE_LOCALES 本批只有中文一项，切换器因此不渲染——机制可测、入口
  # 不暴露，直到设计 13 的五批全部翻完（见 spec §7）。
  test "只有一种可选语言时页头不出现切换器" do
    sign_in_as users(:one)

    get users_path

    assert_select ".chrome-locale", count: 0
  end

  test "有多种可选语言时页头出现切换器" do
    User.stub_const(:SELECTABLE_LOCALES, %w[zh-CN en]) do
      sign_in_as users(:one)

      get users_path

      assert_select ".chrome-locale a", count: 2
    end
  end
end
```

- [ ] **Step 2: 跑测试确认它红**

Run: `bin/rails test test/controllers/locales_controller_test.rb`
Expected: FAIL，`NameError: undefined local variable or method 'locale_path'`

- [ ] **Step 3: 加路由**

在 `config/routes.rb` 里，把

```ruby
  resource :session
```

改成

```ruby
  resource :session
  # 改自己的界面语言。刻意【不】放在 resources :users 下面：那一组是 admin
  # 独占的，而换语言人人都得能做（见 LocalesControllerTest 顶部的注释）。
  resource :locale, only: [ :update ]
```

- [ ] **Step 4: 写控制器**

Create `app/controllers/locales_controller.rb`:

```ruby
class LocalesController < ApplicationController
  # 不收 user id：没有「帮别人换语言」这条路径，也就没有需要授权的对象。
  # 这也是它没有 policy 的原因——能改的永远只有自己。
  def update
    Current.user.update(locale: params[:locale])

    # 换语言不该把人从当前页面弹走。referer 不可信但这里无所谓：它只决定
    # 跳回哪一页，fallback 到首页，拿不到或是外站都不会出事。
    redirect_back fallback_location: root_path
  end
end
```

- [ ] **Step 5: 加页头切换器**

在 `app/views/layouts/application.html.erb` 里，把

```erb
        <div class="chrome-user">
          <span><%= Current.user&.display_name %></span>
```

改成

```erb
        <div class="chrome-user">
          <%# 只有一种可选语言时整个不渲染：给一个只有一个选项的切换器，等于
              让人以为还有别的可选。第 5 批把 en 加进 SELECTABLE_LOCALES，
              这里自动出现。 %>
          <% if User::SELECTABLE_LOCALES.many? %>
            <span class="chrome-locale">
              <% User::SELECTABLE_LOCALES.each do |locale| %>
                <%= link_to locale_label(locale), locale_path(locale: locale),
                            data: { turbo_method: :patch },
                            class: ("is-current" if I18n.locale.to_s == locale) %>
              <% end %>
            </span>
          <% end %>
          <span><%= Current.user&.display_name %></span>
```

在 `app/helpers/application_helper.rb` 的 `user_identity` 方法之后、`audit_action_label` 之前加：

```ruby
  # 切换器上的标签。刻意不走 t()：这两个标签在【任何】语言下都该显示成
  # 「中 / EN」——一个正在看英文界面、想切回中文的人，需要认出那个字，
  # 而不是读懂一句英文说明。
  LOCALE_LABELS = { "zh-CN" => "中", "en" => "EN" }.freeze

  def locale_label(locale) = LOCALE_LABELS.fetch(locale, locale)
```

- [ ] **Step 6: 加样式**

在 `app/assets/stylesheets/application.css` 里，紧跟在

```css
.chrome-user form,
.chrome-user form div {
  margin: 0;
}
```

之后加：

```css
.chrome-locale {
  display: flex;
  gap: 0.375rem;
}

.chrome-locale a {
  color: var(--ink-muted);
  text-decoration: none;
}

.chrome-locale a.is-current {
  color: var(--ink);
  font-weight: 600;
}
```

- [ ] **Step 7: 跑测试确认它绿**

Run: `bin/rails test test/controllers/locales_controller_test.rb`
Expected: PASS，7 runs，0 failures

若「有多种可选语言时页头出现切换器」报 `undefined method 'stub_const'`，说明这个
Rails 版本的 `ActiveSupport::Testing::ConstantStubbing` 没有被引入。改成手工存取：

```ruby
  test "有多种可选语言时页头出现切换器" do
    original = User::SELECTABLE_LOCALES
    User.send(:remove_const, :SELECTABLE_LOCALES)
    User.const_set(:SELECTABLE_LOCALES, %w[zh-CN en])

    sign_in_as users(:one)
    get users_path
    assert_select ".chrome-locale a", count: 2
  ensure
    User.send(:remove_const, :SELECTABLE_LOCALES)
    User.const_set(:SELECTABLE_LOCALES, original)
  end
```

- [ ] **Step 8: 跑全量并提交**

```bash
bin/rails test
bin/rubocop app config test
git add app/controllers/locales_controller.rb app/views/layouts/application.html.erb \
        app/helpers/application_helper.rb app/assets/stylesheets/application.css \
        config/routes.rb test/controllers/locales_controller_test.rb
git commit -m "feat: 页头可以切换界面语言

改自己的界面语言【不是】人员管理。人员管理 admin 独占，语言人人都得能改——
把它当成 UsersController#update 的一个字段的话，developer 和 ops 就永远换不了
自己的语言，而他们恰恰是人数最多的那部分用户。所以走独立的 LocalesController，
它根本不收 user id：没有「帮别人换语言」这条路径，也就没有需要授权的对象。

切换器在只有一种可选语言时整个不渲染。本批 SELECTABLE_LOCALES 只有中文，机制
可测、入口不暴露；设计 13 五批全部翻完后把 en 加进那个常量，页头自动出现。

切换器标签刻意不走 t()：「中 / EN」在任何语言下都该是这两个字——一个正在看
英文界面、想切回中文的人，需要认出那个字，而不是读懂一句英文说明。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: 守卫其一 —— 漏翻就让测试红

**Files:**
- Modify: `config/environments/test.rb:46`
- Create: `test/integration/locale_smoke_test.rb`

**Interfaces:**
- Consumes: Task 2 的 locale 解析、Task 1 的 `User#locale`。
- Produces: 无代码接口。产出的是一条约束：此后任何 `t()` 查不到 key 都会让测试失败。

- [ ] **Step 1: 打开 raise_on_missing_translations**

在 `config/environments/test.rb` 里，把

```ruby
  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true
```

改成

```ruby
  # 漏翻就红，而不是在页面上渲染成 "translation missing"。
  #
  # 注意它和 config.i18n.fallbacks = [ :en ] 的配合：缺中文译文时 i18n 会
  # 静默退回英文，【不会】触发这个 raise。所以这一条只拦得住「中英都缺」，
  # 而「有中文没英文」要靠 LocaleSmokeTest 在 :en 下真的渲染一遍才抓得到。
  # 两者缺一不可。
  config.i18n.raise_on_missing_translations = true
```

- [ ] **Step 2: 跑全量，确认打开它没有立刻弄红既有测试**

Run: `bin/rails test`
Expected: PASS，0 failures。

（现有的 `t()` 调用只有 `roles.*`、`audit.*`、`passwords_mailer.*`，中英译文在设计 12 里都已写全，所以这一步应该直接绿。如果红了，说明发现了一个真的漏翻——把它补上，不要把这个配置关回去。）

- [ ] **Step 3: 写英文冒烟测试**

Create `test/integration/locale_smoke_test.rb`:

```ruby
require "test_helper"

# raise_on_missing_translations 配合 fallbacks = [ :en ] 只拦得住「中英都缺」：
# 缺中文时 i18n 会静默退回英文。所以「有中文没英文」这一类漏翻，只有在 :en
# 下真的把页面渲染一遍才抓得到——这个文件就是干这个的。
#
# 刻意【不】断言页面内容，只断言渲染不抛异常。断言内容等于把每一条文案在两种
# 语言下各写一遍，测试数翻倍而信息量不变；而漏翻会让 t() 直接抛出来，
# assert_response :success 就够了。
class LocaleSmokeTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:two)
    @admin.update!(locale: "en")
    @managed_app = ManagedApp.create!(name: "blog",
                                      config_yaml: file_fixture("simple_deploy.yml").read,
                                      destination: "production")
    @credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key,
                                     name: "生产集群")
    AuditLog.record_access!(user: @admin, action_name: "user.deactivate",
                            target_user: users(:one))
  end

  test "英文下每个已登录页面都渲染得出来" do
    sign_in_as @admin

    [
      root_path,
      managed_apps_path, new_managed_app_path,
      managed_app_path(@managed_app), edit_managed_app_path(@managed_app),
      audit_logs_path,
      users_path, new_user_path, edit_user_path(users(:one)),
      credentials_path, new_credential_path, edit_credential_path(@credential),
      new_registry_credential_path
    ].each do |path|
      get path
      assert_response :success, "#{path} 在 :en 下渲染失败"
    end
  end

  test "英文下未登录页面也渲染得出来" do
    get new_session_path, headers: { "HTTP_ACCEPT_LANGUAGE" => "en" }
    assert_response :success

    get new_password_path, headers: { "HTTP_ACCEPT_LANGUAGE" => "en" }
    assert_response :success

    get edit_password_path(users(:one).password_reset_token),
        headers: { "HTTP_ACCEPT_LANGUAGE" => "en" }
    assert_response :success
  end
end
```

- [ ] **Step 4: 跑它确认绿**

Run: `bin/rails test test/integration/locale_smoke_test.rb`
Expected: PASS，2 runs，0 failures。

（本批一行文案都没翻，所有页面仍是中文字面量——字面量不经过 `t()`，所以在 `:en` 下照样渲染得出来。这个测试现在的价值不是抓错，是**占位**：第 2~5 批每翻一个页面，它就自动开始守着那一页的英文译文。）

- [ ] **Step 5: 提交**

```bash
bin/rubocop config test
git add config/environments/test.rb test/integration/locale_smoke_test.rb
git commit -m "test: 漏翻就让测试红

打开 raise_on_missing_translations。但它和 fallbacks = [ :en ] 配合起来只拦得住
「中英都缺」——缺中文译文时 i18n 会静默退回英文，不触发 raise。所以配一个
在 :en 下真的把每个页面渲染一遍的冒烟测试，抓「有中文没英文」那一类。

冒烟测试刻意不断言页面内容：那等于把每条文案在两种语言下各写一遍，测试数翻倍
而信息量不变。漏翻会让 t() 直接抛出来，assert_response :success 就够了。

本批一行文案都没翻，所以它现在全绿——它的价值是占位：设计 13 后面四批每翻一
个页面，它就自动开始守着那一页的英文译文。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: 守卫其二 —— 视图里不许再出现裸中文

**Files:**
- Create: `test/views_have_no_bare_chinese_test.rb`

**Interfaces:**
- Consumes: 无。
- Produces: `UNTRANSLATED_VIEWS` 白名单常量。第 2~5 批各自从里面删掉自己翻完的文件；**白名单清空之日就是设计 13 做完之日**。

- [ ] **Step 1: 写测试（它一开始就该是绿的，见 Step 2 的说明）**

Create `test/views_have_no_bare_chinese_test.rb`:

```ruby
require "test_helper"

# 防「长回去」。
#
# raise_on_missing_translations（Task 4）对「根本没调用 t()」是无感的：一行
# 写死的中文永远查不到 key，也就永远不会触发它。没有这条测试，下一个功能照着
# 旁边的写法又写一行中文进去，而全套测试依然是绿的。
#
# 白名单是这件事的进度条，而且是测试在数、不是人在数：设计 13 的第 2~5 批各自
# 翻完一个版块，就从这里删掉对应的几行。清空之日，这件事做完。
class ViewsHaveNoBareChineseTest < ActiveSupport::TestCase
  CHINESE = /\p{Han}/

  # 设计 13 第 1 批建立本测试时，这些文件里还全是中文字面量。
  # 【只能删，不能加】——往里加一行，意味着有人新写了一页焊死中文的界面。
  UNTRANSLATED_VIEWS = %w[
    app/views/actions/show.html.erb
    app/views/audit_logs/index.html.erb
    app/views/credentials/edit.html.erb
    app/views/credentials/index.html.erb
    app/views/credentials/new.html.erb
    app/views/layouts/application.html.erb
    app/views/managed_apps/_deploy_alerts.html.erb
    app/views/managed_apps/_deploy_history.html.erb
    app/views/managed_apps/_deploy_reporting.html.erb
    app/views/managed_apps/_form.html.erb
    app/views/managed_apps/_host_status.html.erb
    app/views/managed_apps/_host_table.html.erb
    app/views/managed_apps/_refreshing.html.erb
    app/views/managed_apps/edit.html.erb
    app/views/managed_apps/index.html.erb
    app/views/managed_apps/new.html.erb
    app/views/managed_apps/show.html.erb
    app/views/overviews/_grid.html.erb
    app/views/overviews/show.html.erb
    app/views/passwords/edit.html.erb
    app/views/passwords/new.html.erb
    app/views/registry_credentials/edit.html.erb
    app/views/registry_credentials/new.html.erb
    app/views/sessions/new.html.erb
    app/views/users/edit.html.erb
    app/views/users/index.html.erb
    app/views/users/new.html.erb
  ].freeze

  test "白名单之外的视图里没有裸中文" do
    offenders = view_paths_with_chinese - UNTRANSLATED_VIEWS

    assert_empty offenders,
                 "这些视图里有写死的中文，请改用 t()：\\n#{offenders.join("\\n")}"
  end

  # 白名单会随批次缩短。留着已经翻干净的文件在里面，这条守卫就对那个文件失效了
  # ——而失效是静默的，没有这条测试没人会发现。
  test "白名单里没有已经翻干净的文件" do
    stale = UNTRANSLATED_VIEWS - view_paths_with_chinese

    assert_empty stale,
                 "这些文件已经没有中文了，请从 UNTRANSLATED_VIEWS 里删掉：\\n#{stale.join("\\n")}"
  end

  private
    def view_paths_with_chinese
      Dir.glob(Rails.root.join("app/views/**/*.erb")).filter_map do |path|
        # 剥掉 ERB 注释再看：这个仓库的中文注释是资产，不是要翻译的文案。
        body = File.read(path).gsub(/<%#.*?%>/m, "")
        next nil unless body.match?(CHINESE)

        Pathname.new(path).relative_path_from(Rails.root).to_s
      end.sort
    end
end
```

- [ ] **Step 2: 跑它确认绿**

Run: `bin/rails test test/views_have_no_bare_chinese_test.rb`
Expected: PASS，2 runs，0 failures。

这条测试和别的不一样：它**一开始就该是绿的**。它不驱动实现，它是一条约束。验证它
真的有效要靠 Step 3 的故意破坏，不是靠看它变红。

- [ ] **Step 3: 故意破坏一次，确认它抓得到**

先确认它能抓到「新文件里的裸中文」：

```bash
printf '<p>这是一行新写的中文</p>\n' > app/views/overviews/_probe.html.erb
bin/rails test test/views_have_no_bare_chinese_test.rb
```

Expected: FAIL，`这些视图里有写死的中文，请改用 t()：app/views/overviews/_probe.html.erb`

再确认它能抓到「白名单没跟着缩」：

```bash
rm app/views/overviews/_probe.html.erb
printf '<p>placeholder</p>\n' > app/views/sessions/new.html.erb
bin/rails test test/views_have_no_bare_chinese_test.rb
```

Expected: FAIL，`这些文件已经没有中文了，请从 UNTRANSLATED_VIEWS 里删掉：app/views/sessions/new.html.erb`

- [ ] **Step 4: 还原破坏**

```bash
git checkout app/views/sessions/new.html.erb
rm -f app/views/overviews/_probe.html.erb
bin/rails test test/views_have_no_bare_chinese_test.rb
```

Expected: PASS，2 runs，0 failures

- [ ] **Step 5: 跑全量并提交**

```bash
bin/rails test
bin/rails test:system
bin/rubocop test
git add test/views_have_no_bare_chinese_test.rb
git commit -m "test: 视图里不许再出现裸中文

raise_on_missing_translations 对「根本没调用 t()」是无感的：一行写死的中文永远
查不到 key，也就永远不会触发它。没有这条测试，下一个功能照着旁边的写法又写一行
中文进去，而全套测试依然是绿的。

白名单是设计 13 的进度条，而且是测试在数、不是人在数。它还配了第二条断言：
白名单里不许留已经翻干净的文件——留着的话这条守卫就对那个文件静默失效了。
两条合起来，白名单只能变短，清空之日就是这件事做完之日。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## 收尾

- [ ] **合回 main**

```bash
bin/rails test          # 预期 510 + 17 ≈ 527 runs，0 failures
bin/rails test:system   # 预期 34 runs，0 failures，2 errors（ManagedAppOnboardingTest 既有问题，与本批无关）
git checkout main
git merge --no-ff -m "Merge branch 'i18n-infrastructure'" i18n-infrastructure
```

- [ ] **确认第 2 批的起点**

第 2 批（人员与凭据）开工时要做的第一件事，是从 `UNTRANSLATED_VIEWS` 里删掉
`users/*`、`credentials/*`、`registry_credentials/*` 那 8 行——删掉之后测试会红，
红的正是那几个文件里还没翻的中文。**那就是第 2 批的 TODO 列表，由测试生成，不由人列。**
