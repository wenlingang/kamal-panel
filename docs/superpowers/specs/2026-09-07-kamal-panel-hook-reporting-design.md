# kamal-panel 设计 03：hook 上报与两套数据源对账

> 本文是主设计 `2026-09-05-kamal-panel-design.md` 的子设计，落实其中 3.1（两套数据源）、
> 3.3 / 6.4（对账与不一致的显式呈现）、5.4（可选的 hook 上报）三节。主设计仍是权威，
> 与本文冲突时以本文为准，并在主设计中回指。

**Goal:** 让面板除了「现在是什么状态」之外，还能回答「发生过什么」——并且当两套数据源
互相矛盾时，把矛盾摆到台面上，而不是挑一个来信任。

**范围之外（各自单独一轮）：** Kamal 版本兼容矩阵 CI（主设计 9.4）、面板自部署
（主设计 8 节末）、深色模式、从 Observation 推断的 `inferred` 事件。

---

## 1. 为什么需要这一层

SSH 轮询回答的是「现在是什么状态」。它答不了三个问题：

- 这一版是谁在什么时候部署的？
- 上一次部署失败过吗？（版本没变，轮询看不出「试过但没成」）
- 部署命令自己怎么说的？（`kamal deploy` vs `kamal rollback`，performer 是谁）

Kamal 自己在部署过程中就会跑用户的 `.kamal/hooks/*`，并向脚本传入
`KAMAL_SERVICE` / `KAMAL_VERSION` / `KAMAL_PERFORMER` / `KAMAL_DESTINATION` /
`KAMAL_RECORDED_AT` / `KAMAL_COMMAND`（主设计第 4 节已从 v2.12.0 源码逐条核实）。
面板只需要提供一个端点和一段脚本，就能拿到这些信息。

**这一层是可选增强，不是前置条件**：不配 hook 的应用照旧完整可用，只是部署历史是空的。
两套数据源渐进叠加，这是主设计 3.1 定下的路线。

## 2. 关键决策

| 决策 | 结论 | 依据 |
|---|---|---|
| 本轮是否做 `inferred` 事件 | 否。`source` 字段保留，但只写 `hook` | 不把推测写成事实。从 Observation 推断版本变更要处理滚动部署中途的混合版本、回滚、失联后重现，否则会造出一堆假事件 |
| 上报时机 | `pre-deploy` + `post-deploy` 两段 | Kamal 没有「部署失败」钩子。只收 post-deploy 的话，一次失败的部署在面板上彻底隐形；两段之后「开了头没收尾」自己就是一条可见记录 |
| 矛盾告警的生命周期 | 自动消解，但留下痕迹 | 不让页面堆积已经不成立的告警；「每次部署都要拖几分钟才上去」这类模式仍然查得出来 |
| 告警怎么算出来 | 派生式 + 一处回填（见 5 节），不建告警表、不加后台 job | 把唯一真相放在**必然会跑**的轮询路径上。若靠一个定时 job 推状态机，job 挂了告警就永远不出现，而「告警没出现」和「一切正常」在界面上长得一模一样 |
| token 粒度与存储 | per-application，只存 SHA256 摘要，可重置 | 与 SSH 私钥的「只写不读」一致。一把钥匙开所有应用则无法单独吐出某个项目的权限 |
| token 与上报内容不一致 | 拒收（409）并在面板上说清楚 | token 粘错的表现否则是「部署历史永远是空的」，没人查得出原因 |
| 告警计时用谁的时间 | 服务端收到的时刻 | `recorded_at` 是机器上的原文，可伪造、也会时钟漂移。用它计时能让告警永不触发或立刻触发 |
| `DeployEvent` 保留期 | 不清理 | 它是部署历史本身，频率为每次部署一条，与 Observation 的每轮每机器一条不在一个量级 |

## 3. 数据模型

```
DeployEvent    managed_app_id, version, performer, destination, command,
               started_at, succeeded_at   ← 两段上报各自【服务端收到的时刻】
               recorded_at                ← 机器上的原文，只用于展示
               observed_at                ← 轮询回填
               source（本轮恒为 "hook"）
```

**时间列有三种，别混：** `started_at` / `succeeded_at` 是服务端收到两段上报的时刻，
**所有告警计时只用它们**；`recorded_at` 是 `KAMAL_RECORDED_AT` 的原文，可伪造、也会时钟
漂移，只在历史里展示，绝不参与判定；`observed_at` 来自那条 Observation 自己的观测时间。

**一行代表一次部署尝试，不是一条上报。**

- `pre-deploy` 上报建行，填 `started_at`。
- `post-deploy` 上报补**同一应用、同一 version、`succeeded_at` 仍为空的最近一行**的 `succeeded_at`。
- 配不上就新建一行、只填 `succeeded_at`——「pre 那次上报丢了」或「两条乱序到达」都有归宿，
  不静默丢弃、也不造重复行。
- 同一 version 被重复部署（CI 重跑）自然是两行：第一行的 `succeeded_at` 已经不为空。
- `pre-deploy` 重复到达时，若已存在该应用该 version 且 `succeeded_at` 为空的行，视为同一次
  尝试，不建新行。curl 重试与 CI 重跑同一步都不会造出幽灵记录。

`observed_at` 是回填列：轮询发现该 version 已在任一 host 上 running 时写入。它同时是告警
条件（为空且超时）与留痕——`observed_at - succeeded_at` 按符号分两种说法：正数说「延迟 N
秒」，负数或零说「上报前已观测到」。**后者才是常态**：Kamal 的真实时序是容器先 running →
健康检查通过 → 切流量 → `post-deploy` hook 才上报成功，而 Reconciler 一看见 running 就回填
`observed_at`，所以在一次正常部署里，`observed_at` 通常早于 `succeeded_at`，这个差值多半是
负的。

**`ManagedApp` 新增三列：**

- `hook_token_digest` —— SHA256 摘要，带索引。端点按摘要直接查应用，不需要逐个试。
  重置即覆盖摘要，旧值当场失效。
- `last_hook_rejection` / `last_hook_rejection_at` —— 沿用项目已有的 `last_poll_error`
  那套模式，详情页照同样的样式挂横幅。不为它单独建表：它是「当前配置有问题」的状态，
  不是需要留存的历史。

**`DeployEvent` 与 `AuditLog` 仍然分开**（主设计 5.2 已定）：前者是「机器上发生了什么」，
后者是「谁在面板上点了什么」。

## 4. 端点与认证

`POST /api/deploys`，不走登录、跳过 CSRF，接受表单编码（hook 里就是 `curl -d`）。

**认证：** `Authorization: Bearer <token>` → SHA256 → 按 `hook_token_digest` 查应用。
查不到返回 401。**成功也不返回任何内容（204）**——token 只是写入凭证，不能顺带变成
读取面板状态的通道。

**限流是硬要求**，因为收到事件会触发 burst 轮询：一个 token 能撬动面板对用户的所有机器
发起 SSH 扇出。两道约束一起上：

1. 按应用限流（Rails 8 的 `rate_limit`，30 次 / 分钟）。
2. burst 只在**状态真的发生变化时**触发——新建行，或首次补上 `succeeded_at`。重复上报
   不再撬动一次扇出。

**输入：** `version` 按保守字符集校验（它进 UI、进告警文案、参与配对查询）；
`performer` / `command` 只截断长度、当纯文本存。**上报字段与写操作参数完全隔离**：动作的
`cli_args` 由封闭动作集自己生成，任何上报字段都不进入那条路径。这条要用测试显式钉住
（见 7 节），不能靠「我知道它们没连着」。

**响应码：** 204 成功 / 401 token 不认 / 409 service·destination 与 token 不匹配 /
422 字段不合法 / 429 限流。

## 5. 回填、告警与呈现

**回填**放在 `PollManagedAppJob` 中、容器采集之后，做成独立的 `DeployEvents::Reconciler`，
与两个采集器一样彼此隔离——它自己抛异常不能连累采集结果。

规则：取本轮 `latest_for` 里处于 running 的 version 集合，给该应用中 `observed_at` 为空且
version 命中的行填上**那条观测的 `observed_at`**，而不是 `Time.current`。用观测时间才诚实：
留痕说的是「机器上什么时候被看到 running」相对「hook 什么时候报告部署成功」，不是「面板
多久之后才想起来算这件事」。这两个时间点谁先谁后没有必然顺序——Kamal 的常规时序是容器先
running、健康检查通过、切流量之后 `post-deploy` hook 才会跑，所以 `observed_at` 经常早于
`succeeded_at`，差值为负是正常现象而不是异常；只有轮询周期长、或者 hook 抢跑等少见情况才会
出现正的「延迟」。

**两类告警，语义不同，不合成一条：**

| 告警 | 条件 | 文案 | 阈值依据 |
|---|---|---|---|
| 上报成功但观测不到 | `succeeded_at` 非空、`observed_at` 为空、已过 90 秒 | 「v3f9a2 已上报部署成功（2 分钟前），但未在任何机器上观测到」 | 只需盖住「容器起来后被下一轮轮询看到」这一小段 |
| 开了头没收尾 | `started_at` 非空、`succeeded_at` 为空、已过 15 分钟 | 「v3f9a2 于 14:02 开始部署，至今未收到完成上报」 | 要盖住一次正常部署的全长（构建 + 健康检查） |

两个数字量级不同，硬编码成同一个会让其中一个必然误报。

**呈现位置：** 详情页顶部横幅（与 `last_poll_error` 同一区域、同一套样式）；总览页该应用行
加文字标识「上报未验证」——不靠颜色，遵守主设计一贯的约束。

**部署历史：** 详情页一个区块，列 version / performer / 开始 / 完成 / 观测延迟 / 命令。
没配 hook 的应用显示空列表加一句「配上部署上报就能在这里看到部署历史」，而不是一个看不出
所以然的空表格。

## 6. hook 脚本的生成与交付

应用详情页新增「部署上报」区块，仅 operator 可见。未启用时只有一个按钮：**生成上报 token**。

点下去当场展示两段可直接复制的脚本，面板 URL 用 `request.base_url` 自动填好（面板不需要
额外配一个 `PANEL_URL`，也就不会配错）：

```sh
#!/bin/sh
# .kamal/hooks/pre-deploy
curl -sf --max-time 5 -X POST "https://panel.example.com/api/deploys" \
  -H "Authorization: Bearer <token>" \
  -d phase=started \
  -d service="$KAMAL_SERVICE" -d destination="$KAMAL_DESTINATION" \
  -d version="$KAMAL_VERSION" -d performer="$KAMAL_PERFORMER" \
  -d recorded_at="$KAMAL_RECORDED_AT" -d command="$KAMAL_COMMAND" || true
```

`post-deploy` 同形，只差 `phase=succeeded`。要点：

- **末尾的 `|| true` 与 `--max-time 5` 都是硬性的**：面板挂掉或变慢，绝不能让用户的部署
  失败或卡住。这条同时写进 README 与页面上的说明文字，否则没人敢加这个 hook。
- 脚本必须 `chmod +x`（Kamal 按可执行文件跑 `.kamal/hooks/*`），页面上直接给出这条命令。
- token 完整值**只在这一次展示**。离开页面就只剩摘要，想再要就重置。这句话说在展示旁边，
  而不是等人吃了亏才知道。

**一处必须写清楚的交叉影响：** 面板自己执行 rollback 时，Kamal 会照常跑用户的
`post-deploy` hook，于是**面板会收到一条由自己造成的上报**。这是对的，不是要去消除的重复：
`DeployEvent` 记「机器上发生了什么」，`AuditLog` 记「谁在面板上点了什么」，两者能对上账才是
完整的追查链。后来的人不要把它当 bug「修掉」。

## 7. 测试策略

主设计 9.4 列的三个必测场景里，第三个「上报了但观测不到」正是这一轮的东西——它此前只是
纸面承诺。

- **端点层：** 204 / 401 / 409 / 422 / 429 各一例；重复 `pre-deploy` 不建新行；post 先到
  （pre 丢包）建出只有 `succeeded_at` 的行；`recorded_at` 伪造成一小时后，告警计时仍按
  服务端时间走。
- **token：** 断言数据库里搜不到原值（项目对 SSH 私钥就是这么钉的）；重置后旧 token 立即 401。
- **回填与告警：** `Reconciler` 单测（填的是观测时间而不是当下、不越过应用边界、只认
  running）；两类告警各测阈值两侧（89 / 91 秒，14 / 16 分），用 `travel_to` 推时间——项目的
  「不 mock」约束针对 SSH，时间旅行不在其内。消解后断言横幅消失**且**历史里那行的延迟数字还在。
- **页面给出的脚本真的能用：** 系统测试里 operator 生成 token → 从页面上展示的脚本里原样
  取出 URL、参数名与 token → 真的 POST 一次（打的就是 Capybara 起的那个 server）→ 断言部署
  历史出现一行。它守的是别的测试都守不住的那种失败：端点单测过、页面单测过，但页面给出的
  参数名和端点期望的不一致，于是用户照着抄下来永远收不到数据。
- **完整链路（对应主设计 9.4 第三场景）：** 连真实 fake host，POST 一条 succeeded 事件但
  **不启动任何容器** → 跑一轮真实轮询 → 推进 91 秒 → 断言矛盾告警出现；然后真的起一个该
  version 的容器 → 再跑一轮 → 断言告警消失、历史里留下延迟。
- **安全：** 拿 `version` 字段塞 shell 元字符与路径穿越，断言它只落库和显示，不影响任何动作的
  `cli_args`。

## 8. 已知限制

- **401 与 429 在面板上看不见。** 409 拿得到应用上下文（token 有效、只是内容不匹配），
  可以写 `last_hook_rejection`；token 根本不认或被限流时，面板不知道该把这件事记到哪个应用
  名下。于是一个 token 拼错的 hook，在面板上的表现就是「部署历史一直是空的」。
  缓解只有一条，也够用：页面上那句「还没收到任何上报」旁边直接给出排查提示（检查 token、
  检查脚本可执行位、`curl -v` 手跑一次）。不为此建一张「无主上报」表——那张表会立刻变成
  任何人都能往里写的垃圾桶。
- **失败的部署仍然只能靠「开了头没收尾」推断。** Kamal 没有失败钩子，面板收不到
  「部署失败了」这件事本身，只能观察到 15 分钟没有完成上报。真正的失败事件需要用户在 CI 里
  包一层 `kamal deploy || 上报失败`，那就不再是「零改造」，本轮不做。
- **`inferred` 事件不做**，因此没配 hook 的应用没有部署历史。这是自愿增强模型的固有代价。
- **同一 version 在同一秒内并发上报两次**（同一应用在两条 CI 流水线上同时部署同一 sha）
  可能造出两行。这不影响告警正确性（两行各自回填），且这个场景本身已经是用户侧的问题。
