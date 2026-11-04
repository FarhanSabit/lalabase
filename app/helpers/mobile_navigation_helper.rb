# frozen_string_literal: true

module MobileNavigationHelper
  PROJECT_AREAS = %w[tickets knowledge meetings time_sessions documentation dashboard members settings activities].freeze

  # Rails controller names, not route names. Project pages use their project name.
  PAGE_TITLE_KEYS = {
    'accept_invitations' => 'mobile.page_titles.accept_invitation',
    'access_matrix' => 'views.organisations.access_matrix.index.title',
    'ai_configurations' => 'views.organisations.ai_overview.pages.access',
    'ai_overviews' => 'settings.ai',
    'ai_protocols' => 'views.organisations.ai_overview.protocol.title',
    'ai_settings' => 'views.organisations.ai_overview.pages.access',
    'ai_sync_statuses' => 'views.organisations.ai_overview.pages.index',
    'ai_usages' => 'views.organisations.ai_overview.usage.title',
    'appearances' => 'settings.appearance',
    'archives' => 'settings.archive',
    'billing' => 'settings.billing',
    'changelog' => 'navigation.changelog',
    'codebase_import_files' => 'mobile.page_titles.imports',
    'glossary' => 'navigation.glossary',
    'help' => 'mobile.help',
    'invitations' => 'mobile.page_titles.invitations',
    'meetings_overview' => 'navigation.all_meetings',
    'memberships' => 'settings.members',
    'organisation_settings' => 'navigation.management',
    'overview_configurations' => 'mobile.page_titles.overview_configuration',
    'people' => 'navigation.people',
    'power_search' => 'mobile.search',
    'projects' => 'mobile.projects',
    'prompt_personas' => 'views.organisations.ai_overview.pages.personas',
    'roles' => 'settings.roles_permissions',
    'smart_folders' => 'mobile.page_titles.smart_folders',
    'tags' => 'mobile.page_titles.tags',
    'time_session_groups' => 'mobile.billings',
    'user_activities' => 'mobile.page_titles.user_activities'
  }.freeze

  def mobile_project
    return current_project if current_project.present?
    return if params[:project_context].blank?

    @mobile_project ||= policy_scope(Project).where(organisation_id: current_organisation.id).find_by(id: params[:project_context])
  end

  def mobile_area
    return params[:area] if controller_name == 'mobile_navigation' && PROJECT_AREAS.include?(params[:area])
    return 'time_sessions' if controller_name == 'time_sessions' && mobile_project

    current_sidebar_tab.presence || 'tickets'
  end

  def mobile_project_items(project)
    cache = request.env['lalabase.mobile_project_items'] ||= {}
    return cache[project.id] if cache.key?(project.id)

    items = NeoSidebarProjectItemComponent.new(project: project).navigation_items(view_context: self)
    items << { key: 'time_sessions', label: t('mobile.times'), path: organisation_time_sessions_path(current_organisation, project_id_filter: project.id, project_context: project.id) } if mobile_time_visible?(project)
    cache[project.id] = items.sort_by { |item| PROJECT_AREAS.index(item[:key]) || PROJECT_AREAS.length }
  end

  # Batch the permission rows once; the project switcher renders every project.
  def mobile_time_visible?(project)
    return false unless project.organisation_id == current_organisation.id

    scope = request.env['lalabase.mobile_time_scope'] ||= TimeSessions::ViewingScope.for_organisation(user: current_user, organisation: current_organisation)
    scope.tier_for(project.id) != :none
  end

  def mobile_project_destination(project, area: mobile_area, switched: false)
    items = mobile_project_items(project)
    item = items.find { |entry| entry[:key] == area } || items.first
    path = item[:path]
    return path unless switched

    uri = URI.parse(path)
    query = Rack::Utils.parse_nested_query(uri.query)
    query['project_switched'] = '1' if params[:search].present? || params[:filter].present? || params[:smart_folder_id].present?
    uri.query = query.to_query.presence
    uri.to_s
  end

  def mobile_projects
    groups = sidebar_project_groups
    (groups[:pinned] + groups[:active] + groups[:rest]).uniq
  end

  def mobile_ticket_counts
    @mobile_ticket_counts ||= policy_scope(Ticket).where(project_id: mobile_projects.map(&:id)).group(:project_id).count
  end

  def mobile_active_destination
    return 'projects' if mobile_project || (controller_name == 'mobile_navigation' && action_name == 'projects')
    return 'start' if controller_name == 'briefings'
    return 'inbox' if controller_name == 'notifications'
    return 'times' if controller_name == 'time_sessions'

    'more'
  end

  def mobile_navigation_items
    org = current_organisation
    [
      { key: 'start', icon: 'house', path: organisation_root_path(org) },
      { key: 'inbox', icon: 'bell', path: organisation_notifications_path(org) },
      { key: 'projects', icon: 'grid', path: organisation_mobile_projects_path(org) },
      { key: 'times', icon: 'clock', path: organisation_time_sessions_path(org, creator_id: current_user.id) },
      { key: 'more', icon: 'three-dots', path: organisation_mobile_more_path(org) }
    ].reject { |item| item[:key] == 'times' && !policy(TimeSession).index? }
  end

  def mobile_page_title
    return mobile_project.name if mobile_project

    return t("mobile.#{mobile_active_destination}") unless mobile_active_destination == 'more'
    return t('mobile.more') if controller_name == 'mobile_navigation'

    t(PAGE_TITLE_KEYS.fetch(controller_name, 'mobile.more'))
  end

  def mobile_ticket_link(ticket)
    query = request.query_parameters.except('ticket_id', 'id', 'project_switched')
    organisation_project_ticket_path(current_organisation, ticket.project, ticket, query.merge('viewport' => 'mobile'))
  end
end
