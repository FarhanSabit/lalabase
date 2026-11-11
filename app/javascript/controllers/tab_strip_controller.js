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
//
// The reader's hand wins (review of S4A). Once the reader has moved the row (a
// finger, a pen or a mouse on it, a wheel over it, or a scroll that did not come
// from here), nothing here moves it again: not a tab that changes size later, as
// with a late web font, and not a turned phone either. The browser keeps the
// reader's offset through a turn (Chrome, measured: 100 at 390 px, unscrolled
// while the row wraps at 844, 100 again back at 390), so the place is still the
// reader's, and pulling the row back then would be the same jump with another
// cause. Until the reader moves it, every report brings the open tab back into
// view, a turn's included.

// What the reader does to a row before it scrolls.
const READER_INPUT = ["pointerdown", "touchstart", "wheel"]

export default class extends Controller {
  connect() {
    this.held = false // the reader has moved the row
    this.position = this.element.scrollLeft // where this controller last left the row
    this.hold = () => { this.held = true }
    // The browser reports every move a frame later, this controller's own
    // included: only a position other than the one left here is the reader's.
    this.scrolled = () => {
      if (this.element.scrollLeft !== this.position) this.held = true
    }
    for (const type of READER_INPUT) this.element.addEventListener(type, this.hold, { passive: true })
    this.element.addEventListener("scroll", this.scrolled, { passive: true })

    // Measured whenever the row or a tab changes size, until the reader has
    // moved the row: when the row is first laid out, when the web font replaces
    // the fallback (font-display: swap, the tabs grow) and when the phone turns.
    this.observer = new ResizeObserver(() => this.resized())
    this.observer.observe(this.element)
    for (const item of this.element.children) this.observer.observe(item)
  }

  disconnect() {
    this.observer.disconnect()
    for (const type of READER_INPUT) this.element.removeEventListener(type, this.hold)
    this.element.removeEventListener("scroll", this.scrolled)
  }

  resized() {
    if (!this.held) this.reveal()
    this.position = this.element.scrollLeft
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
