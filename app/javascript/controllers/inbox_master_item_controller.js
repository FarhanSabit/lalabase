import { Controller } from "@hotwired/stimulus"

// Inbox master item: responsive click behavior.
//
// - Desktop (≥ lg = 1024px): click loads the ticket in the right pane via
//   data-turbo-frame="ticket_pane". We keep the URL in sync via
//   history.pushState — NOT via data-turbo-action="advance": that promotes
//   the frame load to a second drive visit, which immediately overwrites the
//   freshly loaded pane again with the placeholder (visible flicker).
//   pushState gives URL sync (reload/share/back) without this second visit.
//   The lane itself belongs to layout-toggle, as on the other list pages:
//   it opens here, and its ✕, Escape and Back close it there.
// - Mobile/tablet (< lg): the pane is hidden via CSS. If we let the
//   frame click run, it would be invisible. Instead: navigate to the
//   full view of the ticket (data-fullview-url).
//
// See doc/inbox_feature_spec.md chapter 4.7.
export default class extends Controller {
  static values = { fullviewUrl: String }

  // Tailwind lg breakpoint per the default theme.
  static LG_BREAKPOINT = 1024

  // The open row carries the tint of the lane pages (.selected-row), and the
  // address says which row is open: a row a stream has just redrawn marks
  // itself, and one whose lane was shut meanwhile does not.
  connect() {
    const row = this.row
    if (!row) return
    const open = new URLSearchParams(window.location.search).get("notification")
    row.classList.toggle("selected-row", open !== null && open === row.dataset.notificationId)
  }

  handleClick(event) {
    if (window.innerWidth >= this.constructor.LG_BREAKPOINT) {
      // Desktop: Turbo loads the pane frame; we mirror the URL (an entry of
      // the lane, like the ones layout-toggle writes), move the tint to this
      // row and open the lane, which is shut while nothing is chosen.
      if (this.element.href) {
        window.history.pushState({ lane: true }, "", this.element.href)
      }
      document.querySelectorAll(".inbox-row.selected-row").forEach((row) => row.classList.remove("selected-row"))
      this.row?.classList.add("selected-row")
      this.layoutToggle?.showContent()
      return
    }
    if (!this.hasFullviewUrlValue || !this.fullviewUrlValue) return
    event.preventDefault()
    // Top-level navigation to the full view instead of a frame load.
    Turbo.visit(this.fullviewUrlValue, { action: "advance" })
  }

  get row() {
    return this.element.closest(".inbox-row")
  }

  get layoutToggle() {
    const page = this.element.closest('[data-controller~="layout-toggle"]')
    return page ? this.application.getControllerForElementAndIdentifier(page, "layout-toggle") : null
  }
}
