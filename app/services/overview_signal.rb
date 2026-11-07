# Tells open overview pages that something they show may have changed. It is a signal, not
# content: the overview depends on who is looking (their filter, the actions their role allows),
# so the server can't render it for them. Each page's live-refresh controller fetches its own URL
# in the background and morphs the affected regions — coalesced, so a fleet of apps finishing
# their polling rounds doesn't turn into a page that never stops reloading.
module OverviewSignal
  STREAM = "overview".freeze
  TARGET = "overview-live".freeze

  module_function

  def broadcast
    Turbo::StreamsChannel.broadcast_stream_to(
      STREAM,
      content: Turbo::StreamsChannel.turbo_stream_action_tag(:live_refresh, target: TARGET)
    )
  end
end
