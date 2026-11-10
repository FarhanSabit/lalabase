import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["container", "loadingIndicator", "endMessage", "sentinel"]
  static values = { 
    url: String,
    page: Number,
    hasMore: Boolean,
    loading: Boolean 
  }
  
  connect() {
    // Adjust rootMargin for mobile - load earlier on mobile for smoother experience
    const isMobile = window.innerWidth < 640
    const rootMargin = isMobile ? "200px" : "100px"
    
    this.observer = new IntersectionObserver(
      this.handleIntersection.bind(this),
      {
        root: null,
        rootMargin: rootMargin,
        threshold: 0.1
      }
    )
    
    // Prefer observing the sentinel — it is always visible (1px). The
    // loading indicator is hidden (display:none, no box) and would
    // never be reported as visible by the IntersectionObserver.
    if (this.hasSentinelTarget) {
      this.observer.observe(this.sentinelTarget)
    } else if (this.hasLoadingIndicatorTarget) {
      this.observer.observe(this.loadingIndicatorTarget)
    }

    // Initialize values
    this.pageValue = this.pageValue || 1
    this.hasMoreValue = this.hasMoreValue ?? true
    this.loadingValue = false
  }
  
  disconnect() {
    if (this.observer) {
      this.observer.disconnect()
    }
  }
  
  handleIntersection(entries) {
    entries.forEach(entry => {
      if (entry.isIntersecting && this.hasMoreValue && !this.loadingValue) {
        this.loadMore()
      }
    })
  }
  
  async loadMore() {
    if (this.loadingValue || !this.hasMoreValue) {
      return
    }
    
    this.loadingValue = true
    this.showLoadingIndicator()
    
    try {
      const nextPage = this.pageValue + 1
      const url = this.nextPageUrl(nextPage)

      const response = await fetch(url, {
        headers: {
          'Accept': 'text/html',
          'X-Requested-With': 'XMLHttpRequest'
        }
      })
      
      if (response.ok) {
        const html = await response.text()
        const doc = new DOMParser().parseFromString(html, 'text/html')

        // Get the new items container of the next page.
        const newContainer = doc.querySelector('[data-neo-endless-scroll-target="container"]')
        const newScroller = doc.querySelector('[data-controller~="neo-endless-scroll"]')
        const { found } = newContainer ? this._appendChildren(newContainer) : { found: 0 }

        // The page counts when it HELD rows, shown already or not: a page of
        // rows that are all on screen (see _appendChildren) is no end of the list.
        if (found > 0) {
          this.pageValue = nextPage
          // Read hasMore directly from the next page's data attribute
          // (Pagy-driven), instead of looking for .pagy-nav.
          this.hasMoreValue =
            newScroller?.getAttribute('data-neo-endless-scroll-has-more-value') === 'true'
        } else {
          this.hasMoreValue = false
        }
      } else {
        console.error('Failed to load more notifications:', response.status)
        this.hasMoreValue = false
      }
    } catch (error) {
      console.error('Error loading more notifications:', error)
      this.hasMoreValue = false
    } finally {
      this.loadingValue = false
      this.updateIndicators()
    }
  }
  
  // The address of the next page: the list address with every parameter of
  // the current address, repeated keys included, and the page number.
  // ⚠️ Not URLSearchParams#set per pair: a repeated key such as
  // state_filters[]=read&state_filters[]=unread (the "Alle" view of the
  // inbox) would keep only its last value, and page two would list another
  // set of rows than page one.
  nextPageUrl(nextPage) {
    const url = new URL(this.urlValue, window.location.origin)
    const currentParams = new URLSearchParams(window.location.search)
    for (const key of new Set(currentParams.keys())) url.searchParams.delete(key)
    for (const [key, value] of currentParams) {
      if (key !== 'page') url.searchParams.append(key, value)
    }
    url.searchParams.set('page', nextPage)
    return url
  }

  // Appends the children of the new container to the existing one and
  // returns { found, appended }: the notification items the page held, and
  // those of them that were new.
  //
  // The pages are cut by offset, and the list moves under them: a
  // notification that arrives after page one was drawn pushes the last row
  // of page one onto page two. A row that is on screen already is left out,
  // by its notification id.
  // A heading (data-date-header: a period key of the grouped view) waits for
  // its first new row: one that repeats the last heading shown is dropped,
  // and so is one whose rows were all on screen.
  _appendChildren(newContainer) {
    const shown = new Set(
      [...this.containerTarget.querySelectorAll('[data-notification-item]')]
        .map((item) => item.getAttribute('data-notification-item'))
    )
    const lastHeader = [...this.containerTarget.querySelectorAll('[data-date-header]')].pop()
    let lastHeaderDate = lastHeader?.getAttribute('data-date-header') || null
    let waitingHeader = null
    let found = 0
    let appended = 0

    Array.from(newContainer.children).forEach((child) => {
      if (child.matches('[data-date-header]')) {
        waitingHeader = child.getAttribute('data-date-header') === lastHeaderDate ? null : child
        return
      }

      const isItem = child.matches('[data-notification-item]')
      if (isItem) {
        found += 1
        const id = child.getAttribute('data-notification-item')
        if (shown.has(id)) return
        shown.add(id)
      }

      if (waitingHeader) {
        this.containerTarget.appendChild(waitingHeader.cloneNode(true))
        lastHeaderDate = waitingHeader.getAttribute('data-date-header')
        waitingHeader = null
      }
      this.containerTarget.appendChild(child.cloneNode(true))
      if (isItem) appended += 1
    })

    return { found, appended }
  }

  showLoadingIndicator() {
    if (this.hasLoadingIndicatorTarget) {
      this.loadingIndicatorTarget.classList.remove('hidden')
    }
    
    if (this.hasEndMessageTarget) {
      this.endMessageTarget.classList.add('hidden')
    }
  }
  
  updateIndicators() {
    if (this.hasLoadingIndicatorTarget) {
      this.loadingIndicatorTarget.classList.add('hidden')
    }
    
    if (this.hasEndMessageTarget) {
      if (!this.hasMoreValue) {
        this.endMessageTarget.classList.remove('hidden')
      } else {
        this.endMessageTarget.classList.add('hidden')
      }
    }
  }
  
  // Called when filters change to reset pagination
  reset() {
    this.pageValue = 1
    this.hasMoreValue = true
    this.loadingValue = false
    
    // Clear container except for initial load
    const items = this.containerTarget.querySelectorAll('[data-notification-item]')
    items.forEach((item, index) => {
      if (index >= 20) { // Keep first page of items
        item.remove()
      }
    })
    
    this.updateIndicators()
  }
}