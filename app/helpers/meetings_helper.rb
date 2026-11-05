# frozen_string_literal: true

module MeetingsHelper
  # Below this width a meetings list shows either the list or the meeting, on
  # the phone layout. The row opener's number (FULL_PAGE_BELOW_PX in
  # lib/list_row/address.js): narrower, a lane would cover the list.
  LANE_FULL_PAGE_BELOW_PX = 1024

  # The choices of the inbox select in the organisation settings.
  def meeting_inbox_options(projects)
    projects.map do |project|
      label = project.archived? ? t('organisations.organisation_settings.show.meeting_inbox_archived_option', name: project.name) : project.name
      [label, project.id]
    end
  end

  def meeting_list_state(pagy: nil)
    state = Meetings::ListState.extract(params)
    state['page'] = pagy.page.to_s if pagy && state.key?('page')
    state
  end

  # What the lane's forms and links carry: the state of the list it was opened
  # from, and which list that is (list_context, Meetings::ListState). A save
  # redraws that list with that state. Rendered only by the two controllers of
  # MeetingList, whose helper answers the question.
  def meeting_lane_state
    meeting_list_state.merge(Meetings::ListState.context_query(organisation: meeting_organisation_list?))
  end

  # The "move" dialog (README_MODAL_PATTERN.md): the empty frame in the lane
  # head, one opening inside it (its token), and the trigger the focus returns to.
  def meeting_move_modal_id(meeting)
    "meeting-move-modal-#{meeting.id}"
  end

  def meeting_move_modal_instance_id(meeting, token)
    "#{meeting_move_modal_id(meeting)}-#{token}"
  end

  def meeting_move_trigger_id(meeting)
    "meeting-move-trigger-#{meeting.id}"
  end

  def meeting_list_hidden_fields
    safe_join(URI.decode_www_form(meeting_lane_state.to_query).map { |key, value| hidden_field_tag(key, value) })
  end

  # The categories of the meetings filter bar, every option from `scope`, the
  # meetings this reader may read in this list. projects: the options of the
  # category "Projekt", given only on the list of the whole organisation ("Alle
  # Meetings"); a project page has its project already.
  def meeting_filter_categories_json(scope:, organisation:, projects: nil)
    categories = []
    if projects
      categories << { key: 'project', label: t('smart_folders.fields.project'), icon: 'bi-folder',
                      type: 'special', allowed_operators: %w[or not],
                      options: projects.map { |project| { value: project.id, label: project.name } } }
    end
    categories << { key: 'participant', label: t('smart_folders.fields.participant'), icon: 'bi-people',
                    type: 'special', allowed_operators: %w[or and not],
                    options: MeetingParticipant.distinct_names_for_meetings(scope).map { |label, value| { value: value, label: label } } }
    creators = organisation.users.where(id: scope.select(:creator_id)).map { |user| { value: user.id, label: user.display_name } }
    categories << { key: 'creator', label: t('smart_folders.fields.creator'), icon: 'bi-person-badge',
                    type: 'special', allowed_operators: %w[or not], options: creators.sort_by { |option| option[:label].downcase } }
    %w[occurred_at created_at updated_at].each do |key|
      categories << { key: key, label: t("smart_folders.fields.#{key}"), icon: 'bi-calendar-event',
                      type: 'special', allowed_operators: %w[or],
                      options: SmartFolders::DatePresets::KEYS.map { |preset| { value: preset, label: t("views.organisations.tickets.index.date_preset_#{preset}") } } }
    end
    categories.to_json
  end

  def meeting_column_value(meeting, column)
    case column[:key]
    when 'title' then meeting.title
    when 'occurred_at', 'created_at', 'updated_at'
      display_time_split(meeting.public_send(column[:key]), user: current_user)
    when 'duration_minutes'
      t('views.organisations.meetings.shared.duration_minutes', count: meeting.duration_minutes) if meeting.duration_minutes
    when 'participants' then meeting.meeting_participants.map(&:display_name).join(', ')
    when 'project' then meeting.project.name
    when 'creator' then viewer_display_name(meeting.creator)
    end
  end

  # The wrapper of a meetings list page with its lane, the element that carries
  # the page's controllers: the project page and "Alle Meetings" share it
  # (doc/meetings_uebersicht_vereinheitlichen_plan.md, PR 3) and differ in their
  # address, their list frame and whether the lane knows a form state (the
  # project page's "+"). layout-toggle is the page's one writer of the address
  # (syncUrlFromFrame, the list state in list_filter_params); the row opener
  # and the ✕ write the lane part. The column picker's wiring is merged in by
  # the page (meeting_column_picker_data).
  def meeting_list_page_data(index_url:, list_frame_id:, viewport_mode:, selected:, lane_forms: [], new_form_open: false)
    detail_frame_id = Organisations::MeetingsController::DETAIL_FRAME_ID
    unresolved = meeting_unresolved_lane_params(selected: selected, lane_forms: lane_forms, new_form_open: new_form_open)
    # Which list the lane belongs to, added by layout-toggle to every request of
    # the lane at click and submit: also to a link rendered without it (a
    # broadcast, a section refresh). None on the project page.
    lane_context = Meetings::ListState.context_query(organisation: meeting_organisation_list?)
    {
      controller: 'layout-toggle hover-arrows index-page keyboard-navigation viewport column-picker',
      hover_arrows_layout_toggle_outlet: '.labor-layout-view',
      layout_toggle_list_frame_ids_value: [list_frame_id].to_json,
      layout_toggle_detail_frame_id_value: detail_frame_id,
      layout_toggle_content_selector_value: '.meeting-content',
      layout_toggle_selected_row_selector_value: '.selected-row[data-meeting-id]',
      layout_toggle_selection_params_value: %w[meeting_id].to_json,
      layout_toggle_list_filter_params_value: Meetings::ListState::KEYS.to_json,
      layout_toggle_storage_key_value: 'layoutState:meetings',
      layout_toggle_clear_detail_on_close_value: 'true',
      layout_toggle_lane_context_value: (lane_context.to_json if lane_context.any?),
      layout_toggle_unresolved_selection_value: (unresolved.to_json if unresolved.any?),
      viewport_breakpoint_value: LANE_FULL_PAGE_BELOW_PX,
      index_page_param_name_value: 'meeting_id',
      index_page_frame_id_value: detail_frame_id,
      index_page_content_selector_value: '.meeting-content',
      index_page_placeholder_id_value: 'meeting-display-placeholder',
      index_page_placeholder_class_value: 'ticket-placeholder px-4',
      index_page_placeholder_title_value: t('views.organisations.meetings.index.placeholder_title'),
      index_page_placeholder_body_value: t('views.organisations.meetings.index.placeholder_body'),
      index_page_selected_row_selector_value: '.selected-row[data-meeting-id]',
      index_page_skip_if_content_visible_value: 'true',
      viewport_current_mode_value: viewport_mode,
      index_url: index_url,
      lane_params: lane_params_json(selection: %w[meeting_id], form: lane_forms)
    }.compact
  end

  # The lane parameters of this visit the server did not open: a meeting_id it
  # could not resolve (deleted, unknown, unreadable, another project's) and a
  # new form it did not render. layout-toggle takes them out of the address
  # before anything reads it, so the page stays the list instead of opening an
  # empty lane. Name and value, so it never drops a selection made since.
  def meeting_unresolved_lane_params(selected:, lane_forms:, new_form_open:)
    unresolved = {}
    meeting_id = params[:meeting_id]
    unresolved['meeting_id'] = meeting_id if meeting_id.is_a?(String) && meeting_id.present? && selected.nil?
    new_form = params[:new]
    unresolved['new'] = new_form if lane_forms.include?('new') && new_form.is_a?(String) && new_form.present? && !new_form_open
    unresolved
  end

  # The placeholders column_picker_controller fills in itself, passed through
  # the translation as they are.
  COLUMN_PICKER_NAME_TOKEN = '%{name}' # rubocop:disable Style/FormatStringToken
  COLUMN_PICKER_POSITION_TOKEN = '%{position}' # rubocop:disable Style/FormatStringToken

  # The column picker's wiring on a meetings list page, the element that
  # carries data-controller="column-picker": where a change is saved, which
  # frame it reloads, and its words. project nil is "Alle Meetings". A change
  # goes into the open saved view, else into the base view of this list.
  def meeting_column_picker_data(organisation:, project:, active_view:, frame_id:)
    {
      column_picker_frame_value: frame_id,
      column_picker_required_value: ViewConfiguration.required_columns_for('meetings').to_json,
      column_picker_fixed_width_value: ViewConfiguration::COLUMN_MIN_WIDTH_PX['title'],
      column_picker_save_url_value: meeting_columns_save_url(organisation: organisation, project: project, active_view: active_view),
      # Only an org-wide TICKET view needs to name a project; a meeting view
      # belongs to its list, so none is sent from "Alle Meetings".
      column_picker_project_id_value: project&.id,
      column_picker_editable_value: (active_view.nil? || policy(active_view).update?).to_s,
      column_picker_error_label_value: t('components.column_picker.save_failed'),
      column_picker_moved_template_value: t('components.column_picker.moved', name: COLUMN_PICKER_NAME_TOKEN,
                                                                              position: COLUMN_PICKER_POSITION_TOKEN),
      column_picker_pin_label_on_value: t('components.column_picker.pin_label_on', name: COLUMN_PICKER_NAME_TOKEN),
      column_picker_pin_label_off_value: t('components.column_picker.pin_label_off', name: COLUMN_PICKER_NAME_TOKEN),
      column_picker_pin_title_on_value: t('components.column_picker.pinned'),
      column_picker_pin_title_off_value: t('components.column_picker.pin')
    }
  end

  def meeting_columns_save_url(organisation:, project:, active_view:)
    return columns_organisation_smart_folder_path(organisation, active_view) if active_view
    return columns_organisation_meetings_view_configuration_path(organisation) unless project

    columns_organisation_project_view_configuration_path(organisation, project, view_type: 'meetings')
  end

  # "für alle Ansichten übernehmen": the base view of this list and the
  # reader's own views of it (Actors::ApplyColumnsToViews).
  def meeting_columns_apply_all_url(organisation:, project:)
    return apply_columns_to_all_organisation_meetings_view_configuration_path(organisation) unless project

    apply_columns_to_all_organisation_project_view_configuration_path(organisation, project, view_type: 'meetings')
  end

  # A column head that sorts its list: base_path is the list's address (the
  # project page or "Alle Meetings"), frame_id the frame the list lives in. The
  # link keeps the list state and the open meeting, and starts again at page 1.
  def meeting_sort_link(column, base_path:, frame_id:)
    return column[:label] unless Meetings::ListQuery::SORT_COLUMNS.include?(column[:key])

    sort = params[:sort].respond_to?(:[]) && params[:sort].respond_to?(:permit) ? params[:sort] : {}
    direction = sort['column'] == column[:key] && sort['direction'] == 'asc' ? 'desc' : 'asc'
    query = meeting_list_state.except('page').merge(params.permit(:meeting_id, :new).to_h).merge('sort' => { column: column[:key], direction: direction })
    link_to column[:label], "#{base_path}?#{query.to_query}", data: { turbo_frame: frame_id }
  end

  # DOM id of the "Verknüpfte Tickets" turbo-frame on the meeting detail
  # (Gespräche Slice 3).
  #
  # This is a SHARED CONTRACT with exactly two callers that must agree:
  #   1. app/views/organisations/meetings/_ticket_links_section.html.erb wraps the
  #      section body in <turbo-frame id="<this>">.
  #   2. Organisations::MeetingTicketLinksController replaces THIS id after a link
  #      create/destroy (turbo_stream.replace).
  #
  # It lives here, in one place, on purpose: if the section's frame id and the
  # controller's replace target ever drift apart, the in-place refresh silently
  # stops working with NO error — the kind of bug a duplicated literal invites.
  def meeting_ticket_links_frame_id(meeting)
    dom_id(meeting, :ticket_links)
  end

  # DOM id of the analyses RESULTS turbo-frame on the meeting detail (Gespräche Slice
  # 7a). SHARED CONTRACT between _analyses_results.html.erb (which wraps the result list
  # in this frame) and MeetingAnalysesController (which replaces THIS id after a
  # create/flip/destroy/retry). One place, so the two cannot drift. The results live in
  # the meeting flow; creation now happens in the assistant.
  def meeting_analyses_frame_id(meeting)
    dom_id(meeting, :analyses)
  end

  # Inner result-list target used by creator-scoped completion broadcasts. Keeping
  # the assistant entry outside this target prevents an old queued analysis job
  # from removing the current "Analyse erstellen" action when it finishes.
  def meeting_analyses_list_id(meeting)
    dom_id(meeting, :analyses_list)
  end

  # DOM id of the "Ticket-Vorschläge" turbo-frame on the meeting detail (Slice 8).
  # SHARED CONTRACT between _ticket_suggestions_section.html.erb and
  # MeetingTicketSuggestionsController (which replaces THIS id after run/accept/
  # dismiss). One place, so the section wrapper and the replace target cannot drift.
  def meeting_ticket_suggestions_frame_id(meeting)
    dom_id(meeting, :ticket_suggestions)
  end

  # The analyses of `meeting` the given user may see (public ∪ own private), ready
  # for the section partial (creator + prompt eager-loaded, newest first). Visibility
  # filtering happens HERE, in the caller (E21 / Slice-4 lesson) — the section partial
  # stays a pure function of its locals and never touches current_user.
  def visible_meeting_analyses(meeting, user = current_user)
    MeetingAnalysis.visible_for(meeting, user)
  end

  # Prepares a meeting's raw notes/transcript (Markdown pasted from AI transcript
  # tools) for display: strip a leading YAML frontmatter block (metadata noise) and,
  # for a transcript, bold the speaker labels. Storage is untouched; the edit textarea
  # still shows the raw Markdown incl. the frontmatter block. Used for BOTH the notes
  # and the transcript section (one path, no drift).
  #
  # Returns MARKDOWN, not HTML: the render belongs to Neo::MarkdownPreviewComponent,
  # which every display site goes through — so the two-layer SafeMarkdown pass
  # (Redcarpet + allowlist sanitise, NO <img>, meetings are PII-dense) cannot be
  # forgotten at a call site. `speakers` has to run BETWEEN the frontmatter strip and
  # that render, which is why it is a parameter here rather than a second helper.
  def meeting_markdown_source(text, speakers: nil)
    body = Meeting.strip_frontmatter(text)
    return body if speakers.blank?

    Meetings::SpeakerMarkup.call(text: body, participant_names: speakers)
  end

  # The transcript, with its speaker turns bolded against the meeting's own
  # participant list. The caller passes the participants it ALREADY loaded for the
  # header chips — never re-query here, that would be one extra query per render.
  def meeting_transcript_source(meeting, participants)
    meeting_markdown_source(meeting.transcript, speakers: participants.map(&:display_name))
  end

  # The HTML the transcript block of the page holds: the component's own render
  # of meeting_transcript_source. Meetings::TranscriptMark reads the text the
  # browser shows out of it, to find a mark of the reader in the stored
  # transcript (K4b); rendered the same way, the two texts are the same.
  def meeting_transcript_html(meeting, participants)
    Neo::MarkdownPreviewComponent.new(markdown: meeting_transcript_source(meeting, participants)).rendered_markdown
  end

  # Plain-text source for the header "Abriss": the AI summary if present, else the
  # notes. Both run through the SAME path — frontmatter strip + StripDown (markdown →
  # plain text) — so a leading metadata block and "##"/"**" syntax never surface as
  # raw characters in the excerpt. The summary is Markdown too (the LLM answers with
  # "**Kopf:**" / "- Punkt"), so StripDown does real work on BOTH branches; the full
  # rendered version lives in _summary_section via Neo::MarkdownPreviewComponent.
  # Truncation stays at the call site (line-clamp + truncate length).
  def meeting_excerpt_source(meeting)
    raw = meeting.generated_summary.presence || meeting.notes.presence
    return '' if raw.blank?

    Documentation::PlainTextRenderer.new.render(Meeting.strip_frontmatter(raw))
  end

  # NeoTag optik per participant type (Nachtrag: Teilnehmer-Kennzeichnung).
  # ONE mapping, used by BOTH chip render sites — the form partial
  # (_participant_chip, also cloned into the JS <template>s) and the read-only
  # detail header — so the two look-and-feels can never drift apart. Icons are
  # Bootstrap Icon names (NeoTagComponent prepends "bi-").
  PARTICIPANT_CHIP_STYLES = {
    project_member: { variant: :primary, icon: 'person-check' },
    org_member: { variant: :info, icon: 'person' },
    external: { variant: :neutral, icon: 'person-dash' }
  }.freeze

  # Classifies a participant into one of three states from the meeting's linked
  # user and the project's permitted_user_ids. The caller passes a Set loaded ONCE
  # per render (never one query per chip → no N+1):
  #   :project_member — linked user WITH an explicit ProjectPermission on the project
  #   :org_member     — linked user WITHOUT project access (org member only)
  #   :external       — no linked user (name-only participant)
  def meeting_participant_type(participant, permitted_user_ids)
    return :external if participant.user_id.blank?

    permitted_user_ids.include?(participant.user_id) ? :project_member : :org_member
  end

  # Resolves a participant type to its chip optik (variant + icon) plus a
  # translated tooltip. Unknown types fall back to the external style rather than
  # raising, so a future type can never blow up a render.
  def meeting_participant_chip_style(participant_type)
    type = participant_type.to_sym
    style = PARTICIPANT_CHIP_STYLES.fetch(type, PARTICIPANT_CHIP_STYLES[:external])
    style.merge(title: t("views.organisations.meetings.shared.participant_type.#{type}",
                         default: t('views.organisations.meetings.shared.participant_type.external')))
  end

  # NeoInfoTag optik per search/index status (Meeting-Such-Status). ONE mapping,
  # used by BOTH badge render sites — the detail-header badge (_search_status)
  # and the compact list column (_meeting_row) — so the two can never drift
  # apart. Icons are Bootstrap Icon names (NeoInfoTagComponent prepends "bi-").
  SEARCH_STATUS_STYLES = {
    searchable: { variant: :success, icon: 'search' },
    processing: { variant: :processing, icon: 'clock-fill', animated: true },
    waiting_ai: { variant: :warning, icon: 'exclamation-circle' },
    failed: { variant: :danger, icon: 'exclamation-triangle-fill' },
    off: { variant: :neutral, icon: 'slash-circle' }
  }.freeze

  # Derives the search/index status of a meeting from create_embeddings and
  # embeddings_creation_flag. Rendered only from the detail badge
  # (_search_status), which always holds a full meeting row (find_selected_meeting
  # / the toggle stream's reload), so every attribute is available; the badge
  # reads embedding_creation_error itself for the error text. Flag semantics
  # (EmbeddingProcessingService): nil = pending/never attempted, true = indexed,
  # false = errored. ai_available is passed in, computed ONCE per render site.
  def meeting_search_status(meeting, ai_available:)
    return :off unless meeting.create_embeddings?

    case meeting.embeddings_creation_flag
    when true then :searchable
    when false then :failed
    else ai_available ? :processing : :waiting_ai
    end
  end

  # Resolves a search status to its badge optik (variant + icon + animated flag).
  # Unknown statuses fall back to :off rather than raising, mirroring
  # meeting_participant_chip_style — a future status can never blow up a render.
  def meeting_search_status_style(status)
    SEARCH_STATUS_STYLES.fetch(status.to_sym, SEARCH_STATUS_STYLES[:off])
  end

  # data-html content for a participant <option> in the SlimSelect field: a type
  # icon (project member / external) plus the name. SlimSelect renders this as the
  # dropdown option's innerHTML (tokens stay plain text — they use option.text), so
  # the name MUST be html-escaped HERE for that innerHTML context; the attribute-
  # escaping ERB adds at the render site only protects the attribute context.
  # Returns a plain (non-safe) String on purpose so ERB still attribute-escapes it.
  def meeting_participant_option_html(type, label)
    icon = type.to_sym == :member ? 'person-check' : 'person-dash'
    %(<i class="bi bi-#{icon}" aria-hidden="true"></i> #{ERB::Util.html_escape(label)})
  end

  # Live participant-claim hints for the current user + organisation, memoized per
  # request (Nachtrag: Teilnehmer-Claim). Lazy on purpose: computed only when a full
  # index actually renders the banner — every :index render path (index, standalone
  # show, new, failed-form) shows the same hint, while the turbo-frame meeting-detail
  # path returns before rendering :index and never calls this, so it pays no query.
  # Single wiring shared by the project and org-wide index.
  def meeting_claim_matches
    @meeting_claim_matches ||= Meetings::ParticipantClaimMatches.new(
      user: current_user, organisation: current_organisation
    ).call
  end
end
