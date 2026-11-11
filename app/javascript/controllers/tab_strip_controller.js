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
// The reader's hand wins (reviews of S4A). Only a MOVE of the row that did not
// come from here holds it: a pan with a finger or a pen, a sideways wheel, a key.
// From then on nothing here moves the row again: not a tab that changes size
// later, as with a late web font, and not a turned phone either. The browser
// keeps the reader's offset through a turn (Chrome, measured: 100 at 390 px,
// unscrolled while the row wraps at 844, 100 again back at 390), so the place is
// still the reader's, and pulling the row back then would be the same jump with
// another cause. Until the reader moves the row, every report brings the open tab
// back into view, a turn's included.
//
// A hand that rests on the row moves nothing and holds nothing. A finger or a pen
// on it pauses reveals while it is down, so a reveal never fights a hand, and the
// reveal it held back comes when it lifts. A touch lasts from touchstart to
// touchend or touchcancel (the pointercancel a pan sends while the finger stays
// down does not end it), a pen from pointerdown to pointerup or pointercancel. A
// mouse press does not pause: it cannot move the row, and its pointerup may come
// over another element. No wheel listener either: a sideways wheel moves the row
// and counts as a move, an upright one moves nothing and must not hold the row.
export default class extends Controller {
  connect() {
    this.held = false // the reader has moved the row
    this.touching = false // a finger is on the row, by its touch events
    this.pressing = false // a finger or a pen is on the row, by its pointer events
    this.waiting = false // a reveal waits for the hand to lift
    this.position = this.element.scrollLeft // where this controller last left the row
    this.listeners = {
      touchstart: () => { this.touching = true },
      touchend: event => this.touchLifted(event),
      touchcancel: event => this.touchLifted(event),
      pointerdown: event => { if (event.pointerType !== "mouse") this.pressing = true },
      pointerup: event => this.pointerLifted(event),
      pointercancel: event => this.pointerLifted(event),
      scroll: () => this.scrolled()
    }
    for (const [type, listener] of Object.entries(this.listeners)) {
      this.element.addEventListener(type, listener, { passive: true })
    }

    // Measured whenever the row or a tab changes size, until the reader has
    // moved the row: when the row is first laid out, when the web font replaces
    // the fallback (font-display: swap, the tabs grow) and when the phone turns.
    this.observer = new ResizeObserver(() => this.resized())
    this.observer.observe(this.element)
    for (const item of this.element.children) this.observer.observe(item)
  }

  disconnect() {
    this.observer.disconnect()
    for (const [type, listener] of Object.entries(this.listeners)) this.element.removeEventListener(type, listener)
  }

  resized() {
    if (this.touching || this.pressing) this.waiting = true
    else if (!this.held) this.reveal()
    this.position = this.element.scrollLeft
  }

  touchLifted(event) {
    // Another finger that began on the row may still be down.
    this.touching = (event.targetTouches?.length ?? 0) > 0
    this.lifted()
  }

  pointerLifted(event) {
    if (event.pointerType === "mouse") return
    this.pressing = false
    this.lifted()
  }

  // The hand is off the row: the reveal held back while it was down comes now.
  lifted() {
    if (this.touching || this.pressing || !this.waiting) return
    this.waiting = false
    this.resized()
  }

  // The browser reports every move a frame later, this controller's own
  // included: only a position other than the one left here is someone else's.
  scrolled() {
    const now = this.element.scrollLeft
    if (now === this.position) return

    // A clamp, not a move: the tabs shrank after this controller left the row
    // near its end, and the browser pulled the row back to the new, nearer end
    // before it reported the move made here. The position left here lies beyond
    // that end now, and the row stands exactly at it; no reader put it there.
    const end = this.element.scrollWidth - this.element.clientWidth
    if (this.position > end && Math.abs(now - end) < 1) {
      this.position = now
      return
    }
    this.held = true
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
