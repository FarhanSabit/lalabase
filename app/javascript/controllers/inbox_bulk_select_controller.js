import { Controller } from "@hotwired/stimulus"

// Gmail-style bulk select for the inbox master list.
//
// Connects a checkbox per notification item to an action bar over the tools
// row that shows "X selected · All · Mark as read · Archive · ×" as soon as at
// least one item is selected. The checkboxes show on hover (CSS); while the
// element carries `inbox-selecting` they show on every row: from the first
// tick on, and after "Auswählen" in the "···" menu, the way in on a phone,
// which has no hover. Existing single-item actions (click to the detail
// view) remain untouched — the checkbox only stops its own click, so that
// the enclosing link_to does not fire.
//
// Backend: extends the existing mark_all_read / archive_all routes with
// params[:ids][]. See doc/inbox_v1_plan.md PR-2.
export default class extends Controller {
  static targets = ["row", "checkbox", "bar", "count", "form"]
  static values  = { selectedIds: Array }

  connect() {
    this.selectedIdsValue = []
    this.selecting = false
    this._render()
  }

  // "Auswählen" in the "···" menu: show every checkbox without ticking one,
  // and close the menu it was chosen from.
  startSelecting(event) {
    event?.target?.closest("details")?.removeAttribute("open")
    this.selecting = true
    this._render()
  }

  // "Alle" in the bulk bar: tick every row the list shows.
  selectAll() {
    const ids = []
    this.checkboxTargets.forEach((cb) => {
      cb.checked = true
      if (cb.dataset.notificationId) ids.push(cb.dataset.notificationId)
    })
    this.selectedIdsValue = Array.from(new Set(ids))
    this._render()
  }

  toggle(event) {
    const id = event.target.dataset.notificationId
    if (!id) return
    const current = new Set(this.selectedIdsValue)
    if (event.target.checked) {
      current.add(id)
    } else {
      current.delete(id)
    }
    this.selectedIdsValue = Array.from(current)
    this._render()
  }

  // Prevents a click on the checkbox from triggering the enclosing link.
  stopRowClick(event) {
    event.stopPropagation()
  }

  clear() {
    this.checkboxTargets.forEach((cb) => { cb.checked = false })
    this.selectedIdsValue = []
    this.selecting = false
    this._render()
  }

  // After a successful bulk submit (mark_all_read / archive_all): clear the
  // selection, so that the action bar disappears and no longer shows
  // "3 selected" even though the items have since left the list.
  onBulkSubmit(event) {
    if (event?.detail?.success === false) return
    this.clear()
  }

  _render() {
    const count = this.selectedIdsValue.length
    const selecting = this.selecting || count > 0
    this.element.classList.toggle("inbox-selecting", selecting)
    if (this.hasBarTarget) {
      this.barTarget.classList.toggle("hidden", !selecting)
    }
    if (this.hasCountTarget) {
      this.countTarget.textContent = count
    }
    // ⚠️ Without ids, mark_all_read and archive_all act on EVERY notification:
    // the bar is open in selection mode before anything is ticked, so its
    // actions stay disabled until a row is.
    this.formTargets.forEach((form) => {
      form.querySelectorAll('button[type="submit"]').forEach((button) => { button.disabled = count === 0 })
    })
    this._syncHiddenInputs()
    this._highlightRows()
  }

  // Writes the selected IDs as hidden inputs into all bulk action forms,
  // so that submit sends the correct IDs.
  _syncHiddenInputs() {
    this.formTargets.forEach((form) => {
      // Remove previously existing ids[] inputs
      form.querySelectorAll('input[data-bulk-id="true"]').forEach((el) => el.remove())
      this.selectedIdsValue.forEach((id) => {
        const input = document.createElement("input")
        input.type = "hidden"
        input.name = "ids[]"
        input.value = id
        input.dataset.bulkId = "true"
        form.appendChild(input)
      })
    })
  }

  _highlightRows() {
    const selected = new Set(this.selectedIdsValue)
    this.rowTargets.forEach((row) => {
      const id = row.dataset.notificationId
      row.classList.toggle("inbox-row--checked", selected.has(id))
    })
  }
}
