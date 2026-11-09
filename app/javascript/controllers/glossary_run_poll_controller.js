import { Controller } from "@hotwired/stimulus"

const MAX_TIMEOUT_DELAY = 2_147_483_647

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
// the right was taken) stops the polling. Transient HTTP and network failures
// ask again after a delay while this bar remains active and connected.
// A tab in the background asks only once it is shown again.
export default class extends Controller {
  static values = {
    active: Boolean,
    url: String,
    frame: String,
    interval: { type: Number, default: 5000 }
  }

  connect() {
    this.connected = true
    this.schedule()
  }

  disconnect() {
    this.connected = false
    clearTimeout(this.timer)
    this.timer = null
    this.request?.abort()
    this.request = null
  }

  canPoll() {
    return this.connected && this.activeValue && this.element.isConnected
  }

  schedule(delay = this.intervalValue) {
    clearTimeout(this.timer)
    this.timer = this.canPoll() ? setTimeout(() => this.reload(), delay) : null
  }

  retryDelay(response) {
    if (response.status !== 429 && response.status !== 503) return this.intervalValue
    const value = response.headers.get("Retry-After")?.trim()
    if (!value) return this.intervalValue

    let delay
    if (/^\d+$/.test(value)) {
      delay = Number(value) * 1000
    } else {
      const date = Date.parse(value)
      // Only accept a valid HTTP date, not Date.parse's loose numeric formats.
      if (!Number.isFinite(date) || new Date(date).toUTCString() !== value) return this.intervalValue
      delay = date - Date.now()
    }
    // Avoid overflowing the browser's timer into an immediate retry.
    return Number.isSafeInteger(delay) && delay >= 0 && delay <= MAX_TIMEOUT_DELAY
      ? Math.max(this.intervalValue, delay) : this.intervalValue
  }

  async reload() {
    this.timer = null
    if (!this.canPoll()) return
    if (document.hidden) return this.schedule()

    const request = this.request = new AbortController()
    try {
      const response = await fetch(this.urlValue, {
        signal: request.signal,
        headers: { Accept: "text/html", "Turbo-Frame": this.frameValue }
      })
      if (request !== this.request || !this.canPoll() || response.redirected) return
      if (!response.ok) {
        const transient = response.status === 408 || response.status === 429 ||
          (response.status >= 500 && response.status <= 599)
        if (transient) this.schedule(this.retryDelay(response))
        return
      }
      const html = await response.text()
      const fresh = new DOMParser().parseFromString(html, "text/html").getElementById(this.frameValue)
      const frame = document.getElementById(this.frameValue)
      if (request !== this.request || !this.canPoll() || !fresh || !frame) return
      frame.replaceChildren(...fresh.childNodes)
    } catch (error) {
      if (error?.name !== "AbortError" && request === this.request) this.schedule()
    } finally {
      if (request === this.request) this.request = null
    }
  }
}
