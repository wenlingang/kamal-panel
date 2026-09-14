module Api
  # 唯一的上报入口（spec 03 第 4 节）。
  #
  # 成功也不返回任何内容：token 是写入凭证，不能顺带变成读取面板状态的通道。
  #
  # 限流是硬要求而不是防御性编程——收到事件会触发 burst 轮询，也就是一个
  # token 能撬动面板对用户的所有机器发起 SSH 扇出。
  class DeploysController < ActionController::API
    # version 会进 UI、进告警文案、参与配对查询。这里按保守字符集收口，
    # 与"上报字段不进入任何 cli_args"是两道独立的防线。
    VERSION_FORMAT = /\A[A-Za-z0-9._-]{1,128}\z/
    TEXT_LIMIT = 255

    rate_limit to: 30, within: 1.minute, by: -> { request.headers["Authorization"].to_s }

    # rate_limit 触发时默认抛 ActionController::TooManyRequests，Rails 靠
    # "public/429.html 不存在"这个巧合才回退成空 body。一旦有人给浏览器端加了
    # 统一错误页（哪怕只是给 public/429.html 塞了内容），这个 API 端点也会跟着
    # 把那页 HTML 吐进 body——"成功和限流都不回内容"必须由这个 controller 自己
    # 保证，不能依赖 public 目录现在恰好是空的。
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

      # :ok / :mismatch / :unparsable ——三种结果分别对应不同的拒收文案，
      # 因为"token 粘错了"和"这个应用的配置现在解析不过"是两种完全不同的
      # 排查方向，混成一句话会把运维者指向错误的地方去查。
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
        # 只在状态真的变化时才撬动一次扇出。
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

      # 配置现在解析不了，判断不了 service/destination 是否匹配——这时候不猜，
      # 照样 409 拒收，但文案不能说"粘错了"：真实原因很可能是 deploy.yml 本身
      # 解析不过（比如 Kamal 升级后语法变了），运维者照着"粘错了"的提示去查
      # token 永远查不到。
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

      # 机器上的原文，只用于展示。解析不了就丢掉，绝不因此拒收整条上报——
      # 也绝不用它做任何判定（那会让时钟漂移变成告警的开关）。
      def parsed_recorded_at
        Time.zone.parse(params[:recorded_at].to_s)
      rescue ArgumentError, TypeError
        nil
      end
  end
end
