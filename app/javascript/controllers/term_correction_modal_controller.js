import TicketRelationModalController from "controllers/ticket_relation_modal_controller"
import { countQuery, withQuery } from "transcript_mark"

/**
 * Term Correction Modal Controller
 *
 * The dialog "Begriff korrigieren" beside the transcript of a meeting (K4b, markup in
 * organisations/meeting_term_corrections/_modal.html.erb). The same frame-content modal as the
 * ticket relation modal, so it IS that controller: opening on connect, one id per opening,
 * focus trap, closing on the backdrop and on Escape, the focus back to the button over the
 * mark. What it adds: the focus on the right form, and the count of the heard form, asked
 * again (meeting_term_corrections#count, its own frame) once its typing rests.
 */
export default class extends TicketRelationModalController {
  static targets = ["card", "form", "heard", "correct"]
  static values = { countUrl: String, countFrame: String, countDelay: { type: Number, default: 250 } }

  connect() {
    super.connect()
    if (!this.discarded && this.hasCorrectTarget) this.correctTarget.focus()
  }

  disconnect() {
    clearTimeout(this.timer)
    super.disconnect()
  }

  recount() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.reloadCount(), this.countDelayValue)
  }

  reloadCount() {
    const frame = document.getElementById(this.countFrameValue)
    if (!frame || !this.hasFormTarget) return

    frame.src = withQuery(this.countUrlValue, countQuery(new FormData(this.formTarget).entries()))
  }
}
