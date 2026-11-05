# frozen_string_literal: true

# Correcting a misheard word in the transcript of a meeting (K4b, plan §5):
# new renders the dialog into its frame (README_MODAL_PATTERN.md), count
# redraws the count of one opening when the heard form changes, create
# corrects (Actors::CorrectMeetingTerm) and answers with streams: the
# transcript, the summary, this opening removed, a flash with the number.
#
# What the browser sends is a mark (what the reader marked, a little of the
# text around it, its offset in the text the page shows) and the digest of the
# transcript it saw. The place in the stored transcript is the server's
# (Meetings::TranscriptMark, through Meetings::TermCorrectionDialog); a digest
# that is no longer the stored one is counted again and asked again, never
# replaced.
#
# Rights, before anything is read or written, all three actions alike:
#   1. write on meetings in the project of the route: the area gate of
#      ProjectController (every action here is a meeting write);
#   2. MeetingPolicy#update? on the meeting, found inside that project;
#   3. what the dialog offers of the glossary: suggestions with view_glossary,
#      the box "take over" with manage_glossary, "propose" without (E2).
# A denial answers 403, a meeting of another project 404 (another
# organisation: 404 from Organisations::BaseController).
module Organisations
  class MeetingTermCorrectionsController < Organisations::BaseController
    include ProjectController

    # The token of one dialog opening, echoed by its form and its count.
    MODAL_TOKEN = /\A\h{16}\z/
    MARK_KEYS = %i[text before after].freeze
    NOT_FOUND_CODES = %i[not_found].freeze
    FORBIDDEN_CODES = %i[forbidden].freeze
    # The actor's refusals that come from a changed transcript: count again.
    RECOUNT_CODES = %i[stale_transcript].freeze

    rescue_from Pundit::NotAuthorizedError, with: :render_forbidden

    before_action :read_modal_token
    before_action :set_meeting
    before_action :authorize_correction

    def new
      @modal_token = SecureRandom.hex(8)
      @dialog = build_dialog(heard: nil)
      render layout: false
    end

    def count
      @dialog = build_dialog(heard: heard_param)
      render partial: 'organisations/meeting_term_corrections/count',
             locals: { meeting: @meeting, token: @modal_token || SecureRandom.hex(8), dialog: @dialog }
    end

    def create
      @dialog = build_dialog(heard: heard_param)
      return refused(notice: :recounted) if @dialog.recounted?
      return refused(errors: [mark_error_text(@dialog)]) unless @dialog.correctable?
      # Everywhere only where the page shows every occurrence (the dialog offers no button otherwise).
      return refused(errors: [t('views.organisations.meetings.term_correction.count.everywhere_hidden')]) if everywhere_hidden?

      actor = Actors::CorrectMeetingTerm.new(**correction_arguments)
      result = actor.call
      return corrected(actor) if result.success?

      refused_by_actor(result)
    end

    private

    # ProjectController derives the area from the controller name, which is no
    # area, and every action here is a write: the dialog offers only that.
    def determine_access_area
      :meetings
    end

    def determine_required_action
      :write
    end

    # The area gate answers like Pundit here: 403, not a redirect into the frame.
    def handle_access_denied(_area)
      render_forbidden
    end

    def read_modal_token
      @modal_token = scalar_param(:modal_token).to_s[MODAL_TOKEN]
    end

    # Inside the project of the route: a meeting of another project or
    # organisation is not found, as is one moved or deleted meanwhile.
    def set_meeting
      @meeting = @project.meetings.find_by(id: params[:meeting_id].to_s)
      render_not_found unless @meeting
    end

    def authorize_correction
      authorize @meeting, :update?
    end

    def participants
      @participants ||= @meeting.meeting_participants.in_row_order.to_a
    end

    def build_dialog(heard:)
      Meetings::TermCorrectionDialog.new(
        transcript: @meeting.transcript, participants: participants, mark: mark_param, heard: heard,
        render: ->(text) { helpers.meeting_transcript_html(text, participants) }, digest: scalar_param(:digest)
      )
    end

    def correction_arguments
      fields = correction_fields
      { meeting: @meeting, project: @project, heard: @dialog.heard, correct: fields[:correct].to_s,
        scope: scalar_param(:scope).to_s, place: @dialog.place, digest: scalar_param(:digest).to_s,
        speaker_id: fields[:speaker_id], to_glossary: fields[:to_glossary] != '0', current_user: current_user }
    end

    # The transcript, drawn again in full (the reader was looking at the place),
    # the summary (replaced on "everywhere"), this opening gone, the flash.
    def corrected(actor)
      @meeting = actor.record
      @participants = @meeting.meeting_participants.in_row_order.to_a
      @summary_replaced = actor.summary_replaced?
      @flash_message = { notice: corrected_message(actor) }
      render 'organisations/meeting_term_corrections/corrected', formats: :turbo_stream
    end

    def corrected_message(actor)
      key = 'views.organisations.meetings.term_correction.flash'
      outcome = { confirmed: "#{key}.confirmed", proposed: "#{key}.proposed" }[actor.glossary_outcome]
      [t("#{key}.replaced", count: actor.replaced_count), (t(outcome) if outcome)].compact.join(' ')
    end

    def refused_by_actor(result)
      return render_not_found(result.errors) if NOT_FOUND_CODES.include?(result.code)
      return render_forbidden if FORBIDDEN_CODES.include?(result.code)
      return refused(notice: :recounted, reload: true) if RECOUNT_CODES.include?(result.code)

      refused(errors: result.errors)
    end

    # The dialog again, in place of the opening that sent it, with what was
    # typed, counted against the transcript stored now. Read again after a
    # refusal of the actor inside this project only: a move or a delete that
    # committed right after it leaves nothing to draw here.
    def refused(errors: [], notice: nil, reload: false)
      if reload
        @meeting = @project.meetings.find_by(id: @meeting.id)
        @participants = nil
        return render_not_found unless @meeting

        @dialog = build_dialog(heard: heard_param)
      end
      @errors = errors
      @notice = notice
      @fields = correction_fields
      render 'organisations/meeting_term_corrections/refused', formats: :turbo_stream, status: :unprocessable_content
    end

    def mark_error_text(dialog)
      key = 'views.organisations.meetings.term_correction'
      return t("#{key}.mark_errors.#{dialog.mark_error}", max: GlossaryTerm::MAX_LENGTH) if dialog.mark_error
      return t("#{key}.count.ambiguous") if dialog.heard_error == :ambiguous

      t('services.actors.correct_meeting_term.place_gone')
    end

    def everywhere_hidden?
      scalar_param(:scope) == 'everywhere' && !@dialog.everywhere?
    end

    def render_forbidden
      skip_authorization
      if turbo_frame_request?
        render html: helpers.turbo_frame_tag(request.headers['Turbo-Frame']) {
          helpers.tag.p(t('shared.errors.not_authorized'), class: 'term-correction-gone text-sm text-red-800', role: 'alert')
        }, layout: false, status: :forbidden
      else
        render plain: t('shared.errors.not_authorized'), status: :forbidden
      end
    end

    # The meeting is not in this project (another one, moved or deleted): the
    # frame says so, a stream closes this opening with a flash. Nothing of the
    # meeting is drawn: it may be in a project this request was not checked for.
    def render_not_found(errors = [t('services.actors.correct_meeting_term.not_found')])
      skip_authorization
      @meeting_id = params[:meeting_id].to_s
      @errors = errors
      if turbo_frame_request?
        render 'organisations/meeting_term_corrections/not_found', layout: false, status: :not_found
      else
        render 'organisations/meeting_term_corrections/gone', formats: :turbo_stream, status: :not_found
      end
    end

    # The mark as the browser sent it: three strings and a whole number.
    def mark_param
      raw = params[:mark]
      raw = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : {}
      mark = MARK_KEYS.index_with { |key| raw[key.to_s].is_a?(String) ? raw[key.to_s] : '' }
      mark[:offset] = raw['offset'].is_a?(String) ? Integer(raw['offset'], 10, exception: false) : nil
      mark
    end

    def heard_param
      value = correction_fields[:heard]
      value.is_a?(String) ? value : nil
    end

    # The fields of the form, each a string or nil.
    def correction_fields
      raw = params[:term_correction]
      raw = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : {}
      %w[heard correct speaker_id to_glossary].to_h { |key| [key.to_sym, (raw[key] if raw[key].is_a?(String))] }
    end

    # A nested or repeated parameter is no value here.
    def scalar_param(key)
      value = params[key]
      value.is_a?(String) ? value : nil
    end
  end
end
