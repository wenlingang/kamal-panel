# frozen_string_literal: true

# 演示数据的构造逻辑。只被 lib/tasks/demo.rake 调用（且只在 development 下），
# 不参与任何生产代码路径。
#
# 取值都刻意"像真的"：版本号是七位 sha 的形状，主机是内网网段，发起人分别是
# CI 与人，时间跨度从几十秒到几小时——因为这份数据的用途是让人判断"这个界面
# 在真实情况下好不好用"，而不是证明页面能渲染。
module Demo
  class Seeder
    def initialize(admin)
      @admin = admin
      @now = Time.current
    end

    def call
      shop = seed_healthy
      blog = seed_drift
      api  = seed_unhealthy
      jobs = seed_unreachable
      seed_never_polled

      seed_deploy_history(shop, blog)
      seed_alerts(api, jobs)
      seed_audit_logs(shop, blog, jobs)
      seed_hook_state(shop, blog)

      puts "演示数据就绪：#{ManagedApp.where('name LIKE ?', 'demo-%').count} 个应用、" \
           "#{DeployEvent.count} 条部署事件、#{AuditLog.count} 条审计"
    end

    private
      attr_reader :admin, :now

      # 一切正常：两台机器、web 与 worker 两个角色，同一版本，都在接流量。
      def seed_healthy
        app = build("demo-shop", "shop", %w[10.1.0.11 10.1.0.12], worker: true)

        app.cached_app_hosts.each do |host|
          observe(app, host: host, version: "9f3c2a1", health: "healthy")
          observe(app, host: host, version: "9f3c2a1", role: "worker")
          route(app, host: host, container: "shop-web-production-9f3c2a1")
        end

        app
      end

      # 版本漂移：一台已经换到新版，另一台还停在旧版——这是本产品要一眼看见的头号场景。
      def seed_drift
        app = build("demo-blog", "blog", %w[10.1.0.21 10.1.0.22])

        observe(app, host: "10.1.0.21", version: "7b19e04", health: "healthy")
        observe(app, host: "10.1.0.22", version: "2c84f6d", health: "healthy")
        # 旧版本的容器还留在机器上（已停止）——回滚候选就是从这里来的
        observe(app, host: "10.1.0.21", version: "2c84f6d", status: "exited")

        route(app, host: "10.1.0.21", container: "blog-web-production-7b19e04")
        route(app, host: "10.1.0.22", container: "blog-web-production-2c84f6d")

        app
      end

      # 容器起来了但健康检查不过
      def seed_unhealthy
        app = build("demo-api", "api", %w[10.1.0.31], destination: "staging")

        observe(app, host: "10.1.0.31", version: "44ab90c", health: "unhealthy")
        route(app, host: "10.1.0.31", container: "api-web-staging-44ab90c", state: "unhealthy")

        app
      end

      # 一台机器连不上：面板显示它【上次已知的状态】而不是清空（spec 6.4）
      def seed_unreachable
        app = build("demo-jobs", "jobs", %w[10.1.0.41 10.1.0.42])

        observe(app, host: "10.1.0.41", version: "5d7e118", health: "healthy")
        observe(app, host: "10.1.0.42", version: nil, status: nil,
                     reachable: false, error: "SSH 连接超时（5s）")

        app
      end

      # 刚接入、一次都还没采集——空状态长什么样
      def seed_never_polled
        build("demo-fresh", "fresh", %w[10.1.0.51])
      end

      def seed_deploy_history(shop, blog)
        # hook 上报：拿得到发起人与命令，观测延迟是正的（面板在上报之后才看见）
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
        # 面板推断：没有发起人与命令，因为机器上看不出来
        DeployEvent.create!(managed_app: blog, version: "2c84f6d", source: "inferred",
                            succeeded_at: now - 6.hours, observed_at: now - 6.hours)
      end

      def seed_alerts(api, jobs)
        # 告警一：上报说成功了，但任何机器上都观测不到这一版
        DeployEvent.create!(managed_app: api, version: "44ab90c", source: "hook",
                            performer: "ci-bot", command: "deploy",
                            started_at: now - 9.minutes, succeeded_at: now - 7.minutes,
                            recorded_at: now - 7.minutes)
        # 告警二：开了头没收尾（Kamal 没有失败钩子，失败的部署只能这样被看见）
        DeployEvent.create!(managed_app: jobs, version: "6a0c933", source: "hook",
                            performer: "ci-bot", command: "deploy",
                            started_at: now - 38.minutes, recorded_at: now - 38.minutes)
      end

      def seed_audit_logs(shop, blog, jobs)
        AuditLog.create!(user: admin, managed_app: shop, action_name: "restart",
                         target_version: "9f3c2a1", hosts: shop.cached_app_hosts,
                         result: "success", command: "kamal app boot --version 9f3c2a1",
                         output_digest: "INFO [a1b2] Running docker start on 10.1.0.11\n" \
                                        "INFO [a1b2] Finished in 2.1 seconds",
                         duration_ms: 4210, finished_at: now - 55.minutes,
                         created_at: now - 56.minutes)
        # 被部署锁挡下：先写审计再取锁，所以"没执行"这件事本身也留了痕
        AuditLog.create!(user: admin, managed_app: jobs, action_name: "stop",
                         target_version: nil, hosts: jobs.cached_app_hosts,
                         result: "failure", command: "(未执行)",
                         output_digest: "部署进行中，未执行。持有者：Locked by: ci",
                         duration_ms: 380, finished_at: now - 2.hours,
                         created_at: now - 2.hours)
        # 进行中：面板中途崩溃时留下的正是这种记录，它是"有人发起过"的证据
        AuditLog.create!(user: admin, managed_app: blog, action_name: "rollback",
                         target_version: "7b19e04", hosts: blog.cached_app_hosts,
                         result: "pending", created_at: now - 40.seconds)
      end

      def seed_hook_state(shop, blog)
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

      def observe(app, host:, version:, status: "running", health: nil, role: "web",
                  reachable: true, error: nil)
        Observation.create!(
          managed_app: app, host: host, role: role, version: version,
          container_name: version && "#{app.service}-#{role}-#{app.destination}-#{version}",
          docker_status: status, health: health, reachable: reachable, error: error,
          # 同一轮采集里所有机器共享一个时间戳——真实的 ContainerCollector 就是这样
          observed_at: now - 20.seconds
        )
      end

      # kamal-proxy 的路由表指向【容器名】，不是 host:port。填错了的话"正常"的
      # 应用会显示接流量"否"，整份演示数据自相矛盾。
      def route(app, host:, container:, state: "healthy")
        ProxyTarget.create!(managed_app: app, host: host, service_name: app.service,
                            target: "#{container}:3000", state: state,
                            reachable: true, observed_at: now - 20.seconds)
      end
  end
end
