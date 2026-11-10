import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'

// The delayed mark-as-read gives the reader a few seconds for a look. It
// counts only while the ticket is still in view: a lane shut in place hides
// it by a class on the grid and leaves this controller connected.

const source = readFileSync(new URL('../../../app/javascript/controllers/pane_mark_read_delay_controller.js', import.meta.url), 'utf8')
  .replace(/^import .*\n/gm, '')
  .replace('export default class', 'class PaneMarkReadDelayController')

function build({ laneShut }) {
  const requests = []
  const rendered = []
  const context = {
    Controller: class {},
    document: { querySelector: () => ({ content: 'token' }) },
    fetch: async (url, options) => { requests.push({ url, options }); return { ok: true, text: async () => '<turbo-stream></turbo-stream>' } },
    Turbo: { renderStreamMessage: (html) => rendered.push(html) },
    console
  }
  const Controller = runInNewContext(`${source}\nPaneMarkReadDelayController`, context)
  const controller = new Controller()
  controller.urlValue = '/org/acme/inbox/n1/mark_read'
  controller.element = { closest: (selector) => (selector === '.layout.hide-content' && laneShut ? {} : null) }
  return { controller, requests, rendered }
}

test('a ticket still in view is marked as read and the answer is rendered', async () => {
  const { controller, requests, rendered } = build({ laneShut: false })

  await controller.markRead()

  assert.equal(requests.length, 1)
  assert.equal(requests[0].url, '/org/acme/inbox/n1/mark_read')
  assert.equal(requests[0].options.method, 'PATCH')
  assert.equal(rendered.length, 1)
})

test('a ticket whose lane was shut before the time was up stays unread', async () => {
  const { controller, requests } = build({ laneShut: true })

  await controller.markRead()

  assert.equal(requests.length, 0)
})
