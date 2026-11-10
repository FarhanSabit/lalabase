import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'

// A row of the inbox list. On a wide page a click opens the ticket in the
// lane: the frame load is Turbo's, the address, the tint of the open row and
// the lane itself (layout-toggle) are this controller's. On a narrow page
// there is no lane, and the click visits the ticket's full view.

const source = readFileSync(new URL('../../../app/javascript/controllers/inbox_master_item_controller.js', import.meta.url), 'utf8')
  .replace(/^import .*\n/gm, '')
  .replace('export default class', 'class InboxMasterItemController')

function classList(initial = []) {
  const set = new Set(initial)
  return {
    add(name) { set.add(name) },
    remove(name) { set.delete(name) },
    toggle(name, force) { if (force) set.add(name); else set.delete(name) },
    has(name) { return set.has(name) }
  }
}

function build({ search = '', width = 1280, rowId = 'n1', rowClasses = [], otherRows = [] } = {}) {
  const pushed = []
  const visited = []
  const shown = []
  const row = { dataset: { notificationId: rowId }, classList: classList(rowClasses) }
  const page = {}
  const window = {
    innerWidth: width,
    location: { search },
    history: { pushState: (state, _title, url) => pushed.push({ state, url }) }
  }
  const document = { querySelectorAll: () => [row, ...otherRows].filter((r) => r.classList.has('selected-row')) }
  const Turbo = { visit: (url, options) => visited.push({ url, options }) }
  const Controller = runInNewContext(`${source}\nInboxMasterItemController`, {
    Controller: class {}, window, document, Turbo, URLSearchParams
  })
  const controller = new Controller()
  controller.element = {
    href: `https://inbox.example/org/acme/inbox?notification=${rowId}`,
    closest: (selector) => (selector === '.inbox-row' ? row : page)
  }
  controller.application = { getControllerForElementAndIdentifier: () => ({ showContent: () => shown.push(true) }) }
  controller.hasFullviewUrlValue = true
  controller.fullviewUrlValue = '/org/acme/projects/p/tickets/t'
  return { controller, row, pushed, visited, shown }
}

test('the row the address names marks itself as open', () => {
  const { controller, row } = build({ search: '?state_filters%5B%5D=unread&notification=n1' })
  controller.connect()

  assert.equal(row.classList.has('selected-row'), true)
})

test('a row redrawn as open after the lane was shut takes the mark off', () => {
  const { controller, row } = build({ search: '?state_filters%5B%5D=unread', rowClasses: ['selected-row'] })
  controller.connect()

  assert.equal(row.classList.has('selected-row'), false)
})

test('a click on a wide page pushes the address, moves the mark and opens the lane, and lets the frame load', () => {
  const other = { dataset: { notificationId: 'n0' }, classList: classList(['selected-row']) }
  const { controller, row, pushed, visited, shown } = build({ otherRows: [other] })
  let prevented = false

  controller.handleClick({ preventDefault: () => { prevented = true } })

  assert.equal(pushed.length, 1)
  assert.equal(pushed[0].url, 'https://inbox.example/org/acme/inbox?notification=n1')
  assert.equal(pushed[0].state.lane, true)
  assert.equal(other.classList.has('selected-row'), false)
  assert.equal(row.classList.has('selected-row'), true)
  assert.equal(shown.length, 1)
  assert.equal(prevented, false)
  assert.equal(visited.length, 0)
})

test('a click on a narrow page visits the full view of the ticket instead', () => {
  const { controller, pushed, visited, shown } = build({ width: 800 })
  let prevented = false

  controller.handleClick({ preventDefault: () => { prevented = true } })

  assert.equal(prevented, true)
  assert.equal(visited.length, 1)
  assert.equal(visited[0].url, '/org/acme/projects/p/tickets/t')
  assert.equal(pushed.length, 0)
  assert.equal(shown.length, 0)
})
