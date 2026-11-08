# frozen_string_literal: true

# A meeting a program sends, for both surfaces (POST /api/v1/organisations/:id/meetings
# and the MCP tool create_meeting): where it lands and who took part. The write is
# Actors::SaveMeeting, the web form's, so the activity and the participants run as
# they do there. Each surface authorizes `meeting_for_policy` itself, which is what
# marks its tripwire, and answers a refusal in its own envelope.
#
# Without a project the meeting lands in the organisation's inbox
# (Organisation#meeting_inbox). The difference to a named project is the refusal:
# the caller did not choose the inbox, so an inbox out of reach says so (forbidden)
# instead of a 404 nobody could act on. It tells nothing but that the organisation
# has one.
#
# `glossary_replacements` (K4d) is what the sender replaced from the glossary before
# it sent the transcript: rows of heard, term and count. Checked here as a whole
# (shape, lengths, counts, at most TermApplication::MAX_ENTRIES) and refused as a
# whole, like the participants; written as TermApplication rows in the meeting's
# transaction, so a retry under one Idempotency-Key writes them once.
#
# A participant is a name, optionally with `ref`, the id the people list hands out
# (member:<uuid>, person:<uuid>). A ref is resolved through People::Lookup, so the
# token's reach and the writer's people right apply, and a ref that does not resolve
# refuses the whole meeting: sent on without its link, the meeting would look fine
# and the person's history would lack it.
#
# Entry point: new, refusal, meeting_for_policy, save, .summary
module Meetings
  class Intake
    # reason: names the refusal for a program. code: the error class of both surfaces.
    Refusal = Data.define(:reason, :code)

    FIELDS = %i[title occurred_at duration_minutes notes transcript].freeze

    NOT_FOUND = Refusal.new(reason: :not_found, code: :not_found)
    INBOX_MISSING = Refusal.new(reason: :meeting_inbox_missing, code: :refused)
    INBOX_FORBIDDEN = Refusal.new(reason: :meeting_inbox_forbidden, code: :forbidden)
    PROJECT_ARCHIVED = Refusal.new(reason: :project_archived, code: :refused)
    UNKNOWN_PARTICIPANT = Refusal.new(reason: :unknown_participant, code: :invalid_input)
    INVALID_REPLACEMENTS = Refusal.new(reason: :invalid_glossary_replacements, code: :invalid_input)

    attr_reader :project, :refusal, :meeting

    # #refusal is a Refusal, or nil when the meeting may go on to the policy and #save.
    # @param organisation [Organisation] reached by the token; the caller holds its tenant
    # @param reach [PersonalAccessToken::Reach]
    # @param input [Hash] project_id, FIELDS, participants: [{ display_name:, ref: }],
    #   glossary_replacements: [{ heard:, term:, count: }]
    def initialize(organisation:, reach:, viewer:, input:)
      @organisation = organisation
      @reach = reach
      @viewer = viewer
      @input = input.to_h.deep_symbolize_keys
      @participants = []
      @links = {}
      @replacements = nil
      @refusal = resolve_target || resolve_participants || resolve_replacements
    end

    # What the surface authorizes :create? on.
    def meeting_for_policy
      project.meetings.build
    end

    # @return [BaseActor::Result]
    #
    # With a list of replacements the actor runs inside one transaction with the
    # rows (its own transaction joins it; a refusal of the actor rolls the whole
    # back, as a list that cannot be written takes the meeting with it), so a
    # retry under one Idempotency-Key finds either both or neither. The actor's
    # jobs run after the outer commit. Without a list the actor runs as before.
    def save
      actor = Actors::SaveMeeting.new(project: project, params: meeting_params, current_user: @viewer,
                                      participant_links: @links)
      return actor.call.tap { @meeting = actor.record } unless @replacements

      result = nil
      Meeting.transaction do
        result = actor.call
        @meeting = actor.record
        raise ActiveRecord::Rollback unless result.success?

        TermApplication.record!(meeting: @meeting, entries: @replacements)
      end
      result
    end

    # The answer of both surfaces, and it stays this small: an idempotent write
    # stores its answer for good (Mcp::IdempotencyStore), outside the meeting, so
    # a transcript in here would survive the meeting's deletion.
    def self.summary(meeting)
      {
        id: meeting.id,
        project_id: meeting.project_id,
        in_meeting_inbox: meeting.project.meeting_inbox?,
        title: meeting.title,
        occurred_at: meeting.occurred_at.iso8601,
        path: Rails.application.routes.url_helpers.organisation_project_meeting_path(
          meeting.organisation_id, meeting.project_id, meeting
        )
      }
    end

    private

    def meeting_params
      fields = @input.slice(*FIELDS)
      fields[:participants] = @participants if @input.key?(:participants)
      fields.with_indifferent_access
    end

    def resolve_target
      return resolve_inbox if @input[:project_id].blank?

      @project = @organisation.projects.find_by(id: @input[:project_id])
      return NOT_FOUND unless @reach.project?(@project)

      # Asked here, not left to the policy: its area check lets an account admin
      # write into an archived project (see MeetingPolicy#move?).
      PROJECT_ARCHIVED if @project.archived?
    end

    def resolve_inbox
      @project = @organisation.meeting_inbox
      return INBOX_MISSING if @project.nil?
      return if @reach.project?(@project) && Pundit.policy!(@viewer, meeting_for_policy).create?

      INBOX_FORBIDDEN
    end

    # Checked as a whole before anything is written: no list, a list too long, a
    # row that is no object, no text, text too long, or a count that is no whole
    # number within storage bounds refuses the meeting. Duplicate spellings must
    # agree on the term and their sum must fit too. Counts come as numbers (JSON)
    # or as digits (a form); nothing is trimmed or guessed.
    def resolve_replacements
      return unless @input.key?(:glossary_replacements)

      entries = @input[:glossary_replacements]
      return INVALID_REPLACEMENTS unless entries.is_a?(Array) && entries.size <= TermApplication::MAX_ENTRIES

      rows = entries.map { |entry| replacement_row(entry) }
      return INVALID_REPLACEMENTS if rows.any?(&:nil?)

      @replacements = TermApplication.summed_entries(rows)
      nil
    rescue TermApplication::InvalidEntries
      INVALID_REPLACEMENTS
    end

    def replacement_row(entry)
      return unless entry.is_a?(Hash)

      heard = replacement_text(entry[:heard])
      term = replacement_text(entry[:term])
      count = replacement_count(entry[:count])
      { heard: heard, term: term, count: count } if heard && term && count
    end

    def replacement_text(value)
      return unless value.is_a?(String)

      cleaned = GlossaryText.clean(value)
      cleaned if cleaned.present? && cleaned.length <= GlossaryTerm::MAX_LENGTH
    end

    def replacement_count(value)
      number = case value
               when Integer then value
               when String then value.match?(/\A\d+\z/) ? value.to_i : nil
               end
      number if number&.between?(1, TermApplication::MAX_COUNT)
    end

    def resolve_participants
      entries = @input.fetch(:participants, [])
      return UNKNOWN_PARTICIPANT unless entries.is_a?(Array) && entries.all?(Hash)

      entries.each do |entry|
        participant = { display_name: entry[:display_name], user_id: nil }
        if entry[:ref].present?
          found = directory_entry(entry[:ref])
          return UNKNOWN_PARTICIPANT if found.nil?

          attach(participant, found)
        end
        @participants << participant
      end
      nil
    end

    # A member is linked by user_id, the path the meeting form uses; a contact by
    # person_id, which the actor takes from participant_links, never from a payload.
    def attach(participant, found)
      if found.member?
        participant[:user_id] = found.user.id
      else
        @links[MeetingParticipant.normalize_name(participant[:display_name])] = found.person.id
      end
    end

    def directory_entry(ref)
      people = people_lookup
      return nil unless people&.allowed?

      people.entry(ref)
    rescue People::Lookup::InvalidArgument
      nil
    end

    def people_lookup
      return @people_lookup if defined?(@people_lookup)

      @people_lookup = People::Lookup.for_token(reach: @reach, viewer: @viewer, organisation_id: @organisation.id)
    end
  end
end
