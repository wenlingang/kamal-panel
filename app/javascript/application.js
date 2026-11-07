import { Turbo } from "@hotwired/turbo-rails"
import "confirm_dialog"
import "enhance_selects"
import "controllers"

// A server signal that a live region should catch up (see OverviewSignal and the live-refresh
// controller): forwarded as a DOM event to the target, which decides when to fetch.
Turbo.StreamActions.live_refresh = function () {
  this.targetElements.forEach((element) => element.dispatchEvent(new CustomEvent("live-refresh:signal")))
}
