import { Controller } from "@hotwired/stimulus"

// A row of tabs that scrolls sideways where the tabs do not fit in one line
// (the bar of organisations/shared/_subnav on a phone). It keeps the open tab,
// the one with aria-current, inside the row's visible box: a tab past the edge
// reads as a page without its tab.
//
// Only the row moves (scrollLeft), never the page. scrollIntoView walks every
// scrollable ancestor and can move the page too, against Turbo's scroll
// restoration (filter_bar_controller#scrollActiveTabIntoView keeps its strip
// the same way). An open tab that is wholly in view stays where it is, so a row
// that fits, and its first tab, never move. One past the edge comes to the
// middle of the row as far as the row's ends allow (the browser stops the
// scroll there), so a neighbour shows on either side where there is one.
//
// Not CSS: scroll-initial-target would do it, but only in Chromium (Safari and
// Firefox lack it as of 2026-11), and a phone is often an iPhone.
export default class extends Controller {
  connect() {
    // Measured whenever the row or a tab changes size: when the row is first
    // laid out, when the web font replaces the fallback (font-display: swap,
    // the tabs grow) and when the phone turns.
    this.observer = new ResizeObserver(() => this.reveal())
    this.observer.observe(this.element)
    for (const item of this.element.children) this.observer.observe(item)
  }

  disconnect() {
    this.observer.disconnect()
  }

  reveal() {
    const tab = this.element.querySelector("[aria-current]")
    if (!tab) return

    const row = this.element
    const start = row.getBoundingClientRect().left + row.clientLeft
    const box = tab.getBoundingClientRect()
    const left = box.left - start
    const right = box.right - start
    // Within a pixel counts as in view: the browser rounds the row's scroll
    // width to whole pixels, so the last tab can end a fraction past it.
    if (left > -1 && right < row.clientWidth + 1) return

    row.scrollLeft += (left + right - row.clientWidth) / 2
  }
}
