module DeployEvents
  # 把一条上报并进"一次部署尝试"里。
  class Ingest
    STARTED   = "started".freeze
    SUCCEEDED = "succeeded".freeze
    PHASES    = [ STARTED, SUCCEEDED ].freeze

    DUPLICATE_WINDOW = 1.minute

    # 认领窗口：多久之内到达的 post 还算同一次部署的收尾。
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

      def open_attempt
        managed_app.deploy_events
                   .where(source: "hook")
                   .where(version: attributes.fetch(:version), succeeded_at: nil)
                   .where(started_at: CLAIM_WINDOW.ago..)
                   .order(created_at: :desc)
                   .first
      end

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
