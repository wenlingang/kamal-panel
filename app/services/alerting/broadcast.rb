module Alerting
  # Tells open pages that alerts changed, in the same style as PollManagedAppJob: the alerts page
  # and the overview refresh themselves (morph); an app's page gets its alert banner replaced in
  # place (refreshing it whole would reload its SSH frames). Failures are logged, never raised: a
  # missed repaint must not undo an evaluation.
  module Broadcast
    module_function

    def call(app_ids)
      Turbo::StreamsChannel.broadcast_refresh_to("alerts")
      Turbo::StreamsChannel.broadcast_refresh_to("overview")

      ManagedApp.where(id: app_ids.to_a).find_each do |app|
        html = ApplicationController.render(partial: "managed_apps/firing_alerts", locals: { managed_app: app })
        Turbo::StreamsChannel.broadcast_stream_to(
          "managed_app_#{app.id}",
          content: Turbo::StreamsChannel.turbo_stream_action_tag(:replace, target: "app-alerts", template: html)
        )
      end
    rescue StandardError => e
      Rails.logger.error("[alerts] 广播投递失败：#{e.class}: #{e.message}")
    end
  end
end
