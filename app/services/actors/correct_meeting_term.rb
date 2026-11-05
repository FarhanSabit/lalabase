# frozen_string_literal: true

# app/services/actors/correct_meeting_term.rb
#
# Corrects one misheard word in the transcript of a meeting and learns it for
# the glossary of the organisation (K4b, plan §5): the heard form, the right
# form, who spoke, the project and the place.
#
# * The meeting first: its row lock in the project the request was checked
#   for (Meeting#lock_in_project!; a meeting moved meanwhile is gone), then
#   the right to edit it again under the lock (MeetingPolicy#update?, E2;
#   closed in an archived project as every meeting write), then the digest:
#   the dialog counted a transcript, and a different one now is not replaced
#   (code :stale_transcript; the caller counts again and asks).
# * The place comes from the client (through Meetings::TranscriptMark) and is
#   only taken where the heard form stands as an occurrence
#   (Meetings::TermReplacement#at): never in a speaker label, never part of a
#   longer word.
# * The transcript is written through Actors::SaveMeeting (derived text,
#   search, fragments as for an edit). On "everywhere" the AI summary gets the
#   same replacement; it stays in either case (keep_summary: true, the one
#   exception of Meeting#invalidate_stale_summary, E4/E5).
# * The glossary, when asked: the term of the right form is found (in any
#   spelling of the same normalized form) or created; one created at the same
#   moment is found, not refused. Then its row lock (Glossary::TermLock: the
#   meeting first, then the term, always in this order). With manage_glossary
#   (GlossaryPolicy.manage_allowed?) the term is confirmed and the heard form
#   too; without it a new term is proposed, a term keeps its status, and the
#   heard form is a proposal, also at a confirmed term (E3): it works nowhere
#   before someone with the right confirmed it. A heard form that is the term
#   itself (case aside) writes no row (plan §3.2).
# * The speaker is a participant of THIS meeting, never a raw id: the person
#   or the member it is linked to, or nobody.
#
# One transaction (BaseActor#call): a refusal anywhere leaves everything as it was.
module Actors
  class CorrectMeetingTerm < BaseActor
    SCOPES = %w[here everywhere].freeze

    # How many places the transcript changed, and what the glossary learnt:
    # :none (not asked), :term (the heard form is the term itself), :confirmed
    # or :proposed (the heard form's status).
    attr_reader :replaced_count, :glossary_outcome

    # Whether the AI summary got the replacement too ("everywhere", and the
    # word stood in it).
    def summary_replaced?
      @summary_replaced == true
    end

    # place: { line_index:, char_offset:, length: } of the marked span in the
    # stored transcript. digest: SHA-256 (hex) of the transcript the dialog
    # counted. speaker_id: a meeting_participants id of this meeting, or nil.
    def initialize(meeting:, project:, heard:, correct:, scope:, place:, digest:, speaker_id:, to_glossary:,
                   current_user:)
      super()
      @meeting = meeting
      @project = project
      @heard = heard.to_s
      @correct = GlossaryText.clean(correct)
      @scope = scope.to_s
      @place = place.to_h.symbolize_keys.slice(:line_index, :char_offset, :length)
      @digest = digest.to_s
      @speaker_id = speaker_id.presence
      @to_glossary = to_glossary
      @current_user = current_user
      @glossary_outcome = :none
    end

    def record
      @meeting
    end

    def perform
      refuse(:invalid_scope) unless SCOPES.include?(@scope)
      check_forms
      lock_meeting
      refuse(:stale_transcript) unless Digest::SHA256.hexdigest(@meeting.transcript.to_s) == @digest

      occurrence = marked_occurrence
      speaker = chosen_speaker
      write_meeting(occurrence)
      learn(occurrence, speaker) if @to_glossary
    end

    private

    attr_reader :current_user

    def refuse(code)
      raise ActorError.new(I18n.t("services.actors.correct_meeting_term.#{code}"), code: code)
    end

    def check_forms
      heard = @heard.strip
      refuse(:heard_invalid) if heard.empty? || heard.match?(/[\r\n]/) || heard.length > GlossaryTerm::MAX_LENGTH
      refuse(:correct_blank) if @correct.empty?
      refuse(:correct_too_long) if @correct.length > GlossaryTerm::MAX_LENGTH
      refuse(:same_form) if @correct == GlossaryText.clean(heard)
    end

    def lock_meeting
      refuse(:not_found) unless @meeting.lock_in_project!(@project.id)
      refuse(:forbidden) unless MeetingPolicy.new(current_user, @meeting).update?
    end

    def participants
      @participants ||= @meeting.meeting_participants.to_a
    end

    def replacement
      @replacement ||= Meetings::TermReplacement.new(text: @meeting.transcript, heard: @heard, participants: participants)
    end

    def marked_occurrence
      line_index, char_offset, length = @place.values_at(:line_index, :char_offset, :length)
      refuse(:place_gone) unless [line_index, char_offset, length].all?(Integer)

      replacement.at(line_index: line_index, char_offset: char_offset, length: length) || refuse(:place_gone)
    end

    def chosen_speaker
      return if @speaker_id.nil?

      participants.find { |participant| participant.id == @speaker_id } || refuse(:speaker_not_found)
    end

    def write_meeting(occurrence)
      transcript = @scope == 'everywhere' ? replacement.replace(with: @correct) : replacement.replace(with: @correct, only: occurrence)
      params = { transcript: transcript.text }
      summary = replaced_summary if @scope == 'everywhere'
      params[:generated_summary] = summary if summary
      @summary_replaced = !summary.nil?

      @replaced_count = transcript.count
      saved = Actors::SaveMeeting.call(project: @project, params: params, id: @meeting.id, current_user: current_user,
                                       keep_summary: true)
      raise ActorError.new(saved.errors, code: saved.code) unless saved.success?

      @meeting = saved.resource
    end

    # The summary with the same replacement, or nil where the word is not in it.
    def replaced_summary
      summary = Meetings::TermReplacement.new(text: @meeting.generated_summary, heard: @heard, participants: participants)
      summary.replace(with: @correct).text if summary.count.positive?
    end

    def learn(occurrence, speaker)
      manage = GlossaryPolicy.manage_allowed?(current_user, @meeting.organisation)
      term = existing_term || create_term(manage ? 'confirmed' : 'proposed')
      Glossary::TermLock.call(term: term)
      term.update!(status: 'confirmed') if manage && !term.confirmed?
      return @glossary_outcome = :term if GlossaryText.normalize(@heard) == term.normalized_term

      TermCorrection.create!(
        organisation: @meeting.organisation, glossary_term: term, project: @meeting.project, meeting: @meeting,
        heard: @heard, line_index: occurrence.line_index, char_offset: occurrence.char_offset,
        transcript_digest: @digest, replaced_count: @replaced_count, corrected_by: current_user,
        status: manage ? 'confirmed' : 'proposed', **speaker_link(speaker)
      )
      @glossary_outcome = manage ? :confirmed : :proposed
    end

    def existing_term
      terms.find_by(normalized_term: GlossaryText.normalize(@correct))
    end

    # A term of the same form created at the same moment is that term: the
    # validation that saw it, or the unique index that caught it, finds it.
    # The insert runs in a savepoint, so the index refusal leaves the
    # transaction usable.
    def create_term(status)
      term = GlossaryTerm.new(organisation: @meeting.organisation, term: @correct, status: status, created_by: current_user)
      return term_of_the_same_form if term.invalid? && term.errors.of_kind?(:term, :taken)
      raise ActiveRecord::RecordInvalid, term if term.errors.any?

      GlossaryTerm.transaction(requires_new: true) { term.save!(validate: false) }
      term
    rescue ActiveRecord::RecordNotUnique
      term_of_the_same_form
    end

    def term_of_the_same_form
      terms.find_by!(normalized_term: GlossaryText.normalize(@correct))
    end

    def terms
      GlossaryTerm.where(organisation_id: @meeting.organisation_id)
    end

    # The person or the member a participant is linked to. A member who has
    # left the organisation is no speaker any more (TermCorrection#speaker_is_member).
    def speaker_link(speaker)
      return {} unless speaker
      return { person_id: speaker.person_id } if speaker.person_id
      return {} unless speaker.user_id && Membership.exists?(organisation_id: @meeting.organisation_id, user_id: speaker.user_id)

      { user_id: speaker.user_id }
    end
  end
end
