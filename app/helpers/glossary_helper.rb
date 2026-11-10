# frozen_string_literal: true

# The glossary page (Organisations::GlossaryController): the wiring of its list
# and lane, the words of a term, and what the page shows of a heard form.
#
# What a reader with view_glossary sees (E3): every term with its heard forms
# and their projects, also from projects they cannot read. Three things need
# more: the title and the link of a meeting (read access to that meeting,
# glossary_readable_meetings), the name of a speaker (someone the reader may
# see on the members or the people page, glossary_speaker_visible?) and the
# link to a speaker (view_people as well, glossary_speaker_url).
#
# The review list of the extraction (K5b) follows the same rule: every
# proposal with the projects and kinds of its sources, but the snippet of a
# source only for a reader of that source (glossary_source_access), and the
# model's hint only for a reader of every source sent in its model call
# (glossary_proposal_hint).
module GlossaryHelper
  # What a row opens in the lane: a term, or a proposal of the review list.
  # They exclude each other.
  SELECTION_PARAMS = %w[term_id proposal_id].freeze
  # The distinct heard forms a row names before "…".
  ROW_FORMS_SHOWN = 4
  # The characters of a line without a term the check of an import shows
  # (K5): such a line can be as long as anything pasted.
  IMPORT_LINE_SHOWN = 60

  # What the lane of a proposal knows about its sources (K5b): which the
  # reader may read and which are still there, as [source_type, source_id].
  SourceAccess = Data.define(:readable, :present) do
    def readable?(source)
      readable.include?([source.source_type, source.source_id])
    end

    # Every one of these sources, and there is one: a list without a source
    # has nothing the reader could have read.
    def all_readable?(sources)
      list = sources.to_a
      list.any? && list.all? { |source| readable?(source) }
    end

    def gone?(source)
      !readable?(source) && !present.include?([source.source_type, source.source_id])
    end
  end

  # The page wrapper's data: the lane (layout-toggle, index-page) and the
  # desktop/mobile switch, the controllers of the people page
  # (people_page_data).
  def glossary_page_data(viewport_mode:, term:, form_open:, proposal: nil)
    detail_frame_id = Organisations::GlossaryController::DETAIL_FRAME_ID
    unresolved = glossary_unresolved_lane_params(term: term, proposal: proposal, form_open: form_open)
    {
      controller: 'layout-toggle index-page viewport',
      layout_toggle_list_frame_ids_value: [Organisations::GlossaryController::LIST_FRAME_ID].to_json,
      layout_toggle_detail_frame_id_value: detail_frame_id,
      layout_toggle_content_selector_value: '.glossary-content',
      layout_toggle_selected_row_selector_value: '.selected-row[data-glossary-row]',
      layout_toggle_selection_params_value: SELECTION_PARAMS.to_json,
      layout_toggle_list_filter_params_value: Organisations::GlossaryController::LIST_PARAMS.to_json,
      layout_toggle_storage_key_value: 'layoutState:glossary',
      layout_toggle_unresolved_selection_value: (unresolved.to_json if unresolved.any?),
      viewport_breakpoint_value: MeetingsHelper::LANE_FULL_PAGE_BELOW_PX,
      viewport_current_mode_value: viewport_mode,
      index_page_param_name_value: SELECTION_PARAMS.join(','),
      index_page_frame_id_value: detail_frame_id,
      index_page_content_selector_value: '.glossary-content',
      index_page_placeholder_id_value: 'glossary-term-placeholder',
      index_page_placeholder_class_value: 'ticket-placeholder px-4',
      index_page_placeholder_title_value: t(glossary_placeholder_key(:title)),
      index_page_placeholder_body_value: t(glossary_placeholder_key(:body)),
      index_page_selected_row_selector_value: '.selected-row[data-glossary-row]',
      index_page_skip_if_content_visible_value: 'true',
      index_url: organisation_glossary_terms_path(current_organisation),
      lane_params: lane_params_json(selection: SELECTION_PARAMS, form: %w[new])
    }.compact
  end

  # "Liste importieren": its address and its wiring, for the head's "···" and
  # the empty glossary. It opens the import in the lane (?new=import, the
  # index answers the lane frame for it, no route of its own) and keeps the
  # list state; the href is the same state for a new tab. One owner, so the
  # two places cannot open the import in two different ways.
  def glossary_import_link
    import_state = Organisations::GlossaryController::IMPORT_STATE
    {
      url: organisation_glossary_terms_path(current_organisation, list_state.merge('new' => import_state)),
      data: {
        controller: 'lane-link',
        action: 'click->lane-link#click',
        lane_link_url_value: organisation_glossary_terms_path(current_organisation, new: import_state),
        lane_link_frame_value: Organisations::GlossaryController::DETAIL_FRAME_ID,
        lane_link_set_value: { new: import_state }.to_json,
        lane_link_remove_value: SELECTION_PARAMS.to_json,
        lane_link_focus_value: '#glossary_import_text'
      }
    }
  end

  # Lane parameters of this visit the server did not open (an unknown term or
  # proposal, a form the reader may not open). layout-toggle takes them out
  # of the address, so the page stays the list.
  def glossary_unresolved_lane_params(term:, proposal:, form_open:)
    unresolved = {}
    { 'term_id' => term, 'proposal_id' => proposal, 'new' => form_open }.each do |name, opened|
      value = params[name]
      unresolved[name] = value if value.is_a?(String) && value.present? && !opened
    end
    unresolved
  end

  # The words of the empty lane, for the view of the list beside it.
  def glossary_placeholder_key(part)
    scope = glossary_proposals_view? ? 'proposals' : 'index'
    "views.organisations.glossary.#{scope}.placeholder_#{part}"
  end

  def glossary_category_name(category)
    t("views.organisations.glossary.categories.#{category}")
  end

  def glossary_status_name(status)
    t("views.organisations.glossary.statuses.#{status}")
  end

  # The category choices of a select: [name, key], in GlossaryTerm's order.
  def glossary_category_options
    GlossaryTerm::CATEGORIES.map { |category| [glossary_category_name(category), category] }
  end

  # The heard forms of a term as the page groups them: one entry per compared
  # form, with the spelling last heard, how often it was corrected, and its
  # corrections newest first. Reads the loaded corrections, no query.
  def glossary_heard_groups(term)
    term.term_corrections.group_by(&:normalized_heard).sort_by(&:first).map do |_normalized, corrections|
      newest_first = corrections.sort_by { |correction| [-correction.created_at.to_f, correction.id] }
      { heard: newest_first.first.heard, count: corrections.size, corrections: newest_first }
    end
  end

  # How many heard forms of a term are open (K4b, E3): forms with at least one
  # proposal, which work nowhere until confirmed. Reads the loaded corrections.
  def glossary_open_form_count(term)
    term.term_corrections.select(&:proposed?).map(&:normalized_heard).uniq.size
  end

  # The line under a term in the list: its heard forms, each with its count
  # when it was heard more than once.
  def glossary_row_forms(term)
    groups = glossary_heard_groups(term)
    shown = groups.first(ROW_FORMS_SHOWN).map do |group|
      quoted = t('views.organisations.glossary.quoted', text: group[:heard])
      group[:count] > 1 ? t('views.organisations.glossary.index.form_count', form: quoted, count: group[:count]) : quoted
    end
    shown << t('views.organisations.glossary.index.more_forms', count: groups.size - ROW_FORMS_SHOWN) if groups.size > ROW_FORMS_SHOWN
    shown.join(', ')
  end

  # The second line of a row: who spoke and in which projects, distinct, as
  # names only (links live in the lane). The speakers the reader may not see
  # stand last, as one neutral word however many they are.
  def glossary_row_origin(term)
    corrections = term.term_corrections
    shown, hidden = corrections.select(&:speaker?).partition { |correction| glossary_speaker_visible?(correction) }
    speakers = shown.map { |correction| glossary_speaker_name(correction) }.uniq
    speakers << t('views.organisations.glossary.speaker_hidden') if hidden.any?
    projects = corrections.filter_map { |correction| correction.project&.name }.uniq
    [speakers.join(', ').presence, projects.join(', ').presence].compact.join(' · ')
  end

  # Whether the reader may see who spoke a heard form, the rule of the
  # members and the people page: a member they may see on the members page
  # (MembershipPolicy::Scope, deactivated ones too; a guest of one project
  # sees no members of other projects), a row of the directory they may see
  # on the people page (PersonPolicy::Scope, so only with view_people).
  def glossary_speaker_visible?(correction)
    if correction.user_id then glossary_visible_members.key?(correction.user_id)
    elsif correction.person_id then glossary_visible_person_ids.include?(correction.person_id)
    else false
    end
  end

  # The speaker of a heard form as the reader may see them: a member through
  # the reader's name display setting, a row of the directory as written
  # there, any other speaker as a neutral word (speaker_hidden); nil without
  # a speaker (none linked, or deleted).
  def glossary_speaker_name(correction)
    return unless correction.speaker?
    return t('views.organisations.glossary.speaker_hidden') unless glossary_speaker_visible?(correction)

    correction.user ? viewer_display_name(correction.user) : correction.person.name
  end

  # Where the name of a speaker links to on the people page, or nil: only
  # with view_people, and only for someone that page lists to the reader (a
  # visible row, a visible ACTIVE member), so the link never opens an empty
  # lane.
  def glossary_speaker_url(correction)
    return unless glossary_people_linkable? && glossary_speaker_visible?(correction)

    if correction.user_id
      organisation_people_path(current_organisation, member_id: correction.user_id) if glossary_visible_members[correction.user_id]
    else
      organisation_people_path(current_organisation, person_id: correction.person_id)
    end
  end

  # The meetings of these heard forms the reader may READ, as id => title
  # (MeetingPolicy::Scope, one query). A meeting not in it shows neither
  # title nor link: only its project's name stands (E3).
  def glossary_readable_meetings(corrections)
    ids = corrections.filter_map(&:meeting_id).uniq
    return {} if ids.empty?

    policy_scope(Meeting).where(id: ids).pluck(:id, :title).to_h
  end

  # The other terms a term can be merged into, by spelling.
  def glossary_merge_options(term)
    policy_scope(GlossaryTerm).where.not(id: term.id).order(:normalized_term, :id).pluck(:term, :id)
  end

  def glossary_proposal_status_name(status)
    t("views.organisations.glossary.proposals.statuses.#{status}")
  end

  # The projects a proposal was found in, by name, each once: a part of the
  # glossary for every reader, like the project of a heard form (E3). Reads
  # the loaded sources.
  def glossary_proposal_projects(proposal)
    proposal.glossary_proposal_sources.filter_map { |source| source.project&.name }.uniq.sort_by { |name| [name.downcase, name] }
  end

  # A hint may repeat any context of its classifier batch, even a candidate
  # the model dropped. Require current access to the complete stored input
  # provenance; the proposal's own example sources are insufficient. Missing,
  # malformed or deleted provenance never grants access to a hint.
  def glossary_proposal_hint(proposal, access)
    proposal.hint.presence if access.all_readable?(proposal.hint_source_references)
  end

  # Ticket, Kommentar, Notiz, ...: what every reader may know of a source.
  def glossary_source_kind(source)
    t("views.organisations.glossary.proposals.show.source_kinds.#{source.source_type.underscore}")
  end

  # Which sources of a proposal the reader may READ and which are still there,
  # one query per kind and question, never one per source. The run wrote them
  # with the rights of the account that started it, which says nothing about
  # this reader, so the page asks again (glossary_readable_sources). A source
  # neither readable nor there is gone.
  def glossary_source_access(sources)
    readable = Set.new
    present = Set.new
    sources.group_by(&:source_type).each do |type, rows|
      next unless GlossaryProposalSource::SOURCE_TYPES.include?(type)

      ids = rows.map(&:source_id).uniq
      found = glossary_readable_sources(type).where(id: ids).pluck(:id)
      found.each { |id| readable << [type, id] }
      rest = ids - found
      next if rest.empty?

      GlossaryProposalSource.polymorphic_class_for(type).where(organisation_id: current_organisation.id, id: rest)
                            .pluck(:id).each { |id| present << [type, id] }
    end
    SourceAccess.new(readable: readable, present: present)
  end

  # The rows of one kind the reader may read, the rule of each kind's own
  # page: a ticket through the ticket policy scope; a comment only when it is
  # public (never a private one, also not for an account admin), readable_by
  # the reader and on a readable ticket; a file through its ticket or its
  # public, readable comment; a note through the note policy scope; a version
  # through the document policy scope of its document.
  def glossary_readable_sources(type)
    organisation_id = current_organisation.id
    case type
    when 'Ticket' then glossary_readable_tickets
    when 'Post' then glossary_readable_comments
    when 'TicketDocument' then TicketDocument.where(organisation_id: organisation_id, ticket_id: glossary_readable_tickets.select(:id))
    when 'PostDocument' then PostDocument.where(organisation_id: organisation_id, post_id: glossary_readable_comments.select(:id))
    when 'Note' then policy_scope(Note.where(organisation_id: organisation_id))
    when 'DocumentVersion'
      DocumentVersion.where(organisation_id: organisation_id,
                            document_id: policy_scope(Document.where(organisation_id: organisation_id)).select(:id))
    end
  end

  def glossary_readable_tickets
    @glossary_readable_tickets ||= policy_scope(Ticket.where(organisation_id: current_organisation.id))
  end

  def glossary_readable_comments
    @glossary_readable_comments ||= Post.public_posts.readable_by(current_user, current_organisation)
                                        .where(organisation_id: current_organisation.id,
                                               ticket_id: glossary_readable_tickets.select(:id))
  end

  # The choices of "Ist eine Schreibweise von …": the confirmed terms, then
  # the other open proposals, by spelling, as option groups. A value names
  # its kind (term:<id>, proposal:<id>), and the merge looks it up among the
  # same targets again (proposal_merge_targets).
  def glossary_proposal_merge_options(proposal)
    targets = proposal_merge_targets(proposal)
    scope = 'views.organisations.glossary.proposals.show'
    {
      t("#{scope}.merge_terms") => glossary_merge_choices(targets[:term], 'term'),
      t("#{scope}.merge_proposals") => glossary_merge_choices(targets[:proposal], 'proposal')
    }.reject { |_label, choices| choices.empty? }
  end

  def glossary_merge_choices(relation, kind)
    relation.order(:normalized_term, :id).pluck(:term, :id).map { |term, id| [term, "#{kind}:#{id}"] }
  end

  # Whether a run is still at work: queued or running, and moving. One that
  # has not moved for STALE_AFTER lost its worker; the next start ends it
  # (Actors::StartGlossaryExtraction), so nothing waits for it.
  def glossary_run_active?(run)
    run.present? && run.active? && !run.stale?
  end

  # The line about the last run, for every reader of the review list: running
  # since when, what a finished run read and found, or why it failed (a stale
  # run as what it will be: ended as stale). A run over one document (K5c)
  # names the document where a run over the organisation names its projects
  # (glossary_run_source).
  def glossary_run_status(run)
    scope = 'views.organisations.glossary.runs'
    return t("#{scope}.never") unless run

    # A clock time, so in the reader's own zone, not the app's (UTC).
    date = l(run.created_at.in_time_zone(current_user.time_zone), format: :long)
    source = glossary_run_source(run) if run.document?
    lines = source ? 'views.organisations.glossary.document_runs' : scope
    return t("#{lines}.running_since", time: date, source: source) if glossary_run_active?(run)
    return t("#{scope}.last_run", date: date, summary: glossary_run_summary(run.stats, place: source)) if run.succeeded?

    code = run.stale? ? 'stale' : run.error_code.presence || 'internal_error'
    "#{t("#{lines}.failed", date: date, source: source)} #{t("services.glossary_extraction.errors.#{code}")}"
  end

  # What a finished run read and found (the stats of Glossary::Extraction):
  # its sources, "aus 3 von 5 Projekten" (the projects the starter could read
  # of all of the organisation) or the place given instead, its new proposals.
  def glossary_run_summary(stats, place: nil)
    stats = {} unless stats.is_a?(Hash)
    sources = stats['sources'].is_a?(Hash) ? stats['sources'].values.sum(&:to_i) : 0
    scope = 'views.organisations.glossary.runs'
    place ||= t("#{scope}.projects", count: stats['projects_total'].to_i, reached: stats['projects_reached'].to_i)
    [t("#{scope}.sources_read", count: sources), place,
     t("#{scope}.proposals_created", count: stats['proposals_created'].to_i)].join(', ')
  end

  # Where a run over one document read (K5c): "aus „Zorbel-Handbuch“" for a
  # reader of the document (the document policy scope, as for a source of a
  # proposal: glossary_readable_sources), by the title it has now; "aus einem
  # Dokument" for any other reader of the review list and for a document that
  # is gone. One query.
  def glossary_run_source(run)
    versions = glossary_readable_sources('DocumentVersion').where(id: run.document_version_id)
    title = Document.where(organisation_id: current_organisation.id, id: versions.select(:document_id))
                    .joins(:current_version).pick(DocumentVersion.arel_table[:title])
    scope = 'views.organisations.glossary.document_runs'
    title.present? ? t("#{scope}.source", title: title) : t("#{scope}.source_hidden")
  end

  # Whether a finished run stopped at one of its limits (stats truncated).
  def glossary_run_truncated?(run)
    run&.succeeded? && run.stats.is_a?(Hash) && run.stats['truncated'] == true
  end
end
