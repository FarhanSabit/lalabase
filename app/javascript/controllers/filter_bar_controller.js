// The filter bar rebuilt along the Belegungstabelle (doc/filterleiste_s1_s4_plan.md).
import { Controller } from "@hotwired/stimulus"
import { buildFilterUrl, appendConditionParams, BUILTIN_VIEW_PARAM } from 'filter_bar/url_builder'
import { readLaneParams, laneParamNames } from 'lane/params'
import { buildCategoryListHtml, buildValueMenuHtml } from 'filter_bar/menu_renderer'
import { buildChipHtml, labelFor, PILL_OPEN } from 'filter_bar/chip_renderer'
import { buildSaveRowHtml, buildNamingRowHtml } from 'filter_bar/save_row'
import { targetForTypes, typeWidened } from 'filter_bar/save_target'
import { changeSentence, countSentence, filterSignTitle } from 'filter_bar/change_sentence'
import { stashUndo, takeUndo } from 'filter_bar/undo_handoff'
import { effectiveConditions, orderedCategories, isDirty, conditionCount, describeChange, applyEdit } from 'filter_bar/change_set'
import { getOptionsMap, getCSRFToken } from 'filter_bar/utils'

// How long a flash stands (ms). The templates in the component carry their
// own hide_delay for a plain render; the controller sets the value on the
// clone, so these three numbers are the ones that count here.
const FLASH_DELAY = 2500
const ERROR_FLASH_DELAY = 4000
// A flash that carries a way back stands longer: one reads, then decides (F25).
const UNDO_FLASH_DELAY = 7000
// A floating layer (F29) hangs LAYER_GAP_PX under its anchor and keeps
// LAYER_INSET_PX from the bar's edges; a layer still hidden reads as 0 wide,
// then LAYER_FALLBACK_WIDTH_PX stands in for the clamp.
const LAYER_GAP_PX = 4
const LAYER_INSET_PX = 8
const LAYER_FALLBACK_WIDTH_PX = 250
// The keys that walk a layer with role="menu" (the category list, the search
// depth), as the role promises assistive tech.
const MENU_KEYS = ['ArrowDown', 'ArrowUp', 'Home', 'End']

// Unified Filter Bar Controller
//
// Row 1: the saved views as tabs (server-rendered links), the menu of the
//        active view behind its chevron (S5), [+ Filter] and the search
// Row 2: one pill per condition, hidden when there is none
//        + the proposal row (F31) while something outside proposes a condition
// Row 3: the save row (F23) while the state differs from the view
//
// The address is the one source of truth. The controller derives its state
// from it on connect and writes every change back:
//   _saved     the active view as stored (dissolver output), never mutated;
//              a folder (smartFolderId) or a built-in type view (viewKey, S7)
//   adHoc      activeFilters/activeOperators, the reader's edits (URL: filter[], filter_op[])
//   _dropped   saved categories the reader emptied (URL: filter_drop[])
//   effective  what the pills show (lib/filter_bar/change_set.js)
//
// HTML generation is delegated to ES modules in lib/filter_bar/.

export default class extends Controller {
  static targets = [
    "tabStrip", "tab", "unsavedDot",
    "viewMenu", "viewMenuButton", "viewMenuChevron", "viewMenuList", "renameForm", "renameInput", "renameError",
    "chipRow", "chipZone", "proposalRow", "saveRow", "flashTemplate", "errorFlashTemplate",
    "search", "searchInput",
    "searchDepthButton", "searchDepthMenu",
    "filterButton", "filterMenu", "categoryList", "valueMenu",
    "sentenceRow", "sentenceFrame", "editWord",
    "overflowButton", "overflowMenu", "overflowChevron",
    "operatorDropdownContainer", "operatorDropdown"
  ]

  static values = {
    url: String,
    frame: String,
    categories: Array,
    activeFilters: Object,
    activeOperators: Object,
    dropped: Array,
    labels: Object,
    operatorLabels: Object,
    saveUrl: String,
    projectId: String,
    saveLabels: Object,
    searchMode: String,
    smartFolderId: String,
    viewKey: String,
    typeTargets: Object,
    smartFolders: Array,
    dissolver: Object,
    valueLabels: Object,
    returnKeys: Array
  }

  // === Lifecycle ===

  // The state lives from initialize() on, not from connect(): Stimulus fires
  // the initial activeFiltersValueChanged() BEFORE connect(), and that
  // callback already renders the pills from this state.
  initialize() {
    this.isFilterMenuOpen = false
    this.currentCategory = null
    this._chipEditMode = false
    this.searchTimeout = null
    this._saveState = null

    const dissolver = this.dissolverValue || {}
    this._saved = {
      filters: dissolver.filters || {},
      operators: dissolver.operators || {},
      dissolvable: dissolver.dissolvable === true
    }
    this._complexRules = dissolver.complex_rules || []
    this._dropped = [...(this.droppedValue || [])]
  }

  connect() {
    this._boundCloseMenus = this.closeOnOutside.bind(this)
    this._boundEscape = this.closeOnEscape.bind(this)
    // Reading is the resting state (20a): the sentence stands, the pills wait.
    this._editing = false
    // What the list found under the current conditions (20a, § 8). Read before
    // the first render, or the draft row is built without it and nothing
    // reloads the frame on a page that was simply opened.
    this._hits = this._readHits()

    this.renderCategoryList()
    this.renderChips()
    this.scrollActiveTabIntoView()
    this._showPendingUndo()

    if (this.hasSearchInputTarget) {
      this._boundDblclick = () => this.searchInputTarget.select()
      this.searchInputTarget.addEventListener('dblclick', this._boundDblclick)
    }

    this._boundModalSubmitEnd = this.handleModalSubmitEnd.bind(this)
    document.addEventListener('turbo:submit-end', this._boundModalSubmitEnd)

    // Afterwards it comes from the reloaded frame, never from a question of
    // its own: the list counted its rows for the pager anyway, and a second
    // count query per tick is the one running cost this proposal would have had.
    this._boundFrameLoad = this.onListFrameLoad.bind(this)
    document.addEventListener('turbo:frame-load', this._boundFrameLoad)
  }

  onListFrameLoad(event) {
    const id = event.target?.id
    if (id === `${this.frameValue}_sentence`) { this._restoreSentenceFocus(); return }
    if (id !== this.frameValue) return

    this._hits = this._readHits()
    this.renderChips()
  }

  _restoreSentenceFocus() {
    const category = this._refocusCategory
    this._refocusCategory = null
    if (!category || !this.hasSentenceRowTarget) return

    this.sentenceRowTarget
      .querySelector(`[data-fb-prose] button[data-category="${CSS.escape(category)}"]`)
      ?.focus()
  }

  // What the list found, for the draft row (20a, § 8). It stood in the editing
  // row for one evening as well and came out again (user, 08.09.2026): the
  // number belongs where a change is decided, not beside every keystroke.
  _readHits() {
    const found = document.querySelector(`#${CSS.escape(this.frameValue)} [data-fb-hits-total]`)
    return found?.dataset.fbHitsTotal || null
  }

  disconnect() {
    document.removeEventListener('click', this._boundCloseMenus)
    document.removeEventListener('keydown', this._boundEscape)
    document.removeEventListener('turbo:submit-end', this._boundModalSubmitEnd)
    document.removeEventListener('turbo:frame-load', this._boundFrameLoad)
    if (this.hasSearchInputTarget && this._boundDblclick) {
      this.searchInputTarget.removeEventListener('dblclick', this._boundDblclick)
    }
    if (this.searchTimeout) clearTimeout(this.searchTimeout)
  }

  activeFiltersValueChanged() {
    this.renderChips()
  }

  // === State ===

  get _adHoc() {
    return { filters: this.activeFiltersValue || {}, operators: this.activeOperatorsValue || {} }
  }

  get _effective() {
    return effectiveConditions({ saved: this._saved, adHoc: this._adHoc, dropped: this._dropped })
  }

  // A saved view is active: a folder, or a built-in type view (S7). Both hand
  // the bar their conditions as the saved set.
  get _hasSavedView() {
    return !!this.smartFolderIdValue || !!this.viewKeyValue
  }

  get _dirty() {
    return this._hasSavedView && isDirty(this._saved, this._effective)
  }

  // A saved condition can be edited in the bar only when the whole view
  // dissolves into conditions (D4): saving on a view with complex rules would
  // drop those rules. The reader's own additions are always editable.
  _categoryEditable(category) {
    if (!this._hasSavedView) return true
    if (this._saved.dissolvable) return true
    return !Object.prototype.hasOwnProperty.call(this._saved.filters, category)
  }

  // The reader changes one category. The edit goes into the ad-hoc set and
  // the address; the pills re-render from the effective set. A category the
  // bar shows read-only (D4) takes no edit, whichever menu it came through.
  // keepLayer: the edit was made INSIDE an open layer. A layer does not close
  // because something was done in it (F29), so the list is rebuilt and the
  // layer finds its anchor again instead of going away.
  _applyEdit(category, values, operator, { keepLayer = false } = {}) {
    if (!this._categoryEditable(category)) return
    const next = applyEdit({ saved: this._saved, adHoc: this._adHoc, dropped: this._dropped }, category, values, operator)
    this._dropped = next.dropped
    this._saveState = null
    this.activeOperatorsValue = next.adHoc.operators
    this.activeFiltersValue = next.adHoc.filters
    this.navigateWithFilters({ keepLayer })
  }

  // === View tabs (F10) ===

  // A tab is a link to the view's address (the base list, or the list with
  // smart_folder_id). JavaScript only adds the search the reader typed, so it
  // survives the switch the way it did with the pills. A click with a modifier
  // key (new tab, new window) is left to the browser, as on any link.
  selectView(event) {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0) return
    event.preventDefault()
    event.stopPropagation()

    const url = new URL(event.currentTarget.href, window.location.origin)
    this._preserveSearchParams(url)
    // Not blocked: the switch happens, and what was built here is thrown
    // away. The address holds all of it, so the next page can offer the way back.
    if (this._dirty) this._stashUndo(this._label('change_discarded'))
    else if (!this._hasSavedView && conditionCount(this._effective) > 0) this._stashUndo(this._label('conditions_reset'))
    window.Turbo.visit(url.toString())
  }

  // The strip scrolls instead of folding views into a menu. Only the strip is
  // moved, never the page: scrollIntoView would also scroll vertically, which
  // fights Turbo's scroll restoration.
  scrollActiveTabIntoView() {
    if (!this.hasTabStripTarget) return
    const active = this.tabTargets.find(tab => tab.getAttribute('aria-selected') === 'true')
    if (!active) return

    const strip = this.tabStripTarget
    const left = active.offsetLeft - strip.offsetLeft
    const right = left + active.offsetWidth
    if (left < strip.scrollLeft || right > strip.scrollLeft + strip.clientWidth) {
      strip.scrollLeft = Math.max(0, left - 16)
    }
  }

  // "Zurücksetzen" on the base view: the unfiltered list, search kept. No
  // confirmation (F21): a condition is two clicks away, and the flash on the
  // next page carries the way back.
  resetConditions(event) {
    event.preventDefault()
    event.stopPropagation()
    this._stashUndo(this._label('conditions_reset'))
    window.Turbo.visit(this._viewUrl(null).toString())
  }

  // === The menu of the active view (S5) ===

  // Everything one can do with the view on screen sits behind the chevron of
  // the active tab. The layer is server-rendered; the controller only opens
  // it, positions it against the root (the strip clips its overflow) and
  // runs rename and delete.
  toggleViewMenu(event) {
    event.preventDefault()
    event.stopPropagation()
    if (!this.hasViewMenuTarget) return

    const wasOpen = !this.viewMenuTarget.classList.contains('hidden')
    this.closeAllMenus()
    if (wasOpen) return

    this.viewMenuTarget.classList.remove('hidden')
    this._positionLayerAt(this.viewMenuButtonTarget, this.viewMenuTarget)
    this._setViewMenuOpen(true)
    this._lastTrigger = this.viewMenuButtonTarget
    this._focusLayer(this.viewMenuTarget)
    this._armOutsideClose()
  }

  closeViewMenu() {
    if (!this.hasViewMenuTarget) return
    this.viewMenuTarget.classList.add('hidden')
    this._showRenameForm(false)
    this._setViewMenuOpen(false)
  }

  _setViewMenuOpen(open) {
    if (this.hasViewMenuButtonTarget) this.viewMenuButtonTarget.setAttribute('aria-expanded', String(open))
    if (this.hasViewMenuChevronTarget) this.viewMenuChevronTarget.classList.toggle('rotate-180', open)
  }

  // Rename happens in the layer: the list gives way to a field and "Sichern".
  startRename(event) {
    event.preventDefault()
    event.stopPropagation()
    if (!this.hasRenameFormTarget) return
    this._showRenameForm(true)
    this.renameInputTarget.value = this.viewMenuTarget.dataset.viewName || ''
    requestAnimationFrame(() => {
      this.renameInputTarget.focus()
      this.renameInputTarget.select()
    })
  }

  cancelRename(event) {
    if (event) { event.preventDefault(); event.stopPropagation() }
    this._showRenameForm(false)
  }

  _showRenameForm(show) {
    if (!this.hasRenameFormTarget || !this.hasViewMenuListTarget) return
    this.renameFormTarget.classList.toggle('hidden', !show)
    this.renameFormTarget.classList.toggle('flex', show)
    this.viewMenuListTarget.classList.toggle('hidden', show)
    this._showRenameError(null)
  }

  // The server's reason for a refused name stands at the field (the input's
  // aria-describedby names it); null clears it.
  _showRenameError(text) {
    if (!this.hasRenameErrorTarget) return
    this.renameErrorTarget.textContent = text || ''
    this.renameErrorTarget.classList.toggle('hidden', !text)
  }

  async submitRename(event) {
    event.preventDefault()
    event.stopPropagation()
    const url = this.viewMenuTarget.dataset.renameUrl
    const name = this.hasRenameInputTarget ? this.renameInputTarget.value.trim() : ''
    if (!url || !name || this._saving) return

    const body = new FormData()
    body.append('name', name)
    this._saving = true
    try {
      const response = await fetch(url, {
        method: 'PATCH',
        headers: { 'X-CSRF-Token': getCSRFToken(), 'Accept': 'application/json' },
        body
      })
      const answer = await this._jsonAnswer(response)
      if (answer && answer.success === true) {
        this._applyRename(answer.name || name)
        this.closeAllMenus()
        this._flash(this._label('renamed'))
      } else {
        // A refused name (422) says why: the reason stands at the field and
        // the form stays open. Anything else (a denial's redirect, no JSON)
        // is the generic flash.
        const reason = answer && answer.error ? answer.error : null
        this._showRenameError(reason)
        this._flash(reason || this._label('rename_failed'), { type: 'error', delay: ERROR_FLASH_DELAY })
      }
    } catch (_e) {
      this._flash(this._label('rename_failed'), { type: 'error', delay: ERROR_FLASH_DELAY })
    } finally {
      this._saving = false
    }
  }

  // The tab, the layer and the folder list say the new name at once; the
  // address does not change, the view is the same one.
  _applyRename(name) {
    this.viewMenuTarget.dataset.viewName = name
    const label = this.element.querySelector('a[role="tab"][aria-selected="true"] [data-view-name]')
    if (label) label.textContent = name
    this.smartFoldersValue = (this.smartFoldersValue || []).map(sf => (sf.id === this.smartFolderIdValue ? { ...sf, name } : sf))
  }

  // Deleting a view is not restorable, so this is the one action of the bar
  // that asks (F21's rule). Then the base view, with a plain flash: there is
  // no way back to offer.
  async deleteView(event) {
    event.preventDefault()
    event.stopPropagation()
    const url = this.viewMenuTarget.dataset.deleteUrl
    const name = this.viewMenuTarget.dataset.viewName || ''
    if (!url || this._saving) return
    if (!window.confirm(this._label('delete_confirm').replace('%{name}', name))) return

    this._saving = true
    try {
      const response = await fetch(url, {
        method: 'DELETE',
        headers: { 'X-CSRF-Token': getCSRFToken(), 'Accept': 'application/json' }
      })
      if (response.ok && !response.redirected) {
        this._stashUndo(this._label('view_deleted').replace('%{name}', name), { url: null })
        window.Turbo.visit(this._viewUrl(null).toString())
      } else {
        this._flash(this._label('delete_failed'), { type: 'error', delay: ERROR_FLASH_DELAY })
      }
    } catch (_e) {
      this._flash(this._label('delete_failed'), { type: 'error', delay: ERROR_FLASH_DELAY })
    } finally {
      this._saving = false
    }
  }

  // Duplicating is the way that does not overwrite a view somebody else uses
  // (20a, § 4). The copy belongs to the reader, and the list opens on it at
  // once: a copy you have to go and find is not an offer, it is a chore.
  async duplicateView(event) {
    event.preventDefault()
    event.stopPropagation()
    const url = event.currentTarget.dataset.url
    if (!url || this._saving) return

    this._saving = true
    try {
      const response = await fetch(url, {
        method: 'POST',
        headers: { 'X-CSRF-Token': getCSRFToken(), 'Accept': 'application/json' }
      })
      const data = response.ok ? await response.json() : null
      if (data?.success) {
        this.closeAllMenus()
        window.Turbo.visit(this._viewUrl(data.id).toString())
      } else {
        this._flash(this._label('duplicate_failed'), { type: 'error', delay: ERROR_FLASH_DELAY })
      }
    } catch (_e) {
      this._flash(this._label('duplicate_failed'), { type: 'error', delay: ERROR_FLASH_DELAY })
    } finally {
      this._saving = false
    }
  }

  // === The proposal row (F31, S6) ===

  // A proposal accepted becomes a normal condition through the same edit as
  // any other: the view differs, the save row appears. The row goes; nothing
  // is persisted here.
  acceptProposal(event) {
    event.preventDefault()
    event.stopPropagation()
    const row = event.currentTarget.closest('[data-proposal]')
    if (!row) return
    const { category, value } = row.dataset
    if (!category || !value) return
    // A category the bar shows read-only (D4) takes no edit; the row stays,
    // so a question is never answered by nobody.
    if (!this._categoryEditable(category)) return

    const effective = this._effective
    const current = effective.filters[category] || []
    if (!current.includes(value)) this._applyEdit(category, [...current, value], effective.operators[category])
    this._removeProposal(row)
  }

  declineProposal(event) {
    event.preventDefault()
    event.stopPropagation()
    const row = event.currentTarget.closest('[data-proposal]')
    if (row) this._removeProposal(row)
  }

  _removeProposal(row) {
    row.remove()
    if (this.hasProposalRowTarget && this.proposalRowTarget.querySelector('[data-proposal]') === null) {
      this.proposalRowTarget.classList.add('hidden')
    }
  }

  // === The views that did not fit (20a, D1) ===

  // Its own layer, and a small one: the trigger already says what is in it
  // ("2 weitere"), so it carries no head.
  toggleOverflowMenu(event) {
    event.preventDefault()
    event.stopPropagation()
    if (!this.hasOverflowMenuTarget) return

    const wasOpen = !this.overflowMenuTarget.classList.contains('hidden')
    this.closeAllMenus()
    if (wasOpen) return

    this.overflowMenuTarget.classList.remove('hidden')
    this.overflowButtonTarget.setAttribute('aria-expanded', 'true')
    // No chevron on "n weitere" any more (designer, 09.09.2026); the target is kept optional.
    if (this.hasOverflowChevronTarget) this.overflowChevronTarget.classList.add('rotate-180')
    this._lastTrigger = this.overflowButtonTarget
    this._focusLayer(this.overflowMenuTarget)
    this._armOutsideClose()
  }

  closeOverflowMenu() {
    if (!this.hasOverflowMenuTarget) return

    this.overflowMenuTarget.classList.add('hidden')
    this.overflowButtonTarget.setAttribute('aria-expanded', 'false')
    if (this.hasOverflowChevronTarget) this.overflowChevronTarget.classList.remove('rotate-180')
  }

  // === Filter Menu (+ Filter button) ===

  // Two triggers open this one layer: "+ Filter" in the tab row and
  // "+ Bedingung" among the pills. It opens where the trigger stands.
  toggleFilterMenu(event) {
    event.preventDefault()
    event.stopPropagation()
    this.isFilterMenuOpen ? this.closeFilterMenu() : this.openFilterMenu(event.currentTarget)
  }

  openFilterMenu(anchor = null) {
    this.closeAllMenus() // one layer at a time: the view menu goes too
    this.isFilterMenuOpen = true
    this.currentCategory = null
    // Re-read: a condition may have come or gone since the last opening, and
    // "in Gebrauch" is a statement about now.
    this.renderCategoryList()
    this.filterMenuTarget.classList.remove('hidden')
    this._filterMenuAnchor = anchor || (this.hasFilterButtonTarget ? this.filterButtonTarget : null)
    if (this._filterMenuAnchor) {
      this._positionLayerAt(this._filterMenuAnchor, this.filterMenuTarget)
      this._filterMenuAnchor.setAttribute('aria-expanded', 'true')
      this._lastTrigger = this._filterMenuAnchor
    }
    if (this.hasValueMenuTarget) this.valueMenuTarget.classList.add('hidden')
    this._focusLayer(this.filterMenuTarget)
    this._armOutsideClose()
  }

  closeFilterMenu() {
    const closingCategory = this.currentCategory
    const fromSentence = this._sentenceCategory
    this._sentenceCategory = null
    this.isFilterMenuOpen = false
    this.currentCategory = null
    this._chipEditMode = false
    this.filterMenuTarget.classList.add('hidden')
    this.filterMenuTarget.style.left = ''
    this.filterMenuTarget.style.top = ''
    this._filterMenuAnchor?.setAttribute('aria-expanded', 'false')
    this._filterMenuAnchor = null
    if (this.hasFilterButtonTarget) this.filterButtonTarget.setAttribute('aria-expanded', 'false')
    if (this.hasValueMenuTarget) {
      this.valueMenuTarget.classList.add('hidden')
      this.valueMenuTarget.style.left = ''
      this.valueMenuTarget.style.top = ''
      this.valueMenuTarget.style.position = ''
      this.valueMenuTarget.style.zIndex = ''
    }
    this._markPillOpen(null)
    // A condition without a value is not a condition. It stood only as long as
    // its layer was open, and is tidied away silently now (F29).
    if (closingCategory && (this._effective.filters[closingCategory] || []).length === 0) this.renderChips()
    // The layer hung on a word of the sentence, and that word may have changed.
    if (fromSentence) this.refreshSentence(fromSentence)
  }

  // "+ Filter" offers only what the bar may edit: on a view with rules it
  // cannot dissolve (D4) the saved categories stay out of the list, or the
  // menu would show their values as changeable while the server keeps the
  // folder's rule.
  renderCategoryList() {
    if (!this.hasCategoryListTarget) return
    this.categoryListTarget.innerHTML = buildCategoryListHtml({
      categories: (this.categoriesValue || []).filter(category => this._categoryEditable(category.key)),
      activeFilters: this._effective.filters,
      labels: this.labelsValue || {}
    })
  }

  openValueMenu(event) {
    event.preventDefault()
    event.stopPropagation()

    const category = event.currentTarget.dataset.category
    this.currentCategory = category

    // Who builds a condition wants to see it: picking a category from
    // "+ Filter" opens the editing state, and the pill appears there at once,
    // empty and quiet. Without it the reader picks a category and nothing
    // happens on the surface.
    this._editing = true
    this.renderChips()
    this.filterMenuTarget.classList.add('hidden')
    this.renderValueMenu(category)
    this.valueMenuTarget.classList.remove('hidden')
    this._positionMenuAtButton()
    this._focusLayer(this.valueMenuTarget)
  }

  // The boxes show the effective values of the category: what the pill shows.
  // The layer is a dialog named after the category.
  renderValueMenu(category, { chipEdit = false } = {}) {
    const effective = this._effective
    const cat = (this.categoriesValue || []).find(c => c.key === category)
    this.valueMenuTarget.setAttribute('aria-label', cat ? cat.label : category)
    this.valueMenuTarget.innerHTML = buildValueMenuHtml({
      category,
      categories: this.categoriesValue,
      activeFilters: effective.filters,
      activeOperators: effective.operators,
      labels: this.labelsValue,
      operatorLabels: this.operatorLabelsValue,
      chipEdit
    })
  }

  // One level back (F36): the layer stays open, the list is back. Called from
  // the arrow in the head and from Escape, which has no event to swallow.
  backToFilterMenu(event) {
    if (event) { event.preventDefault(); event.stopPropagation() }
    const leaving = this.currentCategory
    this.currentCategory = null
    this.valueMenuTarget.classList.add('hidden')
    this.renderCategoryList()
    this.filterMenuTarget.classList.remove('hidden')
    if (this._filterMenuAnchor) this._positionLayerAt(this._filterMenuAnchor, this.filterMenuTarget)
    this._focusLayer(this.filterMenuTarget)
    if (leaving && (this._effective.filters[leaving] || []).length === 0) this.renderChips()
  }

  // === A pill opens its values (F13 + F22 + F29) ===

  // The chevron button opens the layer; a click on the pill's body reaches
  // here too (pointer convenience). Both arrive with the pill as the nearest
  // [data-condition]. A value is not removed here any more (F19 left the
  // condition row): the layer this opens is the only place for it.
  openCondition(event) {
    event.preventDefault()
    event.stopPropagation()

    const pill = event.currentTarget.closest('[data-condition]')
    const category = pill && pill.dataset.condition
    if (!category) return

    const wasOpen = this.currentCategory === category && this._chipEditMode
    this.closeAllMenus()
    if (wasOpen) return

    this.currentCategory = category
    this._lastTrigger = pill.querySelector('[data-fb-open]') || pill
    this.renderValueMenu(category, { chipEdit: true })
    this._positionMenuAtChip(pill)
    this._markPillOpen(pill)
    this._focusLayer(this.valueMenuTarget)
  }

  _markPillOpen(pill) {
    if (!this.hasChipZoneTarget) return
    this.chipZoneTarget.querySelectorAll('[data-condition][data-open]').forEach(open => {
      delete open.dataset.open
      open.classList.remove(...PILL_OPEN)
      open.querySelector('[data-fb-open]')?.setAttribute('aria-expanded', 'false')
      open.querySelector('[data-chevron]')?.classList.remove('rotate-180')
    })
    if (!pill) return
    pill.dataset.open = 'true'
    pill.classList.add(...PILL_OPEN)
    pill.querySelector('[data-fb-open]')?.setAttribute('aria-expanded', 'true')
    pill.querySelector('[data-chevron]')?.classList.add('rotate-180')
  }

  // === Save / discard the edited view (the save row, F23) ===

  // "Verwerfen": back to the view as saved, no confirmation (F21). The flash
  // on the next page carries the way back.
  discardChanges(event) {
    event.preventDefault()
    event.stopPropagation()
    this._stashUndo(this._label('change_discarded'))
    window.Turbo.visit(this._viewUrl(this.smartFolderIdValue, this.viewKeyValue).toString())
  }

  // PATCH the effective set into the active folder. On success the effective
  // set becomes the saved one and the address loses its edits. One save at a
  // time: a second click while the first is in flight would answer out of
  // order and could overwrite newer edits with an older result. The
  // project_id names the list the bar sits on; an org-wide view has no
  // project of its own and the endpoint needs one for the attribute names.
  async saveChanges(event) {
    event.preventDefault()
    event.stopPropagation()
    if (this._saving) return

    const activeFolder = this._activeFolder()
    if (!activeFolder || !activeFolder.update_from_filters_url) return

    const effective = this._effective
    const formData = appendConditionParams(new FormData(), effective.filters, effective.operators)
    if (activeFolder.allow_empty_filters && this._ruleCount(effective) === 0) formData.append('clear_filters', '1')
    if (this.hasProjectIdValue && this.projectIdValue) formData.append('project_id', this.projectIdValue)

    this._saving = true
    try {
      const response = await fetch(activeFolder.update_from_filters_url, {
        method: 'PATCH',
        headers: { 'X-CSRF-Token': getCSRFToken(), 'Accept': 'application/json' },
        body: formData
      })
      if (await this._savedOk(response)) {
        this._onSaveSuccess(effective)
      } else {
        this._setSaveState('error')
      }
    } catch (e) {
      this._setSaveState('error')
    } finally {
      this._saving = false
    }
  }

  // Only the endpoint's own answer counts. A denial or a missing folder comes
  // back as a redirect to a list page, which fetch follows to a 200 of HTML:
  // "ok", but nothing was saved.
  async _savedOk(response) {
    const answer = await this._jsonAnswer(response)
    return !!(answer && answer.success === true)
  }

  // The body of the endpoint's own answer: a 2xx, or the 422 that says why a
  // name or a set was refused. A redirect or HTML is nobody's answer: null.
  async _jsonAnswer(response) {
    if (response.redirected) return null
    if (!response.ok && response.status !== 422) return null
    if (!(response.headers.get('content-type') || '').includes('application/json')) return null
    try {
      return await response.json()
    } catch (_e) {
      return null
    }
  }

  // The effective set is the saved one now: dot and row go together (F23),
  // the address loses its edits, the flash says it (F25).
  _onSaveSuccess(effective) {
    this._saved = { filters: { ...effective.filters }, operators: { ...effective.operators }, dissolvable: true }
    this._dropped = []
    this._saveState = null
    this.activeFiltersValue = {}
    this.activeOperatorsValue = {}
    window.history.replaceState({}, '', this._viewUrl(this.smartFolderIdValue).toString())
    this.renderChips()
    this._flash(this._label('view_saved'))
  }

  _setSaveState(state) {
    this._saveState = state
    this.renderChips()
    if (state === 'error') this._flash(this._label('save_failed'), { type: 'error', delay: ERROR_FLASH_DELAY })
  }

  // === Operator Toggle ===

  toggleOperatorDropdown(event) {
    event.preventDefault()
    event.stopPropagation()

    const container = event.currentTarget.closest('[data-filter-bar-target="operatorDropdownContainer"]')
    if (!container) return

    const dropdown = container.querySelector('[data-filter-bar-target="operatorDropdown"]')
    if (!dropdown) return

    dropdown.classList.toggle('hidden')
  }

  setOperator(event) {
    event.preventDefault()
    event.stopPropagation()

    const op = event.currentTarget.dataset.operator
    const category = event.currentTarget.dataset.category
    const values = this._effective.filters[category] || []

    if (values.length > 0) this._applyEdit(category, values, op, { keepLayer: true })
    this.renderValueMenu(category, { chipEdit: this._chipEditMode })
  }

  // === Filter Value Toggle ===

  toggleFilterValue(event) {
    event.stopPropagation()

    const category = event.currentTarget.dataset.category
    const value = event.currentTarget.dataset.filterValue
    const effective = this._effective
    const current = effective.filters[category] || []
    const values = event.currentTarget.checked
      ? [...current, value]
      : current.filter(v => v !== value)

    // The box the reader just clicked already shows the new state, so the
    // layer is not re-rendered: that would move the focus away mid-selection.
    this._applyEdit(category, values, effective.operators[category], { keepLayer: true })
  }

  // === Taking a condition away (designer, 07.09.2026) ===
  //
  // The chip's right zone. stopPropagation because the pill's left zone opens
  // the layer on click: without it, deleting a condition would open the layer
  // of the condition that was just deleted.
  removeCondition(event) {
    event.preventDefault()
    event.stopPropagation()

    const category = event.currentTarget.dataset.category
    if (!category) return

    this._applyEdit(category, [], this._effective.operators[category])
  }

  // One value out of several. A condition with one value left keeps no crosses
  // on its tiles (the pill's own cross takes the whole thing), so the renderer
  // decides that again on the next pass.
  removeValue(event) {
    event.preventDefault()
    event.stopPropagation()

    const { category, value } = event.currentTarget.dataset
    if (!category) return

    const effective = this._effective
    const values = (effective.filters[category] || []).filter(v => v !== value)
    this._applyEdit(category, values, effective.operators[category])
  }

  // === Search ===

  // Tight (rule 7, components/filter_bar.css) only the magnifier stands; the
  // field opens INTO the right end of the same row - the free stretch and the
  // column tool make way for it - and folds back when it is left empty. The
  // attribute has no effect at full width.
  // DELIBERATE DUPLICATION: search_disclosure_controller repeats openSearch,
  // closeSearch and searchBlur for the lists that have this search without
  // the rest of the bar (NeoListSearchComponent: the inbox, Personen). Change
  // one, check the other.
  openSearch(event) {
    if (event) { event.preventDefault(); event.stopPropagation() }
    if (!this.hasSearchTarget) return
    this.searchTarget.setAttribute('data-fb-search-open', '')
    if (this.hasSearchInputTarget) {
      // The field was display:none a moment ago; a forced layout applies the
      // new style, or focus() would find it still hidden and do nothing.
      void this.searchInputTarget.offsetWidth
      this.searchInputTarget.focus()
    }
  }

  closeSearch(event) {
    if (!this.hasSearchTarget) return
    if (this.hasSearchInputTarget && this.searchInputTarget.value) return
    this.searchTarget.removeAttribute('data-fb-search-open')
    if (!(event && event.type === 'keydown') || !this.hasSearchInputTarget) return
    // Escape folded the field: the focus goes to the magnifier that stands in
    // its place, not to nowhere. At full width there is no magnifier and the
    // field stays; so does the focus.
    const magnifier = this.searchTarget.querySelector('[data-fb-search-open-button]')
    if (magnifier && magnifier.offsetParent !== null) magnifier.focus()
  }

  searchBlur() {
    if (this.hasSearchInputTarget && this.searchInputTarget.value) return
    // The depth trigger inside the wrapper may be what took the focus
    requestAnimationFrame(() => {
      if (this.hasSearchTarget && !this.searchTarget.contains(document.activeElement)) this.closeSearch()
    })
  }

  onSearchInput() {
    if (this.searchTimeout) clearTimeout(this.searchTimeout)

    // Every debounced change navigates - no minimum length. The old > 3
    // threshold left a 1-3 character search visible in the input and the
    // chips while URL and list still carried the previous state, and a
    // reload then "lost the context" by faithfully replaying the URL
    // (user report 03.09., the stranded "ggg" search).
    this.searchTimeout = setTimeout(() => {
      this.navigateWithFilters()
    }, 300)
  }

  onSearchClear() {
    if (this.searchInputTarget.value === '') {
      if (this.searchTimeout) clearTimeout(this.searchTimeout)
      this.navigateWithFilters()
    }
  }

  // === Search Depth ===

  toggleSearchDepthMenu(event) {
    event.preventDefault()
    event.stopPropagation()

    if (this.hasSearchDepthMenuTarget) {
      const isOpen = !this.searchDepthMenuTarget.classList.contains('hidden')
      this.closeAllMenus()
      if (!isOpen) {
        this.searchDepthMenuTarget.classList.remove('hidden')
        if (this.hasSearchDepthButtonTarget) {
          this.searchDepthButtonTarget.setAttribute('aria-expanded', 'true')
          this._lastTrigger = this.searchDepthButtonTarget
        }
        this._focusLayer(this.searchDepthMenuTarget)
        this._armOutsideClose()
      }
    }
  }

  closeSearchDepthMenu() {
    if (this.hasSearchDepthMenuTarget) {
      this.searchDepthMenuTarget.classList.add('hidden')
    }
    if (this.hasSearchDepthButtonTarget) this.searchDepthButtonTarget.setAttribute('aria-expanded', 'false')
  }

  setSearchMode(event) {
    event.preventDefault()
    event.stopPropagation()

    const mode = event.currentTarget.dataset.mode
    this.searchModeValue = mode
    this.updateSearchDepthIcon(mode)
    this.closeAllMenus()
    this.navigateWithFilters()
  }

  updateSearchDepthIcon(mode) {
    if (!this.hasSearchDepthButtonTarget) return
    const icon = this.searchDepthButtonTarget.querySelector('i:first-child')
    if (!icon) return
    icon.className = mode === 'full' ? 'bi bi-binoculars text-xs' : 'bi bi-search text-xs'
  }

  // === Navigation ===

  // The address of a view: the base list, or the list with smart_folder_id,
  // plus the typed search. No edits. Built by the same builder as every other
  // address of the bar, so sort, page size and the open detail travel along
  // and the page still matches its address after a discard or a save.
  _viewUrl(smartFolderId, viewKey = null) {
    return buildFilterUrl({
      baseUrl: this.urlValue,
      filters: {},
      operators: {},
      dropped: [],
      smartFolderId,
      viewKey,
      searchValue: this.hasSearchInputTarget ? this.searchInputTarget.value : '',
      searchMode: this.searchModeValue,
      carry: this._carriedParams()
    })
  }

  navigateWithFilters({ keepLayer = false } = {}) {
    this.navigateToUrl(this._filterUrl(), { keepLayer })
  }

  // The address of the current state. The list, the sentence and the tabs all
  // read the same one.
  _filterUrl() {
    const adHoc = this._adHoc
    return buildFilterUrl({
      baseUrl: this.urlValue,
      filters: adHoc.filters,
      operators: adHoc.operators,
      dropped: this._dropped,
      smartFolderId: this.smartFolderIdValue,
      viewKey: this.viewKeyValue,
      searchValue: this.hasSearchInputTarget ? this.searchInputTarget.value : '',
      searchMode: this.searchModeValue,
      carry: this._carriedParams()
    })
  }

  // What a list reload carries from the address: the open object and its
  // preview, the page's lane names (D9 of doc/dateivorschau_plan.md), read
  // from the wrapper's groups; the old three names where a page has none.
  _carriedParams() {
    const groups = readLaneParams(this.element, null)
    return groups ? [...laneParamNames(groups), ...groups.form] : ['ticket_id', 'note_id', 'document_id']
  }

  _returnContextFields() {
    const fields = {}
    const allowed = this.returnKeysValue || []
    for (const [name, value] of new URLSearchParams(window.location.search)) {
      const key = name.split('[')[0]
      if (!allowed.includes(key)) continue
      // Nested list state travels through the editor without colliding with its own fields.
      const contextName = `list_context[${key}]${name.slice(key.length)}`
      if (name.endsWith('[]')) (fields[contextName] ||= []).push(value)
      else fields[contextName] = value
    }
    return fields
  }

  carryReturnContext(event) {
    if (!(this.returnKeysValue || []).length) return
    const link = event.currentTarget
    const url = new URL(link.href, window.location.origin)
    for (const name of [...url.searchParams.keys()]) {
      if (name.startsWith('list_context[')) url.searchParams.delete(name)
    }
    for (const [name, values] of Object.entries(this._returnContextFields())) {
      for (const value of [].concat(values)) url.searchParams.append(name, value)
    }
    link.href = url.toString()
  }

  navigateToUrl(url, { keepLayer = false } = {}) {
    // The page's own entry (lane: true, lib/lane/history); the wrapper learns
    // the list part it now shows, so Back to the old filter restores the page.
    window.history.pushState({ lane: true }, '', url.toString())
    this.element.dispatchEvent(new CustomEvent('lane:list-changed', { bubbles: true }))

    const frame = document.getElementById(this.frameValue)
    if (frame) frame.src = url.toString()

    this.renderChips()
    if (keepLayer) this._reanchorOpenLayer()
    else this.closeAllMenus()
  }

  // The condition row was rebuilt under the open layer, so a layer that hangs
  // on a pill lost the element it hangs on. It gets it back; the category list
  // re-reads which categories are in use. Only if the pill is really gone does
  // the layer go with it.
  _reanchorOpenLayer() {
    if (this.isFilterMenuOpen && !this.filterMenuTarget.classList.contains('hidden')) this.renderCategoryList()
    if (!this._chipEditMode || !this.currentCategory || !this.hasChipZoneTarget) return

    const pill = this.chipZoneTarget.querySelector(`[data-condition="${CSS.escape(this.currentCategory)}"]`)
    if (!pill) { this.closeAllMenus(); return }

    this._lastTrigger = pill.querySelector('[data-fb-open]') || pill
    this._markPillOpen(pill)
    this._positionLayerAt(pill, this.valueMenuTarget)
  }

  // === Chip Rendering ===

  renderChips() {
    if (!this.hasChipZoneTarget || !this._saved) return

    const effective = this._effective
    const dirty = this._dirty

    this.chipZoneTarget.innerHTML = buildChipHtml({
      effective,
      order: orderedCategories({ saved: this._saved, adHoc: this._adHoc }),
      categories: this.categoriesValue,
      valueLabels: this.valueLabelsValue || {},
      labels: this.labelsValue || {},
      connectors: this.operatorLabelsValue || {},
      editable: (category) => this._categoryEditable(category),
      complexRules: this._complexRules,
      openCategory: this.currentCategory
    })
    this.updateChipRowVisibility()
    this._renderSaveRow(effective, dirty)
    this._renderAddSign(effective)
    if (this.hasUnsavedDotTarget) this.unsavedDotTarget.classList.toggle('hidden', !dirty)
  }

  // The "+ Filter" trigger carries its word in the title, with the count:
  // "Filter · 2 Bedingungen". Tight (components/filter_bar.css, 760px) the
  // funnel is all that shows of it, and the title is all the word it has. Set
  // on every state render, because the bar lives outside the frame that
  // reloads: a condition added or dropped never reloads the page, and the
  // server's first paint (NeoFilterBarComponent#filter_sign_title) would
  // stand stale.
  _renderAddSign(effective) {
    if (!this.hasFilterButtonTarget) return
    const title = filterSignTitle(conditionCount(effective), this.labelsValue || {})
    if (!title) return
    this.filterButtonTarget.title = title
    this.filterButtonTarget.setAttribute('aria-label', title)
  }

  // === The save row (F23) ===

  // Two layers: on a saved view the named change with save, save-as-new and
  // discard; on the base view the count of conditions with save-as-view and
  // reset. A view with rules the bar cannot dissolve offers only discard (D4).
  _renderSaveRow(effective, dirty) {
    if (!this.hasSaveRowTarget) return

    const labels = this.labelsValue || {}
    let html = ''
    if (this._naming && (dirty || conditionCount(effective) > 0)) {
      this.saveRowTarget.innerHTML = this._namingRowHtml()
      this.saveRowTarget.classList.remove('hidden')
      return
    }
    if (this._hasSavedView) {
      if (dirty) {
        const sentence = changeSentence(describeChange(this._saved, effective), labels, (category, value) => this._valueLabel(category, value))
        const folder = this._activeFolder()
        // The folder supplies whether an empty rule set remains a valid view.
        // A built-in view has no folder, so nothing can be updated: a new view
        // or discard. A type condition (S7) is a folder's target, immutable: it
        // cannot be saved into this folder either, only into a new one, where
        // it becomes the target; and alone it makes no rule at all.
        const hasRules = this._ruleCount(effective) > 0
        html = buildSaveRowHtml({
          layer: 'saved',
          sentence,
          labels,
          canSave: !this._hasTypeCondition(effective) && this._saved.dissolvable && !!(folder && folder.update_from_filters_url) && (hasRules || folder.allow_empty_filters === true),
          canCreate: this._saved.dissolvable && hasRules && this.hasSaveUrlValue,
          saveState: this._saveState,
          hits: this._hits
        })
      }
    } else if (conditionCount(effective) > 0) {
      html = buildSaveRowHtml({
        layer: 'base',
        sentence: countSentence(conditionCount(effective), labels),
        labels,
        canCreate: this.hasSaveUrlValue && this._ruleCount(effective) > 0,
        hits: this._hits
      })
    }
    this.saveRowTarget.innerHTML = html
    this.saveRowTarget.classList.toggle('hidden', html === '')
  }

  // The conditions that become rules of a folder: all but the type condition,
  // which becomes the folder's target instead (lib/filter_bar/save_target.js).
  _ruleCount(effective) {
    return Object.entries(effective.filters)
      .filter(([category, values]) => category !== BUILTIN_VIEW_PARAM && values && values.length > 0)
      .length
  }

  _hasTypeCondition(effective) {
    return (effective.filters[BUILTIN_VIEW_PARAM] || []).length > 0
  }

  _activeFolder() {
    return (this.smartFoldersValue || []).find(sf => sf.id === this.smartFolderIdValue)
  }

  _valueLabel(category, value) {
    return labelFor(value, getOptionsMap(this.categoriesValue, category), this.valueLabelsValue || {})
  }

  _label(key) {
    return (this.labelsValue || {})[key] || key
  }

  // === The flash (F25) and the way back ===

  // The way back is stashed as a path of this app, not as a full URL: that is
  // all Turbo.visit needs, and takeUndo accepts nothing else. With url null
  // it is a message without a way back (a deleted view): the flash on the
  // next page, nothing else.
  _stashUndo(message, { url = this._currentPath() } = {}) {
    try {
      stashUndo(window.sessionStorage, { url, message })
    } catch (_e) {
      // no storage, no way back; the switch still happens
    }
  }

  _showPendingUndo() {
    let entry = null
    try {
      entry = takeUndo(window.sessionStorage, { currentUrl: this._currentPath() })
    } catch (_e) {
      return
    }
    if (!entry) return
    if (entry.url) this._flash(entry.message, { undoUrl: entry.url, delay: UNDO_FLASH_DELAY })
    else this._flash(entry.message)
  }

  _currentPath() {
    return window.location.pathname + window.location.search
  }

  // Clones the flash the component rendered into a <template>, so the look
  // lives in NeoFlashComponent and not in a second copy here.
  _flash(message, { type = 'success', undoUrl = null, delay = FLASH_DELAY } = {}) {
    const template = type === 'error'
      ? (this.hasErrorFlashTemplateTarget ? this.errorFlashTemplateTarget : null)
      : (this.hasFlashTemplateTarget ? this.flashTemplateTarget : null)
    if (!template || !template.content.firstElementChild) return

    const flash = template.content.firstElementChild.cloneNode(true)
    flash.id = `flash_filter_bar_${Date.now()}`
    flash.dataset.neoFlashHideDelayValue = String(delay)
    // Said aloud too: the flash is the only word about a rename or a delete
    flash.setAttribute('role', type === 'error' ? 'alert' : 'status')
    const text = flash.querySelector('p')
    if (text) text.textContent = message

    if (undoUrl) {
      const undo = document.createElement('button')
      undo.type = 'button'
      undo.className = 'text-sm font-medium underline underline-offset-2 text-body hover:text-heading focus:outline-none focus-visible:ring-1 focus-visible:ring-ink rounded'
      undo.textContent = this._label('undo')
      undo.setAttribute('data-filter-bar-undo', '')
      undo.addEventListener('click', () => window.Turbo.visit(undoUrl))
      if (text) text.insertAdjacentElement('afterend', undo)
    }

    ;(document.getElementById('flash') || document.body).appendChild(flash)
  }

  // The row is gone while there is nothing in it, not collapsed to zero
  // height: one row at rest, two with conditions; a proposal and the save row
  // add one each. Which of the two rows stands is the editing state: the
  // sentence is read, the pills are edited, never both at once.
  updateChipRowVisibility() {
    if (!this.hasChipRowTarget) return

    const hasChips = this.hasChipZoneTarget && this.chipZoneTarget.children.length > 0
    this.chipRowTarget.classList.toggle('hidden', !hasChips || !this._editing)
    if (this.hasSentenceRowTarget) {
      const hasSentence = this.sentenceRowTarget.querySelector('[data-fb-prose]') !== null
      this.sentenceRowTarget.classList.toggle('hidden', this._editing || !hasSentence)
    }
  }

  // === The sentence and the pills are two states of one row (20a, S1) ===

  startEditing(event) {
    if (event) { event.preventDefault(); event.stopPropagation() }
    this._editing = true
    this.renderChips()
    this.chipZoneTarget?.querySelector('[data-fb-open]')?.focus()
  }

  // "fertig" ends the editing state. It saves nothing: saving lives in the row
  // below and only where something differs from the view.
  stopEditing(event) {
    if (event) { event.preventDefault(); event.stopPropagation() }
    this._editing = false
    this.closeAllMenus()
    this.refreshSentence()
    this.updateChipRowVisibility()
    if (this.hasEditWordTarget) this.editWordTarget.focus()
  }

  // A value in the sentence opens its own layer. Changing one value is the
  // commonest move and does not deserve a change of form, so this does NOT
  // enter the editing state; the sentence is rebuilt when the layer closes.
  openConditionFromSentence(event) {
    event.preventDefault()
    event.stopPropagation()

    const anchor = event.currentTarget
    const category = anchor.dataset.category
    if (!category || !this._categoryEditable(category)) return

    this.closeAllMenus()
    this.currentCategory = category
    this._sentenceCategory = category
    this._lastTrigger = anchor
    this.renderValueMenu(category, { chipEdit: true })
    this.valueMenuTarget.classList.remove('hidden')
    this._positionLayerAt(anchor, this.valueMenuTarget)
    this._armOutsideClose()
    this._focusLayer(this.valueMenuTarget)
  }

  // The sentence is built on the server, so it is fetched, not re-rendered
  // here. Once per editing session, not once per tick: while the pills stand,
  // the sentence is hidden anyway.
  // refocus: the field whose word was clicked. The frame comes back as new
  // markup, so the button that had the focus is gone by then; without this the
  // focus falls to the document and a keyboard reader is left nowhere.
  refreshSentence(refocus = null) {
    if (!this.hasSentenceFrameTarget) return

    this._refocusCategory = refocus
    this.sentenceFrameTarget.src = this._filterUrl().toString()
  }

  // === Save as SmartFolder Modal ===

  // The modal carries the EFFECTIVE set: on a saved view the remaining saved
  // values belong to the new folder too, not only the reader's additions.
  // Naming a new view happens in the save row itself (20a, § 9), not in a
  // modal: a modal for one word covers the conditions the name is about. The
  // field opens filled with a name derived from those conditions and selected,
  // so the quickest answer is Enter.
  openSaveModal(event) {
    if (event) { event.preventDefault(); event.stopPropagation() }

    this._naming = true
    this.renderChips()

    const field = this.saveRowTarget.querySelector('input[name="smart_folder_name"]')
    if (field) requestAnimationFrame(() => { field.focus(); field.select() })
  }

  cancelNaming(event) {
    if (event) { event.preventDefault(); event.stopPropagation() }
    this._naming = false
    this.renderChips()
  }

  closeSaveModal() {
    this._naming = false
  }

  // The type condition (S7) is not a rule but the folder's target: exactly one
  // type with a target becomes it, anything else is a folder of all types.
  _namingRowHtml() {
    const effective = this._effective
    const { [BUILTIN_VIEW_PARAM]: types, ...filters } = effective.filters
    const { [BUILTIN_VIEW_PARAM]: _typeOperator, ...operators } = effective.operators
    const typeTargets = this.typeTargetsValue || {}
    const saveLabels = this.saveLabelsValue || {}

    return buildNamingRowHtml({
      saveUrl: this.saveUrlValue,
      projectId: this.projectIdValue,
      filters,
      operators,
      suggestion: this._suggestedName(effective),
      labels: this.labelsValue || {},
      saveLabels,
      extraFields: { ...this._returnContextFields(), target_object_type: targetForTypes(types, typeTargets) },
      // Two types, or one without a folder kind of its own, widen the folder
      // to all types: said before the save, not found out after it.
      extraHint: typeWidened(types, typeTargets) ? saveLabels.save_filter_type_widened_hint : null
    })
  }

  // A name made of what the view actually holds. Not clever, just a start that
  // is usually right: the values, in the order of the conditions.
  _suggestedName(effective) {
    const parts = []
    orderedCategories({ saved: this._saved, adHoc: this._adHoc }).forEach(category => {
      const values = effective.filters[category]
      if (!values || values.length === 0) return
      parts.push(values.map(value => this._valueLabel(category, value)).join(', '))
    })
    const name = parts.join(' · ')
    return name.length > 40 ? `${name.slice(0, 39)}…` : name
  }

  // === Close / Escape Handlers ===

  // Closing a layer that held the focus gives the focus back to what opened
  // it; closing by a click elsewhere leaves the focus where the click put it.
  closeAllMenus() {
    const focusWasInLayer = this._layers().some(layer => layer.contains(document.activeElement))
    const trigger = this._lastTrigger
    this._lastTrigger = null

    this.closeFilterMenu()
    this.closeSearchDepthMenu()
    this.closeViewMenu()
    this.closeOverflowMenu()
    this.closeSaveModal()
    this._disarmOutsideClose()

    if (focusWasInLayer && trigger) this._liveTrigger(trigger)?.focus()
  }

  // The trigger as it stands in the page now. A pill's chevron is rebuilt with
  // every edit (renderChips), so the element that opened the layer may be
  // detached by the time the layer closes; its category finds the new one.
  _liveTrigger(trigger) {
    if (trigger.isConnected) return trigger
    const category = trigger.closest('[data-condition]')?.dataset.condition
    if (!category || !this.hasChipZoneTarget) return null
    return this.chipZoneTarget.querySelector(`[data-condition="${CSS.escape(category)}"] [data-fb-open]`)
  }

  // The document listeners that close an open layer on a click elsewhere or on
  // Escape. Armed a frame late, so the click that opened the layer does not
  // close it again; a controller gone by then (a Turbo visit in between) arms
  // nothing, or the listeners would outlive it.
  _armOutsideClose() {
    requestAnimationFrame(() => {
      if (!this.element.isConnected) return
      document.addEventListener('click', this._boundCloseMenus)
      document.addEventListener('keydown', this._boundEscape)
      this._escapeArmed = true
    })
  }

  _disarmOutsideClose() {
    document.removeEventListener('click', this._boundCloseMenus)
    document.removeEventListener('keydown', this._boundEscape)
    this._escapeArmed = false
  }

  // Escape owner (lib/escape_owner.js): the lane behind stays open while this is true.
  // True exactly while the Escape listener of an open layer is armed. The
  // search field's own Escape (closeSearch) folds the field and owns nothing:
  // the lane closes with it, as it did before.
  ownsEscape() {
    return Boolean(this._escapeArmed)
  }

  _layers() {
    return [
      this.hasFilterMenuTarget ? this.filterMenuTarget : null,
      this.hasValueMenuTarget ? this.valueMenuTarget : null,
      this.hasViewMenuTarget ? this.viewMenuTarget : null,
      this.hasOverflowMenuTarget ? this.overflowMenuTarget : null,
      this.hasSearchDepthMenuTarget ? this.searchDepthMenuTarget : null
    ].filter(Boolean)
  }

  // Focus moves into an opened layer, onto its first control, so keyboard and
  // screen-reader users land where the pointer user looks.
  _focusLayer(layer) {
    if (!layer) return
    void layer.offsetWidth // the layer was hidden a moment ago: apply the style first
    // The body first, never the head: the close is a way out, not a place to
    // start. Inside the body the boxes come before anything else, so a pill's
    // layer opens on its values.
    const body = layer.querySelector('[data-fb-body]') || layer
    const first = body.querySelector('input[type="checkbox"]') ||
      body.querySelector('input:not([type="hidden"]), button, a[href], [tabindex="0"]') ||
      layer.querySelector('input:not([type="hidden"]), button, a[href], [tabindex="0"]')
    if (first) first.focus()
  }

  // A step back exists only in the layer that was opened from "+ Filter", and
  // only while it stands on its second level.
  get _canStepBack() {
    return this.hasValueMenuTarget && this.hasFilterMenuTarget && this.isFilterMenuOpen &&
      !this._chipEditMode && !this.valueMenuTarget.classList.contains('hidden')
  }

  closeOnOutside(event) {
    if (!this.element.contains(event.target)) {
      this.closeAllMenus()
      return
    }
    // A click inside the bar but outside an open layer closes that layer
    if (this.hasValueMenuTarget && !this.valueMenuTarget.classList.contains('hidden')) {
      if (!this.valueMenuTarget.contains(event.target)) {
        this.closeFilterMenu()
        this._disarmOutsideClose()
      }
    }
    if (this.hasViewMenuTarget && !this.viewMenuTarget.classList.contains('hidden')) {
      if (!this.viewMenuTarget.contains(event.target)) {
        this.closeViewMenu()
        this._disarmOutsideClose()
      }
    }
    if (this.hasOverflowMenuTarget && !this.overflowMenuTarget.classList.contains('hidden')) {
      if (!this.overflowMenuTarget.contains(event.target) && !event.target.closest('[data-fb-overflow]')) {
        this.closeOverflowMenu()
        this._disarmOutsideClose()
      }
    }
  }

  // Escape closes the open layer. In a layer that is a menu (role="menu": the
  // category list, the search depth) the arrow keys walk its items, as the
  // role promises; Home and End jump to the ends.
  closeOnEscape(event) {
    if (event.key === 'Escape') {
      // Two steps, two Escapes. From the values of a category back to the list
      // of categories (F36), and only from there out. Opened from a pill there
      // is no step below, so Escape leaves at once.
      if (this._canStepBack) this.backToFilterMenu()
      else this.closeAllMenus()
      return
    }
    if (!MENU_KEYS.includes(event.key)) return

    // The menu is the list inside the layer, not the layer itself: the layer
    // is a dialog, because its head holds a close.
    const menu = document.activeElement?.closest('[role="menu"]')
    if (!menu || !this._layers().some(layer => layer.contains(menu))) return
    const items = [...menu.querySelectorAll('[role="menuitem"]')].filter(item => !item.disabled)
    if (items.length === 0) return

    event.preventDefault()
    const index = items.indexOf(document.activeElement)
    const next = event.key === 'Home' ? 0
      : event.key === 'End' ? items.length - 1
      : event.key === 'ArrowDown' ? (index + 1) % items.length
      : (index - 1 + items.length) % items.length
    items[next].focus()
  }

  // === Helpers ===

  _positionMenuAtChip(chip) {
    this._chipEditMode = true
    this.filterMenuTarget.classList.add('hidden')
    this.valueMenuTarget.classList.remove('hidden')
    this._positionLayerAt(chip, this.valueMenuTarget)
    this._armOutsideClose()
  }

  // A floating layer under its anchor, positioned against the controller
  // root (position: relative) and kept inside the bar's width. The layer must
  // be visible when this runs, or its width reads as zero.
  _positionLayerAt(anchor, layer) {
    const anchorRect = anchor.getBoundingClientRect()
    const barRect = this.element.getBoundingClientRect()

    layer.style.position = 'absolute'
    const width = layer.offsetWidth || LAYER_FALLBACK_WIDTH_PX

    let left = anchorRect.left - barRect.left
    if (left + width > barRect.width - LAYER_INSET_PX * 2) {
      left = barRect.width - LAYER_INSET_PX * 2 - width
    }
    left = Math.max(LAYER_INSET_PX, left)

    layer.style.left = `${left}px`
    layer.style.top = `${anchorRect.bottom - barRect.top + LAYER_GAP_PX}px`
    layer.style.zIndex = '9999'
  }

  _positionMenuAtButton() {
    this._positionLayerAt(this._filterMenuAnchor || this.filterButtonTarget, this.valueMenuTarget)
  }

  // Same rule as buildFilterUrl: the default depth "content" is not written,
  // so the same state has one address wherever it is built.
  _preserveSearchParams(url) {
    if (this.hasSearchInputTarget && this.searchInputTarget.value) {
      url.searchParams.set('search', this.searchInputTarget.value)
      if (this.searchModeValue && this.searchModeValue !== 'content') url.searchParams.set('search_mode', this.searchModeValue)
    }
  }

  handleModalSubmitEnd(event) {
    const form = event.target
    if (!form || !event.detail.success || form.dataset.redirectOnSuccess === 'true') return

    const modalFrame = document.getElementById('modal')
    if (modalFrame && modalFrame.contains(form)) {
      setTimeout(() => {
        window.Turbo.visit(window.location.href, { action: 'replace' })
      }, 100)
    }
  }
}
