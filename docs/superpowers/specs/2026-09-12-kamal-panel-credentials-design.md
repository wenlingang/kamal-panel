# kamal-panel 设计 12：凭据模块

> 设计 11 `2026-09-11-kamal-panel-roles-and-people-design.md` 的续篇。那一份在
> 范围之外明确排除了本文，并说明理由：凭据要由 admin 独占，而"只有 admin 能做
> 某件事"需要一个地方去表达——那个地方（policy 层）由设计 11 建成，现在已经就位。

**Goal:** 把 SSH 私钥与 registry 密码从"每个应用各自私有"变成"admin 维护的一池
共享凭据"，接入应用时从池里选。

**范围之外：** `kamal_secrets` 自由文本（保留给 `RAILS_MASTER_KEY` 这类一应用
一份的东西）；把已有应用的 registry 密码从自由文本里自动抽出来（见 5.2 的理由）。

---

## 1. 为什么现在做

今天每个应用私有一把 SSH 私钥：接入表单里粘一次，存成一条只属于它的
`Credential`。这在"一个人管几个应用"时成立，在设计 11 之后不再成立——面板现在
有三档角色和成员关系，而**凭据是这套权限模型里唯一没有主人的东西**。谁接入应用
谁就能粘一把私钥进去，粘的是哪台机器的钥匙、这把钥匙还在哪些地方用着，没有任何
地方回答得了。

registry 密码更隐蔽：它今天藏在 `kamal_secrets` 这段加密自由文本里，和
`RAILS_MASTER_KEY` 之类混在一起。面板知道它在那儿（`Invocation` 把整段写进
`.kamal/secrets-common`），但它不是一个面板认识的东西——没法被列出、被替换、
被审计。

所以本文要建的不是"一个凭据页面"，而是**让凭据成为一等对象**：有名字、有主人
（admin）、能被指着说"这条正被哪几个应用用着"。

### 1.1 registry 凭据的本体是什么

deploy.yml 里 registry 的 server 与 username 本来就是配置的一部分
（`Kamal::ParsedConfig#registry_server` 已经解析了 server）。密码不是——Kamal 2
的标准写法是：

```yaml
registry:
  password:
    - KAMAL_REGISTRY_PASSWORD
```

方括号里是一个**环境变量名**，值由 `.kamal/secrets-common` 提供。所以"registry
凭据"在面板这里的本体是**一个有名字的密码**，加上"它该以什么变量名被注入"这个
问题——而后者的答案在每个应用自己的 deploy.yml 里，不是一个常量（见第 3 节）。

---

## 2. 数据模型

### 2.1 `WriteOnlySecret` concern

`app/models/concerns/write_only_secret.rb`。两种凭据真正共享的只有三件事，
抽出来的也只有这三件：

- `encrypts :value`
- `serializable_hash` 剔掉 `value`——`#inspect` 由 Active Record encryption 自己
  挡住，但**序列化路径不归它管**。这不是新防线，是既有 `Credential` 里已经踩实
  的一条，抽上来是为了让第二种凭据不必重新踩一遍。
- `name` 必填、**在自己那张表里**唯一（两张表各有各的唯一索引；一条 SSH 凭据
  和一条 registry 凭据同名不冲突，它们在界面上分属两个分区，不会被搞混）

别的一概不进。SSH 那套子进程校验、指纹、16 KiB 上限留在 `Credential` 自己身上
（理由见 2.4）。

### 2.2 `Credential` 加 `name`

`string, null: false` + 唯一索引。它今天没有名字，因为从来只被一个应用私有；
进了池子就必须能被人指着说"用这条"。其余不变。

### 2.3 新表 `registry_credentials`

```
registry_credentials
  name       string  not null  unique
  value      text    not null            # 加密，密码本身
  server     string                      # 可空，见下
  created_at / updated_at
```

**`server` 为什么存，又为什么可空：** registry 的 server 已经在 deploy.yml 里，
面板不需要它才能工作。存它只为一件事——选凭据时拿它和这个应用 deploy.yml 里的
`registry_server` 比一下，不一致就在页面上提示。在一个共享池里"选错了另一个
registry 的密码"是很现实的失误，而它的失败现场是部署时的一句 auth error，离
选择的那一刻很远。

这是**软提示，不是校验**：deploy.yml 里的 server 随时可能改，硬拦会拦错人。

**username 不存**：它不给面板任何新信息，凭据的名字本身就够识别了。

### 2.4 为什么不复用 `Credential` 的 `kind`

`Credential` 表面上是通用的（`KINDS = %w[ssh_key]` 像是预留了多种），但它的整个
模型体都是为 SSH 私钥写的：独立子进程加硬超时跑 `SshKeyValidator`、算并缓存
fingerprint、16 KiB 上限、拒绝带密码的私钥。它有近 40 行注释在讲一件具体的事
——**把攻击者可控的字节喂给 net-ssh 这个第三方解析器**的 DoS 风险，以及那次真实
发生过的自制 reader bypass。

registry 密码是一个不透明字符串，没有解析器，没有这个风险。塞进同一个模型意味着
那一整套校验都要挂上 `if ssh_key?`，`fingerprint` 对一半的行没有意义，而下一个
读代码的人会以为这套防护对它也成立。两个东西共享的只有"加密、只写不读、admin
独占"——那正是 2.1 那个 concern 的全部内容。

### 2.5 关联与删除保护

```ruby
# ManagedApp
belongs_to :ssh_credential,      class_name: "Credential",         optional: true
belongs_to :registry_credential, class_name: "RegistryCredential", optional: true
```

`Credential` 今天是 `has_many :managed_apps, dependent: :nullify`：删一条凭据，
引用它的应用静默变成"没有私钥"。在私有凭据的年代这只坑一个应用；进了共享池，
一次删除可以同时搞断好几个应用的采集与部署，而操作的人看不到任何提示。

两个模型都改成 `dependent: :restrict_with_error`。"被引用的凭据不能删，先把
引用它的应用换掉"由这一行落实，凭据页再把"正被哪几个应用用着"列出来，让人知道
要换的是哪几个。

---

## 3. 密码怎么到 kamal 手里

这一节是本设计的技术核心，因为**变量名不能写死**。

### 3.1 解析器交出变量名

`bin/parse_deploy_config` 里已经握着完整的 `Kamal::Configuration`。从**原始配置**
读出 `registry.password` 那个数组的第一项，作为 `registry_password_env` 交回父
进程；`Kamal::ParsedConfig` 加同名属性。

**必须写进注释的坑：不能调 `config.registry.password`。** 那个方法会去解析
secret，而解析阶段 `.kamal/secrets` 根本不存在，会当场抛异常——解析一份完全
正常的 deploy.yml 会失败。要读的是原始配置里的那个数组。

三种情形：

| deploy.yml 的写法 | `registry_password_env` | 含义 |
|---|---|---|
| `password: [FOO]` | `"FOO"` | 面板按这个名字注入 |
| `password: "明文"` | `nil` | 配置里已有明文，面板没有可注入的位置 |
| 整段缺失 | `nil` | 没有 registry 认证 |

### 3.2 合并写 secrets-common

`KamalCli::Invocation#write_dot_kamal` 目前把 `managed_app.kamal_secrets` 原样
写成 `.kamal/secrets-common`。改成合并两个来源：

1. `kamal_secrets` 的自由文本（不变）
2. 如果应用选了 registry 凭据**且** `registry_password_env` 非空：追加一行
   `<变量名>=<密码>`

文件权限仍是 0600、目录 0700，不变。应用没选 registry 凭据时，行为与今天完全
一致——这保证了未迁移的应用不受任何影响。

### 3.3 冲突：保存时拒绝，不在运行时决胜负

如果 `kamal_secrets` 里也定义了同一个变量，**保存 `ManagedApp` 时就拒绝**，
并说清是哪一个变量撞了。

不让某一边"赢"的理由：两种赢法都会在部署时安静地用错一个密码，而失败现场
（拉不动镜像）离原因（两处都写了这个变量）很远。在人还能改的时候大声失败，
是这个仓库一贯的做法。

### 3.4 审计需要一个明细列

`audit_logs` 现在没有"针对哪个对象"的通用列：设计 11 加的是 `target_user_id`，
而凭据不是用户。加一个可空的 `detail` 字符串列，凭据事件用它记下凭据名。

这同时让设计 11 里那条被推迟的 minor 变得可做——"改角色只记录变过、不记录从
什么变成什么"，当时的结论正是"等有明细列再说"。本文不做那件事，只把列加上。

---

## 4. 界面与接入流程

### 4.1 `/credentials`，admin 独占

一页两个分区（SSH 私钥 / Registry 密码）。`CredentialPolicy#manage?` 与
`RegistryCredentialPolicy#manage?` 都只是 `user.admin?`——和 `UserPolicy` 一样，
它们存在的意义不是逻辑复杂，是让"谁能管凭据"有唯一落点。

每条列出：名字、指纹（只有 SSH 有）、**正被哪几个应用引用**。最后这一列是这一页
的重点：它同时回答"能不能删"和"改了会影响谁"。

### 4.2 新建与轮换

新建：两种凭据各自一个表单。SSH 那个沿用现有的粘贴框与子进程校验，只是多一个
名字；registry 那个是名字 + 密码 + 可选的 server。

轮换：只能整体替换 `value`（"只写不读"不变），**替换立刻对所有引用它的应用生效**。
表单上要把这句话和受影响的应用列表一起摆出来——在共享池里，改一条凭据是一次
多应用操作，不该长得像改一个字段。

### 4.3 接入应用：只能从池里选

接入表单里那个"SSH 私钥"粘贴框换成下拉，另加一个"Registry 密码"下拉。两个都
可留空——`ssh_credential` 今天本来就是 `optional: true`，本轮不改这个语义，
免得把"接入"和"凭据"两件事的范围搅在一起。池子为空时，下拉旁边给一句话和一个
去凭据页的链接。

`ManagedAppsController#create` 里那段 `Credential.new(kind: "ssh_key", value:
params[:ssh_private_key])` 整段删掉：**创建凭据只剩凭据页一条路径**。两条创建
路径意味着两套校验、两份测试，以及它们迟早不一致。

### 4.4 审计

`credential.create` / `credential.rotate` / `credential.delete`，registry 同理，
用 3.4 的 `detail` 记凭据名。凭据变更不属于任何应用，走设计 11 已经放宽过的
那条路（`audit_logs.managed_app_id` 可空）。

---

## 5. 迁移

### 5.1 三步，顺序要紧

1. `credentials` 加 `name`（先可空）→ 回填 → 再加 `null: false` 与唯一索引。
2. 建 `registry_credentials`。
3. `managed_apps` 加 `registry_credential_id` + 外键；`audit_logs` 加 `detail`。

回填规则：被某个应用引用的凭据叫「<应用名> 的 SSH 私钥」；没有任何应用引用的
孤儿行叫「未命名凭据 <id>」。

**同名冲突必须在回填时就解决**：`ManagedApp#name` 没有唯一约束，两个应用同名是
可能的，而 `name` 下一步就要加唯一索引。冲突时补 id 后缀。

### 5.2 `kamal_secrets` 一个字都不动

已有应用的 registry 密码继续从自由文本里生效，池子对它们是**可选的升级路径**，
不是强制迁移。

不自动抽取的理由：那要去解析并改写一段加密的自由文本，而它的格式是用户自己写的
——解析错了的后果不是界面难看，是线上拉不动镜像。这类迁移的收益（省几次手工
复制）远不抵它的风险。

---

## 6. 测试

- **concern**：`value` 永远不出现在 `to_json` / `as_json` 里，两种凭据各验一遍。
- **删除保护**：被引用时 `destroy` 失败且记录仍在；把引用换掉之后可以删。
- **解析器**：三种 `registry.password` 形态（数组 / 字面量 / 缺失）各一条，用
  真实的 deploy.yml fixture 跑真实解析子进程。
- **`Invocation`**：选了 registry 凭据时，secrets-common 里出现的必须是**配置
  实际引用的那个变量名**。这条测试**要用一个不叫 `KAMAL_REGISTRY_PASSWORD` 的
  名字**——写死那个名字的实现会在这条测试上当场变红，而用默认名去测则测不出
  任何东西。
- **冲突**：`kamal_secrets` 与 registry 凭据定义同一个变量时，保存被拒。
- **policy 与控制器**：非 admin 进不去凭据页的任何一个动作，并登记进设计 11 那条
  结构性覆盖测试的名单。
- **迁移**：跑完之后没有任何凭据缺名字、没有重名。

---

## 7. 实施顺序（给实现计划的输入）

1. `WriteOnlySecret` concern + `Credential` 加 `name` + 回填迁移。
2. `RegistryCredential` 模型与表。
3. 删除保护（两个模型改 `dependent:`）。
4. 解析器交出 `registry_password_env`。
5. `Invocation` 合并写 secrets-common + 冲突校验。
6. `audit_logs.detail`。
7. `/credentials` 界面（列表、新建、轮换、删除）+ policy。
8. 接入表单改成下拉，删掉行内创建凭据那条路径。

4 与 5 是承重项：它们决定密码能不能以正确的名字到达 kamal。8 依赖 7（池子得先
有地方建条目），7 依赖 1 与 2（得先有名字和模型）。
