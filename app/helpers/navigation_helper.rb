# frozen_string_literal: true

# View helpers for the organisation sidebar navigation (common/_navigation_application).
#
# Two responsibilities, both extracted here so they live in exactly ONE place:
#   1. The permission gates for the org switcher menu and the "Verwaltung" sidebar
#      entry (moved verbatim from the inline checks that used to sit in the partial).
#   2. The SINGLE source of truth for the organisation-management settings tabs — the
#      settings subnav renders from #organisation_settings_tabs, and the sidebar's
#      active-state (#management_section_active?) derives its controller list from the
#      SAME definition. No mirrored array, so the two can never drift apart.
module NavigationHelper
  # Max number of organisation rows shown directly in the switcher menu. Beyond this
  # the user is sent to the full cockpit via "Alle Organisationen" (kept as a named
  # constant instead of a magic number so the boundary is testable + self-documenting).
  ORG_MENU_LIMIT = 7

  # One entry per organisation-management settings tab. `controller_name` is the
  # RAILS controller_name the tab's pages render under (deliberately NOT the key
  # `controller:`, which the stimulus-wiring guard reads as a Stimulus mount);
  # `management_section_active?` uses it to keep the sidebar "Verwaltung" entry
  # highlighted across all eight tabs (plus AI_AREA_CONTROLLERS for the pages behind
  # the "KI" tab, which have no tab of their own). `label_key` / `path_helper` are resolved
  # lazily in #organisation_settings_tabs because both need view context (I18n +
  # the URL helpers, which take the org).
  #
  # `gate:` names an Organisation predicate that must answer true for the tab to be
  # offered at all. It is data rather than an inline `if` in the renderer so a second
  # gated tab needs no new branch. The gate hides the ENTRANCE only; the matching
  # policy still has to refuse the actions (CodebaseImportFilePolicy#import_permitted?).
  #
  # Since 2026-11-11 the sections are no tab row any more but the sidebar's own list while
  # the area is open (common/_navigation_management, doc/verwaltung_seitennavigation_plan.md).
  # `icon:` is the row's sign there, `group:` the block it stands in (a hairline between
  # blocks), in this order: what the organisation is, what it uses, the account above it.
  SETTINGS_TABS = [
    { key: :general,    controller_name: 'organisation_settings', label_key: 'settings.organisation_settings', path_helper: :organisation_settings_path,              icon: 'bi-building',          group: :organisation },
    { key: :members,    controller_name: 'memberships',           label_key: 'settings.members',               path_helper: :organisation_memberships_path,           icon: 'bi-people',            group: :organisation },
    { key: :roles,      controller_name: 'roles',                 label_key: 'settings.roles_permissions',     path_helper: :organisation_roles_path,                 icon: 'bi-shield-check',      group: :organisation },
    { key: :archive,    controller_name: 'archives',              label_key: 'settings.archive',               path_helper: :organisation_archives_path,              icon: 'bi-archive',           group: :organisation },
    { key: :appearance, controller_name: 'appearances',           label_key: 'settings.appearance',            path_helper: :organisation_appearance_path,            icon: 'bi-palette',           group: :organisation },
    { key: :ai,         controller_name: 'ai_overviews',          label_key: 'settings.ai',                    path_helper: :organisation_ai_overview_path,           icon: 'bi-stars',             group: :uses },
    { key: :import,     controller_name: 'codebase_import_files', label_key: 'settings.import_data',           path_helper: :organisation_codebase_import_files_path, icon: 'bi-box-arrow-in-down', group: :uses, gate: :data_import_enabled? },
    # Billing sits LAST on purpose: it is the only section that leaves the organisation
    # and talks about the account above it (BillingController forwards there), which its
    # row says with an outward sign (`leaves:`). Like every other section it is offered to
    # everyone who reaches the management area and gated per page by Pundit
    # (AccountPolicy#show_overview?).
    { key: :billing,    controller_name: 'billing',               label_key: 'settings.billing',               path_helper: :organisation_billing_path,               icon: 'bi-receipt',           group: :account, leaves: true }
  ].each(&:freeze).freeze

  # Controller names that make up the management section — derived from the tab
  # source above, never hand-maintained alongside it.
  SETTINGS_TAB_CONTROLLERS = SETTINGS_TABS.map { |tab| tab[:controller_name] }.freeze

  # The times area: the one time list and the billings behind it. Same shape and
  # same reason as SETTINGS_TABS: organisations/shared/_times_subnav renders
  # these, and times_section_active? derives the sidebar "Zeiten" highlight
  # from the same list, so the two cannot drift. `policy:` names the Pundit
  # question a tab has to answer yes to before it is offered: the bar shows no
  # tab that would end in an error message (unlike the settings bar).
  TIMES_TABS = [
    { key: :times, controller_name: 'time_sessions', label_key: 'navigation.times_tabs.times',
      path_helper: :organisation_time_sessions_path, policy: [TimeSession, :index?] },
    { key: :billings, controller_name: 'time_session_groups', label_key: 'navigation.times_tabs.billings',
      path_helper: :organisation_time_session_groups_path, policy: [TimeSessionGroup, :index?] }
  ].each(&:freeze).freeze

  TIMES_TAB_CONTROLLERS = TIMES_TABS.map { |tab| tab[:controller_name] }.freeze

  # The meetings area of the sidebar: "Alle Meetings" and the glossary. The
  # glossary has no sidebar entry of its own (user, 04.11.2026: it only serves
  # the transcription of meetings); it is reached from the head of the
  # meetings pages, and "Alle Meetings" stays lit while it is open.
  MEETINGS_SECTION_CONTROLLERS = %w[meetings_overview glossary].freeze

  # The AI area (doc/ki_bereich_navigation_plan.md S2): three tabs collapsed into one,
  # with a hub in front of them. The three pages keep their own controllers and routes,
  # so they are NOT in SETTINGS_TABS any more — and that is exactly the trap §7 of the
  # plan warns about: management_section_active? used to see them THROUGH that list, so
  # dropping them there would switch the sidebar's "Verwaltung" highlight off across the
  # whole new area. This list puts them back, and it is deliberately separate rather than
  # a fourth tab entry: they are reachable from the hub, not from the tab bar.
  # ⚠️ `ai_usages` (S6) and `ai_protocols` (S5) are listed here BEFORE the pages exist.
  # On purpose: the list only controls the sidebar highlight, a name without a page
  # has no effect, and this way none of the slices running in parallel has to touch this
  # file. Three branches that each add one word to the same line would otherwise be
  # three conflicts at the most expensive spot: the trap from §7 of the plan, whose break
  # switches the sidebar dark across the whole area.
  AI_AREA_CONTROLLERS = %w[
    ai_overviews ai_settings ai_sync_statuses prompt_personas ai_usages ai_protocols ai_configurations
  ].freeze

  # Pages below a section that are no section of their own: the section they belong to
  # stays marked in the sidebar while they are open. The access overview and the
  # invitation form belong to the members; every page of the AI area to "KI".
  MANAGEMENT_PAGE_SECTIONS = {
    'access_matrix' => :members,
    'invitations' => :members
  }.merge(AI_AREA_CONTROLLERS.index_with { :ai }).freeze

  # The organisations shown in the switcher menu: the user's ACTIVE-membership orgs (active_
  # organisations already merges Membership.active), ordered case-insensitively by name and capped
  # at ORG_MENU_LIMIT. Extracted from the view so this data logic is unit-testable and lives beside
  # the gates it belongs with. Two deliberate choices:
  #   - Organisation.by_name (a reorder) so the alphabetical sort WINS over any default scope on the relation;
  #   - a hard limit so the sidebar costs ONE small query on every page render — the full list lives
  #     in the cockpit behind "Alle Organisationen", and the row colour chips read the memoised
  #     org-colour store (no per-row query), so the switcher stays N+1-free.
  def switcher_organisations(user)
    user.active_organisations.by_name.limit(ORG_MENU_LIMIT)
  end

  # Render-ready section list: resolves label + path for `org`, dropping every section
  # whose `gate:` predicate the org answers false to. The sidebar's management list and the
  # phone's "Mehr" page render it.
  def organisation_settings_tabs(org)
    SETTINGS_TABS.filter_map do |tab|
      next if tab[:gate] && !org&.public_send(tab[:gate])

      { key: tab[:key], label: t(tab[:label_key]), path: public_send(tab[:path_helper], org),
        icon: tab[:icon], group: tab[:group], leaves: tab[:leaves] == true }
    end
  end

  # The section the current page belongs to (a SETTINGS_TABS key), nil outside the
  # management area: a section page by its controller, a page below one through
  # MANAGEMENT_PAGE_SECTIONS.
  def management_section_key(name = controller_name)
    NavigationHelper.section_key_for(name)
  end

  # The same answer without a view: Organisations::ManagementReturn asks it in a
  # before_action, where calling `helpers` would build (and keep) a view context before
  # the controller has set its instance variables.
  def self.section_key_for(name)
    SETTINGS_TABS.find { |tab| tab[:controller_name] == name }&.dig(:key) || MANAGEMENT_PAGE_SECTIONS[name]
  end

  # True on any organisation-management page: a section, or a page below one. It switches
  # the sidebar to the management list and lights the gear in the organisation header.
  def management_section_active?
    !management_section_key.nil?
  end

  # The label of a section, for the page head: the head names the section.
  def management_section_label(key)
    tab = SETTINGS_TABS.find { |entry| entry[:key] == key.to_sym }
    t(tab.fetch(:label_key))
  end

  # The tabs of the members section (doc/verwaltung_seitennavigation_plan.md §5): the list
  # and the access overview, the second only for whom the matrix opens.
  def members_section_tabs(org)
    tabs = [{ key: :members, label: t('settings.members'), path: organisation_memberships_path(org) }]
    if policy(:access_matrix).index?
      tabs << { key: :access_matrix, label: t('views.organisations.access_matrix.index.title'),
                path: organisation_access_matrix_index_path(org) }
    end
    tabs
  end

  # Where "‹ Zurück" of the management list leads: the app page the reader came from
  # (Organisations::ManagementReturn keeps it in the session when the area is entered),
  # the dashboard if there is none or it belongs to another organisation.
  def management_return_path(org)
    stored = session[Organisations::ManagementReturn::SESSION_KEY]
    root = organisation_root_path(organisation_id: org.id)
    stored.is_a?(String) && (stored == root || stored.start_with?("#{root}/", "#{root}?")) ? stored : root
  end

  # The tabs of the times area this reader may open (TIMES_TABS, policy applied).
  def times_area_tabs(org)
    TIMES_TABS.filter_map do |tab|
      next if tab[:policy] && !policy(tab[:policy].first).public_send(tab[:policy].last)

      { key: tab[:key], label: t(tab[:label_key]), path: public_send(tab[:path_helper], org) }
    end
  end

  # True on every page of the times area (the list and the billings). Drives the
  # sidebar "Zeiten" active-state, like management_section_active? does for
  # "Verwaltung": the entry stays lit however deep the reader is.
  def times_section_active?
    TIMES_TAB_CONTROLLERS.include?(controller_name)
  end

  # True on "Alle Meetings" and on the glossary (MEETINGS_SECTION_CONTROLLERS).
  def meetings_section_active?
    MEETINGS_SECTION_CONTROLLERS.include?(controller_name)
  end

  # Can the current user reach organisation management? Port of the inline gate the nav
  # partial used: account admin, or any of the account-management permissions (seeing roles
  # already counts — read access to the management area). Guards on current_user (nil ⟺
  # signed out), which is exactly what user_signed_in? checked but is unit-testable in isolation.
  def can_manage_organisation?(organisation)
    return false unless organisation && current_user

    current_user.account_admin_in?(organisation) ||
      %w[manage_users create_users change_user_roles see_roles modify_roles].any? do |action|
        current_user.has_permission_in_organisation?(organisation, 'accounts', action)
      end
  end

  # Can the current user invite members? A strict SUBSET of #can_manage_organisation?
  # (only the two user-creating permissions), so every inviter also reaches management.
  def can_invite_to_organisation?(organisation)
    return false unless organisation && current_user

    current_user.account_admin_in?(organisation) ||
      %w[manage_users create_users].any? do |action|
        current_user.has_permission_in_organisation?(organisation, 'accounts', action)
      end
  end
end
