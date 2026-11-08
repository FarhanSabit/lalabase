import { Controller } from "@hotwired/stimulus"

// The review list of the glossary while an extraction runs (K5b): reloads the
// list frame every few seconds, so the bar of the run and the new proposals
// show up without a reload of the page. Mounted on the run bar, inside that
// frame (organisations/glossary/_run_bar).
//
// No broadcast: the page asks, and the server renders the list for this
// reader, with this reader's rights, on every request (the form of
// meeting_section_sync). The fresh markup decides whether to go on: replacing
// the frame's children replaces this bar too, this controller disconnects,
// and the new bar's controller polls again only while its active value is
// true. A disconnect stops the timer and the request in flight.
//
// The request carries the list frame's Turbo-Frame header, so the index
// renders without the application layout; the frame is cut out of the
// answer. An answer that is no list (a redirect to the sign-in, a 403 after
// the right was taken) stops the polling; a failed request asks again at the
// next tick. A tab in the background asks only once it is shown again.
export default class extends Controller {
  static values = {
    active: Boolean,
    url: String,
    frame: String,
    interval: { type: Number, default: 5000 }
  }

  connect() {
    this.schedule()
  }

  disconnect() {
    clearTimeout(this.timer)
    this.timer = null
    this.request?.abort()
    this.request = null
  }

  schedule() {
    clearTimeout(this.timer)
    this.timer = this.activeValue ? setTimeout(() => this.reload(), this.intervalValue) : null
  }

  async reload() {
    this.timer = null
    if (!this.element.isConnected) return
    if (document.hidden) return this.schedule()

    const request = this.request = new AbortController()
    try {
      const response = await fetch(this.urlValue, {
        signal: request.signal,
        headers: { Accept: "text/html", "Turbo-Frame": this.frameValue }
      })
      if (request !== this.request || !response.ok || response.redirected) return
      const html = await response.text()
      const fresh = new DOMParser().parseFromString(html, "text/html").getElementById(this.frameValue)
      const frame = document.getElementById(this.frameValue)
      if (request !== this.request || !this.element.isConnected || !fresh || !frame) return
      frame.replaceChildren(...fresh.childNodes)
    } catch (error) {
      if (error?.name !== "AbortError" && request === this.request) this.schedule()
    } finally {
      if (request === this.request) this.request = null
    }
  }
}
