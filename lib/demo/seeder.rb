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

    # name => [service, hosts, options]
    APPS = {
      "demo-shop"    => [ "shop",    %w[10.1.0.11 10.1.0.12], { worker: true } ],
      "demo-blog"    => [ "blog",    %w[10.1.0.21 10.1.0.22], {} ],
      "demo-api"     => [ "api",     %w[10.1.0.31],           { destination: "staging" } ],
      "demo-jobs"    => [ "jobs",    %w[10.1.0.41 10.1.0.42], {} ],
      "demo-legacy"  => [ "legacy",  %w[10.1.0.61],           {} ],
      "demo-fresh"   => [ "fresh",   %w[10.1.0.51],           {} ],
      "demo-archive" => [ "archive", %w[10.1.0.71],           {} ]
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
      seed_audit_logs
      seed_hook_state

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
        write_state
      end
      apps.fetch("demo-archive").deactivate! if added.key?("demo-archive")

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

        seed_deploy_history
        seed_alerts
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
        # Blocked by the deploy lock: audit is written before taking the lock, so "not executed"
        # itself also leaves a trace
        AuditLog.create!(user: admin, managed_app: jobs, action_name: "stop",
                         target_version: nil, hosts: jobs.cached_app_hosts,
                         result: "failure", command: "(未执行)",
                         output_digest: "部署进行中，未执行。持有者：Locked by: ci",
                         duration_ms: 380, finished_at: now - 2.hours,
                         created_at: now - 2.hours)
        # In progress: this is exactly the record left behind when the panel crashes midway; it's
        # evidence that "someone started this"
        AuditLog.create!(user: admin, managed_app: blog, action_name: "rollback",
                         target_version: "7b19e04", hosts: blog.cached_app_hosts,
                         result: "pending", created_at: now - 40.seconds)
      end

      def seed_hook_state
        shop, blog = apps.values_at("demo-shop", "demo-blog")

        shop.regenerate_hook_token! unless shop.hook_reporting_enabled?
        blog.reject_hook!("收到 service=blog / destination=staging 的上报，但这个 token " \
                          "属于本应用。请检查是不是把 token 粘到了别的项目或别的 " \
                          "destination 的 hook 里。")
      end

      def build(name, service, hosts, destination: "production", worker: false)
        ManagedApp.create!(name: name, destination: destination,
                           config_yaml: deploy_yaml(service, hosts, worker: worker))
      end

      def deploy_yaml(service, hosts, worker: false)
        roles = +"  web:\n" + hosts.map { |h| "    - #{h}" }.join("\n")
        if worker
          roles << "\n  worker:\n    hosts:\n"
          roles << hosts.map { |h| "      - #{h}" }.join("\n")
          roles << "\n    cmd: bin/jobs"
        end

        <<~YAML
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
