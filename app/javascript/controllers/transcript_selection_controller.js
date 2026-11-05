import { Controller } from "@hotwired/stimulus"
import { buildMark, markQuery, withQuery } from "transcript_mark"

/**
 * Transcript Selection Controller
 *
 * The transcript of a meeting page for someone who may edit the meeting (K4b, plan §5.1):
 * a mark in it (a double click, a drag, a long press on a phone) shows "Korrigieren" over it.
 * The button is a link into the dialog's frame (README_MODAL_PATTERN.md); this controller only
 * keeps its address current: the mark, a little of the text around it, its offset in the text
 * the page shows, and the digest of the transcript (lib/transcript_mark.js). Where the mark
 * lies in the stored transcript is the server's to find, never a position of this page: the
 * page shows Markdown.
 *
 * On a touch screen the system's own menu (copy, look up) stands above the mark, so the button
 * goes below it there. A mousedown on the button keeps the mark (it would collapse it first).
 *
 * Mounted by organisations/meetings/_transcript_section, never in the panel beside a ticket.
 */
export default class extends Controller {
  static targets = ["content", "button"]
  // context, maxLength: Meetings::TranscriptMark::CONTEXT_LENGTH and GlossaryTerm::MAX_LENGTH.
  static values = { url: String, digest: String, context: { type: Number, default: 40 }, maxLength: { type: Number, default: 255 } }

  connect() {
    this.follow = this.follow.bind(this)
    document.addEventListener("selectionchange", this.follow)
  }

  disconnect() {
    document.removeEventListener("selectionchange", this.follow)
    clearTimeout(this.timer)
  }

  // A drag changes the selection at every step: the button follows once it rests.
  follow() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.place(), 120)
  }

  place() {
    const root = this.textRoot()
    const selection = window.getSelection()
    if (!root || !selection || selection.rangeCount === 0 || selection.isCollapsed) return this.hide()

    const range = selection.getRangeAt(0)
    if (!root.contains(range.startContainer) || !root.contains(range.endContainer)) return this.hide()

    const mark = buildMark(this.pieces(root, range), { context: this.contextValue, maxLength: this.maxLengthValue })
    if (!mark) return this.hide()

    this.buttonTarget.href = withQuery(this.urlValue, markQuery(mark, this.digestValue))
    this.show(range)
  }

  // The text before, inside and after the mark, as the browser holds it: text nodes in order,
  // which is what the server reads out of the same HTML.
  pieces(root, range) {
    const before = document.createRange()
    before.selectNodeContents(root)
    before.setEnd(range.startContainer, range.startOffset)
    const after = document.createRange()
    after.selectNodeContents(root)
    after.setStart(range.endContainer, range.endOffset)
    return { prefix: before.toString(), selected: range.toString(), suffix: after.toString() }
  }

  // The prose block of Neo::MarkdownPreviewComponent, with or without its clamp.
  textRoot() {
    return this.hasContentTarget ? this.contentTarget.querySelector(".md-preview") : null
  }

  show(range) {
    const button = this.buttonTarget
    button.classList.remove("hidden")
    const mark = range.getBoundingClientRect()
    const host = this.element.getBoundingClientRect()
    const touch = window.matchMedia("(pointer: coarse)").matches
    const top = touch ? mark.bottom - host.top + 8 : mark.top - host.top - button.offsetHeight - 6
    const left = Math.min(Math.max(mark.left - host.left, 0), Math.max(host.width - button.offsetWidth, 0))
    button.style.top = `${Math.max(top, 0)}px`
    button.style.left = `${left}px`
  }

  hide() {
    if (this.hasButtonTarget) this.buttonTarget.classList.add("hidden")
  }

  keepSelection(event) {
    event.preventDefault()
  }
}
