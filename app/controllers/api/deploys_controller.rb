module Api
  # The only reporting entry point (spec 03 §4).
  class DeploysController < ActionController::API
    # version goes into the UI, into alert text, and into the pairing query.
    # This is a separate line of defense from "reported fields never enter any cli_args".
    VERSION_FORMAT = /\A[A-Za-z0-9._-]{1,128}\z/
    TEXT_LIMIT = 255

    rate_limit to: 30, within: 1.minute, by: -> { request.headers["Authorization"].to_s }

    rescue_from ActionController::TooManyRequests do
      head :too_many_requests
    end

    def create
      app = ManagedApp.find_by_hook_token(bearer_token)
      return head(:unauthorized) if app.nil?

      return head(:unprocessable_entity) unless valid_payload?

      case match_status(app)
      when :mismatch
        reject_mismatch(app)
      when :unparsable
        reject_unparsable(app)
      else
        record_and_ingest(app)
      end
    end

    private
      def bearer_token
        request.headers["Authorization"].to_s[/\ABearer (.+)\z/, 1]
      end

      def valid_payload?
        DeployEvents::Ingest::PHASES.include?(params[:phase].to_s) &&
          params[:version].to_s.match?(VERSION_FORMAT)
      end

      def match_status(app)
        params[:service].to_s == app.service &&
          params[:destination].to_s == app.destination.to_s ? :ok : :mismatch
      rescue Kamal::ConfigParser::ParseError
        :unparsable
      end

      def record_and_ingest(app)
        app.update_columns(last_hook_rejection: nil, last_hook_rejection_at: nil) if app.last_hook_rejection.present?

        result = DeployEvents::Ingest.call(managed_app: app, phase: params[:phase],
                                           attributes: ingest_attributes)
        # Only kick off a fan-out when the status has actually changed.
        PollCadence.mark_burst!(app) if result[:changed]

        head :no_content
      end

      def reject_mismatch(app)
        app.reject_hook!(
          "收到 service=#{params[:service]} / destination=#{params[:destination]} 的上报，" \
          "但这个 token 属于本应用。请检查是不是把 token 粘到了别的项目或别的 destination 的 hook 里。"
        )
        head :conflict
      end

      def reject_unparsable(app)
        app.reject_hook!(
          "暂时无法判断这条上报是否属于本应用，因为这个应用的 deploy.yml 现在解析不过" \
          "（见页面上的解析错误横幅）。配置修好之后，上报会自动恢复。"
        )
        head :conflict
      end

      def ingest_attributes
        { version: params[:version].to_s,
          performer: params[:performer].to_s.truncate(TEXT_LIMIT).presence,
          command: params[:command].to_s.truncate(TEXT_LIMIT).presence,
          recorded_at: parsed_recorded_at }
      end

      # The raw text from the machine, for display only.
      # Never use it for any decision (that would make clock drift a switch for alerts).
      def parsed_recorded_at
        Time.zone.parse(params[:recorded_at].to_s)
      rescue ArgumentError, TypeError
        nil
      end
  end
end
