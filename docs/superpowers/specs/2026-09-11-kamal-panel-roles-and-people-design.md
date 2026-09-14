# kamal-panel 设计 11：角色、人员与授权

> 主设计 `2026-09-05-kamal-panel-design.md` 的续篇。主设计第 7 节只定了
> `viewer` / `operator` 两档全局角色，够用到"一个人管全部应用"为止；本文回答
> 的是它没回答的问题：**多个人、各自只管自己那几个应用时，谁能对谁做什么。**

**Goal:** 把两档全局角色换成三档（admin / developer / ops），引入"人 ↔ 应用"的
从属关系，把散在控制器与视图两处的授权判断收拢成一层，并补上 ops 这个角色赖以
成立的新能力：查看服务日志。

**范围之外：** 凭据模块（SSH 私钥与 registry 凭据抽成 admin 独占的资源池，
接入应用时从池里选）——那是设计 12，依赖本文的授权层。本文不动 `Credential`
的形状，也不动接入应用的表单。

---

## 1. 为什么两档不够

今天的模型是 `viewer`（只能看）与 `operator`（能做一切）。它成立的前提是
"能动线上的人只有一类"。一旦面板管的应用超过一个团队的范围，这个前提就断了：
给 A 团队的人 operator，他同时也能回滚 B 团队的应用；不给，他连自己的应用都
重启不了。中间没有档位。

所以要引入的不是"更多角色"，而是**一个新的维度**：权限不再只由"你是谁"决定，
还由"这是谁的应用"决定。三档角色回答前者，一张成员表回答后者。

三档的定义（用户原话的直接翻译）：

- **admin** —— 超管，管全站。接入应用、管人、管凭据（设计 12），对任何应用执行
  任何动作。
- **developer** —— 开发者。对**名下的应用**能执行全部动作；不能接入新应用、
  不能管人、不能管凭据。
- **ops** —— 日常运维。全站只读，外加**查看服务日志**。不能执行任何会改变线上
  状态的动作。

### 1.1 一个刻意不做的选择：不做 per-app 角色

同一个人在 A 应用是 developer、在 B 应用是 ops，这种模型更灵活，但它让每一次
授权判断都要先查一次"这个人在这个应用上是什么角色"，权限页面也要为每个应用
维护一份名单。这个面板服务的是一个内部运维场景，不是多租户 SaaS。
**全站角色 + 一张只回答"哪些应用"的成员表**是能表达需求的最小模型，就用它。

这条选择有一个可检验的后果写在下面第 2 节：`app_memberships` 表上**不允许有
角色列**。哪天真需要 per-app 角色，那是一次显式的模型变更，不该由某个人往这张
表上悄悄加一列来完成。

---

## 2. 数据模型

### 2.1 `User`

```ruby
ROLES = %w[admin developer ops].freeze
```

- `users.role` 的默认值从 `"viewer"` 改成 `"ops"`。默认值的含义是"没指定角色时
  给什么"，三档里权限最小的是 ops。
- 谓词方法 `viewer?` / `operator?` 删除，换成 `admin?` / `developer?` / `ops?`。
- 新增 `users.deactivated_at`（`datetime`，可空）。见 2.3。

**迁移**：一次性 migration 把 `operator` 改成 `admin`、`viewer` 改成 `ops`，
并改列默认值。不保留任何兼容层——两个旧值在 `ROLES` 里彻底消失，残留的旧值会
被 `inclusion` 校验当场拦下，而不是悄悄变成"哪一档都不是"因而处处判假。

`db/seeds.rb` 里 `user.role = "operator"` 一并改成 `admin`（连同那句"首个
operator"的注释）。

### 2.2 `AppMembership`

```
app_memberships
  user_id        integer  not null  → users
  managed_app_id integer  not null  → managed_apps
  created_at     datetime not null
  unique index [user_id, managed_app_id]
```

- 关联：`User has_many :app_memberships` / `has_many :managed_apps, through:`；
  `ManagedApp has_many :app_memberships` / `has_many :members, through:, source: :user`。
  两侧都是 `dependent: :destroy`——这是纯关联行，应用或用户没了它没有任何意义。
- **这张表上不放角色列**（理由见 1.1）。它只回答"这个人能动哪几个应用"。
- admin 与 ops 永远不进这张表。给 admin 建成员行不会让他权限更大，只会制造
  "有两个地方决定 admin 能不能动这个应用"的假象；ops 同理。

### 2.3 不删用户，只停用

`audit_logs.user_id` 是 `null: false` 且带外键。删用户要么被外键拒绝，要么就得
连带删审计记录——而"审计不可删除"是这个仓库既有的规矩（`AuditLog` 的注释、
审计页的副标题都在讲这件事）。为了做人员管理去打穿它是本末倒置。

所以人员管理**不提供删除**，只提供停用：`deactivated_at` 非空的用户

- 无法登录（`Authentication` 建立会话时拒绝，并销毁其现有 session）；
- 仍然出现在审计记录里，署名照旧；
- 在人员列表里单独分组显示，可以随时启用。

---

## 3. 能力矩阵

"全站"指对所有应用生效；"仅名下"指仅对 `app_memberships` 里有自己的应用生效。

| 能力 | admin | developer | ops |
|---|---|---|---|
| 总览 / 应用详情 / 部署历史 | 全站 | **全站** | 全站 |
| 手动刷新（`refreshes#create`） | ✅ | ✅ | ✅ |
| restart / stop / start / rollback | 全站 | 仅名下 | ❌ |
| force_unlock | 全站 | 仅名下 | ❌ |
| 查看服务日志（新动作） | 全站 | 仅名下 | 全站 |
| 接入应用 | ✅ | ❌ | ❌ |
| 重新生成上报 token | 全站 | 仅名下 | ❌ |
| 人员管理 | ✅ | ❌ | ❌ |
| 凭据管理（设计 12） | ✅ | ❌ | ❌ |
| 审计页 | 全站 | 全站 | 全站 |

### 3.1 developer 能看全站，只是不能动别人的

可见性不按成员关系收窄。理由：总览页的全部价值在于**一屏看全**——版本漂移、
某台机器失联这类问题，常常是跨应用比较才看得出来的；而按成员过滤会让 developer
面对一个"应用数量对不上"的面板，却没有任何提示告诉他还有别的应用存在。

代价是 developer 能看到别的团队的应用名、版本号与机器地址。这是一个**被接受的
取舍**，不是疏漏：这个面板的部署单位是一间公司的内部运维，不是互不信任的租户。
如果哪天需要按团队隔离可见性，那是一次显式的范围变更，要连同"总览页还能不能
叫总览"一起重新设计。

同一条原则适用于审计页：它对三档角色都是全站可见。审计是一条时间线，按成员
关系过滤它，等于在每一处查询里重新引入 3.1 反对的那种收窄——而且"谁动了哪个
应用"本来就是一条应该人人看得见的记录。**看得见**和**动得了**是两件事，这份
设计里只有后者受成员关系约束。

### 3.2 `refreshes#create` 对所有角色开放

它是读动作：不取部署锁、不写审计、不改变线上任何状态，只是让一次本来就会自动
发生的采集提前（见 `config/routes.rb` 里那条注释）。按"能不能改变线上状态"划线，
它就该对三档角色都开放。

### 3.3 新动作：查看服务日志

`Actions::Logs`，接进现有的封闭动作集 `Actions::Base.registry`：

- `cli_args = [ "app", "logs", "--lines", <N> ]`
- `requires_lock? = false` —— 看日志不改变线上状态，不该跟一次正在进行的部署
  抢锁。这是这个动作与其余五个动作唯一的结构性差别。
- 输出走现有的 `actions#show` 流式页面，照旧写审计（谁在什么时候看了哪个应用的
  日志，本身就是该留痕的事）。

**`Actions::Base.required_role` 必须删掉。** 它现在返回 `"operator"`——把角色
字符串写在动作类上，等于让授权规则同时活在动作层和控制器层两个地方。换成动作
只声明自己的性质：

```ruby
def self.mutating? = true          # Base
def self.mutating? = false         # Actions::Logs
```

由 policy 去解释"谁能执行 mutating 的动作"。

---

## 4. 授权层

### 4.1 形状：一个资源一个 policy 对象

```
app/policies/managed_app_policy.rb
app/policies/user_policy.rb
app/policies/credential_policy.rb   # 设计 12
```

不引入 Pundit：为三档角色和一张成员表引入一个 gem 及其整套约定不划算，而这几个
对象本身就是普通 Ruby 类，放在 `app/policies/` 与既有的 `app/services/` 同构。

`ManagedAppPolicy.new(user, managed_app)` 暴露的是**能力**，不是角色：

```ruby
def show?                  = true
def act?                   = user.admin? || (user.developer? && member?)
def view_logs?             = act? || user.ops?
def regenerate_hook_token? = act?
def manage_members?        = user.admin?

# 动作层收口到一个方法，动作类自己只声明性质（见 3.3）
def run?(action_class) = action_class.mutating? ? act? : view_logs?
```

`UserPolicy` 全部方法都是 `user.admin?`——它存在的意义不是逻辑复杂，而是让
"谁能管人"这句话有一个唯一的落点。

### 4.2 控制器与视图必须问同一句话

这是整节的要点。今天 `ApplicationController#require_operator!` 与
`AuthorizationHelper#operator_only` 各自独立地判断 `Current.user.operator?`：
两处写法一致纯属巧合，角色一多必然漂移——按钮还在，点下去被拒；或者更糟，
按钮没了，接口却还放行。

- `ApplicationController`：`require_operator!` 删掉，换成
  `require_permission!(:act, @managed_app)` 这类调用，失败沿用现在的
  `redirect_to root_path, alert: ...`。
- 视图：`operator_only` 帮助器删掉，换成 `allowed_to(:act, app) do ... end`，
  它内部调的就是同一个 policy 方法。

**本仓库已经吃过一次"同一条规则活在两个地方"的亏**：总览网格的渲染侧与轮询侧
对"配置解析失败"的判断一度不一致，修复记录留在 `_grid.html.erb` 的注释里。
授权是比渲染严重得多的场合。

### 4.3 钉住"别漏挂过滤器"

除了逐条 policy 的单测，加一条**结构性测试**：遍历所有需要授权的控制器动作，
断言每一个都声明了对应的 `require_permission!`。

理由：漏挂一个 `before_action` 是这类重构最典型的事故，而它**不会让任何别的
测试变红**——那个动作照常工作，只是对谁都工作。这条测试是唯一能在 CI 里抓到它
的东西。

---

## 5. 人员管理界面

`/users`，admin 独占。列表 / 新建 / 改角色 / 停用启用 / 指派名下应用。

### 5.1 admin 不设置别人的密码

新建用户时只填邮箱与角色，系统复用**现有的找回密码流程**（`PasswordsMailer` +
带过期的 token）发一封设置密码的邮件。

理由有两条，都不是洁癖：admin 不该知道别人的密码；而这套流程连同 token 过期、
邮件模板、中文文案已经在仓库里了，新造一套"邀请"机制只是多一条要维护的认证
路径——认证路径是这个应用最不该有第二条的地方。

### 5.2 成员指派只有一个写入口

在**用户编辑页**勾选应用（一次把一个人配齐）。应用详情页只做**只读**展示
"谁能动这个应用"。

两处都能编辑意味着两套表单、两条写路径、两份测试，以及它们迟早不一致。既然
成员关系是"给人配应用"而不是"给应用配人"，写入口就放在人这一侧。

### 5.3 审计要记权限变更——为此要放宽一列

`audit_logs.managed_app_id` 现在是 `null: false`。但"改某人的角色""停用某人"
这类事件不属于任何应用。

**做法**：把该列放宽为可空，并新增 `audit_logs.target_user_id`（可空，指向被
操作的用户）。新增的 `action_name` 取值：`user.create` / `user.update_role` /
`user.deactivate` / `user.reactivate` / `app.add_member` / `app.remove_member`
（后两者同时带 `managed_app_id` 与 `target_user_id`）。

**为什么不另起一张表**：审计的价值在于**一条时间线**。把权限变更和部署操作分到
两张表、两个页面，等于让事后查事故的人自己在脑子里做归并排序——而"谁在部署前
五分钟把自己加进了这个应用"恰恰是最需要这两类事件挨在一起才看得出来的。

代价是 `audit_logs/index` 与它的查询要处理 `managed_app` 为 nil 的行，
以及列表要能显示"针对某个用户"的那一类记录。这个代价明确接受。

**不记录不是一个选项**——权限变更是这个系统里最该留痕的一类事件。

---

## 6. 测试

- `test/policies/managed_app_policy_test.rb`、`user_policy_test.rb`：三档角色 ×
  名下/非名下 的完整组合，逐条能力断言。这是本轮的核心测试。
- 结构性测试（4.3）：所有需授权的控制器动作都挂了过滤器。
- `test/controllers/users_controller_test.rb`：非 admin 访问任何一个动作都被拒；
  新建用户会发出设置密码邮件；停用后无法登录且现有会话失效。
- 现有控制器测试全部要按新角色改写（`users(:one)` = viewer → ops，
  `users(:two)` = operator → admin），并**补上 developer 的用例**：对名下应用
  能执行动作、对别人的应用被拒。
- `Actions::Logs`：`requires_lock?` 为假、能被 ops 执行、写了审计。
- 迁移测试：跑完迁移后没有任何用户的 role 落在 `ROLES` 之外。

---

## 7. 实施顺序（给实现计划的输入）

1. `User::ROLES` 与迁移、`deactivated_at`、seeds。
2. `AppMembership` 与关联。
3. policy 对象 + `require_permission!` / `allowed_to`，删掉
   `require_operator!` / `operator_only`，改写现有视图与控制器。
4. 结构性测试（4.3）。
5. `Actions::Logs` 与 `mutating?`，删掉 `required_role`。
6. 审计表放宽与 `target_user_id`，审计页适配。
7. `/users` 界面与成员指派。

3 是承重项：它一落地，全站的授权判断就只剩一处定义。5 依赖 3（`run?` 在 policy
上），7 依赖 6（人员操作要能写审计）。
