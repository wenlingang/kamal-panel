# Adaptive polling cadence (spec 6.3). The intervals are the deployer's call: status.* in
# config/collection.yml (CollectionSettings), which also checks tick <= burst <= viewing <= idle.
class PollCadence
  VIEWING_TTL = 30.seconds   # the page renews every 10 seconds; 30 seconds without renewal means nobody is viewing
  BURST_TTL   = 90.seconds

  class << self
    def idle = settings.status_idle
    def viewing = settings.status_viewing
    def burst = settings.status_burst
    # How often PollAllManagedAppsJob runs (config/recurring.yml reads the same setting).
    def tick = settings.status_tick

    def interval_for(managed_app)
      return burst   if flag?(managed_app, :burst)
      return viewing if flag?(managed_app, :viewing)

      idle
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

    # How long a claimed slot is held: a little less than the app's interval, so an app whose
    # interval is a multiple of the tick is picked up on the tick it falls due, not one tick later
    # (cache expiry and the tick would otherwise land on the same second and race).
    def slot_ttl_for(managed_app)
      interval_for(managed_app) - [ 1.second, tick / 2.0 ].min
    end

    private
      def settings = CollectionSettings.current

      def flag?(managed_app, name)
        Rails.cache.read(key(managed_app, name)).present?
      end

      def key(managed_app, name)
        "poll_cadence/#{managed_app.id}/#{name}"
      end
  end
end
