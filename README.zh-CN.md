# kamal-panel

[English](README.md) | **简体中文**

一个（基本上）只读的 [Kamal](https://kamal-deploy.org/) 部署控制面板：用一张「应用 × 主机」总览表，
几秒钟回答「有没有哪里出问题了」。它通过 SSH 读取 Kamal 本来就会产生的状态，**不是** Kamal 的替代品，
部署仍然照旧由 CI 执行 `kamal deploy`。

**官网：** <https://wenlingang.github.io/kamal-panel-site/zh-CN/> · **文档：** <https://wenlingang.github.io/kamal-panel-site/zh-CN/docs/>

> [!WARNING]
> **面板的安全级别，等于它所管理的每一台服务器的安全级别。**
> 任何能向面板提交 `deploy.yml` 的人，都能在面板所在的主机上运行任意 Ruby 代码，所以只能让可信的
> admin 添加应用。部署到任何地方之前，先读[安全边界](https://wenlingang.github.io/kamal-panel-site/zh-CN/docs/#security)。

## 部署

`config/deploy.yml` 是一份可用的 Kamal 配置，改好 `image`、`servers.web`、`proxy.host` 三行，然后：

```sh
bin/rails db:encryption:init   # 只需一次；妥善保管生成的密钥
export KAMAL_REGISTRY_USERNAME=... KAMAL_REGISTRY_PASSWORD=...
export AR_ENCRYPTION_PRIMARY_KEY=... AR_ENCRYPTION_DETERMINISTIC_KEY=... AR_ENCRYPTION_KEY_DERIVATION_SALT=...
bin/kamal setup                # 之后用 bin/kamal deploy
```

接着创建第一个 admin 账号，见[部署面板](https://wenlingang.github.io/kamal-panel-site/zh-CN/docs/#deploy)。

## 本地开发

```sh
bin/setup
bin/rails db:encryption:init                              # 把密钥加进 development credentials
bin/rails demo:seed                                       # 可选：五个应用，覆盖全部状态
docker compose -f docker-compose.test.yml up -d --build  # 测试要连的假 SSH 主机
bin/rails test:all                                        # 前台、单进程运行
```

为什么测试不能并行跑，以及其余的准备步骤，见[本地开发](https://wenlingang.github.io/kamal-panel-site/zh-CN/docs/#development)。

## 协议

[MIT](LICENSE) © 2026 wenlingang
