# 自适应轮询节奏（spec 6.3）。
#
# 没人看的时候不该烧 SSH 连接；有人正在看、或刚有动静时才加密。
class PollCadence
  IDLE     = 60.seconds
  VIEWING  = 10.seconds
  BURST    = 2.seconds

  VIEWING_TTL = 30.seconds   # 页面每 10 秒续一次，30 秒不续即视为无人查看
  BURST_TTL   = 90.seconds

  class << self
    def interval_for(managed_app)
      return BURST   if flag?(managed_app, :burst)
      return VIEWING if flag?(managed_app, :viewing)

      IDLE
    end

    def mark_viewed!(managed_app)
      Rails.cache.write(key(managed_app, :viewing), true, expires_in: VIEWING_TTL)
    end

    def mark_burst!(managed_app)
      Rails.cache.write(key(managed_app, :burst), true, expires_in: BURST_TTL)
    end

    # 调度器（PollAllManagedAppsJob）用它来认领本轮是否轮到自己跑。
    # 和 :viewing/:burst 共用同一个前缀，集中在这一处，避免两处字符串各写一份、日后不一致。
    def last_run_key(managed_app)
      key(managed_app, :last_run)
    end

    private
      def flag?(managed_app, name)
        Rails.cache.read(key(managed_app, name)).present?
      end

      def key(managed_app, name)
        "poll_cadence/#{managed_app.id}/#{name}"
      end
  end
end
