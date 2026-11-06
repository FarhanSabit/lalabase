# frozen_string_literal: true

# The one read of an organisation's glossary for programs (K4c): GET
# /api/v1/organisations/:organisation_id/terms and the MCP tool get_glossary
# read through here, so a device that learns the terms before a transcription
# gets the same answer on both doors. Rights, reach, what works, the order and
# the pages live here; the doors only name the organisation and word the answer.
#
# Entry point: read
module Glossary
  # * Rights (E2): GlossaryPolicy.view_allowed? (#allowed?, asked again by #read
  #   before anything is read), which asks for an ACTIVE membership. The rows
  #   come through the policy scope as well, so nothing is read without it.
  # * What works (E3): confirmed terms only, and at them only the heard forms
  #   TermCorrection.effective names (confirmed at a confirmed term). A confirmed
  #   term without one comes with an empty heard list.
  # * Tokens (E4, .for_token): every term of an organisation the token reaches,
  #   but the heard forms only of its projects; a form without a project (its
  #   project was deleted) only for a token that reaches every project. Unlike
  #   the people directory, a token limited to some projects is answered, not
  #   refused.
  # * project_id (E5): its heard forms first within each term, every term
  #   anyway. Outside the organisation or the token it is NotFound, never ignored.
  # * Speakers (E6): only with the people right, as the people directory names
  #   them to the reader (the ref of GET .../people/:id); a speaker it does not
  #   list counts in the form alone. Without the right no directory is read.
  # * Fields: no meeting, no place in a transcript, no corrector: what a device
  #   knows itself or what is a meeting's content (plan §4).
  #
  # The caller sets nothing: the reads run under the organisation's tenant here.
  class Lookup
    DEFAULT_PER_PAGE = 50
    MAX_PER_PAGE = 100
    # Far beyond any glossary, so an absurd page number is refused rather than skipped to.
    MAX_PAGE = 100_000
    # How much of a refused value a message quotes back.
    QUOTED_LENGTH = 20
    # The machine word of a refusal for want of the glossary right, on both doors.
    FORBIDDEN_REASON = 'glossary_forbidden'

    # The reader may not see the glossary of this organisation.
    class Refused < StandardError; end
    # A page value the lookup cannot take.
    class InvalidArgument < ArgumentError; end
    # A project_id outside the organisation or the token, a missing or a malformed one.
    class NotFound < StandardError; end

    # One correction as the answer needs it. user_id and person_id are the
    # speaker, read the way People::Directory#entry_for_participant reads a
    # meeting participant (the same speaker model, plan §3.2).
    Correction = Data.define(:glossary_term_id, :normalized_heard, :heard, :created_at, :id, :replaced_count,
                             :person_id, :user_id, :project_id)

    attr_reader :organisation

    # The lookup a Personal Access Token may open, or nil (E4): an organisation
    # the token reaches, with the token's projects as the limit of the heard
    # forms (PersonalAccessToken::Reach, nil = every project). An organisation
    # outside the token (an inactive membership included), a missing one and a
    # malformed id all answer nil, so a caller tells none of them apart.
    def self.for_token(reach:, viewer:, organisation_id:)
      id = Lalabase::Uuid.dashed(organisation_id)
      return nil if id.nil? || !reach.organisation?(id)

      organisation = Organisation.find_by(id: id)
      new(viewer: viewer, organisation: organisation, project_ids: reach.project_ids_for(id)) if organisation
    end

    # project_ids: the projects whose heard forms may go out, nil for every
    # project (the forms without a project included). Required: nil drops a limit.
    def initialize(viewer:, organisation:, project_ids:)
      @viewer = viewer
      @organisation = organisation
      @project_ids = project_ids
    end

    # The one rights question of the glossary, the glossary page's own. Under
    # the organisation's tenant: the membership it reads is a tenant's row.
    def allowed?
      ActsAsTenant.with_tenant(@organisation) { GlossaryPolicy.view_allowed?(@viewer, @organisation) }
    end

    # => { data: [term rows], people: [{ ref:, name: }], meta: { page:, per_page:, total: } }
    # page and per_page as text (REST) or whole numbers (MCP), absent or empty
    # for the default.
    def read(project_id: nil, page: nil, per_page: nil)
      raise Refused unless allowed?

      page = whole_number(:page, page, max: MAX_PAGE) || 1
      per_page = whole_number(:per_page, per_page, max: MAX_PER_PAGE) || DEFAULT_PER_PAGE
      ActsAsTenant.with_tenant(@organisation) do
        first = first_project_id(project_id)
        terms = Pundit.policy_scope!(@viewer, GlossaryTerm).confirmed
        total = terms.count
        offset = (page - 1) * per_page
        shown = offset < total ? terms.order(:normalized_term, :id).limit(per_page).offset(offset).to_a : []
        answer(shown, first).merge(meta: { page: page, per_page: per_page, total: total })
      end
    end

    private

    def answer(terms, first)
      corrections = corrections_of(terms.map(&:id))
      speakers = speaker_entries(corrections)
      by_term = corrections.group_by(&:glossary_term_id)
      {
        data: terms.map { |term| term_row(term, by_term.fetch(term.id, []), first, speakers) },
        people: people(speakers)
      }
    end

    def term_row(term, corrections, first, speakers)
      { id: term.id, term: term.term, category: term.category, heard: heard_forms(corrections, first, speakers) }
    end

    # One entry per compared form: the spelling last heard, how often it was
    # replaced, and who spoke it. The forms of `first` lead, then the most
    # heard, then by form.
    def heard_forms(corrections, first, speakers)
      groups = corrections.group_by(&:normalized_heard).map do |normalized, group|
        count = group.sum(&:replaced_count)
        lead = heard_in?(group, first) ? 0 : 1
        [[lead, -count, normalized], { form: newest(group).heard, count: count, speakers: speaker_counts(group, speakers) }]
      end
      groups.sort_by(&:first).map(&:last)
    end

    def heard_in?(group, project_id)
      !project_id.nil? && group.any? { |correction| correction.project_id == project_id }
    end

    # The correction heard last, the one the glossary page shows a form by.
    def newest(group)
      group.min_by { |correction| [-correction.created_at.to_r, correction.id] }
    end

    # How often each speaker the reader may see said this form, most first. A
    # speaker without a link, or one the directory does not list to the reader,
    # counts in the form's count only.
    def speaker_counts(group, speakers)
      counts = Hash.new(0)
      group.each do |correction|
        entry = speakers[speaker_key(correction)]
        counts[People::Lookup.key_for(entry)] += correction.replaced_count if entry
      end
      counts.sort_by { |ref, count| [-count, ref] }.map { |ref, count| { ref: ref, count: count } }
    end

    # Everyone the answer names, once, in the directory's order.
    def people(speakers)
      entries = speakers.values.uniq { |entry| People::Lookup.key_for(entry) }
      entries.sort_by { |entry| [entry.sort_name, People::Lookup.key_for(entry)] }
             .map { |entry| { ref: People::Lookup.key_for(entry), name: entry.plain_name } }
    end

    # The working heard forms of these terms that may go out, one row per
    # correction, in one query. A token limited to some projects gets the rows
    # of those (IN leaves out the rows without a project).
    def corrections_of(term_ids)
      return [] if term_ids.empty?

      rows = Pundit.policy_scope!(@viewer, TermCorrection).effective.where(glossary_term_id: term_ids)
      rows = rows.where(project_id: @project_ids) unless @project_ids.nil?
      table = TermCorrection.arel_table
      rows.pluck(*Correction.members.map { |column| table[column] }).map { |values| Correction.new(*values) }
    end

    # speaker key => directory entry, for every speaker of these rows the
    # reader may see in the people directory (E6). Without the people right
    # nothing, and no directory is read.
    def speaker_entries(corrections)
      linked = corrections.select { |correction| correction.person_id || correction.user_id }.uniq { |correction| speaker_key(correction) }
      return {} if linked.empty? || !PersonPolicy.view_allowed?(@viewer, @organisation)

      directory = People::Directory.new(viewer: @viewer, organisation: @organisation)
      linked.to_h { |correction| [speaker_key(correction), directory.entry_for_participant(correction)] }.compact
    end

    def speaker_key(correction)
      [correction.person_id, correction.user_id]
    end

    # The project whose heard forms lead, or nil. Blank is none; anything else
    # must be a project of this organisation within the token.
    def first_project_id(value)
      return nil if value.nil? || (value.is_a?(String) && value.strip.empty?)

      id = Lalabase::Uuid.dashed(value) if value.is_a?(String)
      raise NotFound unless id && (@project_ids.nil? || @project_ids.include?(id))
      raise NotFound unless Project.exists?(organisation_id: @organisation.id, id: id)

      id
    end

    # A whole number from 1 to max, as text (REST: digits only) or as a JSON
    # number (MCP: an Integer, or a Float with a whole value, which JSON Schema
    # counts as an integer: 2.0); absent or empty is nil (the default). A refused
    # value is quoted back only when it is text or a number, and only its start.
    def whole_number(name, raw, max:)
      return nil if raw.nil? || raw == ''

      number = raw if raw.is_a?(Integer)
      number = raw.to_i if raw.is_a?(Float) && raw.finite? && raw == raw.floor
      number = Integer(raw, 10) if raw.is_a?(String) && raw.match?(/\A\d+\z/)
      return number if number&.between?(1, max)

      shown = raw.is_a?(String) || raw.is_a?(Numeric) ? " #{raw.to_s.truncate(QUOTED_LENGTH).inspect}" : ''
      raise InvalidArgument, I18n.t('services.glossary.lookup.invalid_number', name: name, shown: shown, max: max)
    end
  end
end
