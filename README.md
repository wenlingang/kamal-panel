# kamal-panel

**English** | [简体中文](README.zh-CN.md)

A read-only(-ish) control panel for [Kamal](https://kamal-deploy.org/) deployments: an
Application × Host overview that answers "is anything broken?" in a few seconds, without
you having to SSH into every box and run `kamal app details` by hand.

kamal-panel does **not** replace Kamal. It reads the state Kamal already produces
(`docker ps`, `kamal-proxy list --json`) over SSH and renders it. Deploys still happen
via `kamal deploy` from CI, exactly as before.

---

## ⚠️ Security posture — read this before you run it anywhere

> **The panel's security level equals the security level of every server it manages.**
> Anyone who can reach the panel and read its database can, transitively, act on your
> infrastructure. Treat it with the same care as an SSH private key.

- **Every page requires a signed-in user.** There are two roles: **viewer** (read-only)
  and **operator** (can also perform write operations — see "Roles" below).
  `POST /apps` (the "add an application" endpoint) and every action endpoint require the
  **operator** role — see "Deployment: the first operator account" below for how to
  create the first account. Finer-grained RBAC / SSO is out of scope.
- **Adding an Application is code execution, not configuration.** Parsing a pasted
  `deploy.yml` requires evaluating ERB and then `YAML.unsafe_load`-ing the result — that's
  how Kamal itself works, and there's no way around it without losing ERB support. This
  panel does that parsing in an isolated, resource- and time-limited subprocess rather
  than in the web or job process (see spec §7.6), but the practical consequence stands:
  **anyone who can submit a `deploy.yml` to this panel can run arbitrary Ruby on the host
  it's deployed on.** Don't let untrusted users near the "add application" form.
- SSH private keys are encrypted at rest (Rails 8 Active Record encryption) and are
  **write-only**: the UI never displays or downloads a stored key, only its fingerprint.

## Roles

- **viewer** — can only look. Sees no action buttons at all: the panel hides them rather
  than showing greyed-out ones, so a viewer never has to guess what they're allowed to do.
- **operator** — can roll back, restart, stop, start, force-unlock a stale deploy lock,
  and add applications.

> **Adding an application is equivalent to running code on the panel's own host.** A
> pasted `deploy.yml` gets ERB-evaluated (see the security section above), so grant
> `operator` only to people you trust that far.

Destructive actions need more than the role: the affected hosts and roles are shown
before you commit, and rollback and force-unlock additionally require typing the
application's name by hand. Every action is written to the audit log **before** it runs
(`pending`), and the log cannot be deleted from the UI or through Active Record.

## How the panel performs write operations

The panel **never assembles remote commands itself.** Rollback, restart, stop, start and
force-unlock all run the real `kamal` CLI in a restricted subprocess, so behaviour matches
what you'd get typing `kamal rollback` yourself — including your own pre/post-deploy
hooks, the `kamal-proxy` route switch, and the health checks. Re-implementing that on top
of `Kamal::Commands::App` would mean maintaining a second implementation that has to agree
with Kamal forever.

Two consequences worth knowing:

- The private key is injected through a **fresh `ssh-agent` per invocation** (`ssh-add -`
  reading from stdin); it is never written to disk, not even to a 0600 temp file.
- The action set is **closed and defined in code** (`app/services/actions/`). There is no
  free-text command input, and adding one would undo every other security decision here.

Because the panel doesn't trust a command's exit status as the final word, finishing an
action triggers a short burst of polling: the answer to "did it work?" comes from fresh
`docker ps` observations, not from the CLI's return code.

Rollback only offers versions it can prove are rollback-able: `kamal rollback` refuses
unless that version's container still exists on every host, and the panel already holds a
full `docker ps --all` per host — so unavailable versions are listed greyed out, naming
the host where the container was already pruned, instead of failing after you click.

## Deploy reporting (optional)

SSH polling answers "what is running right now". It cannot answer "who deployed this,
when, and did the previous attempt fail?" — a failed deploy leaves the running version
unchanged, so polling sees nothing at all.

Kamal already runs your `.kamal/hooks/*` during a deploy and hands them
`KAMAL_SERVICE`, `KAMAL_VERSION`, `KAMAL_PERFORMER`, `KAMAL_DESTINATION`,
`KAMAL_RECORDED_AT` and `KAMAL_COMMAND`. The panel gives you two `curl` snippets —
one for `pre-deploy`, one for `post-deploy` — generated per application from its
detail page, and stores what they report as deploy history.

**This is optional.** Without it everything else works; you just don't get deploy
history, and the panel can't tell you "this version was reported deployed but never
showed up on any machine".

Two properties of the generated snippets are non-negotiable, and you should check they
survive any edit you make:

- `--max-time 5` and a trailing `|| true`. **The panel going down or getting slow must
  never fail or stall your deploy.**
- The hook files need the executable bit (`chmod +x`) — Kamal runs them as executables.

The reporting token is per application and is shown **once**, at generation time; the
panel stores only its SHA256 digest and cannot show it to you again. Regenerating
invalidates the previous one immediately.

When a report says a version deployed successfully but no machine is observed running it
within 90 seconds, the panel says so on the application page rather than picking one of
the two sources to trust. The warning clears itself once the version is observed, and the
history row keeps the delay — so "every deploy takes four minutes to actually show up"
stays visible as a pattern.

Even without the hooks you get *some* history: every poll compares the version running on
each host, and when all of them converge on a version different from the last one, the
panel records that as an inferred deployment. That gives you "something was deployed, and
when" — but not who did it, not the command, and not failed deploys, since a failed deploy
leaves the running version unchanged. Those three only come from the hooks.

## What it deliberately does *not* do

| Not doing | Why |
|---|---|
| Building or publishing new versions | The panel never touches your source code. New builds come from CI running `kamal deploy`. |
| Git integration | `deploy.yml` is pasted in by hand. The panel holds no git credentials, ever. |
| `kamal app exec` / arbitrary remote shell | This is the one feature that would turn the panel into a web-based remote shell and invalidate every other security decision in this project. It is a deliberate omission, not a TODO. |
| Kamal 1.x support | Only **Kamal 2+** is supported. Kamal 1.x used Traefik instead of `kamal-proxy` and has a different container-label model, deploy-lock format, and routing story — supporting both would mean maintaining two parallel collection/execution paths. |
| Fine-grained RBAC / SSO | There are exactly two roles, viewer and operator — nothing more granular. |
| Fleets over ~50 hosts | See below. |

## Scale ceiling

This design targets **up to ~50 hosts**. Every poll fans out one SSH connection per
configured host per managed app; past roughly 50 hosts that fan-out becomes the
bottleneck, and the right fix at that point is a different architecture (e.g. an agent),
not a bigger box. If you're operating a fleet near or beyond that size, this tool is not
(yet) for you.

---

## Getting started (development)

### 1. Ruby & dependencies

Ruby version: see `.ruby-version`. Then:

```sh
bin/setup
```

### 2. Active Record encryption credentials (required)

SSH private keys are stored via Rails 8's `active_record_encryption`, whose keys are read
**only from environment variables / Rails credentials**, never hardcoded. Without this
step you cannot save an SSH private key, which means you cannot complete onboarding an
application in the UI at all:

```sh
bin/rails db:encryption:init
```

Follow the command's output to add the generated keys to your development credentials
(`bin/rails credentials:edit --environment development`) or to the corresponding
`AR_ENCRYPTION_*` environment variables (see `config/application.rb`).

### 3. Database

```sh
bin/rails db:prepare
```

### 4. Demo data (optional, but recommended on a first look)

A freshly installed panel is a blank page, and the whole point of this thing is what it
looks like *when something is wrong*. One command fills the development database with
five applications covering every state — healthy, version drift, an unhealthy container,
an unreachable host, and one never polled — plus both kinds of reconciliation alert,
deploy history from both sources, and audit entries that succeeded, failed and are still
running:

```sh
bin/rails demo:seed
```

It refuses to run outside development, and refuses to run twice (audit logs are
undeletable by design, so there is no "clear and re-seed" — use `bin/rails db:reset`).

## Running the test suite

The test suite exercises real SSH against two containerized "fake hosts" that stand in
for machines running Kamal-deployed containers plus `kamal-proxy`. You need Docker
running locally.

```sh
docker compose -f docker-compose.test.yml up -d --build
```

Wait for both nodes to come up (the compose file exposes node-1 on `localhost:2201` and
node-2 on `localhost:2202`); see `test/fake_host/README.md` for details on the fixture
itself, including why the checked-in test SSH key needs `chmod 600` after a fresh clone
before the system `ssh` client will accept it.

Then run the whole suite:

```sh
bin/rails test:all
```

**Run this in the foreground, as a single process.** Two things about this suite are not
optional:

- **Never trigger a poll against the test database via `bin/rails runner` while
  `RAILS_ENV=test`.** `bin/rails runner` boots a *separate* process from the test run;
  anything it writes lands in the same SQLite test database the test suite is using and
  will corrupt whatever test happens to be running concurrently. If you need to
  experiment against the test fixtures, do it inside `bin/rails console -e test`
  sequentially, never in parallel with `bin/rails test`.
- **Don't parallelize the test run.** The suite relies on SQLite's single-writer
  semantics for a few things (see `10.1` in the design doc for the specific one:
  polling de-duplication) and on exclusive access to the fake-host containers (some
  tests genuinely stop/start a container to simulate an unreachable host). Running
  workers in parallel, or running another `bin/rails` process against the test database
  at the same time, will produce flaky, hard-to-reproduce failures that have nothing to
  do with the code you changed.

`bin/rails test` alone does **not** include the system tests (Rails' default excludes
`test/system`); use `bin/rails test:all` (or `bin/rails test:system` in addition to
`bin/rails test`) if you want the full picture, which is also what CI runs.

## Deployment: the first operator account

There is no default password, ever — a panel that ships with a known credential is worse
than one with no auth, because it looks protected. The first `operator` account is instead
created from environment variables at seed time:

```sh
KAMAL_PANEL_ADMIN_EMAIL=you@example.com \
KAMAL_PANEL_ADMIN_PASSWORD=<a strong, unique password> \
bin/rails db:seed
```

`db/seeds.rb` is idempotent (`find_or_create_by!` on the email), so re-running `db:seed`
on redeploy is safe and won't reset the password of an already-existing account. If
`KAMAL_PANEL_ADMIN_EMAIL` is unset, seeding does nothing — no account, `operator` or
otherwise, is ever created implicitly. Once the first operator exists, further users
(viewer or operator) are managed the same way any other Rails app manages `User` records
(console, a future admin UI, etc.) — this codebase does not yet ship a self-serve sign-up
flow, deliberately.

## Deploying the panel itself

The panel deploys with Kamal, like anything else. `config/deploy.yml` in this repo is a
working configuration with placeholders — `image`, `servers.web` and `proxy.host` are the
three lines you have to change.

```sh
# One-time: generate the Active Record encryption keys and keep them somewhere safe
bin/rails db:encryption:init

# Every deploy reads these from your shell (see .kamal/secrets)
export KAMAL_REGISTRY_USERNAME=your-github-user
export KAMAL_REGISTRY_PASSWORD=<a PAT with write:packages>
export AR_ENCRYPTION_PRIMARY_KEY=... AR_ENCRYPTION_DETERMINISTIC_KEY=... AR_ENCRYPTION_KEY_DERIVATION_SALT=...

bin/kamal setup     # first time
bin/kamal deploy    # thereafter
```

Two things about this deployment are not incidental:

- **It is single-machine by design.** State lives in SQLite and Solid Queue runs inside
  Puma. Adding a second `web` host does not give you a sturdier panel; it gives you two
  panels each holding half the truth and unaware of the other.
- **The storage volume holds encrypted SSH private keys.** Backing it up is backing up
  the access credentials to every server the panel manages. Treat the backup with the
  care you would treat those keys — and note that losing the three `AR_ENCRYPTION_*`
  values makes that volume permanently undecryptable, which means re-entering every key.

`.kamal/hooks/pre-deploy` and `post-deploy` in this repo are the deploy-reporting snippets
from the "Deploy reporting" section above, in reusable form: they read `PANEL_URL` and
`PANEL_TOKEN` from the environment and exit quietly when those are unset, so a repo that
hasn't been wired to a panel doesn't fire requests at nothing on every deploy.

### Don't manage the panel with itself

Adding the panel to its own application list is a foot-gun, and the panel does not stop
you — so this is the warning instead.

Restarting or stopping the panel *from* the panel kills the process midway through its own
command. What you are left with: an audit entry frozen at `pending`, the live output pane
cut off mid-line, and possibly Kamal's deploy lock still held on the primary host, which
someone then has to force-unlock by hand. The `pending` row is not corruption — it is
exactly what the audit design promises ("someone initiated this operation"), and here it
is the only trace of what happened.

If you want the panel's own deploy history in the panel, you have to register it as an
application, and then those action buttons exist for it too. That is the trade-off; make
it knowingly. Deploy the panel from your workstation with `bin/kamal deploy` instead.

