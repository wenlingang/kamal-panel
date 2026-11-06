# Absolute links back to the panel, for messages read outside it (alert notifications). Set
# PANEL_URL (e.g. https://panel.example.com) in production; without it notifications simply carry
# no link — a guessed host would be worse than none.
module PanelUrl
  module_function

  def base = Rails.application.config.x.panel_url.presence

  def for(path)
    return nil if base.nil?

    "#{base.chomp('/')}#{path}"
  end
end
