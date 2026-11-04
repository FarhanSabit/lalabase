# frozen_string_literal: true

# The glossary page (Organisations::GlossaryController): the wiring of its list
# and lane, the words of a term, and what the page shows of a heard form.
#
# What a reader with view_glossary sees (E3): every term with its heard forms,
# speakers and projects, also from projects they cannot read. Two things need
# more: the title and the link of a meeting (read access to that meeting,
# glossary_readable_meetings) and the link to a person (view_people and a row
# the reader may see, glossary_speaker_url).
module GlossaryHelper
  # The one thing a row opens in the lane.
  SELECTION_PARAMS = %w[term_id].freeze
  # The distinct heard forms a row names before "…".
  ROW_FORMS_SHOWN = 4

  # The page wrapper's data: the lane (layout-toggle, index-page) and the
  # desktop/mobile switch, the controllers of the people page
  # (people_page_data).
  def glossary_page_data(viewport_mode:, selected:, form_open:)
    detail_frame_id = Organisations::GlossaryController::DETAIL_FRAME_ID
    unresolved = glossary_unresolved_lane_params(selected: selected, form_open: form_open)
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
      index_page_placeholder_title_value: t('views.organisations.glossary.index.placeholder_title'),
      index_page_placeholder_body_value: t('views.organisations.glossary.index.placeholder_body'),
      index_page_selected_row_selector_value: '.selected-row[data-glossary-row]',
      index_page_skip_if_content_visible_value: 'true',
      index_url: organisation_glossary_terms_path(current_organisation),
      lane_params: lane_params_json(selection: SELECTION_PARAMS, form: %w[new])
    }.compact
  end

  # Lane parameters of this visit the server did not open (an unknown term, a
  # form the reader may not open). layout-toggle takes them out of the
  # address, so the page stays the list.
  def glossary_unresolved_lane_params(selected:, form_open:)
    unresolved = {}
    term_id = params[:term_id]
    unresolved['term_id'] = term_id if term_id.is_a?(String) && term_id.present? && selected.nil?
    new_state = params[:new]
    unresolved['new'] = new_state if new_state.is_a?(String) && new_state.present? && !form_open
    unresolved
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
  # names only (links live in the lane).
  def glossary_row_origin(term)
    corrections = term.term_corrections
    speakers = corrections.filter_map { |correction| glossary_speaker_name(correction) }.uniq
    projects = corrections.filter_map { |correction| correction.project&.name }.uniq
    [speakers.to_sentence.presence, projects.join(', ').presence].compact.join(' · ')
  end

  # The speaker of a heard form as a name: a member through the reader's name
  # display setting, a person of the directory as written there; nil without
  # a speaker (none linked, or deleted).
  def glossary_speaker_name(correction)
    if correction.user then viewer_display_name(correction.user)
    elsif correction.person then correction.person.name
    end
  end

  # Where the name of a speaker links to on the people page, or nil: only
  # with view_people, and only for a row or a member the reader may see
  # there (PersonPolicy::Scope, MembershipPolicy::Scope), so the link never
  # opens an empty lane.
  def glossary_speaker_url(correction)
    return unless glossary_people_linkable?

    if correction.person_id && glossary_visible_person_ids.include?(correction.person_id)
      organisation_people_path(current_organisation, person_id: correction.person_id)
    elsif correction.user_id && glossary_visible_member_ids.include?(correction.user_id)
      organisation_people_path(current_organisation, member_id: correction.user_id)
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
end
