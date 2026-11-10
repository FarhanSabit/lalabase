import { Controller } from "@hotwired/stimulus"
import { submitTrigger, isOwnFrameEcho } from "auto_submit"

// Automatically submits the enclosing form on changes to selects, checkboxes,
// radios and date inputs. Text and search inputs are debounced (300ms) so that
// a request does not run on every keystroke. Which control counts is decided
// in lib/auto_submit.js: one without a name never does.
//
// A submit still pending when a page visit starts is dropped. The forms this
// runs on aim at a frame that advances history, and a late frame answer does
// not just land somewhere: Turbo promotes it to a visit of its own, which
// cancels the one in flight and pushes the frame's address. On the time list
// that put the narrow address back under a billing the reader had just chosen.
//
// The drop hangs on turbo:visit, not turbo:before-visit: before-visit is
// cancelable (undefined_url_guard vetoes visits there), and a vetoed visit
// must not eat a pending submit -- the page stays, so the typed search still
// has to reach the list. turbo:visit fires once navigation actually proceeds,
// restoration visits included. One visit is no navigation: the promotion of
// this form's OWN frame answer (data-turbo-action), which only writes the
// address; a search typed while that answer ran still goes out (isOwnFrameEcho).
export default class extends Controller {
  static values = { debounce: { type: Number, default: 300 } }

  connect() {
    this.boundHandle = this.handleChange.bind(this)
    this.boundInput  = this.handleInput.bind(this)
    this.boundCancel = this.cancelOnVisit.bind(this)
    this.element.addEventListener("change", this.boundHandle)
    this.element.addEventListener("input",  this.boundInput)
    document.addEventListener("turbo:visit", this.boundCancel)
    this.debounceTimer = null
  }

  disconnect() {
    this.element.removeEventListener("change", this.boundHandle)
    this.element.removeEventListener("input",  this.boundInput)
    document.removeEventListener("turbo:visit", this.boundCancel)
    this.cancelPending()
  }

  handleChange(event) {
    // Text/search is handled debounced via handleInput; the change event a blur
    // fires for it must not submit a second time.
    if (submitTrigger(event.target) === "now") this.submitForm()
  }

  handleInput(event) {
    if (submitTrigger(event.target) !== "debounced") return
    this.cancelPending()
    this.debounceTimer = setTimeout(() => this.submitForm(), this.debounceValue)
  }

  cancelOnVisit(event) {
    if (isOwnFrameEcho(event?.detail?.url, this.ownFrame()?.src)) return
    this.cancelPending()
  }

  ownFrame() {
    const id = this.element.dataset.turboFrame
    return id && id !== "_top" ? document.getElementById(id) : null
  }

  cancelPending() {
    clearTimeout(this.debounceTimer)
    this.debounceTimer = null
  }

  submitForm() {
    if (typeof this.element.requestSubmit === "function") {
      this.element.requestSubmit()
    } else {
      this.element.submit()
    }
  }
}
