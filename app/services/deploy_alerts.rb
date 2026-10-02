# The contradiction between the two data sources (spec 03 §5).
class DeployAlerts
  # An alert is something that "needs someone to take a look right now": a contradiction from three
  # days ago is history, and the history section shows it itself. Only look at events within this
  # recent window (by created_at), so that old contradictions that no longer hold do not occupy the
  # alert slot forever.
  RECENT_WINDOW = 24.hours

  def initialize(managed_app)
    @managed_app = managed_app
  end

  def list
    unobserved + unfinished
  end

  def any? = list.any?

  def badge_text
    kinds = list.map { |alert| alert[:kind] }.uniq
    return nil if kinds.empty?

    if kinds == [ :unobserved ]
      I18n.t("deploy_alerts.unobserved")
    elsif kinds == [ :unfinished ]
      I18n.t("deploy_alerts.unfinished")
    else
      I18n.t("deploy_alerts.mixed")
    end
  end

  private
    attr_reader :managed_app

    def unobserved
      not_superseded(
        managed_app.deploy_events
                   .where(observed_at: nil)
                   .where.not(succeeded_at: nil)
                   .where(succeeded_at: ..DeployEvent::UNOBSERVED_AFTER.ago)
                   .where(created_at: RECENT_WINDOW.ago..)
      ).recent_first.map do |event|
        { kind: :unobserved, event: event,
          message: I18n.t("deploy_alerts.unobserved_message",
                           version: event.version, ago: ago(event.succeeded_at)) }
      end
    end

    def unfinished
      not_superseded(
        managed_app.deploy_events
                   .where(succeeded_at: nil)
                   .where.not(started_at: nil)
                   .where(started_at: ..DeployEvent::UNFINISHED_AFTER.ago)
                   .where(created_at: RECENT_WINDOW.ago..)
      ).recent_first.map do |event|
        { kind: :unfinished, event: event,
          message: I18n.t("deploy_alerts.unfinished_message",
                           version: event.version,
                           started_at: event.started_at.strftime("%H:%M")) }
      end
    end

    # Old contradictions no longer need anyone to look at them — the history section still keeps the
    # event row itself as a trace.
    def not_superseded(scope)
      cutoff = managed_app.deploy_events.where.not(observed_at: nil).maximum(:created_at)
      return scope unless cutoff

      scope.where(created_at: cutoff..)
    end

    def ago(time)
      I18n.t("deploy_alerts.ago", time: ApplicationController.helpers.time_ago_in_words(time))
    end
end
