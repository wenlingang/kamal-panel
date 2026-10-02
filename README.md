# kamal-panel

**English** | [简体中文](README.zh-CN.md)

A read-only(-ish) control panel for [Kamal](https://kamal-deploy.org/) deployments: one
Application × Host table that answers "is anything broken?" in a few seconds, read over SSH
from the state Kamal already produces. It does **not** replace Kamal — deploys still happen
via `kamal deploy` from CI.

**Website:** <https://wenlingang.github.io/kamal-panel-site/> · **Docs:** <https://wenlingang.github.io/kamal-panel-site/docs/>

> [!WARNING]
> **The panel's security level equals the security level of every server it manages.**
> Anyone who can submit a `deploy.yml` to it can run arbitrary Ruby on its host, so only
> trusted admins should be able to add applications. Read the
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

Then create the first admin account: [Deploying the panel](https://wenlingang.github.io/kamal-panel-site/docs/#deploy).

## Development

```sh
bin/setup
bin/rails db:encryption:init                              # add the keys to development credentials
bin/rails demo:seed                                       # optional: five apps in every state
docker compose -f docker-compose.test.yml up -d --build  # fake SSH hosts the tests run against
bin/rails test:all                                        # foreground, single process
```

Why the suite must not run in parallel, and the rest of the setup: [Development](https://wenlingang.github.io/kamal-panel-site/docs/#development).

## License

[MIT](LICENSE) © 2026 wenlingang
