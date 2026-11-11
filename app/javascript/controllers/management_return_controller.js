import { Controller } from "@hotwired/stimulus"

// Frame navigation can change the address bar without updating Turbo's stored
// referrer. Management must remember the page as it is now, including its lane.
export default class extends Controller {
  refresh(event) {
    const { url, fetchOptions } = event.detail
    if (fetchOptions.method === "GET" && url.href === this.element.href) {
      fetchOptions.referrer = window.location.href
    }
  }
}
