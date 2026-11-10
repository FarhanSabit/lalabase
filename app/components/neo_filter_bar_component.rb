# frozen_string_literal: true

# The filter bar rebuilt along the Belegungstabelle (doc/filterleiste_s1_s4_plan.md).
# the old bar and FilterBarHelper#filter_bar_component_class picks one of the two.
# Deliberate duplication for days, not a pattern: the copy goes with the flag.

class NeoFilterBarComponent < ViewComponent::Base
  # A tool of the view that is not the bar's own: today the column picker's
  # trigger (20a, S2). It belongs in this row because columns belong to the
  # view, like the conditions do, and it leaves the table header where it was
  # holding a column's width without ever showing data. The bar knows nothing
  # about columns; the call site puts its tool in.
  renders_one :view_tool
  # The selection row of a list that can tick rows (doc/ticket_bulk_edit_plan.md,
  # D2): rendered hidden right after the sentence frame, shown by the list's
  # selection controller in the sentence's place while something is ticked.
  # Both rows are information about the same list, so they share one place.
  renders_one :selection_row

  # (There is no :trailing_tool slot any more. It held "Liste | Kanban", and
  # that control moved to the PAGE head on 07.09.2026: it decides whether there
  # is a table at all - no columns, no lane - so it belongs with the title, the
  # help and the new-ticket button, not among the tools that narrow a list.)

  SEARCH_MODES = %w[title_only content full].freeze

  # The address param AND the category key of a built-in view (S7): today the
  # knowledge type (?type=note, the condition Typ: <key>). The same word lives
  # in lib/filter_bar/url_builder.js as BUILTIN_VIEW_PARAM; a second kind of
  # built-in view gets its own name in both places.
  BUILTIN_VIEW_PARAM = 'type'

  # -- context-free component, all values come from the call site
  def initialize(
    smart_folders:,
    url:,
    frame_id:,
    i18n_scope:,
    all_items_label:,
    smart_folder_context_type:,
    smart_folder_return_to:,
    organisation:,
    project: nil,
    active_smart_folder: nil,
    active_view_permissions: {},
    dissolver_result: nil,
    ad_hoc_filters: {},
    ad_hoc_operators: {},
    dropped_categories: [],
    proposals: [],
    filter_categories_json: '[]',
    search_value: nil,
    search_mode: 'content',
    builtin_views: [],
    type_targets: {},
    type_badge_icons: {},
    save_target_object_type: nil,
    current_user_id: nil,
    search_modes: SEARCH_MODES,
    return_params: {},
    return_keys: [],
    keyboard_navigation: false
  )
    @smart_folders = smart_folders || []
    @url = url
    @frame_id = frame_id
    @i18n_scope = i18n_scope
    @all_items_label = all_items_label
    @smart_folder_context_type = smart_folder_context_type
    @smart_folder_return_to = smart_folder_return_to
    @active_smart_folder = active_smart_folder
    @active_view_permissions = active_view_permissions || {}
    @dissolver_result = dissolver_result
    @ad_hoc_filters = ad_hoc_filters || {}
    @ad_hoc_operators = ad_hoc_operators || {}
    @dropped_categories = Array(dropped_categories).map(&:to_s)
    @proposals = Array(proposals)
    @filter_categories_json = filter_categories_json
    @current_user_id = current_user_id
    @search_value = search_value
    @search_mode = search_mode || 'content'
    # The list's project; nil on a list of the whole organisation ("Alle
    # Meetings"). Then no URL of the bar names a project, and a view saved from
    # it belongs to the organisation-wide list.
    @project = project
    @organisation = organisation
    @builtin_views = Array(builtin_views)
    @type_targets = type_targets || {}
    @type_badge_icons = type_badge_icons || {}
    @save_target_object_type = save_target_object_type
    @search_modes = search_modes
    @return_params = return_params
    @return_keys = return_keys
    # The search field is the page's keyboard_navigation search target: arrow
    # down enters the rows. For lists whose rows hold no link of their own.
    @keyboard_navigation = keyboard_navigation
  end

  private

  attr_reader :smart_folders, :url, :frame_id, :i18n_scope, :all_items_label,
              :smart_folder_context_type, :smart_folder_return_to,
              :active_smart_folder, :active_view_permissions, :dissolver_result,
              :ad_hoc_filters, :ad_hoc_operators, :dropped_categories, :proposals, :filter_categories_json,
              :search_value, :search_mode, :project, :organisation,
              :builtin_views, :type_targets, :type_badge_icons, :save_target_object_type, :search_modes,
              :current_user_id, :return_params, :return_keys, :keyboard_navigation

  def scoped_t(key, **options)
    t("#{i18n_scope}.#{key}", **options)
  end

  def has_active_ad_hoc_filters?
    ad_hoc_filters.any? { |_k, v| Array(v).any?(&:present?) }
  end

  def smart_folder_active?(folder)
    active_smart_folder&.id == folder.id
  end

  def search_mode_icon
    case search_mode
    when 'title_only' then 'bi-search'
    when 'full' then 'bi-binoculars'
    else 'bi-search'
    end
  end

  # Whether the condition row has anything to show on the first paint. The
  # controller decides again from the same inputs once it has rendered the
  # pills; this only keeps the server-rendered page from jumping.
  def has_any_chips?
    return true if has_active_ad_hoc_filters?
    return false unless dissolver_result

    saved_categories = (dissolver_result.ad_hoc_filters || {}).keys.map(&:to_s) - dropped_categories
    saved_categories.any? || dissolver_result.complex_rules.any?
  end

  # === The sentence, the resting state of the conditions (20a, S1) ===

  # The conditions as the reader sees them: the saved ones of the active view,
  # overridden per category by the address, minus the ones the reader emptied.
  # The same rule lives in lib/filter_bar/change_set.js, which answers for the
  # pills while they are being edited; here it answers for the sentence.
  def effective_conditions
    saved = dissolver_result&.dissolvable? ? (dissolver_result.ad_hoc_filters || {}).stringify_keys : {}
    saved_ops = dissolver_result&.dissolvable? ? (dissolver_result.ad_hoc_operators || {}).stringify_keys : {}
    filters = saved.except(*dropped_categories).merge(ad_hoc_filters.stringify_keys)
    operators = saved_ops.except(*dropped_categories).merge(ad_hoc_operators.stringify_keys)

    filters.filter_map do |category, values|
      values = Array(values).reject(&:blank?)
      next if values.empty?

      condition_for(category, values, operators[category])
    end
  end

  # The word of the "+ Filter" trigger when it stands as a sign (tight head,
  # components/filter_bar.css): "Filter" with nothing set, "Filter · 1
  # Bedingung", "Filter · 3 Bedingungen". Written here for the first paint;
  # lib/filter_bar/change_sentence.js (filterSignTitle) answers for every
  # state render after it, from the same three forms, which travel as labels.
  # Two writers on purpose: the count changes without a page load.
  def filter_sign_title
    @filter_sign_title ||= I18n.t('components.filter_bar.filter_sign_title', count: effective_conditions.size)
  end

  # One condition in the shape the grammar wants: the field's own label, and
  # every value with the word it is shown as. A user is a UUID in the address
  # and a name in the sentence.
  def condition_for(category, values, operator)
    definition = parsed_categories.find { |cat| cat['key'].to_s == category.to_s }
    options = (definition&.dig('options') || []).index_by { |option| option['value'].to_s }

    {
      category: category.to_s,
      label: definition&.dig('label') || category.to_s.humanize,
      operator: operator.presence || 'or',
      values: values.map { |value| { value: value, label: options.dig(value.to_s, 'label') || user_labels[value.to_s] || value.to_s } }
    }
  end

  def user_labels
    @user_labels ||= JSON.parse(value_labels_json)
  rescue JSON::ParserError
    @user_labels = {}
  end

  def filter_sentence
    @filter_sentence ||= FilterSentenceService.call(
      subject: scoped_t('filter_bar.sentence_subject'),
      conditions: effective_conditions,
      locale: I18n.locale,
      me_value: current_user_id
    )
  end

  # F4 in the sentence: the value is the only target in it, and it carries no
  # underline, only ink against the muted binding words. The pieces are joined
  # WITHOUT whitespace between them, or the template's own line breaks would
  # put a space in front of every full stop.
  # The prose itself: muted binding words, a measure that stays readable, and
  # a wrap that does not leave one word alone on the last line.
  # The sentence is the SECOND LINE of the tab row's surface, not a band of its
  # own (designer, 07.09.2026). So: no line above it (the tab row already has
  # one, and a second one right below is a doubling), no line below it (the
  # surface's own bottom edge separates it from the table), no tint, no border,
  # no radius. It is text in a zone, not an object.
  #
  # ps-3 puts its first word under the FIRST TAB's word rather than at the
  # page edge. Two left edges in two consecutive lines is exactly what the
  # rest of this page spent the day getting rid of.
  #
  # 13px/1.55 and --muted, because it is an INFORMATION: the navigation above it
  # and the table below it carry the page, this only says what one is looking
  # at. max-w-74ch keeps it readable on a wide page - a sentence one skims must
  # not run over 1000px - and text-wrap:pretty stops a single word from being
  # left alone on the last line.
  #
  # line-clamp-3 is the answer for an open lane: the surface ends at the column
  # boundary there and the sentence wraps early. Three lines, then an ellipsis,
  # and the whole sentence in the title.
  SENTENCE_PROSE_CLASSES = 'max-w-[74ch] ps-3 pt-2 pb-1 text-[13px] leading-[1.55] text-muted ' \
                           '[text-wrap:pretty] line-clamp-3'
  SENTENCE_VALUE_CLASSES = '-mx-0.5 px-0.5 rounded text-heading hover:bg-cream-200 transition-colors ' \
                           'focus:outline-none focus-visible:ring-2 focus-visible:ring-ink'

  def sentence_html
    safe_join(filter_sentence.segments.map { |segment| sentence_segment(segment) })
  end

  def sentence_segment(segment)
    return segment.text unless segment.kind == :value

    tag.button(segment.text, type: 'button',
                             class: SENTENCE_VALUE_CLASSES,
                             title: t('components.filter_bar.change_value'),
                             data: { action: 'click->filter-bar#openConditionFromSentence', category: segment.category })
  end

  # The sentence lives in its own frame: an edit does not rebuild it, leaving
  # the edit does. One request per editing session instead of one per tick.
  def sentence_frame_id
    "#{frame_id}_sentence"
  end

  # How many views stand in the row before the rest folds away. A number, not a
  # measurement: measuring needs JavaScript, and a tab that appears after the
  # page has settled is worse than one that was never promised.
  VISIBLE_TABS = 5

  # The tabs of row 1 (F10): the base view first, then the built-in views
  # (knowledge: one per type, S7), then every saved view the policy scope
  # allows, in the order the controller loaded them (by name). url is the
  # server-built address of the view, so a tab works without JavaScript; the
  # Stimulus action only adds the typed search to it.
  def views
    @views ||= [base_view] + builtin_views.map { |view| builtin_tab(view) } +
               smart_folders.map { |folder| folder_view(folder) }
  end

  # What stands in the row (20a, D1). A tab you have to wipe sideways is worse
  # to reach than a list with a count, so the rest folds into "N weitere"
  # instead of scrolling out of sight. The active view never folds: it carries
  # the underline, the chevron and the amber dot, and a view you cannot see is
  # a view you cannot tell is yours.
  def visible_views
    return views if views.length <= VISIBLE_TABS

    shown = views.first(VISIBLE_TABS)
    return shown if shown.any? { |view| view[:active] }

    shown[0..-2] + [views.find { |view| view[:active] }].compact
  end

  def overflow_views
    views - visible_views
  end

  def base_view
    { id: nil, key: nil, name: all_items_label, url: base_url, active: active_smart_folder.nil? && active_builtin_view.nil?, badge_icon: nil }
  end

  # A built-in view is fixed: no rename, share or delete, and its menu holds
  # only the expert filter. Its condition (Typ: <key>) is the dissolver result
  # the controller hands in, so the pill row and the save row work on it.
  def builtin_tab(view)
    { id: nil, key: view[:key].to_s, name: view[:name], url: view_url(BUILTIN_VIEW_PARAM => view[:key]), active: view[:active] == true, badge_icon: nil }
  end

  def folder_view(folder)
    {
      id: folder.id,
      key: nil,
      name: folder.name,
      url: view_url('smart_folder_id' => folder.id),
      active: smart_folder_active?(folder),
      badge_icon: type_badge_icon(folder)
    }
  end

  def active_builtin_view
    @active_builtin_view ||= builtin_views.find { |view| view[:active] == true }
  end

  def view_key
    active_builtin_view ? active_builtin_view[:key].to_s : ''
  end

  # The address every view is built from: the bar's url without a view of
  # its own (a ?type= a caller may still hand in belongs to the built-in view,
  # not to the list). The url is the same for every tab, so it is parsed once.
  def base_url
    view_url({})
  end

  def view_url(view_params)
    uri = base_uri.dup
    query = base_query.except(BUILTIN_VIEW_PARAM, 'smart_folder_id').merge(view_params)
    uri.query = query.empty? ? nil : query.to_query
    uri.to_s
  end

  def base_uri
    @base_uri ||= URI.parse(url)
  end

  def base_query
    @base_query ||= Rack::Utils.parse_nested_query(base_uri.query)
  end

  # F10 with F6's no-surface variant: the active tab carries a 2 px ink line and
  # weight, the inactive one the same line in transparent so nothing jumps. The
  # focus ring is inset: the strip clips at the tab's edges (overflow-x-auto),
  # so a ring outside the box would never be seen.
  # ⚠️ `rounded-t-sm`, not `rounded-sm`. The active tab is TWO elements side by
  # side - the link with the word and the chevron button that opens the view
  # menu - and both carry the ink underline so it reads as one line. With a
  # radius on all four corners, two rounded bottom corners meet at the seam and
  # the line visibly kinks there. The radius exists for the focus ring, which
  # only needs the top.
  TAB_BASE_CLASSES = 'h-8 px-3 text-sm inline-flex items-center gap-1.5 whitespace-nowrap border-b-2 ' \
                     'rounded-t-sm transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ink'
  TAB_ACTIVE_CLASSES = 'border-ink font-semibold text-heading'
  TAB_INACTIVE_CLASSES = 'border-transparent text-muted hover:text-heading'
  # The chevron beside the active tab (designer, 09.09.2026): its own tile of
  # 28 x 28, the glyph centred by grid, hover and keyboard focus in the
  # neighbours' hover tone with ink, no underline of its own.
  CHEVRON_TILE_CLASSES = 'grid place-items-center h-7 w-7 rounded-md text-muted hover:bg-cream-100 hover:text-ink ' \
                         'transition-colors focus:outline-none focus-visible:bg-cream-100 focus-visible:text-ink ' \
                         'focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ink'

  def tab_classes(active)
    "#{TAB_BASE_CLASSES} #{active ? TAB_ACTIVE_CLASSES : TAB_INACTIVE_CLASSES}"
  end

  # Save form posts to this URL; return_to rides along as a query param. The
  # target type: on a list with built-in type views (knowledge, S7) the bar
  # derives it from the type condition and sends it as a form field; anywhere
  # else the caller's save_target_object_type (PE-B) goes with the URL.
  def save_smart_folder_path
    options = {}
    options[:target_object_type] = save_target_object_type if save_target_object_type.present? && builtin_views.empty?
    options[:return_to] = smart_folder_return_to if save_target_object_type.present? || builtin_views.any?
    helpers.create_from_filters_organisation_smart_folders_path(organisation, options)
  end

  # Badge icon for a folder pill (mixed folder lists, PE-B);
  # empty without configured type_badge_icons (e.g. tickets context).
  def type_badge_icon(folder)
    type_badge_icons[folder.target_object_type]
  end

  # Search-depth options, filtered to the modes supported by the context
  def search_depth_options
    [
      ['title_only', 'bi-search', scoped_t('filter_bar.search_depth_quick'), scoped_t('filter_bar.search_depth_title_only')],
      ['content', 'bi-search', scoped_t('filter_bar.search_depth_standard'), scoped_t('filter_bar.search_depth_title_content')],
      ['full', 'bi-binoculars', scoped_t('filter_bar.search_depth_deep'), scoped_t('filter_bar.search_depth_everything')]
    ].select { |mode, _icon, _label, _description| search_modes.include?(mode) }
  end

  def show_search_depth_selector?
    search_modes.size > 1
  end

  def new_smart_folder_url
    helpers.new_organisation_smart_folder_path(
      organisation,
      project_id: project&.id,
      context_type: smart_folder_context_type,
      modal: true,
      return_to: smart_folder_return_to,
      list_context: return_params.presence
    )
  end

  # The menu at the active tab (S5): everything one can do with the view on
  # screen. Which entries appear is decided at the call site
  # (FilterBarHelper#filter_bar_view_permissions, the policy's answers for the
  # ONE active folder); the base view knows only the expert filter, which
  # there starts a new folder with the list's context type. The expert filter
  # opens the existing modal unchanged; only its door moved here.
  def view_menu
    @view_menu ||= build_view_menu
  end

  def build_view_menu
    if active_smart_folder
      {
        name: active_smart_folder.name,
        rename_url: (helpers.rename_organisation_smart_folder_path(organisation, active_smart_folder) if active_view_permissions[:rename]),
        share_url: (helpers.share_organisation_smart_folder_path(organisation, active_smart_folder) if active_view_permissions[:share]),
        # The way that does not overwrite a view somebody else uses (20a, § 4).
        # Anyone who may see a folder may copy it; the copy belongs to them.
        duplicate_url: helpers.clone_organisation_smart_folder_path(organisation, active_smart_folder),
        expert_url: helpers.edit_organisation_smart_folder_path(organisation, active_smart_folder, modal: true, return_to: smart_folder_return_to, project_id: project&.id, list_context: return_params.presence),
        delete_url: (helpers.organisation_smart_folder_path(organisation, active_smart_folder) if active_view_permissions[:delete])
      }
    else
      name = active_builtin_view ? active_builtin_view[:name] : all_items_label
      { name: name, rename_url: nil, share_url: nil, duplicate_url: nil, expert_url: new_smart_folder_url, delete_url: nil }
    end
  end

  # A proposal from outside (F31, S6): { source:, category:, value:, label: }.
  # Never a pill, because a pill in the condition row claims it already
  # filters. The category's name comes from the same list the pills use, so
  # the row and the pill it becomes never name a category differently.
  def proposal_rows
    @proposal_rows ||= build_proposal_rows
  end

  def build_proposal_rows
    proposals.filter_map do |proposal|
      category = proposal[:category].to_s
      next if category.blank? || proposal[:value].to_s.blank?

      {
        source: proposal[:source].to_s,
        category: category,
        value: proposal[:value].to_s,
        condition: "#{category_label(category)}: #{proposal[:label].presence || proposal[:value]}"
      }
    end
  end

  def category_label(key)
    categories_by_key.fetch(key, key)
  end

  def categories_by_key
    @categories_by_key ||= parsed_categories.to_h { |cat| [cat['key'].to_s, cat['label'].to_s] }
  end

  def parsed_categories
    @parsed_categories ||= JSON.parse(filter_categories_json)
  rescue JSON::ParserError
    @parsed_categories = []
  end

  # What "+ Filter" may offer. A folder with a single-type target does not
  # offer the type category (S7): the target is immutable and never a pill
  # (D4), so a type condition there would contradict it, and the folder could
  # not take it as a rule. The base view, a built-in view and a folder of all
  # types do offer it; saving from those makes the type the new folder's target.
  def categories_json_for_bar
    return filter_categories_json unless active_smart_folder && active_smart_folder.target_object_type != 'All'

    parsed_categories.reject { |cat| cat['key'].to_s == BUILTIN_VIEW_PARAM }.to_json
  end

  # F33: a row in a floating list.
  MENU_ROW_CLASSES = 'w-full text-left px-2 py-1.5 text-xs text-body hover:bg-cream-100 rounded flex items-center gap-2 ' \
                     'transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ink'

  # F4: a word that acts, underlined in ink. The rename form and the proposal
  # row use it for both of their words; the save row (lib/filter_bar/save_row.js)
  # renders the same form at text-sm.
  TEXT_ACTION_CLASSES = 'text-xs font-medium text-body underline underline-offset-2 hover:text-heading ' \
                        'focus:outline-none focus-visible:ring-1 focus-visible:ring-ink rounded'

  # An action of a selection row (the ticket list's, the inbox's): the word
  # above, kept on one line, and quiet while it is disabled.
  SELECTION_ACTION_CLASSES = "#{TEXT_ACTION_CLASSES} whitespace-nowrap " \
                             'disabled:opacity-50 disabled:cursor-not-allowed disabled:no-underline'.freeze

  def filter_bar_labels_json
    {
      no_filter_options: scoped_t('no_filter_options'),
      add_filter: scoped_t('filter_bar.add_filter'),
      rule_field_labels: I18n.t('smart_folders.fields'),
      rule_operator_labels: I18n.t('smart_folders.operators'),
      **shared_labels
    }.to_json
  end

  # Area-neutral words of the bar (components.filter_bar.*): the same in
  # tickets and knowledge, so they are not duplicated per i18n scope.
  # condition_count carries its plural forms ({ one:, other: }) as a hash.
  SHARED_LABEL_KEYS = %w[
    edit_condition not_editable_here close_menu back in_use nothing_selected
    change_value edit_conditions done_editing add_condition
    name_of_view name_save name_cancel
    change_value_removed change_two_values_removed change_values_removed
    change_value_added change_values_added change_conditions_changed condition_count filter_sign_title
    remove_condition remove_value
    save_changes save_as_new_view save_as_view discard reset undo
    change_discarded conditions_reset view_saved save_failed retry
    renamed rename_failed delete_confirm view_deleted delete_failed duplicate_failed
  ].freeze

  def shared_labels
    SHARED_LABEL_KEYS.index_with { |key| I18n.t("components.filter_bar.#{key}") }
  end

  def operator_labels_json
    {
      or: scoped_t('filter_op_or'),
      and: scoped_t('filter_op_and'),
      not: scoped_t('filter_op_not'),
      logic_label: scoped_t('filter_op_logic_label'),
      connector_and: scoped_t('filter_connector_and'),
      connector_or: scoped_t('filter_connector_or'),
      connector_not: I18n.t('components.filter_bar.connector_not')
    }.to_json
  end

  def save_labels_json
    {
      save_as_smart_folder: scoped_t('save_as_smart_folder'),
      save_filter_title: scoped_t('save_filter_title'),
      save_filter_name_label: scoped_t('save_filter_name_label'),
      save_filter_name_placeholder: scoped_t('save_filter_name_placeholder'),
      save_filter_save_button: scoped_t('save_filter_save_button'),
      save_filter_cancel_button: scoped_t('save_filter_cancel_button'),
      save_filter_unsupported_hint: scoped_t('save_filter_unsupported_hint'),
      save_filter_type_widened_hint: I18n.t('components.filter_bar.save_filter_type_widened_hint')
    }.to_json
  end

  def smart_folders_json
    smart_folders.map do |sf|
      {
        id: sf.id,
        name: sf.name,
        allow_empty_filters: sf.target_object_type == 'Meeting',
        update_from_filters_url: helpers.update_from_filters_organisation_smart_folder_path(organisation, sf)
      }
    end.to_json
  end

  def dissolver_data_json
    return '{}' unless dissolver_result

    {
      dissolvable: dissolver_result.dissolvable?,
      filters: dissolver_result.ad_hoc_filters,
      operators: dissolver_result.ad_hoc_operators,
      complex_rules: dissolver_result.complex_rules.map { |r| { field: r.field, operator: r.operator, value: r.value, group_id: r.smart_folder_rule_group_id } }
    }.to_json
  end

  # Filter values for user-typed fields (assignee/creator) are UUIDs. The JS
  # chip renderer resolves them to names via the category options pool — but an
  # ad-hoc filter or a (dissolved) smart folder can reference a user who is NOT
  # in the current project's pool, in which case the chip fell back to the raw
  # UUID. This map provides a display-name fallback (id => name) for every user
  # referenced by the active or dissolved filters, resolved within the
  # organisation: the ids come from the address, and a user of another
  # organisation is nobody's business here (User is not tenant-scoped).
  USER_FILTER_KEYS = %w[assignee creator].freeze

  def value_labels_json
    ids = referenced_user_ids
    return '{}' if ids.empty?

    organisation.users.where(id: ids)
                .each_with_object({}) { |u, map| map[u.id] = u.display_name }
                .to_json
  end

  def referenced_user_ids
    ids = []

    USER_FILTER_KEYS.each do |key|
      ids.concat(Array(ad_hoc_filters[key])).concat(Array(ad_hoc_filters[key.to_sym]))
    end

    if dissolver_result
      dissolved = dissolver_result.ad_hoc_filters || {}
      USER_FILTER_KEYS.each do |key|
        ids.concat(Array(dissolved[key])).concat(Array(dissolved[key.to_sym]))
      end
      Array(dissolver_result.complex_rules).each do |rule|
        field = rule.field.to_s.sub(/\Acustom_/, '')
        ids << rule.value if USER_FILTER_KEYS.include?(field)
      end
    end

    ids.compact.reject(&:blank?).uniq
  end
end
