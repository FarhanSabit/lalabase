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
    Date,
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
const failure = (status, retryAfter = null) => ({
  ok: false, status, redirected: false,
  headers: { get: name => name === "Retry-After" ? retryAfter : null },
  text: async () => assert.fail("error pages must not be rendered")
})

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

test("nontransient errors and redirects stop polling and keep the list", async () => {
  const permanentStatuses = Array.from({ length: 100 }, (_, index) => 400 + index)
    .filter(status => status !== 408 && status !== 429)
  const answers = [
    ...permanentStatuses.map(status => failure(status)),
    failure(600),
    { ...page(), redirected: true },
    { ...failure(503, "30"), redirected: true }
  ]
  for (const answer of answers) {
    const f = fixture({ fetch: async () => answer })
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

for (const status of [408, 429, 500, 501, 502, 503, 504, 599]) {
  test(`HTTP ${status} retries after five seconds and renders an eventual success`, async () => {
    let calls = 0
    const f = fixture({ fetch: async () => ++calls === 1 ? failure(status) : page() })
    f.controller.connect()

    await f.timers[0].callback()

    assert.equal(calls, 1, "a failure must not immediately refetch")
    assert.deepEqual(f.frame.childNodes, [{ text: "old" }])
    assert.equal(f.timers.length, 2)
    assert.equal(f.timers[1].delay, 5000)
    await f.timers[1].callback()

    assert.equal(calls, 2)
    assert.deepEqual(f.frame.childNodes, [{ text: "fresh" }])
    assert.equal(f.timers.length, 2, "the fresh bar takes over polling")
  })
}

test("a longer HTTP outage keeps delayed polling until a response succeeds", async () => {
  let calls = 0
  const f = fixture({ fetch: async () => ++calls <= 6 ? failure(503) : page() })
  f.controller.connect()

  for (let attempt = 0; attempt < 6; attempt++) {
    assert.ok(f.timers[attempt], `expected request ${attempt + 1}`)
    assert.equal(f.timers[attempt].delay, 5000)
    await f.timers[attempt].callback()
  }

  assert.equal(calls, 6)
  assert.equal(f.timers.length, 7)
  assert.deepEqual(f.frame.childNodes, [{ text: "old" }])

  await f.timers[6].callback()
  assert.equal(calls, 7)
  assert.equal(f.timers.length, 7, "the fresh bar takes over polling")
  assert.deepEqual(f.frame.childNodes, [{ text: "fresh" }])
})

test("429 and 503 respect valid Retry-After seconds and HTTP dates", async t => {
  const now = Date.parse("Mon, 09 Nov 2026 12:00:00 GMT")
  t.mock.method(Date, "now", () => now)
  for (const status of [429, 503]) {
    for (const [header, delay] of [["12", 12000], [" 12 ", 12000], ["Mon, 09 Nov 2026 12:00:30 GMT", 30000]]) {
      const f = fixture({ fetch: async () => failure(status, header) })
      f.controller.connect()
      await f.timers[0].callback()
      assert.equal(f.timers[1]?.delay, delay, `${status}: ${header}`)
    }
  }
})

test("short, invalid, past and overflowing Retry-After values use the normal interval", async t => {
  t.mock.method(Date, "now", () => Date.parse("Mon, 09 Nov 2026 12:00:00 GMT"))
  for (const header of [null, "", "0", "2", "-1", "1.5", "1e2", "Infinity", "invalid", "2147484", "9".repeat(400),
    "Mon, 09 Nov 2026 11:59:00 GMT", "Mon, 09 Nov 2099 12:00:00 GMT"]) {
    const f = fixture({ fetch: async () => failure(503, header) })
    f.controller.connect()
    await f.timers[0].callback()
    assert.equal(f.timers[1]?.delay, 5000, `Retry-After: ${header}`)
  }
  const f = fixture({ fetch: async () => failure(500, "30") })
  f.controller.connect()
  await f.timers[0].callback()
  assert.equal(f.timers[1]?.delay, 5000, "only 429 and 503 use Retry-After")
})

test("a disconnect clears a pending HTTP retry", async () => {
  const f = fixture({ fetch: async () => failure(500) })
  f.controller.connect()
  await f.timers[0].callback()
  assert.equal(f.timers.length, 2)

  f.controller.disconnect()

  assert.equal(f.timers[1].cleared, true)
  assert.equal(f.controller.timer, null)
})

test("late HTTP and network failures after disconnect never create a timer", async () => {
  for (const networkFailure of [false, true]) {
    let settle
    let signal
    const f = fixture({ fetch: (_url, options) => {
      signal = options.signal
      return new Promise((resolve, reject) => { settle = networkFailure ? () => reject(new Error("offline")) : () => resolve(failure(503)) })
    } })
    f.controller.connect()
    const running = f.timers[0].callback()

    f.controller.disconnect()
    settle()
    await running

    assert.equal(signal.aborted, true)
    assert.equal(f.timers.length, 1)
    assert.equal(f.controller.timer, null)
    assert.deepEqual(f.frame.childNodes, [{ text: "old" }])
  }
})

test("a stale failure cannot schedule over a reconnected controller's request", async () => {
  const pending = []
  const f = fixture({ fetch: () => new Promise(resolve => pending.push(resolve)) })
  f.controller.connect()
  const stale = f.timers[0].callback()
  f.controller.disconnect()
  f.controller.connect()
  const current = f.timers[1].callback()
  const currentRequest = f.controller.request

  pending[0](failure(503))
  await stale

  assert.equal(f.timers.length, 2)
  assert.equal(f.controller.request, currentRequest)
  pending[1](page())
  await current
  assert.deepEqual(f.frame.childNodes, [{ text: "fresh" }])
})

test("deactivation or detachment before a response prevents retrying or rendering", async () => {
  for (const deactivate of [f => { f.controller.activeValue = false }, f => { f.controller.element.isConnected = false }]) {
    for (const answer of [page(), failure(500), new Error("offline")]) {
      let settle
      const f = fixture({ fetch: () => new Promise((resolve, reject) => {
        settle = () => answer instanceof Error ? reject(answer) : resolve(answer)
      }) })
      f.controller.connect()
      const running = f.timers[0].callback()
      deactivate(f)
      settle()
      await running

      assert.equal(f.timers.length, 1)
      assert.deepEqual(f.frame.childNodes, [{ text: "old" }])
    }
  }
})

test("a pending tick does not fetch after the run becomes inactive or disconnects", async () => {
  for (const stop of [f => { f.controller.activeValue = false }, f => f.controller.disconnect()]) {
    let calls = 0
    const f = fixture({ fetch: async () => { calls++; return page() } })
    f.controller.connect()
    stop(f)
    await f.timers[0].callback()
    assert.equal(calls, 0)
    assert.equal(f.timers.length, 1)
  }
})

test("a retry waits through hidden ticks without sending requests", async () => {
  let calls = 0
  const f = fixture({ fetch: async () => ++calls < 3 ? failure(500) : page() })
  f.controller.connect()
  await f.timers[0].callback()
  f.document.hidden = true

  for (let tick = 1; tick <= 5; tick++) {
    assert.ok(f.timers[tick])
    await f.timers[tick].callback()
  }
  assert.equal(calls, 1)
  assert.deepEqual(f.frame.childNodes, [{ text: "old" }])

  f.document.hidden = false
  await f.timers[6].callback()
  assert.equal(calls, 2)
  assert.equal(f.timers[7]?.delay, 5000)
  await f.timers[7].callback()
  assert.equal(calls, 3)
  assert.deepEqual(f.frame.childNodes, [{ text: "fresh" }])
})
