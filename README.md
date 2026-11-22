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

## Try it

From the prebuilt image, with nothing to build and no keys to set up:

```sh
docker run -d --name kamal-panel -p 8080:80 \
  -v kamal_panel_storage:/rails/storage ghcr.io/wenlingang/kamal-panel:latest
docker logs kamal-panel 2>&1 | grep '\[setup\]'   # the one-time link that creates the first admin
```

Open that link (with `<panel address>` replaced by `http://localhost:8080`), create the admin, and you're in.

- When `SECRET_KEY_BASE` and the three `AR_ENCRYPTION_*` keys aren't provided as environment variables,
  the first boot generates them into `storage/panel_secrets.yml` in the volume. That sits next to the
  database: whoever gets the volume can decrypt the stored SSH keys. Before real use, move the values
  into environment variables and delete the file.
- `GET /health` reports whether the panel's background work (status collection, metrics, alert
  evaluation) is still running, 503 when it stalled — point an uptime monitor at it. `/up` only says the
  process is alive.

## Deploy

`config/deploy.yml` is a working Kamal configuration — change `image`, `servers.web` and
`proxy.host`, then:

```sh
bin/rails db:encryption:init   # once; keep the generated keys safe
export KAMAL_REGISTRY_USERNAME=... KAMAL_REGISTRY_PASSWORD=...
export AR_ENCRYPTION_PRIMARY_KEY=... AR_ENCRYPTION_DETERMINISTIC_KEY=... AR_ENCRYPTION_KEY_DERIVATION_SALT=...
bin/kamal setup                # bin/kamal deploy thereafter
```

### Deploying from GitHub Actions

`config/deploy.yml` turns on Kamal's GitHub Actions layer cache when the job's runtime token is
present, so code-only deploys skip the gem install, bootsnap and asset steps. Actions does not
pass that token to `run` steps by itself; export it before `kamal deploy`:

```yaml
- uses: docker/setup-buildx-action@v3
- uses: actions/github-script@v9 # exposes the cache token to the next steps
  with:
    script: |
      for (const k of ["ACTIONS_RUNTIME_TOKEN", "ACTIONS_RUNTIME_URL", "ACTIONS_CACHE_URL", "ACTIONS_RESULTS_URL", "ACTIONS_CACHE_SERVICE_V2"]) {
        if (process.env[k]) core.exportVariable(k, process.env[k])
      }
- run: bin/kamal deploy
```

Links in alert notifications need the panel's own address: set `PANEL_URL=https://panel.example.com`
(unset, notifications carry no link). The email channel and password resets need SMTP: `SMTP_ADDRESS`,
`SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `PANEL_MAIL_FROM`.

### Collection load

The panel usually shares hosts with production apps, so how hard it probes them is yours to set:
status-poll cadence, resource-metric interval, whether to run `docker stats` (the costly part) or
read kamal-proxy's routing table, log-keyword scans — globally or per host — and how many days of
collected data to keep (`retention.days`, 7 by default; it sizes the panel's database). The defaults and every
knob are documented in [`config/collection.yml`](config/collection.yml). Override them without
rebuilding the image:

- environment variables for global values, e.g. `COLLECTION_STATUS_IDLE=120`,
  `COLLECTION_METRICS_CONTAINERS=false`, `COLLECTION_RETENTION_DAYS=3` (under `env.clear` in
  `deploy.yml`);
- a file with the same shape, partial is fine, at `storage/collection.yml` in the panel's volume (or
  wherever `COLLECTION_CONFIG` points) — the only way to set per-host overrides.

Settings are read at boot (restart the panel to apply) and validated: a typo or an out-of-range
value stops the boot with a message naming it.

Then create the first admin from the browser, with the one-time link in `bin/kamal app logs | grep '\[setup\]'`,
or as before with `KAMAL_PANEL_ADMIN_EMAIL=... KAMAL_PANEL_ADMIN_PASSWORD=... bin/rails db:seed`: [Deploying the panel](https://wenlingang.github.io/kamal-panel-site/docs/#deploy).

Background jobs run in three workers by kind (`config/queue.yml`), each sized by an environment
variable: `JOB_THREADS` (collection, 3 by default), `ACTION_THREADS` (kamal actions, 2; each runs a
~100–150 MB kamal process) and `ALERT_THREADS` (alerting, 1).

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
