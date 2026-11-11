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
  const layout = { widths: [...widths] }
  const page = [] // every call that would move the page
  const writes = [] // every scrollLeft the controller set
  let observer = null
  let offset = scrollLeft

  const lefts = () => layout.widths.reduce((starts, _, index) => {
    starts.push(index === 0 ? 0 : starts[index - 1] + layout.widths[index - 1] + GAP)
    return starts
  }, [])
  const scrollWidth = () => Math.round(lefts().at(-1) + layout.widths.at(-1))
  const tabBox = index => {
    const left = ORIGIN + lefts()[index] - offset
    return { left, right: left + layout.widths[index] }
  }

  const items = layout.widths.map((_, index) => ({
    tab: { getBoundingClientRect: () => tabBox(index), scrollIntoView: () => page.push("scrollIntoView") }
  }))
  const row = {
    clientLeft: 0,
    clientWidth,
    children: items,
    get scrollWidth() { return scrollWidth() },
    get scrollLeft() { return offset },
    set scrollLeft(value) {
      writes.push(value)
      offset = Math.max(0, Math.min(value, scrollWidth() - clientWidth))
    },
    getBoundingClientRect: () => ({ left: ORIGIN, right: ORIGIN + clientWidth }),
    querySelector: selector => (selector === "[aria-current]" && open !== undefined ? items[open].tab : null),
    scrollIntoView: () => page.push("scrollIntoView")
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
    controller, row, page, writes, layout,
    get observer() { return observer },
    // A notification of the observer: the row was laid out or something changed size.
    resized() { observer.callback([]) },
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
