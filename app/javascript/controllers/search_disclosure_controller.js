import { Controller } from "@hotwired/stimulus"

// The search of a list head without the filter bar (NeoListSearchComponent:
// the inbox, Personen): a magnifier that grows into the field on a click and
// folds back when the field is left empty (F35). Markup markers and
// stylesheet are the filter bar's (data-fb-search, data-fb-search-open,
// components/filter_bar.css under .filter-bar); the form inside submits
// itself (auto-submit).
//
// DELIBERATE DUPLICATION: filter_bar_controller#openSearch, #closeSearch and
// #searchBlur do the same for the filter bar, whose search lives among its
// saved views and conditions and cannot be mounted alone. Change one, check
// the other.
export default class extends Controller {
  static targets = ["input"]

  open(event) {
    if (event) event.preventDefault()
    this.element.setAttribute("data-fb-search-open", "")
    // The field was display:none a moment ago; a forced layout applies the
    // new style, or focus() would find it still hidden and do nothing.
    void this.inputTarget.offsetWidth
    this.inputTarget.focus()
  }

  // A typed term keeps the field open, Escape included: what narrows the
  // list stays visible.
  close(event) {
    if (!this.isOpen || this.inputTarget.value) return
    this.element.removeAttribute("data-fb-search-open")
    if (event && event.type === "keydown") {
      this.element.querySelector("[data-fb-search-open-button]")?.focus()
    }
  }

  blur() {
    if (this.inputTarget.value) return
    requestAnimationFrame(() => {
      if (!this.element.contains(document.activeElement)) this.close()
    })
  }

  // Escape folds an open, empty field before the lane behind it closes
  // (lib/escape_owner.js).
  ownsEscape() {
    return this.isOpen && !this.inputTarget.value
  }

  get isOpen() {
    return this.element.hasAttribute("data-fb-search-open")
  }
}
