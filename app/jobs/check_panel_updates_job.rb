# Once a day: is there a newer panel release? (PanelUpdates)
class CheckPanelUpdatesJob < ApplicationJob
  queue_as :default

  def perform = PanelUpdates.check!
end
