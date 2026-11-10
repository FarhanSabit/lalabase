import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'

// The address of the next page keeps every parameter of the current address,
// repeated keys included. URLSearchParams#set per pair kept only the last
// value of state_filters[], so page two of the inbox's "Alle" view
// (state_filters[]=read&state_filters[]=unread) listed unread rows only.

const source = readFileSync(new URL('../../../app/javascript/controllers/neo_endless_scroll_controller.js', import.meta.url), 'utf8')
  .replace(/^import .*\n/gm, '')
  .replace('export default class', 'class EndlessScrollController')

function controllerAt(search) {
  const window = { location: { origin: 'https://inbox.example', search }, innerWidth: 1280 }
  const Controller = runInNewContext(`${source}\nEndlessScrollController`, {
    Controller: class {}, window, URL, URLSearchParams
  })
  const controller = new Controller()
  controller.urlValue = '/org/acme/inbox'
  return controller
}

test('the next page keeps a repeated key with every value', () => {
  const url = controllerAt('?state_filters%5B%5D=read&state_filters%5B%5D=unread&view_mode=grouped').nextPageUrl(2)

  assert.deepEqual(url.searchParams.getAll('state_filters[]'), ['read', 'unread'])
  assert.equal(url.searchParams.get('view_mode'), 'grouped')
  assert.equal(url.searchParams.get('page'), '2')
  assert.equal(url.pathname, '/org/acme/inbox')
})

test('the page of the current address is replaced, not repeated', () => {
  const url = controllerAt('?page=2&state_filters%5B%5D=unread').nextPageUrl(3)

  assert.deepEqual(url.searchParams.getAll('page'), ['3'])
  assert.deepEqual(url.searchParams.getAll('state_filters[]'), ['unread'])
})

test('an address without parameters asks for the page alone', () => {
  assert.equal(controllerAt('').nextPageUrl(2).search, '?page=2')
})

// The pages are cut by offset and the list moves under them: a notification
// that arrives after page one was drawn pushes its last row onto page two.

function node({ item = null, header = null } = {}) {
  return {
    item,
    header,
    matches(selector) { return selector === '[data-date-header]' ? header !== null : item !== null },
    getAttribute(name) { return name === 'data-date-header' ? header : item },
    cloneNode() { return node({ item, header }) }
  }
}

function listOf(children) {
  return {
    children,
    querySelectorAll(selector) {
      return children.filter((child) => child.matches(selector === '[data-date-header]' ? '[data-date-header]' : '[data-notification-item]'))
    },
    appendChild(child) { children.push(child) }
  }
}

function scrollerWith(children) {
  const controller = controllerAt('')
  controller.containerTarget = listOf(children)
  return controller
}

const shape = (controller) => controller.containerTarget.children.map((child) => child.header ? `[${child.header}]` : child.item)

test('a row that is on screen already is not appended a second time', () => {
  const controller = scrollerWith([node({ item: 'a' }), node({ item: 'b' })])

  const result = controller._appendChildren(listOf([node({ item: 'b' }), node({ item: 'c' })]))

  assert.deepEqual(shape(controller), ['a', 'b', 'c'])
  assert.equal(result.found, 2)
  assert.equal(result.appended, 1)
})

test('a heading that repeats the last one is dropped, a new one comes with its first new row', () => {
  const controller = scrollerWith([node({ header: 'today' }), node({ item: 'a' })])

  controller._appendChildren(listOf([
    node({ header: 'today' }), node({ item: 'b' }), node({ header: 'older' }), node({ item: 'c' })
  ]))

  assert.deepEqual(shape(controller), ['[today]', 'a', 'b', '[older]', 'c'])
})

test('a heading whose rows are all on screen is dropped with them', () => {
  const controller = scrollerWith([node({ header: 'today' }), node({ item: 'a' }), node({ header: 'yesterday' }), node({ item: 'b' })])

  const result = controller._appendChildren(listOf([
    node({ header: 'yesterday' }), node({ item: 'b' }), node({ header: 'older' }), node({ item: 'c' })
  ]))

  assert.deepEqual(shape(controller), ['[today]', 'a', '[yesterday]', 'b', '[older]', 'c'])
  assert.equal(result.found, 2)
})

test('a page of rows that are all on screen is found, so it is no end of the list', () => {
  const controller = scrollerWith([node({ item: 'a' })])

  const result = controller._appendChildren(listOf([node({ item: 'a' })]))

  assert.equal(result.found, 1)
  assert.equal(result.appended, 0)
})
