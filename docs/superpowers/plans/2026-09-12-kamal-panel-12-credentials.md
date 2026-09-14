# 凭据模块 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 SSH 私钥与 registry 密码从"每个应用各自私有"变成"admin 维护的一池共享凭据"，接入应用时从池里选。

**Architecture:** 两种凭据各自一个模型，共享一个只管"加密、只写不读、有唯一的名字"的 concern。registry 密码在执行时被写进 `.kamal/secrets-common`，用的是**该应用 deploy.yml 实际引用的那个环境变量名**——这个名字由配置解析器新交出的字段提供，不是常量。被应用引用的凭据不可删除。

**Tech Stack:** Rails 8.1、SQLite、Minitest（`bin/rails test`）、RuboCop（rails-omakase）、Active Record Encryption、ERB。无新增 gem。

**Spec:** `docs/superpowers/specs/2026-09-12-kamal-panel-credentials-design.md`

## Global Constraints

- 凭据是**只写不读**的：UI 永不回显 `value`，不提供下载，编辑只能整体替换。
- `name` 必填，**在自己那张表里**唯一（两张表各有各的唯一索引）。
- 管理凭据是 **admin 独占**。
- **被应用引用的凭据不能删除**，必须先把引用它的应用换成别的凭据。
- **变量名不能写死**：写进 secrets-common 的必须是 deploy.yml 实际引用的那个名字。
- `kamal_secrets` 自由文本**一个字都不动**；已有应用的 registry 密码继续从它生效。
- 创建凭据**只有一条路径**（凭据页）。接入表单不再接受当场粘贴。
- 所有面向用户的文案为中文。提交信息格式：`feat: 做了什么——此前是什么样`。
- 每个 Task 结束时 `bin/rails test` 与 `bin/rubocop` 都必须全绿才提交。

## 给实施者的三条现场纪律

1. **这个仓库的测试套件同一时间只能跑一个进程。** `test/test_helper.rb` 里写明刻意不启用 parallelize：fake host 是跨测试共享的全局状态（两台 docker 容器、一份 docker daemon）。所以：**只跑你这个任务涉及的测试文件**，**不要跑全套 `bin/rails test`**，**不要把任何命令丢进后台任务**。全套由 controller 在任务之间统一跑。
2. 症状认得出来：`SQLite3::BusyException: database is locked` 出现在毫不相干的测试里、FakeHost 断言拿到错的版本号、`Rails.logger` 为 nil。真撞上了就 `pkill -9 -f "rails test"` 然后 `bin/rails db:test:prepare` 重建测试库。
3. `app/assets/images/` 已经没有了（站标的 favicon 在 `public/`）。不要 `git add -A`。

---

### Task 1: `WriteOnlySecret` concern 与 `Credential` 的名字

**Files:**
- Create: `app/models/concerns/write_only_secret.rb`
- Create: `db/migrate/<timestamp>_add_name_to_credentials.rb`
- Modify: `app/models/credential.rb`
- Test: `test/models/credential_test.rb`

**Interfaces:**
- Produces: `WriteOnlySecret` concern —— 被 include 后提供 `encrypts :value`、`validates :name, presence: true, uniqueness: true`、`validates :value, presence: true`、以及剔掉 `value` 的 `serializable_hash`。
- Produces: `Credential#name`（`string`, `null: false`, 唯一索引）。
- Produces: `Credential.has_many :managed_apps, dependent: :restrict_with_error` —— 被引用时 `destroy` 返回 `false` 并在 `errors[:base]` 留下信息。

- [ ] **Step 1: 写失败的测试**

在 `test/models/credential_test.rb` 末尾（最后一个 `end` 之前）追加。注意这个文件里已有的用例都没有给 `name`，Step 4 之后它们会因为缺名字而红——那是预期的，Step 5 一并改：

```ruby
  test "名字必填且唯一" do
    key = FakeHost.private_key

    assert_predicate Credential.new(kind: "ssh_key", value: key), :invalid?

    Credential.create!(kind: "ssh_key", value: key, name: "生产集群")
    dup = Credential.new(kind: "ssh_key", value: key, name: "生产集群")

    refute_predicate dup, :valid?
  end

  # #inspect 已由 Active Record encryption 过滤，但序列化路径不受它管辖。
  # 这条防线此前只在 Credential 上，抽进 concern 之后两种凭据都要有。
  test "序列化时永远不带出 value" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")

    refute_includes credential.to_json, "PRIVATE KEY"
    refute_includes credential.as_json.keys, "value"
  end

  # 共享池里一次删除可以同时搞断好几个应用的采集与部署，而操作的人看不到
  # 任何提示。所以被引用时必须删不掉，不是删完把引用置空。
  test "还被应用引用时删不掉" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")
    app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                             destination: "production", ssh_credential: credential)

    refute credential.destroy
    assert Credential.exists?(credential.id)
    assert_predicate credential.errors[:base], :present?

    app.update!(ssh_credential: nil)
    assert credential.destroy
  end
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `bin/rails test test/models/credential_test.rb`
Expected: FAIL —— `unknown attribute 'name' for Credential`

- [ ] **Step 3: 写 concern**

Create `app/models/concerns/write_only_secret.rb`:

```ruby
# 两种凭据（SSH 私钥、registry 密码）真正共享的只有三件事，这里也只有这三件：
# 加密存储、有一个唯一的名字、以及永远不把明文序列化出去。
#
# 别的一概不进。SSH 那套独立子进程加硬超时的校验、指纹、16 KiB 上限留在
# Credential 自己身上——它们是针对"把攻击者可控的字节喂给 net-ssh 这个第三方
# 解析器"这个具体风险写的，而 registry 密码是一个不透明字符串，没有解析器，
# 也就没有那个风险。把它们放进这里，会让下一个读代码的人以为那套防护对
# registry 密码也成立。
module WriteOnlySecret
  extend ActiveSupport::Concern

  included do
    encrypts :value

    validates :value, presence: true
    validates :name, presence: true, uniqueness: true
  end

  # 防止 to_json / as_json 意外把明文序列化出去。#inspect 已由 Active Record
  # encryption 自动过滤，但序列化路径不受它管辖，需要在这里显式兜底。
  def serializable_hash(options = nil)
    super(options).except("value")
  end
end
```

- [ ] **Step 4: 改 `Credential` 用 concern**

在 `app/models/credential.rb` 里：

1. 类体开头 `class Credential < ApplicationRecord` 下一行加 `include WriteOnlySecret`。
2. 删掉 `encrypts :value` 这一行（concern 里有了）。
3. 删掉 `validates :value, presence: true` 这一行（concern 里有了）。
4. 删掉整个 `def serializable_hash(options = nil) ... end` 方法**及其上方那段注释**——注释已经原样搬进 concern 了。
5. 把 `has_many :managed_apps` 那一行的 `dependent: :nullify` 改成 `dependent: :restrict_with_error`：

```ruby
  # 共享池里的凭据被引用时不能删：删完把引用置空，会让好几个应用静默变成
  # "没有私钥"，而操作的人看不到任何提示。要删就先把引用它的应用换掉。
  has_many :managed_apps, foreign_key: :ssh_credential_id, dependent: :restrict_with_error,
           inverse_of: :ssh_credential
```

`KINDS`、`MAX_VALUE_BYTES`、fingerprint 那一整套、`value_must_be_a_private_key` 等全部保持不动。

- [ ] **Step 5: 写迁移（含回填）**

Run: `bin/rails generate migration AddNameToCredentials`

把生成的文件替换成：

```ruby
class AddNameToCredentials < ActiveRecord::Migration[8.1]
  # 回填用原始 SQL 而不是模型：模型在同一个提交里刚加上 name 的必填校验，
  # 用它来写这批还没有名字的行会跟校验打架。
  def up
    add_column :credentials, :name, :string

    taken = Set.new

    select_all(<<~SQL).each do |row|
      SELECT c.id AS id,
             (SELECT m.name FROM managed_apps m
               WHERE m.ssh_credential_id = c.id ORDER BY m.id LIMIT 1) AS app_name
        FROM credentials c
       ORDER BY c.id
    SQL
      base = row["app_name"].presence ? "#{row["app_name"]} 的 SSH 私钥" : "未命名凭据 #{row["id"]}"
      # ManagedApp#name 没有唯一约束，两个应用同名是可能的——而下一步就要给
      # name 加唯一索引。冲突时补 id 后缀。
      name = taken.include?(base) ? "#{base}（##{row["id"]}）" : base
      taken << name

      execute("UPDATE credentials SET name = #{quote(name)} WHERE id = #{row["id"].to_i}")
    end

    change_column_null :credentials, :name, false
    add_index :credentials, :name, unique: true
  end

  def down
    remove_index :credentials, :name
    remove_column :credentials, :name
  end
end
```

- [ ] **Step 6: 跑迁移，修既有测试里缺名字的那些**

Run: `bin/rails db:migrate && bin/rails test test/models/credential_test.rb`

现在文件里原有的 `Credential.new(kind: "ssh_key", value: ...)` / `create!` 调用会因为缺 `name` 而失败。逐个补上名字（用能说明该用例意图的名字，比如 `name: "带密码的私钥"`）。**不要**为了让它们通过而放宽 concern 里的校验。

Expected: PASS

- [ ] **Step 7: 修其他文件里创建 `Credential` 的地方**

Run: `grep -rn "Credential.new\|Credential.create" app test lib`

每一处都要带上 `name:`。已知会命中的有 `test/jobs/poll_managed_app_job_test.rb`、`test/services/` 下几个、`app/controllers/managed_apps_controller.rb`（这一处 Task 6 会整段删掉，本轮先给它一个名字让测试能跑：`name: "#{@managed_app.name} 的 SSH 私钥"`）。

然后跑这些文件：`bin/rails test test/models/credential_test.rb test/controllers/managed_apps_controller_test.rb`

- [ ] **Step 8: rubocop 与提交**

Run: `bin/rubocop`（需要就 `bin/rubocop -a`）

```bash
git add app/models/concerns/write_only_secret.rb app/models/credential.rb \
        app/controllers/managed_apps_controller.rb db/migrate db/schema.rb test
git commit -m "feat: 凭据有了名字，也删不动了——此前它只属于一个应用，没人需要叫它

凭据此前是每个应用私有的：接入时粘一次，存成一条只属于它的记录。进池子共享
之后，它必须能被人指着说"用这条"，所以加名字；也必须删不掉，因为共享池里
一次删除可以同时搞断好几个应用的采集与部署，而操作的人看不到任何提示
（dependent: :nullify 改成 :restrict_with_error）。

抽出 WriteOnlySecret concern，只装两种凭据真正共享的三件事：加密、唯一的名字、
永远不把明文序列化出去。SSH 那套子进程校验、指纹、大小上限留在 Credential
自己身上——它们针对的是把攻击者可控的字节喂给 net-ssh 的风险，而 registry
密码没有解析器也就没有那个风险。放进去会让人以为那套防护对它也成立。

回填用原始 SQL 不用模型：模型在同一个提交里刚加上必填校验，会跟这批还没有
名字的行打架。应用同名是可能的（ManagedApp#name 没有唯一约束），冲突补 id 后缀。"
```

---

### Task 2: `RegistryCredential` 模型

**Files:**
- Create: `app/models/registry_credential.rb`
- Create: `db/migrate/<timestamp>_create_registry_credentials.rb`
- Create: `db/migrate/<timestamp>_add_registry_credential_to_managed_apps.rb`
- Modify: `app/models/managed_app.rb`（关联区，`belongs_to :ssh_credential` 附近）
- Test: `test/models/registry_credential_test.rb`

**Interfaces:**
- Consumes: Task 1 的 `WriteOnlySecret`。
- Produces: `RegistryCredential`，字段 `name` / `value` / `server`；`has_many :managed_apps, dependent: :restrict_with_error`。
- Produces: `ManagedApp#registry_credential`（`belongs_to`, `optional: true`）。

- [ ] **Step 1: 写失败的测试**

Create `test/models/registry_credential_test.rb`:

```ruby
require "test_helper"

class RegistryCredentialTest < ActiveSupport::TestCase
  test "名字必填且唯一，密码必填" do
    assert_predicate RegistryCredential.new(value: "s3cr3t"), :invalid?
    assert_predicate RegistryCredential.new(name: "Docker Hub"), :invalid?

    RegistryCredential.create!(name: "Docker Hub", value: "s3cr3t")
    refute_predicate RegistryCredential.new(name: "Docker Hub", value: "other"), :valid?
  end

  test "序列化时永远不带出 value" do
    credential = RegistryCredential.create!(name: "Docker Hub", value: "s3cr3t")

    refute_includes credential.to_json, "s3cr3t"
    refute_includes credential.as_json.keys, "value"
  end

  test "密码是加密存的" do
    RegistryCredential.create!(name: "Docker Hub", value: "s3cr3t")

    raw = RegistryCredential.connection.select_value("SELECT value FROM registry_credentials LIMIT 1")
    refute_includes raw.to_s, "s3cr3t"
  end

  # server 只用来在选凭据时提示"这条像是给别的 registry 用的"，所以可空：
  # deploy.yml 里本来就有 server，面板不需要它才能工作。
  test "server 可以留空" do
    assert_predicate RegistryCredential.new(name: "Docker Hub", value: "s3cr3t"), :valid?
  end

  test "还被应用引用时删不掉" do
    credential = RegistryCredential.create!(name: "Docker Hub", value: "s3cr3t")
    app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                             destination: "production", registry_credential: credential)

    refute credential.destroy
    assert RegistryCredential.exists?(credential.id)

    app.update!(registry_credential: nil)
    assert credential.destroy
  end
end
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `bin/rails test test/models/registry_credential_test.rb`
Expected: FAIL —— `uninitialized constant RegistryCredential`

- [ ] **Step 3: 两个迁移**

Run: `bin/rails generate migration CreateRegistryCredentials`

```ruby
class CreateRegistryCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :registry_credentials do |t|
      t.string :name, null: false
      t.text :value, null: false
      # registry 的 server 已经在 deploy.yml 里，面板不需要它才能工作。存它
      # 只为一件事：选凭据时和应用配置里的 registry server 比一下，不一致就
      # 提示。所以可空，而且是软提示不是校验。
      t.string :server
      t.timestamps
    end

    add_index :registry_credentials, :name, unique: true
  end
end
```

Run: `bin/rails generate migration AddRegistryCredentialToManagedApps`

```ruby
class AddRegistryCredentialToManagedApps < ActiveRecord::Migration[8.1]
  def change
    add_reference :managed_apps, :registry_credential, null: true, foreign_key: true
  end
end
```

- [ ] **Step 4: 写模型与关联**

Create `app/models/registry_credential.rb`:

```ruby
# 一个有名字的 registry 密码。
#
# 为什么不是 Credential 的另一个 kind：Credential 表面通用，实际整个模型体都是
# 为 SSH 私钥写的——独立子进程加硬超时跑 SshKeyValidator、算并缓存 fingerprint、
# 16 KiB 上限、拒绝带密码的私钥。那近 40 行注释讲的是一件具体的事：把攻击者
# 可控的字节喂给 net-ssh 这个第三方解析器的 DoS 风险。registry 密码是一个
# 不透明字符串，没有解析器，也就没有那个风险。
#
# 密码怎么到 kamal 手里：见 KamalCli::Invocation#write_dot_kamal。要紧的是
# 变量名取自每个应用自己的 deploy.yml，不是常量。
class RegistryCredential < ApplicationRecord
  include WriteOnlySecret

  has_many :managed_apps, dependent: :restrict_with_error, inverse_of: :registry_credential
end
```

在 `app/models/managed_app.rb` 的 `belongs_to :ssh_credential` 下面加：

```ruby
  belongs_to :registry_credential, optional: true
```

- [ ] **Step 5: 跑测试**

Run: `bin/rails db:migrate && bin/rails test test/models/registry_credential_test.rb`
Expected: PASS

- [ ] **Step 6: rubocop 与提交**

Run: `bin/rubocop`

```bash
git add app/models/registry_credential.rb app/models/managed_app.rb db/migrate db/schema.rb \
        test/models/registry_credential_test.rb
git commit -m "feat: registry 密码成了面板认识的东西——此前它藏在一段加密自由文本里

registry 密码此前混在 kamal_secrets 里，和 RAILS_MASTER_KEY 之类躺在一起。
面板知道它在那儿（执行时整段写进 .kamal/secrets-common），但它不是一个面板
认识的对象：没法被列出、被替换、被审计。

server 可空且只是软提示：它本来就在 deploy.yml 里，面板不需要它才能工作，
存它只为选凭据时比一下、不一致就提醒。deploy.yml 里的 server 随时可能改，
硬拦会拦错人。"
```

---

### Task 3: 解析器交出 registry 的变量名

**Files:**
- Modify: `bin/parse_deploy_config`
- Modify: `app/models/kamal/parsed_config.rb`
- Create: `test/fixtures/files/registry_env_deploy.yml`, `test/fixtures/files/registry_literal_deploy.yml`
- Test: `test/models/kamal/config_parser_test.rb`

**Interfaces:**
- Produces: `Kamal::ParsedConfig#registry_password_env` —— `String` 或 `nil`。

- [ ] **Step 1: 先弄清 Kamal 的原始配置长什么样**

**这一步不是可选的。** 计划不能替你猜第三方 API 的形状。

Run:

```bash
ruby -e '
require "kamal"
require "pathname"
c = Kamal::Configuration.create_from(
  config_file: Pathname.new("test/fixtures/files/simple_deploy.yml"),
  version: "unused"
)
raw = c.raw_config
p raw.class
p(raw[:registry] || raw["registry"])
'
```

把输出记在报告里。你要的是那个 `password` 的值——按 Kamal 2 的写法它是一个数组（元素是环境变量名）。下一步的取值代码按**你实际看到的形状**写：如果 `raw_config` 支持 `raw[:registry]`，就用它；如果只支持字符串键，就用字符串键。

**绝对不要调 `config.registry.password`**：那个方法会去解析 secret，而解析阶段 `.kamal/secrets` 根本不存在，一份完全正常的 deploy.yml 会解析失败。

- [ ] **Step 2: 写失败的测试**

先建两个 fixture。`test/fixtures/files/registry_env_deploy.yml` —— 关键是这个变量名**故意不叫** `KAMAL_REGISTRY_PASSWORD`：

```yaml
service: blog
image: example/blog

servers:
  web:
    - 127.0.0.1

registry:
  server: registry.example.com
  username: someone
  password:
    - MY_OWN_REGISTRY_TOKEN

builder:
  arch: amd64

ssh:
  user: deploy
```

`test/fixtures/files/registry_literal_deploy.yml` —— 密码直接写字面量：

```yaml
service: blog
image: example/blog

servers:
  web:
    - 127.0.0.1

registry:
  server: registry.example.com
  username: someone
  password: hunter2

builder:
  arch: amd64

ssh:
  user: deploy
```

在 `test/models/kamal/config_parser_test.rb` 末尾追加：

```ruby
  # 变量名是每个应用自己 deploy.yml 里的事，不是常量。这条测试【故意】
  # 用一个不叫 KAMAL_REGISTRY_PASSWORD 的名字——写死那个常量的实现会在这里
  # 当场变红，而用默认名去测则测不出任何东西。
  test "解析出 registry 密码引用的环境变量名" do
    parsed = Kamal::ConfigParser.call(yaml: file_fixture("registry_env_deploy.yml").read)

    assert_equal "MY_OWN_REGISTRY_TOKEN", parsed.registry_password_env
  end

  # deploy.yml 里已经写了明文密码：面板没有可注入的位置，也不该假装有。
  test "密码写成字面量时没有可注入的变量名" do
    parsed = Kamal::ConfigParser.call(yaml: file_fixture("registry_literal_deploy.yml").read)

    assert_nil parsed.registry_password_env
  end

  test "没有 registry 段时没有变量名" do
    parsed = Kamal::ConfigParser.call(yaml: file_fixture("simple_deploy.yml").read)

    assert_equal "registry.example.com", parsed.registry_server,
      "这个 fixture 本来就有 registry 段，用它来确认解析没坏"
  end
```

> 第三条用的是既有 fixture（它有 registry 段且密码是数组形式），所以它顺带验证了 Step 1 的取值对既有配置仍然成立。如果 `simple_deploy.yml` 的 registry 密码也是数组形式，把第三条改成断言它解析出的名字，而不是断言 nil——**以文件里实际写的为准**，不要为了让断言好看去改 fixture。

- [ ] **Step 3: 跑测试确认它失败**

Run: `bin/rails test test/models/kamal/config_parser_test.rb`
Expected: FAIL —— `undefined method 'registry_password_env'`

- [ ] **Step 4: 子进程交出这个字段**

在 `bin/parse_deploy_config` 的 `emit(...)` 调用里，`registry_server:` 那一行下面加一行 `registry_password_env: registry_password_env(config),`，并在文件里加这个方法（放在 `emit` 定义附近）：

```ruby
# deploy.yml 里 `registry.password: [FOO]` 方括号里是一个【环境变量名】，
# 可以叫任何名字。面板要按这个名字把密码写进 .kamal/secrets-common。
#
# 【不能调 config.registry.password】：那个方法会去解析 secret，而解析阶段
# .kamal/secrets 根本不存在，一份完全正常的 deploy.yml 会解析失败。所以读
# 原始配置。
#
# 三种情形：数组 → 取第一项；字面量字符串 → nil（配置里已有明文，面板没有
# 可注入的位置）；整段缺失 → nil。
def registry_password_env(config)
  raw = config.raw_config
  registry = raw[:registry] || raw["registry"]
  return nil if registry.nil?

  password = registry["password"] || registry[:password]
  password.is_a?(Array) ? password.first.to_s.presence : nil
end
```

> `raw[:registry]` 与 `raw["registry"]` 两种都写上，是因为 Step 1 会告诉你实际支持哪一种——两个都试一遍不增加任何风险，而只写错的那一个会让整条功能静默失效。如果 Step 1 显示 `raw_config` 根本不是 Hash 风格的对象，按你看到的 API 改写这个方法，并在报告里写清楚。

`Kamal::ParsedConfig` 里，`attr_reader` 列表加 `:registry_password_env`，`initialize` 里加：

```ruby
    @registry_password_env = attributes["registry_password_env"]
```

- [ ] **Step 5: 跑测试**

Run: `bin/rails test test/models/kamal/config_parser_test.rb`
Expected: PASS

- [ ] **Step 6: rubocop 与提交**

Run: `bin/rubocop`

```bash
git add bin/parse_deploy_config app/models/kamal/parsed_config.rb \
        test/fixtures/files/registry_env_deploy.yml test/fixtures/files/registry_literal_deploy.yml \
        test/models/kamal/config_parser_test.rb
git commit -m "feat: 解析器交出 registry 密码引用的变量名——它不是常量

deploy.yml 里 registry.password 方括号里那个是环境变量名，可以叫任何名字。
面板要按它把密码写进 secrets-common，所以必须解析出来，不能写死
KAMAL_REGISTRY_PASSWORD。

读的是原始配置：config.registry.password 那个方法会去解析 secret，而解析
阶段 .kamal/secrets 根本不存在，调它会让一份完全正常的 deploy.yml 解析失败。

测试故意用一个不叫 KAMAL_REGISTRY_PASSWORD 的名字——用默认名去测，写死常量
的实现也会通过，等于什么都没测。"
```

---

### Task 4: 把密码写进 secrets-common，并拒绝冲突

**Files:**
- Modify: `app/services/kamal_cli/invocation.rb`（`write_dot_kamal`）
- Modify: `app/models/managed_app.rb`（校验区）
- Test: `test/services/kamal_cli/invocation_test.rb`, `test/models/managed_app_test.rb`

**Interfaces:**
- Consumes: Task 2 的 `ManagedApp#registry_credential`、Task 3 的 `ParsedConfig#registry_password_env`。
- Produces: 执行时 `.kamal/secrets-common` 里追加一行 `<变量名>=<密码>`。
- Produces: `ManagedApp` 新校验 `registry_secret_must_not_collide`。

- [ ] **Step 1: 写失败的测试**

`test/services/kamal_cli/invocation_test.rb` 里找到既有的那条验证 `kamal_secrets` 落到临时目录的测试（搜 `secrets-common`），照它的写法在同一文件追加：

```ruby
  # 变量名取自应用自己的 deploy.yml。这条测试用的 fixture 里那个名字【不是】
  # KAMAL_REGISTRY_PASSWORD——写死常量的实现会在这里当场变红。
  test "选了 registry 凭据时，密码按配置引用的变量名写进 secrets-common" do
    marker = SecureRandom.hex(4)
    app = env_dumping_app(marker, config_yaml: file_fixture("registry_env_deploy.yml").read)
    app.update!(registry_credential: RegistryCredential.create!(name: "Docker Hub", value: "s3cr3t-#{marker}"))

    written = capture_secrets_common(app)

    assert_includes written, "MY_OWN_REGISTRY_TOKEN=s3cr3t-#{marker}"
  end

  test "没选 registry 凭据时 secrets-common 与此前完全一致" do
    marker = SecureRandom.hex(4)
    app = env_dumping_app(marker, kamal_secrets: "RAILS_MASTER_KEY=abc\n")

    written = capture_secrets_common(app)

    assert_equal "RAILS_MASTER_KEY=abc\n", written
  end

  test "两份内容并存时都写进去" do
    app = env_dumping_app(SecureRandom.hex(4),
                          config_yaml: file_fixture("registry_env_deploy.yml").read,
                          kamal_secrets: "RAILS_MASTER_KEY=abc\n")
    app.update!(registry_credential: RegistryCredential.create!(name: "Docker Hub", value: "s3cr3t"))

    written = capture_secrets_common(app)

    assert_includes written, "RAILS_MASTER_KEY=abc"
    assert_includes written, "MY_OWN_REGISTRY_TOKEN=s3cr3t"
  end
```

> `env_dumping_app` 与"怎么拿到写出去的 secrets-common 内容"这两件事，这个文件里已经有现成做法（既有那条 `kamal_secrets` 测试就是这么写的）。**照搬它的写法**，不要新造一套；如果它没有 `capture_secrets_common` 这样的辅助方法，就按它实际的做法内联，并把你用的写法写进报告。

`test/models/managed_app_test.rb` 追加：

```ruby
  # 两处都定义同一个变量时，无论让谁赢，都会在部署时安静地用错一个密码，
  # 而失败现场（拉不动镜像）离原因很远。在人还能改的时候大声失败。
  test "kamal_secrets 与 registry 凭据撞同一个变量时保存被拒" do
    app = ManagedApp.new(name: "blog",
                         config_yaml: file_fixture("registry_env_deploy.yml").read,
                         kamal_secrets: "MY_OWN_REGISTRY_TOKEN=from-free-text\n",
                         registry_credential: RegistryCredential.create!(name: "Docker Hub", value: "s3cr3t"))

    refute_predicate app, :valid?
    assert_match "MY_OWN_REGISTRY_TOKEN", app.errors[:kamal_secrets].join
  end

  test "撞的是别的变量则正常保存" do
    app = ManagedApp.new(name: "blog",
                         config_yaml: file_fixture("registry_env_deploy.yml").read,
                         kamal_secrets: "RAILS_MASTER_KEY=abc\n",
                         registry_credential: RegistryCredential.create!(name: "Docker Hub", value: "s3cr3t"))

    assert_predicate app, :valid?
  end
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `bin/rails test test/models/managed_app_test.rb test/services/kamal_cli/invocation_test.rb`
Expected: FAIL —— 冲突那条不报错就通过了校验；invocation 那几条找不到变量行

- [ ] **Step 3: `Invocation` 合并两个来源**

把 `app/services/kamal_cli/invocation.rb` 的 `write_dot_kamal` 里那段写 secrets-common 的代码换成：

```ruby
        secrets = secrets_common_content
        if secrets.present?
          File.write(File.join(dot_kamal, "secrets-common"), secrets)
          File.chmod(0o600, File.join(dot_kamal, "secrets-common"))
        end
```

并在私有方法区加：

```ruby
      # secrets-common 有两个来源：应用自己那段自由文本，以及（如果选了）
      # registry 凭据。后者按【应用 deploy.yml 实际引用的那个变量名】写入，
      # 不是常量——见 Kamal::ParsedConfig#registry_password_env。
      #
      # 没选 registry 凭据时，这里的行为与此前逐字节一致，未迁移的应用不受
      # 任何影响。
      def secrets_common_content
        parts = []
        parts << managed_app.kamal_secrets if managed_app.kamal_secrets.present?
        parts << registry_secret_line if registry_secret_line

        return nil if parts.empty?

        parts.map { |part| part.end_with?("\n") ? part : "#{part}\n" }.join
      end

      def registry_secret_line
        return @registry_secret_line if defined?(@registry_secret_line)

        @registry_secret_line =
          if managed_app.registry_credential && (env = managed_app.parsed_config.registry_password_env).present?
            "#{env}=#{managed_app.registry_credential.value}"
          end
      end
```

- [ ] **Step 4: `ManagedApp` 加冲突校验**

在 `app/models/managed_app.rb` 的校验声明区加 `validate :registry_secret_must_not_collide`，并在私有方法区加：

```ruby
    # 两处都定义同一个变量时拒绝保存。无论让哪一边赢，都会在部署时安静地
    # 用错一个密码，而失败现场（拉不动镜像）离原因很远——在人还能改的时候
    # 大声失败，是这个仓库一贯的做法。
    def registry_secret_must_not_collide
      return if registry_credential.nil? || kamal_secrets.blank?
      # 配置本身解析不了时，另一条校验（config_yaml_must_parse）会报错，
      # 这里不重复报，也不能去调解析。
      return if errors[:config_yaml].any?

      env = parsed_config.registry_password_env
      return if env.blank?

      return unless kamal_secrets.match?(/^\s*#{Regexp.escape(env)}\s*=/)

      errors.add(:kamal_secrets,
                 "里已经定义了 #{env}，而它同时来自选中的 registry 凭据。" \
                 "删掉其中一处——两处都在时，部署会安静地用错一个密码。")
    rescue Kamal::ConfigParser::ParseError
      nil # 同上：解析失败由 config_yaml_must_parse 报
    end
```

- [ ] **Step 5: 跑测试**

Run: `bin/rails test test/models/managed_app_test.rb test/services/kamal_cli/invocation_test.rb`
Expected: PASS

- [ ] **Step 6: rubocop 与提交**

Run: `bin/rubocop`

```bash
git add app/services/kamal_cli/invocation.rb app/models/managed_app.rb test
git commit -m "feat: registry 密码按配置引用的变量名注入——此前只能自己写进自由文本

secrets-common 现在有两个来源：应用那段 kamal_secrets 自由文本，以及选中的
registry 凭据。后者用的是这个应用 deploy.yml 实际引用的变量名，不是常量。
没选凭据时行为与此前逐字节一致——未迁移的应用不受任何影响。

两处都定义同一个变量时保存直接被拒，而不是让某一边在运行时赢：两种赢法都会
在部署时安静地用错一个密码，而失败现场（拉不动镜像）离原因很远。"
```

---

### Task 5: 凭据页

**Files:**
- Create: `app/policies/credential_policy.rb`, `app/policies/registry_credential_policy.rb`
- Create: `app/controllers/credentials_controller.rb`, `app/controllers/registry_credentials_controller.rb`
- Create: `app/views/credentials/{index,new,edit}.html.erb`, `app/views/registry_credentials/{new,edit}.html.erb`
- Create: `db/migrate/<timestamp>_add_detail_to_audit_logs.rb`
- Modify: `app/models/audit_log.rb`（`record_access!`）, `app/controllers/application_controller.rb`（`POLICIES`）, `config/routes.rb`, `app/views/layouts/application.html.erb`（导航）
- Test: `test/controllers/credentials_controller_test.rb`, `test/controllers/registry_credentials_controller_test.rb`, `test/policies/credential_policy_test.rb`, `test/controllers/authorization_coverage_test.rb`

**Interfaces:**
- Consumes: Task 1、2 的两个模型；设计 11 的 `authorize` 类宏、`allowed_to` 帮助器、`AuditLog.record_access!`。
- Produces: `AuditLog.record_access!(..., detail: nil)` 多一个关键字参数，写进新的 `audit_logs.detail` 列。

- [ ] **Step 1: 写失败的测试**

Create `test/policies/credential_policy_test.rb`:

```ruby
require "test_helper"

class CredentialPolicyTest < ActiveSupport::TestCase
  test "只有 admin 能管凭据" do
    assert_predicate CredentialPolicy.new(users(:two), nil), :manage?
    refute_predicate CredentialPolicy.new(users(:three), nil), :manage?
    refute_predicate CredentialPolicy.new(users(:one), nil), :manage?

    assert_predicate RegistryCredentialPolicy.new(users(:two), nil), :manage?
    refute_predicate RegistryCredentialPolicy.new(users(:three), nil), :manage?
  end
end
```

Create `test/controllers/credentials_controller_test.rb`:

```ruby
require "test_helper"

class CredentialsControllerTest < ActionDispatch::IntegrationTest
  # 注意：这个文件里【不要】把 ManagedApp 存进 @app——在
  # ActionDispatch::IntegrationTest 里 @app 会覆盖 Runner#app，所有 *_path
  # 辅助方法会整体消失，报错看起来像路由没定义。
  setup do
    @managed_app = ManagedApp.create!(name: "blog",
                                      config_yaml: file_fixture("simple_deploy.yml").read,
                                      destination: "production")
  end

  test "非 admin 一个动作都进不去" do
    [ users(:one), users(:three) ].each do |user|
      sign_in_as user

      get credentials_path
      assert_redirected_to root_path

      assert_no_difference -> { Credential.count } do
        post credentials_path, params: { credential: { name: "偷渡", value: FakeHost.private_key } }
      end

      sign_out
    end
  end

  test "admin 看得到列表，以及每条正被哪些应用引用" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")
    @managed_app.update!(ssh_credential: credential)
    sign_in_as users(:two)

    get credentials_path

    assert_response :success
    assert_select "td", text: /生产集群/
    assert_select "td", text: /blog/
  end

  test "新建写审计，且审计里记得住是哪条凭据" do
    sign_in_as users(:two)

    assert_difference -> { Credential.count }, 1 do
      post credentials_path, params: { credential: { name: "生产集群", value: FakeHost.private_key } }
    end

    log = AuditLog.where(action_name: "credential.create").sole
    assert_equal "生产集群", log.detail
    assert_nil log.managed_app
  end

  test "轮换只换 value，名字不变，并写审计" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")
    sign_in_as users(:two)

    patch credential_path(credential), params: { credential: { value: FakeHost.private_key } }

    assert_equal "生产集群", credential.reload.name
    assert_equal 1, AuditLog.where(action_name: "credential.rotate").count
  end

  test "被引用的凭据删不掉，页面给出理由" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")
    @managed_app.update!(ssh_credential: credential)
    sign_in_as users(:two)

    delete credential_path(credential)

    assert Credential.exists?(credential.id)
    assert_equal 0, AuditLog.where(action_name: "credential.delete").count
  end

  test "没被引用的凭据可以删，并写审计" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "闲置的")
    sign_in_as users(:two)

    delete credential_path(credential)

    refute Credential.exists?(credential.id)
    assert_equal "闲置的", AuditLog.where(action_name: "credential.delete").sole.detail
  end
end
```

Create `test/controllers/registry_credentials_controller_test.rb`:

```ruby
require "test_helper"

class RegistryCredentialsControllerTest < ActionDispatch::IntegrationTest
  test "非 admin 建不了" do
    sign_in_as users(:three)

    assert_no_difference -> { RegistryCredential.count } do
      post registry_credentials_path, params: { registry_credential: { name: "偷渡", value: "x" } }
    end
    assert_redirected_to root_path
  end

  test "admin 新建并写审计" do
    sign_in_as users(:two)

    assert_difference -> { RegistryCredential.count }, 1 do
      post registry_credentials_path,
           params: { registry_credential: { name: "Docker Hub", value: "s3cr3t", server: "registry.example.com" } }
    end

    assert_equal "Docker Hub", AuditLog.where(action_name: "registry_credential.create").sole.detail
  end
end
```

在 `test/controllers/authorization_coverage_test.rb` 的 `DECLARATIVE` 里加两行：

```ruby
    "CredentialsController" => %w[index new create edit update destroy],
    "RegistryCredentialsController" => %w[new create edit update destroy]
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `bin/rails test test/policies/credential_policy_test.rb test/controllers/credentials_controller_test.rb`
Expected: FAIL —— `uninitialized constant CredentialPolicy`

- [ ] **Step 3: 审计加 `detail` 列**

Run: `bin/rails generate migration AddDetailToAuditLogs`

```ruby
class AddDetailToAuditLogs < ActiveRecord::Migration[8.1]
  def change
    # 一句人读的"针对谁/针对什么"。设计 11 加的 target_user_id 只能指用户，
    # 而凭据不是用户。凭据事件用它记凭据名。
    add_column :audit_logs, :detail, :string
  end
end
```

`app/models/audit_log.rb` 的 `record_access!` 加一个关键字参数并透传：

```ruby
  def self.record_access!(user:, action_name:, target_user: nil,
                          managed_app: nil, managed_app_id: nil, detail: nil)
    managed_app_id ||= managed_app&.id
    create!(user:, action_name:, target_user:, managed_app_id:, detail:, hosts: [],
            result: "success", created_at: Time.current, finished_at: Time.current)
  end
```

- [ ] **Step 4: 两个 policy**

Create `app/policies/credential_policy.rb`:

```ruby
# 凭据只有 admin 能管。逻辑简单不是问题——它存在的意义是让"谁能管凭据"
# 有一个唯一的落点，而不是让 Current.user.admin? 散在控制器和视图里。
class CredentialPolicy
  def initialize(user, subject = nil)
    @user = user
    @subject = subject
  end

  def manage? = user.admin?

  private
    attr_reader :user, :subject
end
```

Create `app/policies/registry_credential_policy.rb`（同形，类名换成 `RegistryCredentialPolicy`，注释第一行改成"registry 凭据只有 admin 能管。"）。

`app/controllers/application_controller.rb` 的 `POLICIES` 加两项：

```ruby
  POLICIES = {
    ManagedApp => ManagedAppPolicy,
    User => UserPolicy,
    Credential => CredentialPolicy,
    RegistryCredential => RegistryCredentialPolicy
  }.freeze
```

- [ ] **Step 5: 路由与两个控制器**

`config/routes.rb`，在 `resources :users` 那一组下面加：

```ruby
  # 凭据只有 admin 能管（设计 12）。没有 show：凭据是只写不读的，没有"看一眼
  # 内容"这回事。
  resources :credentials, only: [ :index, :new, :create, :edit, :update, :destroy ]
  resources :registry_credentials, only: [ :new, :create, :edit, :update, :destroy ],
            path: "credentials/registry"
```

Create `app/controllers/credentials_controller.rb`:

```ruby
class CredentialsController < ApplicationController
  authorize :manage, on: Credential, only: %i[ index new create edit update destroy ]

  before_action :set_credential, only: %i[ edit update destroy ]

  def index
    @credentials = Credential.includes(:managed_apps).order(:name)
    @registry_credentials = RegistryCredential.includes(:managed_apps).order(:name)
  end

  def new
    @credential = Credential.new
  end

  def create
    @credential = Credential.new(create_params.merge(kind: "ssh_key"))

    if @credential.save
      AuditLog.record_access!(user: Current.user, action_name: "credential.create",
                              detail: @credential.name)
      redirect_to credentials_path, notice: "已添加 #{@credential.name}"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  # 只换 value：名字不动，因为名字是别人引用这条凭据的方式。换了之后【立刻】
  # 对所有引用它的应用生效——这是一次多应用操作，视图要把受影响的应用列出来。
  def update
    if @credential.update(rotate_params)
      AuditLog.record_access!(user: Current.user, action_name: "credential.rotate",
                              detail: @credential.name)
      redirect_to credentials_path, notice: "已替换 #{@credential.name}"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    name = @credential.name

    if @credential.destroy
      AuditLog.record_access!(user: Current.user, action_name: "credential.delete", detail: name)
      redirect_to credentials_path, notice: "已删除 #{name}"
    else
      redirect_to credentials_path,
                  alert: "#{name} 还被 #{@credential.managed_apps.map(&:name).join("、")} 用着，" \
                         "先把它们换成别的凭据再删。"
    end
  end

  private
    def set_credential = @credential = Credential.find(params[:id])

    def create_params = params.expect(credential: [ :name, :value ])

    # 轮换只收 value：名字不在这里改。
    def rotate_params = params.expect(credential: [ :value ])
end
```

Create `app/controllers/registry_credentials_controller.rb`:

```ruby
class RegistryCredentialsController < ApplicationController
  authorize :manage, on: RegistryCredential, only: %i[ new create edit update destroy ]

  before_action :set_credential, only: %i[ edit update destroy ]

  # 没有 index：两种凭据列在同一页（CredentialsController#index）。

  def new
    @credential = RegistryCredential.new
  end

  def create
    @credential = RegistryCredential.new(create_params)

    if @credential.save
      AuditLog.record_access!(user: Current.user, action_name: "registry_credential.create",
                              detail: @credential.name)
      redirect_to credentials_path, notice: "已添加 #{@credential.name}"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  # 只换 value：名字不动，因为名字是别人引用这条凭据的方式。换了之后【立刻】
  # 对所有引用它的应用生效——这是一次多应用操作，视图要把受影响的应用列出来。
  def update
    if @credential.update(rotate_params)
      AuditLog.record_access!(user: Current.user, action_name: "registry_credential.rotate",
                              detail: @credential.name)
      redirect_to credentials_path, notice: "已替换 #{@credential.name}"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    name = @credential.name

    if @credential.destroy
      AuditLog.record_access!(user: Current.user, action_name: "registry_credential.delete",
                              detail: name)
      redirect_to credentials_path, notice: "已删除 #{name}"
    else
      redirect_to credentials_path,
                  alert: "#{name} 还被 #{@credential.managed_apps.map(&:name).join("、")} 用着，" \
                         "先把它们换成别的凭据再删。"
    end
  end

  private
    def set_credential = @credential = RegistryCredential.find(params[:id])

    def create_params = params.expect(registry_credential: [ :name, :value, :server ])

    # 轮换只收 value：名字与 server 不在这里改。
    def rotate_params = params.expect(registry_credential: [ :value ])
end
```

- [ ] **Step 6: 视图**

Create `app/views/credentials/index.html.erb`:

```erb
<div class="page-head">
  <div class="page-title">
    <h1>凭据</h1>
    <p class="page-sub">面板持有的 SSH 私钥与 registry 密码。接入应用时从这里选，不在别处新建。</p>
  </div>
</div>

<section class="section">
  <div class="section-head">
    <h2>SSH 私钥</h2>
    <%= link_to "添加私钥", new_credential_path, class: "btn-primary" %>
  </div>
  <div class="panel">
    <% if @credentials.empty? %>
      <p class="empty-hint">还没有私钥。面板要靠它登上被管的机器采集状态。</p>
    <% else %>
      <table>
        <thead>
          <tr><th>名字</th><th>指纹</th><th>正被哪些应用用着</th><th></th></tr>
        </thead>
        <tbody>
          <% @credentials.each do |credential| %>
            <tr>
              <td><%= credential.name %></td>
              <td class="mono"><%= credential.fingerprint %></td>
              <td><%= credential.managed_apps.map(&:name).join("、").presence || "（没有）" %></td>
              <td>
                <%= link_to "替换", edit_credential_path(credential) %>
                <%# 被引用时不显示删除入口。控制器那一侧仍然会拦——视图里藏起来
                    是为了少一次注定失败的点击，不是授权本身。 %>
                <% if credential.managed_apps.empty? %>
                  <%= button_to "删除", credential_path(credential), method: :delete, class: "btn-quiet" %>
                <% end %>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    <% end %>
  </div>
</section>

<section class="section">
  <div class="section-head">
    <h2>Registry 密码</h2>
    <%= link_to "添加 registry 密码", new_registry_credential_path, class: "btn-primary" %>
  </div>
  <div class="panel">
    <% if @registry_credentials.empty? %>
      <p class="empty-hint">还没有 registry 密码。没有它，应用启动时拉不动镜像。</p>
    <% else %>
      <table>
        <thead>
          <tr><th>名字</th><th>Registry</th><th>正被哪些应用用着</th><th></th></tr>
        </thead>
        <tbody>
          <% @registry_credentials.each do |credential| %>
            <tr>
              <td><%= credential.name %></td>
              <td><%= credential.server.presence || "—" %></td>
              <td><%= credential.managed_apps.map(&:name).join("、").presence || "（没有）" %></td>
              <td>
                <%= link_to "替换", edit_registry_credential_path(credential) %>
                <% if credential.managed_apps.empty? %>
                  <%= button_to "删除", registry_credential_path(credential), method: :delete, class: "btn-quiet" %>
                <% end %>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    <% end %>
  </div>
</section>
```

Create `app/views/credentials/new.html.erb`:

```erb
<div class="page-head">
  <div class="page-title">
    <h1>添加私钥</h1>
    <p class="page-sub">面板靠它登上被管的机器采集状态。保存后不再显示，只能整体替换。</p>
  </div>
</div>

<section class="section">
  <div class="panel">
    <%= form_with model: @credential do |form| %>
      <% if @credential.errors.any? %>
        <ul class="errors">
          <% @credential.errors.full_messages.each do |message| %>
            <li><%= message %></li>
          <% end %>
        </ul>
      <% end %>

      <div>
        <%= form.label :name, "名字" %>
        <%= form.text_field :name, autocomplete: "off" %>
        <p class="hint">接入应用时你要靠这个名字认出它，起个说得清是哪把钥匙的名字。</p>
      </div>

      <div>
        <%= form.label :value, "私钥内容" %>
        <%= form.text_area :value, rows: 8, autocomplete: "off" %>
      </div>

      <%= form.submit "保存", class: "btn-primary" %>
    <% end %>
  </div>
</section>
```

> 错误展示这一段是照着 `app/views/managed_apps/new.html.erb` 现有的写法写的。这个仓库【没有】`shared/errors` partial，不要新建——那是本任务范围之外的重构。若 `managed_apps/new.html.erb` 里的标记与上面不同，以那个文件为准。

Create `app/views/credentials/edit.html.erb`:

```erb
<div class="page-head">
  <div class="page-title">
    <h1><%= @credential.name %></h1>
    <p class="page-sub">只能整体替换，不能查看。名字不在这里改——别人是靠名字引用这条凭据的。</p>
  </div>
</div>

<section class="section">
  <div class="panel">
    <%# 在共享池里改一条凭据是一次多应用操作，不该长得像改一个字段。 %>
    <p class="warning">
      替换之后立刻对
      <%= @credential.managed_apps.map(&:name).join("、").presence || "（当前没有应用用它）" %>
      生效。
    </p>

    <%= form_with model: @credential, method: :patch do |form| %>
      <% if @credential.errors.any? %>
        <ul class="errors">
          <% @credential.errors.full_messages.each do |message| %>
            <li><%= message %></li>
          <% end %>
        </ul>
      <% end %>

      <div>
        <%= form.label :value, "新的私钥内容" %>
        <%= form.text_area :value, rows: 8, autocomplete: "off" %>
      </div>

      <%= form.submit "替换", class: "btn-primary" %>
    <% end %>
  </div>
</section>
```

Create `app/views/registry_credentials/new.html.erb`:

```erb
<div class="page-head">
  <div class="page-title">
    <h1>添加 registry 密码</h1>
    <p class="page-sub">没有它，应用启动时拉不动镜像。保存后不再显示，只能整体替换。</p>
  </div>
</div>

<section class="section">
  <div class="panel">
    <%= form_with model: @credential do |form| %>
      <% if @credential.errors.any? %>
        <ul class="errors">
          <% @credential.errors.full_messages.each do |message| %>
            <li><%= message %></li>
          <% end %>
        </ul>
      <% end %>

      <div>
        <%= form.label :name, "名字" %>
        <%= form.text_field :name, autocomplete: "off" %>
      </div>

      <div>
        <%= form.label :value, "密码" %>
        <%= form.password_field :value, autocomplete: "off" %>
      </div>

      <div>
        <%= form.label :server, "Registry 地址（可留空）" %>
        <%= form.text_field :server, autocomplete: "off" %>
        <p class="hint">
          填了就会和应用 deploy.yml 里的 registry 比对，不一致时在应用页上提示。
          它只是提示：deploy.yml 随时可能改，面板不会因此拦住你。
        </p>
      </div>

      <%= form.submit "保存", class: "btn-primary" %>
    <% end %>
  </div>
</section>
```

Create `app/views/registry_credentials/edit.html.erb` —— 与 `credentials/edit.html.erb` 同样的结构，三处不同：`form_with model: @credential` 指向的是 `RegistryCredential`（路由自动对上）、字段用 `form.password_field :value` 而不是 `text_area`、标题下那句改成「只能整体替换，不能查看。名字与 registry 地址不在这里改。」

`app/views/layouts/application.html.erb` 的导航，在「人员」那一项后面加：

```erb
          <%= allowed_to(:manage, Credential) do %>
            <%= link_to "凭据", credentials_path, class: ("is-current" if current_page?(credentials_path)) %>
          <% end %>
```

- [ ] **Step 7: 跑测试**

Run: `bin/rails db:migrate && bin/rails test test/policies/credential_policy_test.rb test/controllers/credentials_controller_test.rb test/controllers/registry_credentials_controller_test.rb test/controllers/authorization_coverage_test.rb`
Expected: PASS

- [ ] **Step 8: rubocop 与提交**

Run: `bin/rubocop`

```bash
git add app/policies app/controllers/credentials_controller.rb \
        app/controllers/registry_credentials_controller.rb app/views/credentials \
        app/views/registry_credentials app/controllers/application_controller.rb \
        app/models/audit_log.rb app/views/layouts/application.html.erb \
        config/routes.rb db/migrate db/schema.rb test
git commit -m "feat: 凭据页——此前加一把私钥只能在接入表单里粘，加完就没人知道它在哪

列表里每条都写明"正被哪些应用用着"：这一列同时回答"能不能删"和"改了会影响谁"。
替换页把受影响的应用列在表单上方——在共享池里改一条凭据是一次多应用操作，
不该长得像改一个字段。

轮换只收 value，名字不动：名字是别人引用这条凭据的方式。

audit_logs 加 detail 列。设计 11 加的 target_user_id 只能指用户，而凭据不是
用户；凭据事件用它记凭据名。"
```

---

### Task 6: 接入表单改成从池里选

**Files:**
- Modify: `app/views/managed_apps/new.html.erb`（凭据那一节）
- Modify: `app/controllers/managed_apps_controller.rb`（`create` 与 `managed_app_params`）
- Test: `test/controllers/managed_apps_controller_test.rb`

**Interfaces:**
- Consumes: Task 2 的 `ManagedApp#registry_credential`、Task 5 的凭据页。

- [ ] **Step 1: 写失败的测试**

`test/controllers/managed_apps_controller_test.rb` 追加：

```ruby
  test "接入时从池里选凭据" do
    credential = Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")
    registry = RegistryCredential.create!(name: "Docker Hub", value: "s3cr3t")
    sign_in_as users(:two)

    post managed_apps_path, params: {
      managed_app: {
        name: "blog", config_yaml: file_fixture("simple_deploy.yml").read, destination: "production",
        ssh_credential_id: credential.id, registry_credential_id: registry.id
      }
    }

    app = ManagedApp.find_by(name: "blog")
    assert_equal credential, app.ssh_credential
    assert_equal registry, app.registry_credential
  end

  # 创建凭据只剩凭据页一条路径。两条创建路径意味着两套校验、两份测试，
  # 以及它们迟早不一致。
  test "接入表单不再接受当场粘贴的私钥" do
    sign_in_as users(:two)

    assert_no_difference -> { Credential.count } do
      post managed_apps_path, params: {
        managed_app: { name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                       destination: "production" },
        ssh_private_key: FakeHost.private_key
      }
    end
  end
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `bin/rails test test/controllers/managed_apps_controller_test.rb`
Expected: FAIL —— 第一条报 `ssh_credential_id` 未被允许；第二条会创建出一条 Credential

- [ ] **Step 3: 改控制器**

`app/controllers/managed_apps_controller.rb` 的 `create` 里，**整段删掉**：

```ruby
    if params[:ssh_private_key].present?
      @managed_app.ssh_credential = Credential.new(kind: "ssh_key", value: params[:ssh_private_key])
    end
```

`managed_app_params` 的允许列表加两项：

```ruby
      params.expect(managed_app: [ :name, :config_yaml, :destination, :destination_config_yaml,
                                   :kamal_secrets, :kamal_hooks,
                                   :ssh_credential_id, :registry_credential_id ])
```

- [ ] **Step 4: 改接入表单**

`app/views/managed_apps/new.html.erb` 里「凭据与随配置一起写入的文件」那一节，把 `ssh_private_key` 那个 `text_area_tag` 整块换成：

```erb
      <div>
        <%= form.label :ssh_credential_id, "SSH 私钥" %>
        <%= form.collection_select :ssh_credential_id, Credential.order(:name), :id, :name,
                                   { include_blank: "（不选）" } %>
        <p class="hint">
          面板靠它登上这些机器采集状态。
          <%= link_to "去凭据页添加", credentials_path %>。
        </p>
      </div>

      <div>
        <%= form.label :registry_credential_id, "Registry 密码" %>
        <%= form.collection_select :registry_credential_id, RegistryCredential.order(:name), :id, :name,
                                   { include_blank: "（不选）" } %>
        <p class="hint">
          没有它，应用启动时拉不动镜像。留空则沿用下面 .kamal/secrets 里自己写的那份。
        </p>
      </div>
```

`kamal_secrets` 那一块保持不动。

- [ ] **Step 5: 应用页上的 registry 不一致提示**

这是 spec §2.3 存 `server` 那一列的**唯一理由**：在共享池里选错另一个 registry 的密码是很现实的失误，而它的失败现场是部署时一句 auth error，离选择的那一刻很远。

先写测试，`test/controllers/managed_apps_controller_test.rb` 追加：

```ruby
  test "选中的 registry 凭据与配置里的 registry 对不上时，应用页给出提示" do
    registry = RegistryCredential.create!(name: "别家的", value: "s3cr3t", server: "other.example.com")
    app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                             destination: "production", registry_credential: registry)
    sign_in_as users(:two)

    get managed_app_path(app)

    assert_select "p.warning", text: /other\.example\.com/
  end

  test "对得上时不提示" do
    registry = RegistryCredential.create!(name: "自家的", value: "s3cr3t", server: "registry.example.com")
    app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                             destination: "production", registry_credential: registry)
    sign_in_as users(:two)

    get managed_app_path(app)

    assert_select "p.warning", text: /registry/, count: 0
  end

  # server 留空是允许的（它在 deploy.yml 里本来就有），那就无从比对，也就不提示。
  test "凭据没填 registry 地址时不提示" do
    registry = RegistryCredential.create!(name: "没填地址的", value: "s3cr3t")
    app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                             destination: "production", registry_credential: registry)
    sign_in_as users(:two)

    get managed_app_path(app)

    assert_select "p.warning", text: /registry/, count: 0
  end
```

> 这三条依赖 `simple_deploy.yml` 里 `registry.server` 是 `registry.example.com`。跑之前确认一下那个 fixture 的实际值，不一致就改测试里的字面量，**不要改 fixture**——别的测试在用它。

跑：`bin/rails test test/controllers/managed_apps_controller_test.rb` → 前两条会红。

在 `app/views/managed_apps/show.html.erb` 的「基本信息」那个 `panel` 里，`Registry` 那一行下面加：

```erb
        <%# 软提示不是校验：deploy.yml 里的 server 随时可能改，硬拦会拦错人。
            凭据没填 server 时无从比对，也就不提示。 %>
        <% if (cred = @managed_app.registry_credential) && cred.server.present? &&
              cred.server != @managed_app.parsed_config.registry_server %>
          <p class="warning">
            选中的 registry 凭据「<%= cred.name %>」是给 <%= cred.server %> 用的，
            而这个应用的 registry 是 <%= @managed_app.parsed_config.registry_server %>。
            确认一下是不是选错了——选错的后果是部署时拉不动镜像。
          </p>
        <% end %>
```

**必须放在 `<% unless @managed_app.last_poll_error.present? %>` 那一支里**：配置解析不了时 `parsed_config` 会抛 `ParseError`，而那条分支存在的全部意义就是让这一页在解析失败时仍然渲染得出来（见该文件顶部的注释）。放错地方会把那条路径重新炸掉。

跑：`bin/rails test test/controllers/managed_apps_controller_test.rb` → PASS

- [ ] **Step 6: rubocop 与提交**

Run: `bin/rubocop`

```bash
git add app/controllers/managed_apps_controller.rb app/views/managed_apps/new.html.erb \
        app/views/managed_apps/show.html.erb test/controllers/managed_apps_controller_test.rb
git commit -m "feat: 接入应用改成从池里选凭据——此前只能当场粘一把私钥

粘的是哪台机器的钥匙、这把钥匙还在哪些地方用着，此前没有任何地方回答得了。

接入表单里那段行内创建凭据的代码整段删掉：创建凭据只剩凭据页一条路径。
两条创建路径意味着两套校验、两份测试，以及它们迟早不一致。

两个下拉都可留空——ssh_credential 本来就是 optional，本轮不改这个语义，
免得把"接入"和"凭据"两件事的范围搅在一起。

应用页上加了一句提示：选中的 registry 凭据和配置里的 registry 对不上时说出来。
这是 registry 凭据存 server 那一列的唯一理由——在共享池里选错另一个 registry
的密码很现实，而它的失败现场是部署时一句 auth error，离选择的那一刻很远。
是提示不是校验：deploy.yml 随时可能改，硬拦会拦错人。"
```

---

## 收尾

- [ ] **完整验证**

Run: `bin/rails test && bin/rubocop && bin/brakeman --no-pager`
Expected: 测试全绿、rubocop 无告警、brakeman 无新增告警。

- [ ] **人工验一遍**

`bin/rails server`，用 admin 登录：

1. 凭据页能建一条 SSH 私钥和一条 registry 密码；建完列表里"正被哪些应用用着"是空的。
2. 接入一个应用，两个下拉里都能选到刚建的；接入后回凭据页，那两条各自列出了这个应用。
3. 对被引用的凭据点删除（直接 `curl -X DELETE` 或临时改视图），确认被拒并给出理由。
4. ops 与 developer 登录时看不到导航里的「凭据」。

- [ ] **合回 main**

```bash
git checkout main
git merge --no-ff --no-commit 12-credentials
git commit --no-edit
```

（`--no-ff --no-commit` 分两步是必要的：本仓库里 `git merge --no-ff` 单独用会被快进掉。）
