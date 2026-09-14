module DeployEvents
  # 把一条上报并进"一次部署尝试"里。
  #
  # 返回的 :changed 表示状态真的发生了变化——新建行，或首次补上 succeeded_at。
  # 调用方据此决定要不要触发 burst 轮询：重复上报不该反复撬动一次 SSH 扇出。
  class Ingest
    STARTED   = "started".freeze
    SUCCEEDED = "succeeded".freeze
    PHASES    = [ STARTED, SUCCEEDED ].freeze

    # succeeded 的去重窗口。post-deploy hook 超时重试、CI 重跑同一步都会在几秒内
    # 把同一个 succeeded 打两遍——但只有 post-deploy hook（没配 pre-deploy）的用户，
    # 同一 version 真的二次部署时也长这样，无法靠"该行已 succeeded"本身区分。
    # 窗口内吞掉：代价是 1 分钟内重复部署同一版本（本就异常）会被并成一行；
    # 窗口外新建：代价是窗口外才到的重试会多出一行幽灵尝试。两头都不完美，
    # 但重复上报绝不能无限期地反复撬动一次 SSH 扇出。
    DUPLICATE_WINDOW = 1.minute

    # 认领窗口：多久之内到达的 post 还算同一次部署的收尾。
    # 故意不复用 DeployEvent::UNFINISHED_AFTER（15 分钟）——那是告警阈值，回答的是
    # 「多久没收尾就该提醒人看一眼」，必须短。这里回答的是「多久之内到达的 post 还算
    # 同一次部署」，必须宽到能覆盖一次慢构建（Docker 构建 + 推送 + 健康检查很容易
    # 超过 15 分钟）。2 小时是对「一次部署最长能跑多久」的保守估计，超过它的 post
    # 会新建一行，那时候确实更像是另一回事。
    CLAIM_WINDOW = 2.hours

    def self.call(managed_app:, phase:, attributes:)
      new(managed_app, phase, attributes).call
    end

    def initialize(managed_app, phase, attributes)
      @managed_app = managed_app
      @phase = phase.to_s
      @attributes = attributes
    end

    def call
      raise ArgumentError, "未知阶段：#{phase.inspect}" unless PHASES.include?(phase)

      phase == STARTED ? ingest_started : ingest_succeeded
    end

    private
      attr_reader :managed_app, :phase, :attributes

      def ingest_started
        # 已经有一次尚未收尾的同版本尝试：这是 curl 重试或 CI 重跑同一步，
        # 不是新的一次部署。
        if (open = open_attempt)
          return { event: open, changed: false }
        end

        { event: create(started_at: Time.current), changed: true }
      end

      def ingest_succeeded
        if (open = open_attempt)
          open.update!(succeeded_at: Time.current, **carried_attributes)
          return { event: open, changed: true }
        end

        if (duplicate = recent_succeeded_duplicate)
          return { event: duplicate, changed: false }
        end

        # pre 那次上报丢了（或压根没配 pre-deploy hook）。
        { event: create(succeeded_at: Time.current), changed: true }
      end

      # 只认领 CLAIM_WINDOW 以内的 open row：超过这个时长没收尾的行早就不像是同一次
      # 部署了，不该再被新的上报认领——否则新的 pre 上报会被一行陈旧记录吃掉，
      # changed 为 false，burst 轮询也不会触发。
      #
      # 只在 source: "hook" 里找：推断行（source: "inferred"）不是一次真实的
      # pre/post-deploy 上报，不该被当作"尚未收尾的尝试"被新的上报认领。
      def open_attempt
        managed_app.deploy_events
                   .where(source: "hook")
                   .where(version: attributes.fetch(:version), succeeded_at: nil)
                   .where(started_at: CLAIM_WINDOW.ago..)
                   .order(created_at: :desc)
                   .first
      end

      # 该应用该 version 最近一次已收尾的尝试，如果落在去重窗口内——这是同一次
      # succeeded 上报的重试，不是新的一次部署。
      #
      # 只在 source: "hook" 里找：推断行天生带 succeeded_at（轮询发现收敛时就
      # 打上了），如果不按 source 过滤，轮询先记的一条推断行会把随后到达的
      # 真实 post-deploy 上报误判成"重复"，导致 performer/command/recorded_at
      # 永远落不了库，用户也毫无察觉。去重窗口的语义本来就是"同一条上报的
      # 重试"，只应该跟别的 hook 上报比较。
      def recent_succeeded_duplicate
        managed_app.deploy_events
                   .where(source: "hook")
                   .where(version: attributes.fetch(:version))
                   .where.not(succeeded_at: nil)
                   .order(created_at: :desc)
                   .first
                   .then { |event| event if event && event.succeeded_at >= DUPLICATE_WINDOW.ago }
      end

      def create(**timestamps)
        managed_app.deploy_events.create!(
          source: "hook", destination: managed_app.destination,
          **carried_attributes, **timestamps
        )
      end

      def carried_attributes
        { version: attributes.fetch(:version),
          performer: attributes[:performer],
          command: attributes[:command],
          recorded_at: attributes[:recorded_at] }
      end
  end
end
