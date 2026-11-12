import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"

// tab_strip_controller keeps the open tab of a sideways scrolling tab row in view
// and moves only the row. Here it runs against a row that lays its tabs out in
// one line and scrolls the way a browser does: scrollLeft stays between 0 and
// scrollWidth - clientWidth, the scroll width is whole pixels, and a tab's box
// moves with the scroll. The browser itself: spec/system/management_phone_spec.rb.
const source = readFileSync(new URL("../../../app/javascript/controllers/tab_strip_controller.js", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "")
  .replace("export default class", "class TabStripController")

// The six KI tabs on a 390 px phone, as measured there: widths in px with
// "Protokoll" open, 24 px apart (gap-x-6), the row 358 px wide at x = 16.
const KI_TABS = [65.3, 50.9, 69.5, 79.1, 100.4, 61.1]
const GAP = 24
const ORIGIN = 16

function fixture({ widths = KI_TABS, open, clientWidth = 358, scrollLeft = 0 } = {}) {
  const layout = { widths: [...widths], clientWidth }
  const page = [] // every call that would move the page
  const writes = [] // every scrollLeft the controller set
  const listeners = new Map() // event type -> the functions listening on the row
  let observer = null
  let offset = scrollLeft

  const lefts = () => layout.widths.reduce((starts, _, index) => {
    starts.push(index === 0 ? 0 : starts[index - 1] + layout.widths[index - 1] + GAP)
    return starts
  }, [])
  const scrollWidth = () => Math.round(lefts().at(-1) + layout.widths.at(-1))
  const clamp = value => Math.max(0, Math.min(value, scrollWidth() - layout.clientWidth))
  const tabBox = index => {
    const left = ORIGIN + lefts()[index] - offset
    return { left, right: left + layout.widths[index] }
  }

  const items = layout.widths.map((_, index) => ({
    tab: { getBoundingClientRect: () => tabBox(index), scrollIntoView: () => page.push("scrollIntoView") }
  }))
  const row = {
    clientLeft: 0,
    children: items,
    get clientWidth() { return layout.clientWidth },
    get scrollWidth() { return scrollWidth() },
    get scrollLeft() { return offset },
    set scrollLeft(value) {
      writes.push(value)
      offset = clamp(value)
    },
    getBoundingClientRect: () => ({ left: ORIGIN, right: ORIGIN + layout.clientWidth }),
    querySelector: selector => (selector === "[aria-current]" && open !== undefined ? items[open].tab : null),
    contains: node => inRow(node),
    scrollIntoView: () => page.push("scrollIntoView"),
    // As the browser keeps them: the same function twice for one type is one.
    addEventListener(type, listener) {
      if (!listeners.has(type)) listeners.set(type, new Set())
      listeners.get(type).add(listener)
    },
    removeEventListener(type, listener) { listeners.get(type)?.delete(listener) }
  }
  const fire = (type, detail = {}) => {
    for (const listener of [...(listeners.get(type) ?? [])]) listener({ type, ...detail })
  }

  // The fingers on the screen as the browser lists them in event.touches, each with
  // the element it began on (Touch.target): a tab of the row, or somewhere on the page.
  const fingers = []
  const elsewhere = {}
  let pointerIds = 0
  const inRow = node => node === row || items.some(item => item === node || item.tab === node)
  // As the browser sends them: a finger's events reach the row only when the finger
  // began in it, and targetTouches lists the fingers on the same element (the tab).
  const fingerEvent = (type, finger, detail) => {
    if (!inRow(finger.target)) return
    if (detail.pointerType) {
      fire(type, { ...detail, pointerId: finger.pointerId })
      return
    }
    fire(type, {
      target: finger.target,
      touches: [...fingers],
      targetTouches: fingers.filter(other => other.target === finger.target),
      changedTouches: [finger]
    })
  }

  class FakeResizeObserver {
    constructor(callback) {
      this.callback = callback
      this.observed = []
      this.connected = true
      observer = this
    }

    observe(element) { this.observed.push(element) }
    disconnect() { this.connected = false }
  }

  const Controller = runInNewContext(`${source}\nTabStripController`, {
    Controller: class {},
    ResizeObserver: FakeResizeObserver,
    window: { scrollTo: () => page.push("scrollTo"), scrollBy: () => page.push("scrollBy") }
  })
  const controller = new Controller()
  controller.element = row

  return {
    controller, row, page, writes, layout, listeners,
    get observer() { return observer },
    // A notification of the observer: the row was laid out or something changed size.
    resized() { observer.callback([]) },
    // The browser reports a scroll of the row, whoever moved it (a frame after the move).
    scrolled() { fire("scroll") },
    // The reader swipes the row to `to`, and the browser reports the scroll.
    readerScrolls(to) {
      offset = clamp(to)
      fire("scroll")
    },
    // A finger goes down on tab `on` (the open tab unless named, `"elsewhere"` for
    // the page outside the row), in the browser's order: pointerdown, touchstart.
    fingerDown(on = open ?? 0) {
      const finger = { target: on === "elsewhere" ? elsewhere : items[on].tab, pointerId: ++pointerIds, cancelled: false }
      fingers.push(finger)
      fingerEvent("pointerdown", finger, { pointerType: "touch" })
      fingerEvent("touchstart", finger, {})
      return finger
    },
    // An upright swipe from the finger: the browser takes it over for the page at
    // once (pointercancel), the finger stays down, and the row does not move.
    swipeUpright(finger = fingers.at(-1)) {
      finger.cancelled = true
      fingerEvent("pointercancel", finger, { pointerType: "touch" })
    },
    // A sideways pan: pointercancel, the finger stays down, and the row moves to `to`.
    pan(to, finger = fingers.at(-1)) {
      this.swipeUpright(finger)
      this.readerScrolls(to)
    },
    // The finger lifts (touchend), or the browser cancels its touch (touchcancel).
    fingerUp(finger = fingers.at(-1), { cancel = false } = {}) {
      fingers.splice(fingers.indexOf(finger), 1)
      if (!finger.cancelled) fingerEvent(cancel ? "pointercancel" : "pointerup", finger, { pointerType: "touch" })
      fingerEvent(cancel ? "touchcancel" : "touchend", finger, {})
    },
    penDown(pointerId = 1) { fire("pointerdown", { pointerType: "pen", pointerId }) },
    penUp(pointerId = 1) { fire("pointerup", { pointerType: "pen", pointerId }) },
    penCancel(pointerId = 1) { fire("pointercancel", { pointerType: "pen", pointerId }) },
    mousePress() {
      fire("pointerdown", { pointerType: "mouse", pointerId: 99 })
      fire("pointerup", { pointerType: "mouse", pointerId: 99 })
    },
    // A vertical wheel over the row: the row cannot scroll that way, nothing moves.
    wheel() { fire("wheel", { deltaX: 0, deltaY: 120 }) },
    // The browser pulls the row back to its end when the tabs shrank below it.
    clampToEnd() { offset = clamp(offset) },
    // The open tab against the row's visible box, both from the row's left edge.
    openTab() {
      const box = items[open].tab.getBoundingClientRect()
      return [box.left - ORIGIN, box.right - ORIGIN]
    }
  }
}

function assertInView(f, message) {
  const [left, right] = f.openTab()
  assert.ok(left > -1 && right < f.row.clientWidth + 1, `${message}: the open tab stands at ${left}..${right} of 0..${f.row.clientWidth}`)
}

test("the sixth KI tab, past the edge, brings the row to its end and lies in view; the page never moves", () => {
  const f = fixture({ open: 5 })
  f.controller.connect()
  f.resized()
  assertInView(f, "Protokoll")
  assert.equal(f.row.scrollLeft, f.row.scrollWidth - f.row.clientWidth)
  assert.deepEqual(f.page, [])
})

test("the first tab keeps the row at its start: an open tab in view is never moved", () => {
  const f = fixture({ open: 0 })
  f.controller.connect()
  f.resized()
  assert.deepEqual(f.writes, [])
  assert.equal(f.row.scrollLeft, 0)
})

test("a tab past the edge of a long row comes to the middle of the row", () => {
  const f = fixture({ widths: Array(12).fill(70), open: 6 })
  f.controller.connect()
  f.resized()
  const [left, right] = f.openTab()
  assert.ok(Math.abs((left + right) / 2 - f.row.clientWidth / 2) < 0.5, `the open tab stands at ${left}..${right}`)
  assert.deepEqual(f.page, [])
})

test("a tab cut off at the start comes back into view", () => {
  const f = fixture({ open: 1, scrollLeft: 188 })
  f.controller.connect()
  f.resized()
  assertInView(f, "Zugang with the row at its end")
})

test("a tab less than a pixel past the end counts as in view: the scroll width is whole pixels", () => {
  // 546.3 px of tabs scroll by 546, so at the end "Protokoll" ends 0.3 px past the row.
  const f = fixture({ open: 5, scrollLeft: 188 })
  f.controller.connect()
  f.resized()
  assert.deepEqual(f.writes, [])
})

test("it measures again when a tab grows, as when the web font replaces the fallback", () => {
  const f = fixture({ widths: KI_TABS.map(width => width * 0.9), open: 5 })
  f.controller.connect()
  f.resized()
  assertInView(f, "with the fallback font")

  f.layout.widths = [...KI_TABS]
  f.resized()
  assertInView(f, "with the web font")
  assert.deepEqual(f.page, [])
})

test("it watches the row and every tab, and lets go on disconnect", () => {
  const f = fixture({ open: 5 })
  f.controller.connect()
  assert.equal(f.observer.observed[0], f.row)
  assert.deepEqual(f.observer.observed.slice(1), f.row.children)
  f.controller.disconnect()
  assert.equal(f.observer.connected, false)
})

test("a row without an open tab is left alone", () => {
  const f = fixture()
  f.controller.connect()
  f.resized()
  assert.deepEqual(f.writes, [])
})

// The reader's hand wins (review of S4A). Measured in the browser at 390 px on
// Protokoll: the row at 188, the reader swiped it to 0 to see Übersicht and
// Zugang, a tab grew (letter spacing, as a late web font makes it), and the row
// was pulled back to 193.
test("a row the reader scrolled stays where the reader left it when a tab changes size", () => {
  const f = fixture({ open: 5 })
  f.controller.connect()
  f.resized()
  f.scrolled() // the browser reports the row's own move to its end
  f.readerScrolls(0)
  f.writes.length = 0

  f.layout.widths[0] += 3
  f.resized()
  assert.deepEqual(f.writes, [])
  assert.equal(f.row.scrollLeft, 0)
})

// Review round 2 of S4A: a hand on the row does not hold it, only a MOVEMENT of the
// row that did not come from here does. Measured in Chrome at 390 px before: a
// vertical wheel over the row (deltaY 120) held it without moving it, and tabs
// grown by letter spacing then left the open tab at 393..472 of a 358 px row.
const HANDS = [["fingerDown", "fingerUp"], ["penDown", "penUp"]]

test("a finger or a pen on the row pauses reveals while it is down, and the reveal it held back comes when it lifts", () => {
  for (const [down, up] of HANDS) {
    const f = fixture({ open: 5 })
    f.controller.connect()
    f.resized()
    f.scrolled()
    f.writes.length = 0

    f[down]()
    f.layout.widths[0] += 10 // the open tab now ends past the row
    f.resized()
    assert.deepEqual(f.writes, [], `${down}: a reveal while the hand is down`)

    f[up]()
    assertInView(f, `${up}: the reveal held back`)
  }
})

test("a vertical wheel or a mouse press that does not move the row leaves it free: a later size change brings the open tab back", () => {
  for (const input of ["wheel", "mousePress"]) {
    const f = fixture({ open: 5 })
    f.controller.connect()
    f.resized()
    f.scrolled()

    f[input]()
    f.layout.widths[0] += 10
    f.resized()
    assertInView(f, input)
  }
})

test("a finger or a pen lifted without moving the row leaves it free: a later size change brings the open tab back", () => {
  for (const [down, up] of HANDS) {
    const f = fixture({ open: 5 })
    f.controller.connect()
    f.resized()
    f.scrolled()

    f[down]()
    f[up]()
    f.layout.widths[0] += 10
    f.resized()
    assertInView(f, `after ${up}`)
  }
})

test("a pan while the finger is down holds the row, also after the finger lifts", () => {
  const f = fixture({ open: 5 })
  f.controller.connect()
  f.resized()
  f.scrolled()

  f.fingerDown()
  f.pan(0)
  f.fingerUp()
  f.writes.length = 0
  f.layout.widths[0] += 10
  f.resized()
  assert.deepEqual(f.writes, [])
  assert.equal(f.row.scrollLeft, 0)
})

test("the row's own move, reported back by the browser, is not the reader's", () => {
  const f = fixture({ widths: KI_TABS.map(width => width * 0.9), open: 5 })
  f.controller.connect()
  f.resized()
  f.scrolled()

  f.layout.widths = [...KI_TABS]
  f.resized()
  assertInView(f, "with the web font, after the row's own move was reported")
})

test("a change of the row's own width, as when the phone turns, brings the open tab back while the reader has not moved the row", () => {
  const f = fixture({ open: 5 })
  f.controller.connect()
  f.resized()
  f.scrolled()

  f.layout.clientWidth = 300
  f.resized()
  assertInView(f, "after the turn")
})

// The browser keeps the reader's offset through a turn, so the place stays the
// reader's: a pull back then is the jump of the review with another cause.
test("once the reader has moved the row, not even a turned phone pulls it back", () => {
  const f = fixture({ open: 5 })
  f.controller.connect()
  f.resized()
  f.scrolled()
  f.readerScrolls(0)
  f.writes.length = 0

  f.layout.clientWidth = 300
  f.resized()
  assert.deepEqual(f.writes, [])
  assert.equal(f.row.scrollLeft, 0)
})

test("it listens on the row once per event it needs, not to the wheel, and takes every listener away on disconnect", () => {
  const types = ["touchstart", "touchend", "touchcancel", "pointerdown", "pointerup", "pointercancel", "scroll", "wheel"]
  const f = fixture({ open: 5 })
  f.controller.connect()
  assert.deepEqual(types.map(type => f.listeners.get(type)?.size ?? 0), [1, 1, 1, 1, 1, 1, 1, 0])
  f.controller.disconnect()
  assert.deepEqual(types.map(type => f.listeners.get(type)?.size ?? 0), [0, 0, 0, 0, 0, 0, 0, 0])
})

// Review round 2 of S4A: the tabs shrink after this controller left the row at its
// end (188), and the browser pulls the row back to the new, nearer end (178) before
// it reports the move. The position no longer equals the one left here, and the row
// counted as moved by the reader.
test("the row pulled back to a nearer end by the browser, before this controller's move is reported, is still this controller's", () => {
  const f = fixture({ open: 5 })
  f.controller.connect()
  f.resized()
  f.layout.widths[0] -= 10
  f.clampToEnd()
  f.scrolled()

  f.layout.widths[0] += 20 // the open tab now ends past the row
  f.resized()
  assertInView(f, "after the clamp")
})

// The row with the open tab at its end, its own move reported, and no write since.
function settledAtTheEnd() {
  const f = fixture({ open: 5 })
  f.controller.connect()
  f.resized()
  f.scrolled()
  f.writes.length = 0
  return f
}

// Review of S4F (B1): two fingers on two tabs, one lifts. targetTouches lists only
// the fingers on the same tab as the event's, and one flag cannot count pointers:
// the pause ended under the finger that still rested, and a size change moved the
// row beneath it (Chrome: 188 to 416).
test("a finger lifted from one tab keeps the pause while another finger rests on another tab", () => {
  const f = settledAtTheEnd()
  const first = f.fingerDown(4)
  const second = f.fingerDown(5)
  f.fingerUp(first)
  f.layout.widths[0] += 10 // the open tab now ends past the row
  f.resized()
  assert.deepEqual(f.writes, [], "a reveal under the finger that still rests")

  f.fingerUp(second)
  assertInView(f, "after the last finger lifted")
})

test("a pen lifted keeps the pause while another pen rests on the row", () => {
  const f = settledAtTheEnd()
  f.penDown(1)
  f.penDown(2)
  f.penUp(1)
  f.layout.widths[0] += 10
  f.resized()
  assert.deepEqual(f.writes, [], "a reveal under the pen that still rests")

  f.penUp(2)
  assertInView(f, "after the last pen lifted")
})

test("a finger elsewhere on the page does not keep the row's pause", () => {
  const f = settledAtTheEnd()
  const onTheRow = f.fingerDown()
  f.fingerDown("elsewhere")
  f.fingerUp(onTheRow)
  f.layout.widths[0] += 10
  f.resized()
  assertInView(f, "with a finger down outside the row")
})

// Review of S4F (B3): in Chrome an upright swipe that begins on the row sends
// pointerdown (touch), touchstart and at once pointercancel. The row does not move,
// the finger stays down, and only its touch events keep the pause.
test("an upright swipe begun on the row pauses reveals until the finger leaves, then the held-back reveal comes and the row is free", () => {
  for (const cancel of [false, true]) {
    const end = cancel ? "touchcancel" : "touchend"
    const f = settledAtTheEnd()
    f.fingerDown()
    f.swipeUpright()
    f.layout.widths[0] += 10
    f.resized()
    assert.deepEqual(f.writes, [], `${end}: a reveal while the finger is down`)

    f.fingerUp(undefined, { cancel })
    assertInView(f, `${end}: the reveal held back`)

    // Not held: its own move reported, the next size change brings the open tab back.
    f.scrolled()
    f.writes.length = 0
    f.layout.widths[0] += 10
    f.resized()
    assert.notDeepEqual(f.writes, [], `${end}: the row stayed held`)
    assertInView(f, `${end}: the next size change`)
  }
})

test("a pen pauses reveals until its pointercancel, then the held-back reveal comes", () => {
  const f = settledAtTheEnd()
  f.penDown()
  f.layout.widths[0] += 10
  f.resized()
  assert.deepEqual(f.writes, [], "a reveal while the pen is down")

  f.penCancel()
  assertInView(f, "after pointercancel")
})

// Review of S4F (B4): the clamp rule's first condition. Without "the position left
// here lies beyond the end", a reader who swipes the row exactly to its end counts as
// a clamp, the row is not held, and a later size change pulls it back.
test("a reader who swipes the row to its very end holds it: a later size change does not pull it back", () => {
  const f = fixture({ open: 2 }) // Verbrauch, in view at the row's start
  f.controller.connect()
  f.resized()
  f.readerScrolls(1000)
  assert.equal(f.row.scrollLeft, 188)
  f.writes.length = 0

  f.layout.widths[0] += 10 // the open tab now begins left of the row
  f.resized()
  assert.deepEqual(f.writes, [])
  assert.equal(f.row.scrollLeft, 188)
})

// And its second condition: the row must stand at the new end. A reader's move away
// from it, reported after the tabs shrank below the position left here, is the reader's.
test("a reader's move reported after the tabs shrank below the row's position still holds the row", () => {
  const f = settledAtTheEnd()
  f.layout.widths[0] -= 10
  f.clampToEnd()
  f.readerScrolls(0)

  f.layout.widths[0] += 20
  f.resized()
  assert.deepEqual(f.writes, [])
  assert.equal(f.row.scrollLeft, 0)
})
