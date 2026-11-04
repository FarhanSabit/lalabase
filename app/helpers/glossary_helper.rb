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
end
