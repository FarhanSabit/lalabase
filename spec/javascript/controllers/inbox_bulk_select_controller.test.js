import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'

// The bulk bar of the inbox. Without ids the routes behind its two forms act
// on EVERY notification, so a submit with nothing ticked must never leave:
// the buttons are disabled, and the submit itself is stopped, because Turbo
// re-enables a submitter after a failed request.

const source = readFileSync(new URL('../../../app/javascript/controllers/inbox_bulk_select_controller.js', import.meta.url), 'utf8')
  .replace(/^import .*\n/gm, '')
  .replace('export default class', 'class InboxBulkSelectController')

function classList(initial = []) {
  const set = new Set(initial)
  return {
    toggle(name, force) { if (force) set.add(name); else set.delete(name) },
    has(name) { return set.has(name) }
  }
}

function fakeForm() {
  const button = { disabled: false }
  const inputs = []
  return {
    button,
    inputs,
    querySelectorAll(selector) { return selector.startsWith('button') ? [button] : inputs.splice(0) },
    appendChild(input) { inputs.push(input) }
  }
}

function build({ ids = ['n1', 'n2'] } = {}) {
  const document = {
    activeElement: null,
    createElement: () => ({ dataset: {}, remove() {} })
  }
  const Controller = runInNewContext(`${source}\nInboxBulkSelectController`, { Controller: class {}, document })
  const controller = new Controller()
  const forms = [fakeForm(), fakeForm()]
  const checkboxes = ids.map((id) => ({ checked: false, dataset: { notificationId: id }, focus() { this.focused = true } }))
  const bar = { classList: classList(['hidden']), contains: (node) => node === 'inside-the-bar' }
  controller.element = { classList: classList(), querySelector: () => null }
  controller.formTargets = forms
  controller.checkboxTargets = checkboxes
  controller.rowTargets = checkboxes.map((cb) => ({ dataset: cb.dataset, classList: classList() }))
  controller.hasBarTarget = true
  controller.barTarget = bar
  controller.hasCountTarget = true
  controller.countTarget = { textContent: '' }
  controller.connect()
  return { controller, forms, checkboxes, bar, document }
}

test('"Auswählen" opens the bar with every action disabled and focuses the first checkbox', () => {
  const { controller, forms, checkboxes, bar } = build()
  let closed = false
  controller.startSelecting({ target: { closest: () => ({ removeAttribute: () => { closed = true } }) } })

  assert.equal(closed, true)
  assert.equal(bar.classList.has('hidden'), false)
  assert.equal(controller.element.classList.has('inbox-selecting'), true)
  assert.equal(controller.countTarget.textContent, 0)
  assert.ok(forms.every((form) => form.button.disabled))
  assert.equal(checkboxes[0].focused, true)
})

test('a submit with nothing ticked is stopped, one with a tick leaves with its ids', () => {
  const { controller, forms, checkboxes } = build()
  let prevented = 0
  const submit = { preventDefault: () => { prevented += 1 } }

  controller.startSelecting()
  controller.guardSubmit(submit)
  assert.equal(prevented, 1)

  checkboxes[0].checked = true
  controller.toggle({ target: checkboxes[0] })
  controller.guardSubmit(submit)
  assert.equal(prevented, 1)
  assert.ok(forms.every((form) => !form.button.disabled))
  assert.deepEqual(forms[0].inputs.map((input) => [input.name, input.value]), [['ids[]', 'n1']])
})

test('a failed submit redraws the buttons from the selection instead of leaving them as Turbo left them', () => {
  const { controller, forms, checkboxes } = build()
  checkboxes[0].checked = true
  controller.toggle({ target: checkboxes[0] })
  checkboxes[0].checked = false
  controller.toggle({ target: checkboxes[0] }) // unticked while the request was pending
  forms.forEach((form) => { form.button.disabled = false }) // Turbo re-enabled the submitter

  controller.onBulkSubmit({ detail: { success: false } })

  assert.ok(forms.every((form) => form.button.disabled))
  assert.equal(controller.selectedIdsValue.length, 0)
})

test('a successful submit clears the selection and shuts the bar', () => {
  const { controller, checkboxes, bar } = build()
  controller.selectAll()
  assert.equal(controller.countTarget.textContent, 2)

  controller.onBulkSubmit({ detail: { success: true } })

  assert.equal(controller.selectedIdsValue.length, 0) // an array of the controller's realm, so no deepEqual
  assert.ok(checkboxes.every((cb) => !cb.checked))
  assert.equal(bar.classList.has('hidden'), true)
  assert.equal(controller.element.classList.has('inbox-selecting'), false)
})

test('the way out hands focus back to the "···" trigger when it sat in the bar', () => {
  const { controller, document } = build()
  const trigger = { focus() { this.focused = true } }
  controller.element.querySelector = (selector) => (selector === '.more-menu__trigger' ? trigger : null)
  controller.startSelecting()
  document.activeElement = 'inside-the-bar'

  controller.clear()

  assert.equal(trigger.focused, true)
})

// A stream redraws the list while a selection stands (the delayed mark-read
// of the open ticket does, five seconds after a click). The new rows come
// unticked; the selection used to live on, over rows without a tick and with
// the ids of rows that had left.
const afterRedraw = () => new Promise((resolve) => setTimeout(resolve, 0))

function redraw(controller, ids) {
  const checkboxes = ids.map((id) => ({ checked: false, dataset: { notificationId: id } }))
  controller.checkboxTargets = checkboxes
  controller.rowTargets = checkboxes.map((cb) => ({ dataset: cb.dataset, classList: classList() }))
  checkboxes.forEach(() => controller.checkboxTargetConnected())
  return checkboxes
}

test('a redrawn list ticks the rows that are still selected and drops the ones that left', async () => {
  const { controller, forms } = build({ ids: ['n1', 'n2', 'n3'] })
  controller.selectAll()

  const checkboxes = redraw(controller, ['n2', 'n3', 'n4'])
  await afterRedraw()

  assert.deepEqual(checkboxes.map((cb) => cb.checked), [true, true, false])
  assert.equal(controller.countTarget.textContent, 2)
  assert.deepEqual(forms[0].inputs.map((input) => input.value), ['n2', 'n3'])
  assert.ok(controller.rowTargets[0].classList.has('inbox-row--checked'))
})

test('a redraw that leaves no selected row keeps the mode open with the actions disabled', async () => {
  const { controller, forms, bar } = build({ ids: ['n1'] })
  controller.startSelecting()
  controller.selectAll()

  redraw(controller, ['n9'])
  await afterRedraw()

  assert.equal(controller.selectedIdsValue.length, 0)
  assert.ok(forms.every((form) => form.button.disabled))
  assert.equal(bar.classList.has('hidden'), false) // entered through the menu, left through the way out
})

test('rows added by the endless scroll leave the selection alone', async () => {
  const { controller, checkboxes } = build({ ids: ['n1', 'n2'] })
  checkboxes[0].checked = true
  controller.toggle({ target: checkboxes[0] })

  const more = { checked: false, dataset: { notificationId: 'n3' } }
  controller.checkboxTargets = [...checkboxes, more]
  controller.checkboxTargetConnected()
  await afterRedraw()

  assert.deepEqual(controller.checkboxTargets.map((cb) => cb.checked), [true, false, false])
  assert.equal(controller.countTarget.textContent, 1)
})

test('the rows of the first draw, which connect before the controller does, start nothing', async () => {
  const Controller = runInNewContext(`${source}\nInboxBulkSelectController`, { Controller: class {}, document: {} })
  const controller = new Controller()
  controller.checkboxTargetConnected()
  await afterRedraw()

  assert.equal(controller.reconcilePending, undefined)
})
