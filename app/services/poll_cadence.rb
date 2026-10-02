# Adaptive polling cadence (spec 6.3).
class PollCadence
  IDLE     = 60.seconds
  VIEWING  = 10.seconds
  BURST    = 2.seconds

  VIEWING_TTL = 30.seconds   # the page renews every 10 seconds; 30 seconds without renewal means nobody is viewing
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

    # The scheduler (PollAllManagedAppsJob) uses it to claim whether it is this app's turn to run
    # this round. Shares the same prefix with :viewing/:burst, centralized in this one place, to
    # avoid two string copies drifting apart later.
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
