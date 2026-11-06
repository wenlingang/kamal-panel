# kamal-panel

[English](README.md) | **简体中文**

一个面向 [Kamal](https://kamal-deploy.org/) 的轻量运维平台：总览几秒钟回答「有没有哪里出问题了」，
集中查各应用的日志，选一个 CI 已构建好的版本从面板发布，重启 / 启停 / 维护模式 / 回滚等常用操作，
以及告警规则与通知（Webhook、飞书、Slack、邮件）。它通过 SSH 读取并执行 Kamal 本身的命令，
**不是** Kamal 的替代品，镜像仍由 CI 构建。

**官网：** <https://wenlingang.github.io/kamal-panel-site/zh-CN/> · **文档：** <https://wenlingang.github.io/kamal-panel-site/zh-CN/docs/>

> [!WARNING]
> **面板的安全级别，等于它所管理的每一台服务器的安全级别。**
> 任何能向面板提交 `deploy.yml` 的人，都能在面板所在的主机上运行任意 Ruby 代码，所以只能让可信的
> admin 添加应用。面板还会主动连外部：用 Git 平台 token 读提交与 CI 状态、探测镜像仓库、向通知
> Webhook 发送告警——这些凭据同样只由 admin 管理。部署到任何地方之前，先读[安全边界](https://wenlingang.github.io/kamal-panel-site/zh-CN/docs/#security)。

## 部署

`config/deploy.yml` 是一份可用的 Kamal 配置，改好 `image`、`servers.web`、`proxy.host` 三行，然后：

```sh
bin/rails db:encryption:init   # 只需一次；妥善保管生成的密钥
export KAMAL_REGISTRY_USERNAME=... KAMAL_REGISTRY_PASSWORD=...
export AR_ENCRYPTION_PRIMARY_KEY=... AR_ENCRYPTION_DETERMINISTIC_KEY=... AR_ENCRYPTION_KEY_DERIVATION_SALT=...
bin/kamal setup                # 之后用 bin/kamal deploy
```

告警通知里的链接需要面板自己的地址：设置 `PANEL_URL=https://panel.example.com`（不设则通知不带链接）。
邮件渠道和找回密码需要 SMTP：`SMTP_ADDRESS`、`SMTP_PORT`、`SMTP_USERNAME`、`SMTP_PASSWORD`、`PANEL_MAIL_FROM`。

接着创建第一个 admin 账号，见[部署面板](https://wenlingang.github.io/kamal-panel-site/zh-CN/docs/#deploy)。

## 本地开发

```sh
bin/setup
bin/rails db:encryption:init                              # 把密钥加进 development credentials
bin/rails demo:seed                                       # 可选：演示应用、发布记录与告警
bin/rails demo:refresh                                    # 看之前把演示数据刷新到当前时间
docker compose -f docker-compose.test.yml up -d --build  # 测试要连的假 SSH 主机
bin/rails test:all                                        # 前台、单进程运行
```

为什么测试不能并行跑，以及其余的准备步骤，见[本地开发](https://wenlingang.github.io/kamal-panel-site/zh-CN/docs/#development)。

## 协议

[MIT](LICENSE) © 2026 wenlingang
