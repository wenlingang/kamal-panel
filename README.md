# kamal-panel

**English** | [简体中文](README.zh-CN.md)

A lightweight ops platform for [Kamal](https://kamal-deploy.org/) deployments: an overview that
answers "is anything broken?" in a few seconds, centralized logs across apps, deploying a version
CI already built from the panel, everyday actions (restart, stop/start, maintenance, rollback…),
and alert rules with notifications (webhook, Feishu, Slack, email). It works over SSH through
Kamal's own commands and does **not** replace Kamal — images are still built by CI.

**Website:** <https://wenlingang.github.io/kamal-panel-site/> · **Docs:** <https://wenlingang.github.io/kamal-panel-site/docs/>

> [!WARNING]
> **The panel's security level equals the security level of every server it manages.**
> Anyone who can submit a `deploy.yml` to it can run arbitrary Ruby on its host, so only
> trusted admins should be able to add applications. The panel also reaches out: Git provider
> tokens (commits, CI status), registry probing, and notification webhooks — credentials only
> admins manage. Read the
> [security posture](https://wenlingang.github.io/kamal-panel-site/docs/#security) before you deploy it anywhere.

## Deploy

`config/deploy.yml` is a working Kamal configuration — change `image`, `servers.web` and
`proxy.host`, then:

```sh
bin/rails db:encryption:init   # once; keep the generated keys safe
export KAMAL_REGISTRY_USERNAME=... KAMAL_REGISTRY_PASSWORD=...
export AR_ENCRYPTION_PRIMARY_KEY=... AR_ENCRYPTION_DETERMINISTIC_KEY=... AR_ENCRYPTION_KEY_DERIVATION_SALT=...
bin/kamal setup                # bin/kamal deploy thereafter
```

Links in alert notifications need the panel's own address: set `PANEL_URL=https://panel.example.com`
(unset, notifications carry no link). The email channel and password resets need SMTP: `SMTP_ADDRESS`,
`SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `PANEL_MAIL_FROM`.

Then create the first admin account: [Deploying the panel](https://wenlingang.github.io/kamal-panel-site/docs/#deploy).

## Development

```sh
bin/setup
bin/rails db:encryption:init                              # add the keys to development credentials
bin/rails demo:seed                                       # optional: demo apps, deploys, alerts
bin/rails demo:refresh                                    # bring the demo back to "now" before a look
docker compose -f docker-compose.test.yml up -d --build  # fake SSH hosts the tests run against
bin/rails test:all                                        # foreground, single process
```

Why the suite must not run in parallel, and the rest of the setup: [Development](https://wenlingang.github.io/kamal-panel-site/docs/#development).

## License

[MIT](LICENSE) © 2026 wenlingang
