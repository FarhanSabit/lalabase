import { Controller } from "@hotwired/stimulus"

// Delayed mark-as-read, in the inbox pane and in every ticket view
// (organisations/tickets/_ticket_display, Notifications::MarkTicketRead).
//
// Instead of marking a notification as read immediately when the pane
// opens, we give the user ~5 seconds for a quick look.
// If the pane still shows the same notification after the time elapses,
// we fire a PATCH /mark_read. If the pane is closed beforehand
// (another item opened, navigated elsewhere), the timer is aborted
// (disconnect). A lane shut in place (its ✕, Escape) hides the ticket by a
// class on the grid and leaves it in the page, so the timer asks at its end
// whether the ticket is still in view.
export default class extends Controller {
  static values = {
    url: String,
    delay: { type: Number, default: 5000 }
  }

  connect() {
    if (!this.urlValue) return
    this.timer = setTimeout(() => this.markRead(), this.delayValue)
  }

  disconnect() {
    if (this.timer) {
      clearTimeout(this.timer)
      this.timer = null
    }
  }

  async markRead() {
    if (this.element.closest(".layout.hide-content")) return

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "X-CSRF-Token": csrfToken || "",
          "Accept": "text/vnd.turbo-stream.html"
        },
        credentials: "same-origin"
      })
      if (response.ok) {
        const html = await response.text()
        // Apply the returned turbo-stream actions to the current document.
        Turbo.renderStreamMessage(html)
      }
    } catch (e) {
      // Fail silently — no user feedback needed.
      console.warn("Delayed mark-read failed:", e)
    }
  }
}
