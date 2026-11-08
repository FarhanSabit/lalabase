import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"

// glossary_run_poll: while a run of the glossary extraction is active, the run
// bar reloads the list frame around it; the fresh bar decides whether to go
// on. These pin when it asks, what it replaces and when it stops.
const source = readFileSync(new URL("../../../app/javascript/controllers/glossary_run_poll_controller.js", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "")
  .replace("export default class", "class PollController")

function fixture({ fetch, active = true, hidden = false, freshFrame = { childNodes: [{ text: "fresh" }] } } = {}) {
  const timers = []
  const frame = { childNodes: [{ text: "old" }], replaceChildren(...children) { this.childNodes = children } }
  const document = { hidden, getElementById: id => (id === "glossary_results" ? frame : null) }
  const Controller = runInNewContext(`${source}\nPollController`, {
    Controller: class {},
    AbortController,
    fetch,
    document,
    setTimeout: (callback, delay) => timers.push({ callback, delay, cleared: false }),
    clearTimeout: id => { if (id) timers[id - 1].cleared = true },
    DOMParser: class { parseFromString() { return { getElementById: id => (id === "glossary_results" ? freshFrame : null) } } }
  })
  const controller = new Controller()
  controller.activeValue = active
  controller.urlValue = "/org/a/glossary?view=proposals"
  controller.frameValue = "glossary_results"
  controller.intervalValue = 5000
  controller.element = { isConnected: true }
  return { controller, timers, frame, document }
}

const page = () => ({ ok: true, redirected: false, text: async () => "<html></html>" })

test("an active bar asks again after the interval, with the list frame's header", async () => {
  const requests = []
  const f = fixture({ fetch: async (url, options) => { requests.push([url, { ...options.headers }]); return page() } })

  f.controller.connect()

  assert.equal(f.timers.length, 1)
  assert.equal(f.timers[0].delay, 5000)
  await f.timers[0].callback()
  assert.deepEqual(requests, [["/org/a/glossary?view=proposals", { Accept: "text/html", "Turbo-Frame": "glossary_results" }]])
  assert.deepEqual(f.frame.childNodes, [{ text: "fresh" }])
})

test("a bar without an active run asks nothing", () => {
  const f = fixture({ active: false, fetch: async () => assert.fail("no request expected") })

  f.controller.connect()

  assert.equal(f.timers.length, 0)
})

test("an answer that is no list stops the polling and keeps the list", async () => {
  for (const answer of [{ ok: false, redirected: false }, { ok: true, redirected: true }]) {
    const f = fixture({ fetch: async () => ({ ...answer, text: async () => "" }) })
    f.controller.connect()

    await f.timers[0].callback()

    assert.equal(f.timers.length, 1)
    assert.deepEqual(f.frame.childNodes, [{ text: "old" }])
  }
})

test("an answer without the frame replaces nothing and stops", async () => {
  const f = fixture({ fetch: async () => page(), freshFrame: null })
  f.controller.connect()

  await f.timers[0].callback()

  assert.equal(f.timers.length, 1)
  assert.deepEqual(f.frame.childNodes, [{ text: "old" }])
})

test("a failed request asks again at the next tick", async () => {
  const f = fixture({ fetch: async () => { throw new Error("offline") } })
  f.controller.connect()

  await f.timers[0].callback()

  assert.equal(f.timers.length, 2)
  assert.equal(f.timers[1].delay, 5000)
})

test("a disconnect stops the timer and the request, and a late answer replaces nothing", async () => {
  let answer
  let signal
  const f = fixture({ fetch: (url, options) => { signal = options.signal; return new Promise(resolve => { answer = resolve }) } })
  f.controller.connect()
  const running = f.timers[0].callback()

  f.controller.disconnect()
  answer(page())
  await running

  assert.equal(signal.aborted, true)
  assert.deepEqual(f.frame.childNodes, [{ text: "old" }])
  assert.equal(f.timers.length, 1)
})

test("a tab in the background asks only once it is shown again", async () => {
  const f = fixture({ hidden: true, fetch: async () => assert.fail("no request while hidden") })
  f.controller.connect()

  await f.timers[0].callback()

  assert.equal(f.timers.length, 2)
  assert.deepEqual(f.frame.childNodes, [{ text: "old" }])
})
