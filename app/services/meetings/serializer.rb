# frozen_string_literal: true

# What a program reads of a meeting (REST R8): a row of the list and the whole meeting.
#
# Both are allowlists, so a new column stays inside until somebody names it here: no
# create_embeddings, no *_flag, no *_error, no plain_text_version. Analyses, ticket
# suggestions and linked tickets have visibility rules of their own and are not part of
# this answer. A row carries no text of the meeting: the list selects only
# Meetings::ListQuery::LIST_COLUMNS, and a transcript is up to 1 MB per row.
#
# Formats: generated_summary is Markdown, the LLM answers in it; notes and transcript are
# text a person pasted, and the web renders them as Markdown too. Nothing is cut. All three
# are foreign text for whoever shows them. A leading metadata block is left off notes and
# transcript as on the web (Meeting.strip_frontmatter); the stored value stays.
#
# Entry point: summary, full
module Meetings
  module Serializer
    def self.summary(meeting)
      {
        id: meeting.id,
        project_id: meeting.project_id,
        title: meeting.title,
        occurred_at: meeting.occurred_at.iso8601,
        duration_minutes: meeting.duration_minutes,
        creator: { id: meeting.creator_id, name: meeting.creator&.display_name }
      }
    end

    # The caller preloads creator, meeting_participants and term_applications. sort_by,
    # not in_row_order: a scope would ask the database again. Without an explicit viewer,
    # the glossary's resolved ids stay private.
    def self.full(meeting, viewer: nil)
      summary(meeting).merge(
        participants: meeting.meeting_participants.sort_by(&:created_at)
                             .map { |participant| { display_name: participant.display_name } },
        generated_summary: meeting.generated_summary,
        notes: Meeting.strip_frontmatter(meeting.notes),
        transcript: Meeting.strip_frontmatter(meeting.transcript),
        glossary_replacements: glossary_replacements(meeting, viewer: viewer),
        updated_at: meeting.updated_at.iso8601,
        path: Rails.application.routes.url_helpers.organisation_project_meeting_path(
          meeting.organisation_id, meeting.project_id, meeting
        )
      )
    end

    # What the glossary did to the transcript before it arrived (K4d), as the device
    # sent it: heard spelling, term, how often. A resolved id reveals that a term
    # exists, even for a guess the sender submitted, so only a glossary reader sees it.
    # Empty for a meeting without such a list. Sorted here, not by a scope: the
    # caller preloads the rows.
    def self.glossary_replacements(meeting, viewer: nil)
      rows = meeting.term_applications.sort_by { |row| [row.created_at, row.normalized_heard, row.heard, row.id] }
      return [] if rows.empty?

      view_glossary = viewer && GlossaryPolicy.view_allowed?(viewer, meeting.organisation)
      rows.map do |row|
        { heard: row.heard, term: row.term, count: row.replaced_count,
          glossary_term_id: view_glossary ? row.glossary_term_id : nil }
      end
    end
  end
end
