# frozen_string_literal: true

# Construction logic for the demo data. Called only by lib/tasks/demo.rake (and only in
# development), and takes part in no production code path.
#
# The values are all deliberately "realistic": version strings have the shape of a seven-character
# sha, hosts are on an internal network range, initiators are CI and humans, and durations range
# from tens of seconds to hours, because this data exists to let people judge "is this UI any good
# in real conditions", not to prove the pages render.
#
# Two entry points:
# - call     creates the demo apps and everything about them, audit entries included.
# - refresh  rewrites only what goes stale or gets overwritten (observations, routing, deploy
#            events), relative to now. Demo hosts are made-up addresses, so a single real poll
#            (say, someone clicks "Refresh now" on a demo app) replaces the scenario with SSH
#            errors, and after half an hour everything reads as stale anyway. Audit entries are
#            left alone: they can't be deleted by design, and they don't go stale.
module Demo
  class Seeder
    PREFIX = "demo-"

    # Earlier collection rounds per app for the heartbeat strip, ROUND_INTERVAL apart.
    HISTORY_ROUNDS = 39
    ROUND_INTERVAL = 30.seconds

    # name => [service, hosts, options]
    APPS = {
      "demo-shop"    => [ "shop",    %w[10.1.0.11 10.1.0.12], { worker: true, accessories: true } ],
      "demo-blog"    => [ "blog",    %w[10.1.0.21 10.1.0.22], {} ],
      "demo-api"     => [ "api",     %w[10.1.0.31],           { destination: "staging" } ],
      "demo-jobs"    => [ "jobs",    %w[10.1.0.41 10.1.0.42], {} ],
      "demo-legacy"  => [ "legacy",  %w[10.1.0.61],           {} ],
      "demo-fresh"   => [ "fresh",   %w[10.1.0.51],           {} ],
      "demo-archive" => [ "archive", %w[10.1.0.71],           {} ]
    }.freeze

    # Resource metrics: a day of samples, every METRIC_COARSE apart and every minute for the last
    # hour, so all four chart ranges have something to draw.
    METRIC_SPAN = 24.hours
    METRIC_COARSE = 5.minutes
    METRIC_FINE_SPAN = 1.hour

    # host => [cpus, memory GiB, disk GiB, disk used share, base load share]. 10.1.0.22 is nearly
    # full: it is the host whose deploy failed with "no space left on device".
    METRIC_HOSTS = {
      "10.1.0.11" => [ 4, 8, 80, 0.58, 0.35 ],
      "10.1.0.12" => [ 4, 8, 80, 0.55, 0.30 ],
      "10.1.0.19" => [ 2, 4, 200, 0.41, 0.25 ],
      "10.1.0.21" => [ 2, 4, 40, 0.74, 0.20 ],
      "10.1.0.22" => [ 2, 4, 40, 0.93, 0.22 ],
      "10.1.0.31" => [ 2, 2, 40, 0.48, 0.45 ],
      "10.1.0.41" => [ 2, 4, 60, 0.37, 0.15 ],
      "10.1.0.42" => [ 2, 4, 60, 0.39, 0.15 ],
      "10.1.0.61" => [ 1, 2, 20, 0.66, 0.10 ]
    }.freeze

    def self.apps = ManagedApp.where("name LIKE ?", "#{PREFIX}%")

    def initialize(admin = nil)
      @admin = admin
      @now = Time.current
    end

    def call
      APPS.each { |name, (service, hosts, options)| build(name, service, hosts, **options) }
      write_state
      apps.fetch("demo-archive").deactivate!
      seed_git
      seed_audit_logs
      seed_hook_state
      seed_alerting

      puts "演示数据就绪：#{self.class.apps.count} 个应用、" \
           "#{DeployEvent.count} 条部署事件、#{AuditLog.count} 条审计"
    end

    def refresh
      raise ArgumentError, "还没有演示数据，先运行 bin/rails demo:seed" if apps.empty?

      # Scenarios added after this database was seeded are created here, so an older demo set can
      # be brought up to date without resetting the whole development database.
      added = APPS.except(*apps.keys)
      added.each { |name, (service, hosts, options)| build(name, service, hosts, **options) }
      @apps = nil

      ids = apps.values.map(&:id)
      ManagedApp.transaction do
        Observation.where(managed_app_id: ids).delete_all
        ProxyTarget.where(managed_app_id: ids).delete_all
        DeployEvent.where(managed_app_id: ids).delete_all
        # Alert events are not audit: they go stale like observations, so they are rebuilt as of now.
        AlertEvent.where(managed_app_id: ids).delete_all
        ContainerMetric.where(managed_app_id: ids).delete_all
        HostMetric.where(managed_app_id: ids).delete_all
        write_state
      end
      apps.fetch("demo-archive").deactivate! if added.key?("demo-archive")
      seed_git
      seed_alerting

      puts "演示数据已刷新到当前时间（审计记录保持不变）" +
           (added.any? ? "，新增 #{added.keys.join('、')}" : "")
    end

    private
      attr_reader :admin, :now

      def apps
        @apps ||= self.class.apps.index_by(&:name)
      end

      def write_state
        seed_healthy(apps.fetch("demo-shop"))
        seed_drift(apps.fetch("demo-blog"))
        seed_unhealthy(apps.fetch("demo-api"))
        seed_unreachable(apps.fetch("demo-jobs"))
        seed_stale(apps.fetch("demo-legacy"))
        seed_archived(apps.fetch("demo-archive"))
        # demo-fresh: just onboarded, never collected once: what does the empty state look like

        seed_heartbeats
        seed_deploy_history
        seed_alerts
        seed_metrics
      end

      # Earlier collection rounds, so the heartbeat strips have a story to tell: a blip that
      # recovered, a drift that started a few minutes ago, a host that dropped off. Each scenario's
      # current round (written above) stays the newest, so the badges are unchanged.
      def seed_heartbeats
        history(apps.fetch("demo-shop"), version: "9f3c2a1") { |i| i.between?(14, 15) ? :unhealthy : :ok }
        history(apps.fetch("demo-blog"), version: "2c84f6d", next_version: "7b19e04") { |i| i >= 28 ? :drift : :ok }
        history(apps.fetch("demo-api"), version: "44ab90c") { |i| i >= 31 && i.even? ? :unhealthy : :ok }
        history(apps.fetch("demo-jobs"), version: "5d7e118") { |i| i >= 34 ? :unreachable : :ok }
        history(apps.fetch("demo-legacy"), version: "1f0e2d3", latest_at: now - 2.hours) { :ok }
      end

      def history(app, version:, next_version: nil, latest_at: now - 20.seconds)
        hosts = app.cached_app_hosts

        HISTORY_ROUNDS.times do |i|
          at = latest_at - (HISTORY_ROUNDS - i) * ROUND_INTERVAL
          state = yield(i)

          hosts.each_with_index do |host, index|
            first, last = index.zero?, index == hosts.size - 1

            if state == :unreachable && last && hosts.size > 1
              observe(app, host:, version: nil, status: nil, reachable: false,
                           error: "SSH 连接超时（5s）", observed_at: at)
            else
              observe(app, host:, version: (state == :drift && first ? next_version : version),
                           health: (state == :unhealthy && first ? "unhealthy" : "healthy"), observed_at: at)
            end
          end
        end
      end

      # All normal: two machines, web and worker roles, the same version, both taking traffic.
      def seed_healthy(app)
        app.cached_app_hosts.each do |host|
          observe(app, host: host, version: "9f3c2a1", health: "healthy")
          observe(app, host: host, version: "9f3c2a1", role: "worker")
          route(app, host: host, container: "shop-web-production-9f3c2a1")
        end
      end

      # Version drift: one machine has moved to the new version while the other is still on the old
      # one; this is the number-one scenario this product must show at a glance.
      def seed_drift(app)
        observe(app, host: "10.1.0.21", version: "7b19e04", health: "healthy")
        observe(app, host: "10.1.0.22", version: "2c84f6d", health: "healthy")
        # The old version's container is still on the machine (stopped); rollback candidates come
        # from here
        observe(app, host: "10.1.0.21", version: "2c84f6d", status: "exited")

        route(app, host: "10.1.0.21", container: "blog-web-production-7b19e04")
        route(app, host: "10.1.0.22", container: "blog-web-production-2c84f6d")
      end

      # Container is up but fails its health check
      def seed_unhealthy(app)
        observe(app, host: "10.1.0.31", version: "44ab90c", health: "unhealthy")
        route(app, host: "10.1.0.31", container: "api-web-staging-44ab90c", state: "unhealthy")
      end

      # One machine is unreachable: the panel shows its [last known state] rather than clearing it
      # (spec 6.4)
      def seed_unreachable(app)
        observe(app, host: "10.1.0.41", version: "5d7e118", health: "healthy")
        observe(app, host: "10.1.0.42", version: nil, status: nil,
                     reachable: false, error: "SSH 连接超时（5s）")
      end

      # Every host answered last time, but that was two hours ago: collection has stalled. This is
      # "data stale", not "host unreachable", and the badge must say so.
      def seed_stale(app)
        observe(app, host: "10.1.0.61", version: "1f0e2d3", health: "healthy", observed_at: now - 2.hours)
        route(app, host: "10.1.0.61", container: "legacy-web-production-1f0e2d3", observed_at: now - 2.hours)
      end

      # Deactivated: absent from the overview grid, listed in its own section below it.
      def seed_archived(app)
        observe(app, host: "10.1.0.71", version: "0aa1b2c", health: "healthy", observed_at: now - 3.days)
      end

      def seed_deploy_history
        shop = apps.fetch("demo-shop")
        # Hook report: initiator and command are available, and the observation delay is positive
        # (the panel only sees it after the report)
        DeployEvent.create!(managed_app: shop, version: "9f3c2a1", source: "hook",
                            performer: "ci-bot", command: "deploy",
                            started_at: now - 42.minutes, succeeded_at: now - 39.minutes,
                            observed_at: now - 39.minutes + 54.seconds,
                            recorded_at: now - 39.minutes)
        DeployEvent.create!(managed_app: shop, version: "8e1d5b0", source: "hook",
                            performer: "wen", command: "rollback",
                            started_at: now - 3.hours, succeeded_at: now - 3.hours + 2.minutes,
                            observed_at: now - 3.hours + 90.seconds,
                            recorded_at: now - 3.hours)
        # A deploy started from the panel that failed half-way: the first host took the new version, the
        # second didn't — which is how demo-blog came to drift. Linked to its audit row (and output)
        # once that exists (seed_audit_logs runs after this on a first seed).
        blog = apps.fetch("demo-blog")
        DeployEvent.create!(managed_app: blog, version: "7b19e04", source: "panel",
                            performer: admin&.display_name || "admin", command: "deploy",
                            started_at: now - 18.minutes, failed_at: now - 15.minutes,
                            observed_at: now - 17.minutes,
                            audit_log: AuditLog.find_by(managed_app: blog, action_name: "deploy",
                                                        target_version: "7b19e04"))
        # Panel inference: no initiator or command, since they can't be told from the machine
        DeployEvent.create!(managed_app: apps.fetch("demo-blog"), version: "2c84f6d", source: "inferred",
                            succeeded_at: now - 6.hours, observed_at: now - 6.hours)
      end

      def seed_alerts
        # Alert one: the report says success, but this version isn't observed on any machine
        DeployEvent.create!(managed_app: apps.fetch("demo-api"), version: "44ab90c", source: "hook",
                            performer: "ci-bot", command: "deploy",
                            started_at: now - 9.minutes, succeeded_at: now - 7.minutes,
                            recorded_at: now - 7.minutes)
        # Alert two: started but never finished (Kamal has no failure hook, so a failed deploy can
        # only be seen this way)
        DeployEvent.create!(managed_app: apps.fetch("demo-jobs"), version: "6a0c933", source: "hook",
                            performer: "ci-bot", command: "deploy",
                            started_at: now - 38.minutes, recorded_at: now - 38.minutes)
      end

      def seed_audit_logs
        shop, blog, jobs = apps.values_at("demo-shop", "demo-blog", "demo-jobs")

        AuditLog.create!(user: admin, managed_app: shop, action_name: "restart",
                         target_version: "9f3c2a1", hosts: shop.cached_app_hosts,
                         result: "success", command: "kamal app boot --version 9f3c2a1",
                         output_digest: "INFO [a1b2] Running docker start on 10.1.0.11\n" \
                                        "INFO [a1b2] Finished in 2.1 seconds",
                         duration_ms: 4210, finished_at: now - 55.minutes,
                         created_at: now - 56.minutes)
        AuditLog.create!(user: admin, managed_app: shop, action_name: "accessory_restart",
                         target: "cache", hosts: [ "10.1.0.11" ],
                         result: "success", command: "kamal accessory restart cache --version panel-3e9a01c2",
                         output_digest: "INFO [c3d4] Running docker container stop shop-cache on 10.1.0.11\n" \
                                        "INFO [c3d4] Running docker container start shop-cache on 10.1.0.11",
                         duration_ms: 3120, finished_at: now - 30.minutes,
                         created_at: now - 31.minutes)
        # Blocked by the deploy lock: audit is written before taking the lock, so "not executed"
        # itself also leaves a trace
        AuditLog.create!(user: admin, managed_app: jobs, action_name: "stop",
                         target_version: nil, hosts: jobs.cached_app_hosts,
                         result: "failure", command: "(未执行)",
                         output_digest: "部署进行中，未执行。持有者：Locked by: ci",
                         duration_ms: 380, finished_at: now - 2.hours,
                         created_at: now - 2.hours)
        # The failed panel deploy behind demo-blog's drift (its DeployEvent is in seed_deploy_history).
        deploy = AuditLog.create!(user: admin, managed_app: blog, action_name: "deploy",
                                  target_version: "7b19e04", hosts: blog.cached_app_hosts,
                                  result: "failure", command: "kamal deploy --skip-push --version 7b19e04",
                                  output_digest: "Pull app image...\n" \
                                                 "INFO [5e1f] Running docker pull ghcr.io/acme/blog:7b19e04 on 10.1.0.21\n" \
                                                 "INFO [5e1f] Finished in 6.2 seconds with exit status 0 (successful).\n" \
                                                 "ERROR (SSHKit::Command::Failed): docker exit status: 1\n" \
                                                 "docker stderr: Error response from daemon: no space left on device (10.1.0.22)",
                                  duration_ms: 182_000, finished_at: now - 15.minutes,
                                  created_at: now - 18.minutes)
        DeployEvent.where(managed_app: blog, source: "panel", version: "7b19e04").update_all(audit_log_id: deploy.id)
        # In progress: this is exactly the record left behind when the panel crashes midway; it's
        # evidence that "someone started this"
        AuditLog.create!(user: admin, managed_app: blog, action_name: "rollback",
                         target_version: "7b19e04", hosts: blog.cached_app_hosts,
                         result: "pending", created_at: now - 40.seconds)
      end

      # A Git connection with a made-up token, so the deploy tab, commit links and the settings page
      # have something to show. Calls to GitHub with it fail (401): that is the degraded path the UI
      # must handle anyway, and the links (built locally) still work.
      def seed_git
        connection = GitConnection.find_or_create_by!(name: "demo-github") do |record|
          record.provider = "github"
          record.token = "demo-token-not-a-real-one"
        end

        { "demo-shop" => "acme/shop", "demo-blog" => "acme/blog" }.each do |name, repository|
          app = apps.fetch(name)
          next if app.git_connection.present?

          app.update!(git_connection: connection, repository: repository, version_format: "short_sha")
        end
      end

      # A channel, a handful of rules, and events that tell a story: demo-api is unhealthy right now
      # (firing), demo-blog's failed panel deploy fired, and two older alerts already resolved. The
      # channel points at a reserved .invalid host and is disabled, so nothing is really sent; "send
      # test" on it shows what a failure looks like.
      def seed_alerting
        channel = NotificationChannel.find_or_create_by!(name: "demo-值班群") do |record|
          record.kind = "webhook"
          record.target = "https://example.invalid/hook"
          record.enabled = false
        end

        rules = {
          "应用不健康" => { condition: "unhealthy", for_minutes: 2 },
          "版本漂移" => { condition: "drift", for_minutes: 5 },
          "容器内存过高" => { condition: "memory_high", for_minutes: 5, params: { "threshold" => 90 } },
          "发布失败" => { condition: "deploy_failed", for_minutes: 0 },
          "日志 ERROR" => { condition: "log_keyword", for_minutes: 0, managed_app: apps.fetch("demo-shop"),
                            params: { "keyword" => "ERROR", "window_minutes" => 5, "threshold" => 3, "log_source" => "app" } }
        }.to_h do |name, attributes|
          rule = AlertRule.find_or_create_by!(name:) do |record|
            record.assign_attributes(attributes)
            # Created "a while ago", so the deploy failure from earlier falls inside its lookback.
            record.created_at = now - 1.day
            record.notification_channels = [ channel ]
          end
          [ attributes[:condition], rule ]
        end

        api, blog, shop, jobs = apps.values_at("demo-api", "demo-blog", "demo-shop", "demo-jobs")
        failed = DeployEvent.find_by(managed_app: blog, source: "panel", version: "7b19e04")

        AlertEvent.create!(alert_rule: rules["unhealthy"], managed_app: api, state: "firing",
                           message_key: "unhealthy", started_at: now - 8.minutes, fired_at: now - 6.minutes,
                           last_notified_at: now - 6.minutes)
        # demo-api's web container has been near its memory limit all day (seed_metrics).
        memory = ContainerMetric.where(managed_app: api).order(:sampled_at).last
        AlertEvent.create!(alert_rule: rules["memory_high"], managed_app: api, state: "firing",
                           message_key: "memory_high",
                           message_args: { "container" => memory&.container_name, "host" => memory&.host,
                                           "percent" => memory&.mem_percent&.round(1), "threshold" => 90 },
                           started_at: now - 3.hours, fired_at: now - 3.hours + 5.minutes,
                           last_notified_at: now - 25.minutes)
        # Same dedupe key the evaluator would use, so a real evaluation doesn't raise it a second time.
        AlertEvent.create!(alert_rule: rules["deploy_failed"], managed_app: blog, state: "firing",
                           dedupe_key: "deploy_event:#{failed&.id}", message_key: "deploy_failed",
                           message_args: { "version" => "7b19e04" }, started_at: now - 15.minutes,
                           fired_at: now - 15.minutes + 20.seconds, last_notified_at: now - 15.minutes + 20.seconds)
        # The heartbeat blip on demo-shop (rounds 14–15) and an error burst on demo-jobs last night.
        AlertEvent.create!(alert_rule: rules["unhealthy"], managed_app: shop, state: "resolved",
                           message_key: "unhealthy", started_at: now - 13.minutes, fired_at: now - 11.minutes,
                           resolved_at: now - 10.minutes, last_notified_at: now - 11.minutes)
        AlertEvent.create!(alert_rule: rules["log_keyword"], managed_app: shop, state: "resolved",
                           message_key: "log_keyword",
                           message_args: { "keyword" => "ERROR", "count" => 17, "threshold" => 3, "window" => 5 },
                           started_at: now - 9.hours, fired_at: now - 9.hours, resolved_at: now - 8.hours - 35.minutes,
                           last_notified_at: now - 9.hours)
        AlertEvent.create!(alert_rule: rules["drift"], managed_app: jobs, state: "resolved",
                           message_key: "drift", message_args: { "versions" => "5d7e118, 4c2b9a0" },
                           started_at: now - 2.days, fired_at: now - 2.days + 5.minutes,
                           resolved_at: now - 2.days + 22.minutes, last_notified_at: now - 2.days + 5.minutes)
      end

      # A day of container and host samples. The shapes are deterministic (a seeded Random) and tell
      # the same stories as the rest of the demo: demo-api's web container lives near its 512 MiB
      # limit (the memory alert), 10.1.0.22's disk is nearly full, demo-jobs' second host stopped
      # answering a few minutes ago, and demo-legacy's collection stalled two hours ago.
      def seed_metrics
        random = Random.new(42)
        last = now.change(sec: 0)
        times = metric_times(last)

        containers = [
          [ "demo-shop", "10.1.0.11", "web", "shop-web-production-9f3c2a1", 18, 420, 1024, "9f3c2a1" ],
          [ "demo-shop", "10.1.0.12", "web", "shop-web-production-9f3c2a1", 15, 405, 1024, "9f3c2a1" ],
          [ "demo-shop", "10.1.0.11", "worker", "shop-worker-production-9f3c2a1", 30, 610, nil, "9f3c2a1" ],
          [ "demo-shop", "10.1.0.12", "worker", "shop-worker-production-9f3c2a1", 26, 590, nil, "9f3c2a1" ],
          [ "demo-shop", "10.1.0.19", "db", "shop-db", 9, 1350, nil, nil ],
          [ "demo-shop", "10.1.0.11", "cache", "shop-cache", 2, 95, 256, nil ],
          [ "demo-shop", "10.1.0.11", "kamal-proxy", "kamal-proxy", 1, 28, nil, nil ],
          [ "demo-shop", "10.1.0.12", "kamal-proxy", "kamal-proxy", 1, 27, nil, nil ],
          [ "demo-blog", "10.1.0.21", "web", "blog-web-production-7b19e04", 7, 260, 768, "7b19e04" ],
          [ "demo-blog", "10.1.0.22", "web", "blog-web-production-2c84f6d", 6, 240, 768, "2c84f6d" ],
          [ "demo-api", "10.1.0.31", "web", "api-web-staging-44ab90c", 42, 478, 512, "44ab90c" ],
          [ "demo-api", "10.1.0.31", "kamal-proxy", "kamal-proxy", 1, 30, nil, nil ],
          [ "demo-jobs", "10.1.0.41", "web", "jobs-web-production-5d7e118", 12, 330, nil, "5d7e118" ],
          [ "demo-jobs", "10.1.0.42", "web", "jobs-web-production-5d7e118", 11, 320, nil, "5d7e118" ],
          [ "demo-legacy", "10.1.0.61", "web", "legacy-web-production-1f0e2d3", 5, 180, nil, "1f0e2d3" ]
        ]

        rows = containers.flat_map do |name, host, source, container, cpu, mem_mib, limit_mib, version|
          app = apps.fetch(name)
          kind = if source == "kamal-proxy" then "proxy"
          elsif version then "app"
          else "accessory"
          end
          host_mem = METRIC_HOSTS.fetch(host)[1] * 1024**3

          metric_times_for(times, host, name).map do |at|
            wave = daily_wave(at)
            cpu_now = (cpu * (0.6 + 0.6 * wave) * (0.8 + 0.4 * random.rand)).round(2)
            mem = (mem_mib * (0.97 + 0.03 * wave + 0.02 * random.rand) * 1024**2).round
            mem = [ mem, limit_mib * 1024**2 * 0.97 ].min.round if limit_mib
            limit = limit_mib && limit_mib * 1024**2
            { managed_app_id: app.id, host:, container_name: container, source:, kind:, version:,
              cpu_percent: cpu_now, mem_bytes: mem, mem_limit_bytes: limit,
              mem_percent: (100.0 * mem / (limit || host_mem)).round(2),
              net_rx_bytes: nil, net_tx_bytes: nil, block_read_bytes: nil, block_write_bytes: nil,
              pids: kind == "app" ? 12 + random.rand(6) : 4, sampled_at: at }
          end
        end
        ContainerMetric.insert_all!(rows)

        # Host samples are per app (see HostMetric); in the demo each host serves one app.
        host_apps = containers.to_h { |name, host, *| [ host, apps.fetch(name) ] }

        host_rows = METRIC_HOSTS.filter_map { |host, spec| [ host, spec ] if host_apps.key?(host) }
                                .flat_map do |host, (cpus, mem_gib, disk_gib, disk_share, load_share)|
          owner = host == "10.1.0.42" ? "demo-jobs" : (host == "10.1.0.61" ? "demo-legacy" : nil)
          metric_times_for(times, host, owner).map do |at|
            wave = daily_wave(at)
            load1 = (cpus * load_share * (0.5 + wave) * (0.8 + 0.4 * random.rand)).round(2)
            mem_total = mem_gib * 1024**3
            mem_used_share = host == "10.1.0.31" ? 0.82 + 0.04 * random.rand : 0.45 + 0.15 * wave + 0.05 * random.rand
            disk_total = disk_gib * 1024**3
            { managed_app_id: host_apps.fetch(host).id, host:, load1:, load5: (load1 * 0.9).round(2), load15: (load1 * 0.8).round(2), cpus:,
              cpu_percent: [ (100.0 * load1 / cpus * 0.8).round(1), 100.0 ].min,
              cpu_total_jiffies: nil, cpu_idle_jiffies: nil,
              mem_total_bytes: mem_total, mem_available_bytes: (mem_total * (1 - mem_used_share)).round,
              swap_total_bytes: 1024**3, swap_free_bytes: (1024**3 * (0.9 + 0.1 * random.rand)).round,
              disk_total_bytes: disk_total,
              disk_used_bytes: (disk_total * (disk_share + 0.01 * (at - (now - METRIC_SPAN)) / METRIC_SPAN)).round,
              sampled_at: at }
          end
        end
        HostMetric.insert_all!(host_rows)
      end

      def metric_times(last)
        fine_start = last - METRIC_FINE_SPAN
        coarse = []
        at = fine_start - METRIC_COARSE
        while at >= last - METRIC_SPAN
          coarse.unshift(at)
          at -= METRIC_COARSE
        end
        coarse + (0..(METRIC_FINE_SPAN / 60)).map { |i| fine_start + i.minutes }
      end

      # demo-jobs' second host went dark a few minutes ago; demo-legacy stopped two hours ago.
      def metric_times_for(times, host, app_name)
        cutoff =
          if host == "10.1.0.42" then now - 4.minutes
          elsif app_name == "demo-legacy" then now - 2.hours
          end
        cutoff ? times.select { |at| at < cutoff } : times
      end

      # Busy in the afternoon, quiet at night: 0 at 04:00, 1 at 16:00.
      def daily_wave(at)
        hours = at.hour + at.min / 60.0
        (1 - Math.cos((hours - 4) / 24.0 * 2 * Math::PI)) / 2
      end

      def seed_hook_state
        shop, blog = apps.values_at("demo-shop", "demo-blog")

        shop.regenerate_hook_token! unless shop.hook_reporting_enabled?
        blog.reject_hook!("收到 service=blog / destination=staging 的上报，但这个 token " \
                          "属于本应用。请检查是不是把 token 粘到了别的项目或别的 " \
                          "destination 的 hook 里。")
      end

      def build(name, service, hosts, destination: "production", worker: false, accessories: false)
        ManagedApp.create!(name: name, destination: destination,
                           config_yaml: deploy_yaml(service, hosts, worker:, accessories:))
      end

      def deploy_yaml(service, hosts, worker: false, accessories: false)
        roles = +"  web:\n" + hosts.map { |h| "    - #{h}" }.join("\n")
        if worker
          roles << "\n  worker:\n    hosts:\n"
          roles << hosts.map { |h| "      - #{h}" }.join("\n")
          roles << "\n    cmd: bin/jobs"
        end

        yaml = <<~YAML
          service: #{service}
          image: acme/#{service}
          servers:
          #{roles}
          registry:
            server: ghcr.io
            username: acme
            password:
              - KAMAL_REGISTRY_PASSWORD
          builder:
            arch: amd64
          ssh:
            user: deploy
        YAML
        accessories ? yaml + accessories_yaml(hosts) : yaml
      end

      # A database on its own host and a cache next to the app, so the actions tab has
      # accessories to show (one row each, with restart / rebuild).
      def accessories_yaml(hosts)
        <<~YAML
          accessories:
            db:
              image: postgres:16
              host: 10.1.0.19
            cache:
              image: redis:7
              host: #{hosts.first}
        YAML
      end

      # All machines in the same collection round share one timestamp; the real ContainerCollector
      # does exactly this.
      def observe(app, host:, version:, status: "running", health: nil, role: "web",
                  reachable: true, error: nil, observed_at: now - 20.seconds)
        Observation.create!(
          managed_app: app, host: host, role: role, version: version,
          container_name: version && "#{app.service}-#{role}-#{app.destination}-#{version}",
          docker_status: status, health: health, reachable: reachable, error: error,
          observed_at: observed_at
        )
      end

      # kamal-proxy's routing table points at the [container name], not host:port. If this is wrong,
      # a "normal" app shows taking traffic as "no", and the whole demo data contradicts itself.
      def route(app, host:, container:, state: "healthy", observed_at: now - 20.seconds)
        ProxyTarget.create!(managed_app: app, host: host, service_name: app.service,
                            target: "#{container}:3000", state: state,
                            reachable: true, observed_at: observed_at)
      end
  end
end
