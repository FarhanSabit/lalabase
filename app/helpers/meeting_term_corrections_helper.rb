# frozen_string_literal: true

# Correcting a misheard word in the transcript of a meeting (K4b,
# Organisations::MeetingTermCorrectionsController). The ids are a shared
# contract between the transcript section, the dialog, its count and the
# controller's streams: they live here once, by the meeting's id (an answer for
# a meeting that is gone from this project has only the id of its route).
module MeetingTermCorrectionsHelper
  # The transcript block of the meeting page; a correction redraws it.
  def meeting_transcript_section_id(meeting)
    dom_id(meeting, :transcript)
  end

  # The frame the dialog loads into, beside the transcript block.
  def term_correction_modal_id(meeting_id)
    "meeting-term-correction-modal-#{meeting_id}"
  end

  # One opening of the dialog: a refused correction replaces exactly it, a
  # correction removes it, a late answer to a dialog closed meanwhile finds nothing.
  def term_correction_modal_instance_id(meeting_id, token)
    "#{term_correction_modal_id(meeting_id)}-#{token}"
  end

  # The count of one opening and its buttons, reloaded when the heard form changes.
  def term_correction_count_id(meeting_id, token)
    "meeting-term-correction-count-#{meeting_id}-#{token}"
  end

  # The button over the mark: it opens the dialog, and the focus goes back to it.
  def term_correction_trigger_id(meeting_id)
    "meeting-term-correction-trigger-#{meeting_id}"
  end

  # The digest the page shows the transcript in: the dialog counts against it
  # and a correction refuses another (Actors::CorrectMeetingTerm).
  def meeting_transcript_digest(meeting)
    Digest::SHA256.hexdigest(meeting.transcript.to_s)
  end

  # The terms the dialog suggests while typing: the glossary of the
  # organisation without rejected terms, only for a reader of the glossary
  # (view_glossary, E2), at most Meetings::TermCorrectionDialog::SUGGESTIONS.
  def term_correction_suggestions
    return [] unless GlossaryPolicy.view_allowed?(current_user, current_organisation)

    policy_scope(GlossaryTerm).where.not(status: 'rejected').order(:normalized_term, :id)
                              .limit(Meetings::TermCorrectionDialog::SUGGESTIONS).pluck(:term)
  end
end
