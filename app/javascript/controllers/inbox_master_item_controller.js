import { Controller } from "@hotwired/stimulus"

// Inbox master item: responsive click behavior.
//
// - Desktop (≥ lg = 1024px): click loads the ticket in the right pane via
//   data-turbo-frame="ticket_pane". We keep the URL in sync via
//   history.pushState — NOT via data-turbo-action="advance": that promotes
//   the frame load to a second drive visit, which immediately overwrites the
//   freshly loaded pane again with the placeholder (visible flicker).
//   pushState gives URL sync (reload/share/back) without this second visit.
// - Mobile/tablet (< lg): the pane is hidden via CSS. If we let the
//   frame click run, it would be invisible. Instead: navigate to the
//   full view of the ticket (data-fullview-url).
//
// See doc/inbox_feature_spec.md chapter 4.7.
export default class extends Controller {
  static values = { fullviewUrl: String }

  // Tailwind lg breakpoint per the default theme.
  static LG_BREAKPOINT = 1024

  handleClick(event) {
    if (window.innerWidth >= this.constructor.LG_BREAKPOINT) {
      // Desktop: Turbo loads the pane frame; we mirror the URL and open the
      // lane, which is shut while nothing is chosen (the grid's hide-content,
      // as on the other lane pages).
      if (this.element.href) {
        window.history.pushState({}, "", this.element.href)
      }
      this.openLane()
      return
    }
    if (!this.hasFullviewUrlValue || !this.fullviewUrlValue) return
    event.preventDefault()
    // Top-level navigation to the full view instead of a frame load.
    Turbo.visit(this.fullviewUrlValue, { action: "advance" })
  }

  openLane() {
    const grid = this.element.closest(".layout--lane")
    if (!grid) return
    grid.classList.remove("hide-content")
    grid.classList.add("show-content")
  }
}
