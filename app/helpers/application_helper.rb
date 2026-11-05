# frozen_string_literal: true

module ApplicationHelper
  include Pagy::Frontend if defined?(Pagy::Frontend)
  include Notifications::Constants

  # Operator name and legal links come from the instance admin settings (LegalIdentity).
  def legal_operator_credit
    operator = LegalIdentity.current.operator_name
    if operator
      t('views.shared.legal.operator_credit', year: Date.current.year, operator: operator)
    else
      t('views.shared.legal.powered_by', product: Lalabase::PRODUCT_NAME)
    end
  end

  def legal_page_link(page, label:, fallback_to_label: false, **options)
    target = legal_page_target(page)
    return label if target.blank? && fallback_to_label
    return if target.blank?

    link_to(label, target, **options)
  end

  # Where a legal page lives for this instance. An external address WINS: an
  # operator who has a website links it, and keeping two copies of a privacy
  # policy is how they start to differ. Without one, the operator may write the
  # text in the admin area and this instance serves it. With neither, there is
  # no link -- an internal instance owes nobody an imprint.
  def legal_page_target(page)
    identity = LegalIdentity.current
    external = identity.url_for(page)
    return external if external.present?

    instance_legal_page_path(page) if identity.body_for(page).present?
  end

  def legal_footer_links(separator: '', **options)
    links = LegalIdentity::PAGES.filter_map do |page|
      legal_page_link(page, label: t("views.shared.legal.#{page}"), **options)
    end
    safe_join(links, separator)
  end

  # === Viewer-side name display (doc/user_display_name_avatar_plan.md) ===
  # Surface register (which spot renders what, guard-enforced):
  # docs/dokumentation/namensanzeige_flaechenregister.md
  # Slack model since 05.09.2026 (user decision): the PICTURE always shows at
  # identity spots (Neo::Users::AvatarComponent); the viewer's setting only
  # picks the SPELLING of names. Identity labels render viewer_user_chip
  # (avatar + spelled name), a group of people viewer_user_list (adaptive:
  # pair when alone, chips when several, the viewer first); prose calls
  # viewer_display_name. The name computation itself has ONE owner:
  # User::NameDisplay.
  def viewer_name_display_mode
    viewer_user&.preference_store&.name_display_mode || User::PreferenceStore::NAME_DISPLAY_DEFAULT
  end

  # A timestamp in the viewer's own date format (the preference store's
  # date_strftime_format), the rule for every date a lane shows
  # (doc/dokumentansicht_plan.md, user 10.09.2026). Through viewer_user, because
  # the version row is also rendered from a job (DocumentVersion#broadcast_updated),
  # where Devise's current_user raises and a raise inside an after_commit takes
  # the write's caller down with it; without a viewer the relative form, as
  # display_time gives a reader who chose none.
  def viewer_display_time(timestamp, area: nil)
    display_time(timestamp, area: area, user: viewer_user)
  end

  def viewer_display_name(user)
    return t('views.helpers.application.unknown_user') unless user

    user.display_name(mode: viewer_name_display_mode)
  end

  # THE identity-label pair: avatar chip + name in the viewer's spelling.
  # Feeding queries must preload `user: { avatar_attachment: :blob }` or the
  # chip's attached? check is an N+1 per rendered user.
  def viewer_user_chip(user, size: :small, text_class: nil)
    tag.span(class: 'inline-flex items-center gap-1.5 align-middle whitespace-nowrap') do
      safe_join([
                  render(Neo::Users::AvatarComponent.new(user: user, size: size)),
                  render(Neo::Users::NameComponent.new(user: user, text_class: text_class))
                ], ' ')
    end
  end

  # The PEOPLE at one identity spot (ticket assignees, in the list and in the
  # detail head). Two rules, both the user's (08.09.2026), and both live here
  # so no caller re-implements them by hand:
  #
  # * Adaptive density: ONE person renders as the chip+name pair, SEVERAL as
  #   chips only, each name in the chip's hover title. Two names never fit
  #   the assignee column or the detail's attribute row; the picture alone
  #   does, and it still says who.
  # * Order: the viewer first when they are among the people, the rest
  #   alphabetically (viewer_ordered_users).
  #
  # nil for an empty list, so callers can fall through to their own empty
  # state. size :xs (20px) is the attribute-row scale (user mockup
  # 05.09.2026), :small (26px) the comment/pill scale.
  def viewer_user_list(users, size: :small, text_class: nil)
    people = viewer_ordered_users(users)
    return if people.empty?
    return viewer_user_chip(people.first, size: size, text_class: text_class) if people.one?

    viewer_user_chips(people, size: size)
  end

  # Chips only, in viewer order: the explicit "Nur Avatar" density of the
  # ticket detail, and the several-people branch of viewer_user_list.
  def viewer_user_chips(users, size: :small)
    people = viewer_ordered_users(users)
    return if people.empty?

    tag.span(class: 'inline-flex items-center gap-1.5 align-middle') do
      safe_join(people.map { |u| render(Neo::Users::AvatarComponent.new(user: u, size: size)) })
    end
  end

  # People in the order a viewer reads them: themselves first, then by name.
  # "By name" means the name as displayed (first name first), lower-cased,
  # the same key the assignee picker orders by (TicketsHelper) and the access
  # matrix sorts on (AccessCheck::OrgAccessMatrix); the id breaks ties so two
  # namesakes keep one order across renders. Without a viewer (broadcasts,
  # component specs) it is the alphabetical order alone.
  #
  # Sorts the loaded records in Ruby on purpose: the callers' queries preload
  # the users (with their avatar blobs), an ORDER BY would be a second query
  # per ticket.
  def viewer_ordered_users(users)
    me = viewer_user
    users.to_a.sort_by { |u| [u == me ? 0 : 1, u.display_name.downcase, u.id.to_s] }
  end

  # The signed-in user, or nil where there is none (broadcast renders and
  # component specs: Devise's current_user raises without warden).
  def viewer_user
    current_user
  rescue StandardError
    nil
  end

  # Override the Pagy::Frontend pagy_url_for method
  # Helper to generate URLs with preserved params
  def url_with_params(path, additional_params = {})
    # Get current params that should be preserved
    preserved_params = params.permit(:items, :smart_folder_id, :search, :search_mode, :sort).to_h

    # If no items param in URL, use user DB preference
    if preserved_params[:items].blank? && respond_to?(:current_user) && current_user.respond_to?(:items_per_page_preference)
      value = current_user.items_per_page_preference
      preserved_params[:items] = value if value.present? && value.to_i > 0
    end

    # Merge with additional params
    final_params = preserved_params.merge(additional_params)

    # Remove empty values
    final_params.reject! { |_, v| v.blank? }

    # Generate URL
    if final_params.any?
      "#{path}?#{final_params.to_query}"
    else
      path
    end
  end

  # Builds the URL for one pagination link.
  #
  # PATH FIRST, not url_for. The previous version handed url_for a bare options
  # hash and let Rails work out the route; for a page without route-defining
  # params that raises "arguments passed to url_for can't be handled", i.e. a
  # 500. Measured on /admin/accounts with 26 accounts: the list did not fail on
  # page 2, it failed on page ONE, because the view renders the nav as soon as
  # `@pagy.pages > 1`. The whole screen was gone past 25 accounts.
  #
  # A DENYLIST, not an allowlist. The old permit list named nine parameters, so
  # every screen with a tenth silently dropped it on every page change: the
  # billing list's `on` (the reference date the whole page is about) and the
  # admin account search both disappeared. An allowlist here has to be extended
  # by whoever adds a filter, and nothing tells them -- the link still works, it
  # just forgets. Turned around: keep what the request carries, drop the few
  # things that must not travel.
  # Control parameters only. A FILTER must travel, or page 2 quietly answers a
  # different question than page 1 -- the rule this list exists to enforce.
  #
  # ticket_id came out on 31.08.2026: it is a filter on the time list, not a
  # control parameter, and it had been dropped here since the list was turned
  # around. It went unnoticed while that list's frame did not advance the
  # address; once it did, paging away from a ticket-filtered list left an
  # address without the filter, and the filter pills rebuild from that address.
  PAGY_URL_DROP_PARAMS = %w[
    controller action format script_name original_script_name
    authenticity_token _method commit
  ].freeze

  def pagy_url_for(_pagy, page, **)
    query = request.query_parameters.except(*PAGY_URL_DROP_PARAMS)
    query['page'] = page.to_s

    query_string = query.reject { |_, value| value.blank? }.to_query
    "#{pagy_base_path}#{'?' if query_string.present?}#{query_string}"
  end

  # The request path WITHOUT the format extension.
  #
  # A pagination link points at the same screen, one page further -- never at
  # another representation of it. Rendering the nav during a .turbo_stream
  # request would otherwise produce links to .turbo_stream, and every click
  # would answer with a stream where a page was meant.
  #
  # Asking path_parameters[:format] rather than stripping a regex is what makes
  # this exact: it removes only what ROUTING recognised as the format. That also
  # covers the case the deleted Pageable#sanitize_base_path was built for --
  # `/tickets.d2ddf7cf-4a48-...` -- because Rails parses that trailing UUID AS a
  # format. Its regex treated the symptom; this reads the cause.
  def pagy_base_path
    path = request.path
    format = request.path_parameters[:format]
    return path if format.blank?

    path.delete_suffix(".#{format}")
  end

  def sortable(column, title = nil)
    title ||= column.titleize

    # Check if sorting methods are available from controller
    if defined?(sort_column) && defined?(sort_direction)
      css_class = column == sort_column ? "sortable sorted-#{sort_direction}" : 'sortable'

      # Determine the next sort direction
      next_direction = if column == sort_column
                         sort_direction == 'asc' ? 'desc' : 'asc'
                       else
                         'asc' # Ascending by default on the first click
                       end

      # Determine the icon based on the current sort state
      icon = if column == sort_column
               sort_direction == 'asc' ? 'bi-arrow-up-short' : 'bi-arrow-down-short'
             end
    else
      # Default if sort methods are not available
      css_class = 'sortable'
      next_direction = 'asc'
      icon = nil
    end

    # Collect filter and other parameters for the link - including all pagination params
    # IMPORTANT: smart_folder_id must be explicitly included
    extra_params = params.permit(:start_date, :end_date, :search, :project_id, :page, :items, :limit, :smart_folder_id, :context_type, :filter).to_h

    # EXPLICITLY handle the smart folder parameter - highest priority
    extra_params[:smart_folder_id] = params[:smart_folder_id] if params[:smart_folder_id].present?

    # Determine the correct Turbo Frame based on the controller
    frame_id = case controller_name
               when 'time_sessions'
                 'time_sessions_list_frame'
               when 'tickets'
                 'tickets_list_frame'
               when 'notes'
                 'notes_results'
               when 'documents'
                 'documents-list'
               when 'smart_folders'
                 'smart-folders-list'
               else
                 '_top'
               end

    # Build the link while preserving the other parameters
    # Make sure we do not accidentally pass the :id parameter, as this can cause routing problems
    begin
      link_params = extra_params.except(:id).merge(sort: { column: column, direction: next_direction })

      # Build the URL manually so we can ensure the smart folder parameter is included
      url = url_for(link_params)

      # Add the smart folder ID explicitly if it is missing
      if params[:smart_folder_id].present? && !url.include?('smart_folder_id=')
        separator = url.include?('?') ? '&' : '?'
        url = "#{url}#{separator}smart_folder_id=#{params[:smart_folder_id]}"
      end

      link_to(url,
              class: css_class,
              data: { turbo_frame: frame_id }) do
        concat title
        if icon
          concat ' '
          concat content_tag(:i, '', class: "bi #{icon}")
        end
      end
    rescue StandardError => e
      # Fallback in case of errors
      Rails.logger.error "Error in sortable helper: #{e.message}"
      title
    end
  end

  # Helper to extract a title from different object types
  def extract_title(item)
    case item.class.name
    when 'Note'
      item.title
    when 'Ticket'
      item.title
    when 'Document'
      item.title || item.file_name || I18n.t('views.helpers.application.document_fallback')
    when 'TimeSession'
      I18n.t('views.helpers.application.time_session_for', title: item.ticket.title) if item.respond_to?(:ticket) && item.ticket
    else
      item.try(:title) || item.try(:name) || item.try(:subject) || "#{item.class.name} ##{item.id}"
    end
  end

  def markdown(text)
    return '' if text.blank?

    renderer = Redcarpet::Render::HTML.new(
      hard_wrap: true,
      link_attributes: { target: '_blank' }
    )
    markdown = Redcarpet::Markdown.new(renderer,
                                       autolink: true,
                                       tables: true,
                                       fenced_code_blocks: true,
                                       strikethrough: true)

    sanitize markdown.render(text)
  end

  def ticket_priority_badge(ticket)
    priority_value = ticket.get_custom_attribute('priority')
    return unless priority_value.present?

    # Map priority values to colors based on common naming patterns
    priority_colors = {
      'hoch' => 'bg-red-500 text-on-fill',
      'high' => 'bg-red-500 text-on-fill',
      'dringend' => 'bg-red-500 text-on-fill',
      'urgent' => 'bg-red-500 text-on-fill',
      'mittel' => 'bg-yellow-500 text-cream-900',
      'medium' => 'bg-yellow-500 text-cream-900',
      'normal' => 'bg-yellow-500 text-cream-900',
      'niedrig' => 'bg-blue-500 text-on-fill',
      'low' => 'bg-blue-500 text-on-fill',
      'gering' => 'bg-blue-500 text-on-fill'
    }

    css_class = priority_colors[priority_value.downcase] || 'bg-gray-300 text-cream-900'

    content_tag(:span,
                content_tag(:i, '', class: 'bi bi-flag-fill', style: 'font-size: 10px;') + ' ' + priority_value,
                class: "inline-flex items-center gap-x-1 py-0.5 px-2 rounded-full text-xs font-medium border border-stroke #{css_class}")
  end

  def ticket_status_badge(ticket)
    status_value = ticket.get_custom_attribute('status')
    return unless status_value.present?

    # Map status values to colors based on common naming patterns
    status_colors = {
      'offen' => 'bg-lime-200 text-cream-900',
      'open' => 'bg-lime-200 text-cream-900',
      'neu' => 'bg-lime-200 text-cream-900',
      'new' => 'bg-lime-200 text-cream-900',
      'in bearbeitung' => 'bg-yellow-500 text-cream-900',
      'in arbeit' => 'bg-yellow-500 text-cream-900',
      'in progress' => 'bg-yellow-500 text-cream-900',
      'bearbeitung' => 'bg-yellow-500 text-cream-900',
      'erledigt' => 'bg-green-500 text-on-fill',
      'fertig' => 'bg-green-500 text-on-fill',
      'done' => 'bg-green-500 text-on-fill',
      'abgeschlossen' => 'bg-green-500 text-on-fill',
      'geschlossen' => 'bg-gray-500 text-on-fill',
      'closed' => 'bg-gray-500 text-on-fill'
    }

    css_class = status_colors[status_value.downcase] || 'bg-gray-300 text-cream-900'

    content_tag(:span, status_value,
                class: "inline-flex items-center gap-x-0.5 py-0.5 px-2 rounded-full text-xs font-medium border border-stroke #{css_class}")
  end

  # Info display for status (not like a button)
  def ticket_status_info(ticket)
    status_value = ticket.get_custom_attribute('status')
    return unless status_value.present?

    dot_color = resolve_status_dot_color(ticket, status_value)

    content_tag(:span, class: 'inline-flex items-center gap-1 text-xs text-gray-600') do
      content_tag(:span, I18n.t('views.helpers.application.status_label'), class: 'font-medium') +
        content_tag(:span, '', class: "w-2 h-2 rounded-full #{dot_color}") +
        content_tag(:span, status_value)
    end
  end

  def ticket_priority_info(ticket)
    priority_value = ticket.get_custom_attribute('priority')
    return unless priority_value.present?

    # Priority now reads as Linear-style signal bars (level by fill), replacing the red dot
    # so it never collides with the red "overdue" chip. Falls back to a plain label when the
    # priority has no configured level.
    bars = ticket_priority_bars(ticket)
    # Prefer the human label ("Hoch") over the raw stored value ("high"); fall back to the raw value
    # if the ticket has no display helper or the value has no configured label.
    label_text = priority_value
    label_text = ticket.display_custom_attribute('priority') || priority_value if ticket.respond_to?(:display_custom_attribute)

    content_tag(:span, class: 'inline-flex items-center gap-1 text-xs text-gray-600') do
      safe_join([
        content_tag(:span, I18n.t('views.helpers.application.priority_label'), class: 'font-medium'),
        bars,
        content_tag(:span, label_text)
      ].compact)
    end
  end

  # Helper methods for the permission system

  # Checks whether the user is an account admin
  def account_admin?
    current_user.account_admin_in?(current_organisation)
  end

  # Checks a permission at the organisation level
  def has_permission?(category, action)
    current_user.has_permission_in_organisation?(current_organisation, category, action)
  end

  # Checks a permission at the project level
  delegate :can_access_project?, to: :current_user

  # Shows a badge for the access type
  def access_badge(access)
    badge_colors = {
      'no_access' => 'bg-red-100 text-red-800 border-red-800',
      'read_only' => 'bg-blue-100 text-blue-800 border-blue-800',
      'read_write' => 'bg-green-100 text-green-800 border-green-800'
    }

    css_class = badge_colors[access] || 'bg-gray-100 text-gray-800 border-gray-800'

    content_tag(:span, access.humanize,
                class: "inline-flex items-center gap-x-1.5 py-1 px-2 rounded-full text-xs font-medium border #{css_class}")
  end

  # Shows a badge for a role
  def role_badge(role)
    css_class = if role.account_admin?
                  'bg-purple-100 text-purple-800 border-purple-800'
                elsif role.is_default
                  'bg-blue-100 text-blue-800 border-blue-800'
                else
                  'bg-green-100 text-green-800 border-green-800'
                end

    content_tag(:span, role.title,
                class: "inline-flex items-center gap-x-1.5 py-1 px-2 rounded-full text-xs font-medium border #{css_class}")
  end

  # Displays the errors for a model instance if there are any
  def display_errors_for(object)
    return unless object.errors.any?

    render partial: 'admin/shared/errors',
           locals: { object: object }
  end

  # === Date Display Helpers ===

  # Display time based on user preferences
  def display_time(timestamp, area: nil, user: current_user)
    return '' if timestamp.blank?

    # Get the format for the specific area
    format = user&.date_strftime_format(area)

    if format.nil?
      # Use relative format
      t('views.common.relative_time_ago', time: time_ago_in_words(timestamp))
    else
      # Use absolute format
      begin
        timestamp.strftime(format)
      rescue StandardError => e
        Rails.logger.error "Invalid date format: #{format} - #{e.message}"
        # Fallback to German format
        timestamp.strftime('%d.%m.%Y %H:%M')
      end
    end
  end

  # Display time with date and time in separate spans for responsive hiding
  # The time portion is wrapped in <span class="date-time-part"> so CSS can hide it
  def display_time_split(timestamp, area: nil, user: current_user)
    return '' if timestamp.blank?

    format = user&.date_strftime_format(area)

    if format.nil?
      t('views.common.relative_time_ago', time: time_ago_in_words(timestamp))
    elsif format.include?('%H:%M')
      date_format = format.sub(/ ?%H:%M(:%S)?/, '').strip
      date_part = timestamp.strftime(date_format)
      time_part = timestamp.strftime('%H:%M')
      safe_join([date_part, ' ', content_tag(:span, time_part, class: 'date-time-part')])
    else
      begin
        timestamp.strftime(format)
      rescue StandardError => e
        Rails.logger.error "Invalid date format: #{format} - #{e.message}"
        timestamp.strftime('%d.%m.%Y')
      end
    end
  end

  # A DATE, in the reader's format, without a clock.
  #
  # ⚠️ Not display_time: that one uses the area's whole format, and most areas
  # carry %H:%M. On a Date the clock reads "00:00" - a time nobody entered,
  # printed after a value that has none. A date field has no time of day, so
  # the format loses it here rather than the stylesheet hiding it later
  # (user, 07.09.2026, the due date in the meta line).
  def display_date(date, area: nil, user: current_user)
    return '' if date.blank?

    format = user&.date_strftime_format(area)
    return I18n.l(date.to_date) if format.nil?

    begin
      date.strftime(format.sub(/ ?%H:%M(:%S)?/, '').strip)
    rescue StandardError => e
      Rails.logger.error "Invalid date format: #{format} - #{e.message}"
      date.strftime('%d.%m.%Y')
    end
  end

  # Display time with "ago" suffix for backwards compatibility
  def display_time_ago(timestamp, area: nil, user: current_user)
    return '' if timestamp.blank?

    format = user&.date_strftime_format(area)

    if format.nil?
      # Relative format, localized (de: "vor X", en: "X ago") instead of hardcoded " ago".
      t('views.common.relative_time_ago', time: time_ago_in_words(timestamp))
    else
      # Use absolute format (no "ago" suffix)
      display_time(timestamp, area: area, user: user)
    end
  end

  # === Notification Helpers ===

  # Get target path for a notification
  def notification_target_path(notification)
    organisation_obj = notification.respond_to?(:organisation) ? notification.organisation : nil
    organisation = organisation_obj || current_organisation
    organisation_id = organisation.respond_to?(:id) ? organisation.id : organisation

    return organisation_notifications_path(organisation_id) unless notification.notifiable

    notifiable = notification.notifiable

    case notifiable
    when Ticket
      if notifiable.project
        organisation_project_ticket_path(organisation_id, notifiable.project, notifiable)
      else
        organisation_ticket_path(organisation_id, notifiable)
      end
    when Project
      organisation_project_path(organisation_id, notifiable)
    when Document
      organisation_project_document_path(organisation_id, notifiable.project, notifiable)
    when Note
      organisation_project_note_path(organisation_id, notifiable.project, notifiable)
    else
      organisation_notifications_path(organisation_id)
    end
  rescue StandardError
    organisation_notifications_path(organisation_id || current_organisation)
  end

  def navigation_notifications_label(unread_count)
    count = unread_count.to_i
    base = I18n.t('navigation.notifications_label', count: count)
    count.positive? ? "#{base} (#{count})" : base
  end

  def navigation_notifications_label_tag(unread_count, include_count: true)
    count = unread_count.to_i
    label = content_tag(:span, I18n.t('navigation.notifications_label', count: count),
                        data: { notification_count_listener_target: 'label' })
    badge = render(Neo::UnreadMarkerComponent.new(count: count, live: true, class: 'ml-1',
                                                  data: { notification_count_listener_target: 'indicator' }))
    label + badge
  end

  # Event type descriptions for notification preferences
  def event_description(event_type)
    descriptions = {
      EVENT_TYPE_MENTION => I18n.t('views.helpers.application.event_description.mention'),
      EVENT_TYPE_TICKET_ASSIGNED => I18n.t('views.helpers.application.event_description.ticket_assigned'),
      EVENT_TYPE_TICKET_BLOCKER => I18n.t('views.helpers.application.event_description.ticket_blocker'),
      EVENT_TYPE_TICKET_COMMENTED => I18n.t('views.helpers.application.event_description.ticket_commented'),
      EVENT_TYPE_TICKET_STATUS_CHANGED => I18n.t('views.helpers.application.event_description.ticket_status_changed'),
      EVENT_TYPE_DOCUMENT_ADDED => I18n.t('views.helpers.application.event_description.document_added'),
      EVENT_TYPE_PROJECT_ANNOUNCEMENT => I18n.t('views.helpers.application.event_description.project_announcement'),
      EVENT_TYPE_SYSTEM_MESSAGE => I18n.t('views.helpers.application.event_description.system_message'),
      EVENT_TYPE_INDEX_COMPLETED => I18n.t('views.helpers.application.event_description.index_completed'),
      EVENT_TYPE_INDEX_FAILED => I18n.t('views.helpers.application.event_description.index_failed')
    }

    descriptions[event_type] || event_type.humanize
  end

  # Badge configuration for notification types (used in views)
  def notification_badge_config(event_type)
    config = {
      EVENT_TYPE_TICKET_COMMENTED => { icon: 'chat-left-text', color: 'blue', label: 'Comment' },
      EVENT_TYPE_TICKET_ASSIGNED => { icon: 'person-plus', color: 'green', label: 'Assigned' },
      EVENT_TYPE_TICKET_STATUS_CHANGED => { icon: 'arrow-right-circle', color: 'yellow', label: 'Status' },
      EVENT_TYPE_TICKET_BLOCKER => { icon: 'exclamation-triangle', color: 'red', label: 'Priority' },
      EVENT_TYPE_PROJECT_ANNOUNCEMENT => { icon: 'megaphone', color: 'purple', label: 'Announcement' },
      EVENT_TYPE_DOCUMENT_ADDED => { icon: 'file-plus', color: 'indigo', label: 'Document' },
      EVENT_TYPE_MENTION => { icon: 'at', color: 'pink', label: 'Mention' },
      EVENT_TYPE_SYSTEM_MESSAGE => { icon: 'info-circle', color: 'gray', label: 'System' }
    }

    config[event_type] || config[EVENT_TYPE_SYSTEM_MESSAGE]
  end

  # Uniform display of project names in the parallelogram badge
  # variant: :bold (default) — black filled, for headings/cards
  # variant: :light          — outline, for lists/inline
  def project_name_label(project_or_name, variant: :bold)
    name = project_or_name.respond_to?(:name) ? project_or_name.name : project_or_name.to_s

    case variant
    when :light
      content_tag(:span, name, style: 'background:linear-gradient(to right, rgba(0,0,0,0.18), transparent)', class: 'inline-block font-semibold text-xs px-2 py-px')
    else
      content_tag(:span, style: 'transform:skewX(-12deg)', class: 'inline-block bg-gray-800 px-3 py-0.5') do
        content_tag(:span, name, style: 'transform:skewX(12deg)', class: 'inline-block font-bold text-on-fill')
      end
    end
  end

  # Helper methods to use constants in views (since views can't access constants directly)
  def event_type_ticket_commented
    EVENT_TYPE_TICKET_COMMENTED
  end

  def event_type_ticket_assigned
    EVENT_TYPE_TICKET_ASSIGNED
  end

  def event_type_ticket_unassigned
    EVENT_TYPE_TICKET_UNASSIGNED
  end

  def event_type_ticket_status_changed
    EVENT_TYPE_TICKET_STATUS_CHANGED
  end

  def event_type_ticket_blocker
    EVENT_TYPE_TICKET_BLOCKER
  end

  def event_type_project_announcement
    EVENT_TYPE_PROJECT_ANNOUNCEMENT
  end

  def event_type_document_added
    EVENT_TYPE_DOCUMENT_ADDED
  end

  def event_type_mention
    EVENT_TYPE_MENTION
  end

  def event_type_system_message
    EVENT_TYPE_SYSTEM_MESSAGE
  end

  # System-function-based color resolution (status)
  # Checks system functions first, falls back to TicketColorMap
  def resolve_status_dot_color(ticket, status_value)
    status_functions = [
      SystemFunctions::Registry::IS_BACKLOG,
      SystemFunctions::Registry::IS_NEW,
      SystemFunctions::Registry::IS_IN_PROGRESS,
      SystemFunctions::Registry::IS_COMPLETED,
      SystemFunctions::Registry::IS_CLOSED
    ]

    active = ticket.active_system_functions
    matched = status_functions.find { |f| active.include?(f) }

    if matched
      TicketColorMap.dot_color_for_function(matched)
    else
      TicketColorMap.status_dot_color(status_value)
    end
  end

  def changelog_has_unread?(user)
    latest = Changelog::EntryLoader.call.first&.date
    return false unless latest

    user.changelog_last_read_at.nil? || user.changelog_last_read_at < latest.beginning_of_day
  end

  def changelog_nav_label(has_unread)
    label = content_tag(:span, t('navigation.changelog'))
    return label unless has_unread

    dot = content_tag(:span, '', class: 'changelog-unread-dot inline-block w-2 h-2 bg-lime-500 rounded-full ml-1.5 border border-stroke')
    label + dot
  end

  # JavaScript I18n translations
  #
  # Exposes the ENTIRE `stimulus` locale subtree to window.translations, so every
  # I18n.t('stimulus.*') call in a Stimulus controller resolves. We dump the whole
  # tree instead of maintaining a hand-picked whitelist: the whitelist silently
  # drifted from the locale files (keys existed in de/en.yml but were never added
  # here), so those controllers fell back to the raw key string at runtime.
  def javascript_translations
    { stimulus: I18n.t('stimulus') }
  end

  # HTML as text, for a place that escapes what it writes: truncate, an attribute
  # written with <%= %>, the value of a translation. strip_tags returns HTML: & < >
  # as entities, " and ' as well since Rails 8.1.4.1, a no-break space as &nbsp;.
  # Escaped once more, each would show as its entity. Reading the stripped text as
  # a fragment decodes them all; CGI.unescapeHTML leaves &nbsp; standing. The
  # result is a plain String, so markup in it is escaped wherever it is written.
  def text_from_html(html)
    Nokogiri::HTML5.fragment(strip_tags(html.to_s)).text
  end
end
