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
      speed_up!(managed_app, :viewing, VIEWING_TTL)
    end

    def mark_burst!(managed_app)
      speed_up!(managed_app, :burst, BURST_TTL)
    end

    # The scheduler (PollAllManagedAppsJob) uses it to claim whether it is this app's turn to run
    # this round. Shares the same prefix with :viewing/:burst, centralized in this one place, to
    # avoid two string copies drifting apart later.
    def last_run_key(managed_app)
      key(managed_app, :last_run)
    end

    # How long a claimed slot is held: half a tick less than the app's interval. The slot is claimed
    # when PollAllManagedAppsJob actually runs, which trails its tick by queue and worker-polling
    # delay (a second or more when the workers are busy with SSH); half a tick absorbs that jitter
    # on either side, so an app is picked up on the tick it falls due rather than one tick later,
    # while the tick before still finds the slot taken.
    def slot_ttl_for(managed_app)
      interval_for(managed_app) - tick / 2.0
    end

    private
      def settings = CollectionSettings.current

      # The slot was claimed with the interval in force at the time — up to a minute for an idle
      # app. When the app turns viewed or bursting, release that slot so the faster cadence starts
      # on the next tick instead of after the old claim runs out. Only on the change: the page
      # renews :viewing every 10 seconds, and releasing on every renewal would poll on each one.
      def speed_up!(managed_app, flag, ttl)
        already = flag?(managed_app, flag)
        Rails.cache.write(key(managed_app, flag), true, expires_in: ttl)
        Rails.cache.delete(last_run_key(managed_app)) unless already
      end

      def flag?(managed_app, name)
        Rails.cache.read(key(managed_app, name)).present?
      end

      def key(managed_app, name)
        "poll_cadence/#{managed_app.id}/#{name}"
      end
  end
end
