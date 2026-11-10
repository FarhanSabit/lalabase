# frozen_string_literal: true

require 'rails_helper'

# What:  The "?" contextual-help trigger (doc/kontexthilfe_plan.md) wired into the
#        phase-1 areas (Tickets, Wissen, Chat, Inbox, Übersicht) plus the phase-2
#        areas Zeiten (time_sessions), Abrechnungen (billing), Meetings and
#        Personen (people).
# Type:  Request specs against the real controller actions (full stack).
# Why:   Docs::ContextualHelp + the guard spec already prove the DATA is correct
#        (spec/services/docs/contextual_help_spec.rb); this proves the trigger is
#        actually REACHABLE from each real page and renders the right links —
#        the part a user would notice if the view wiring were missing/broken.
RSpec.describe 'Contextual help menu', type: :request do
  let(:organisation) { create(:organisation, code_indexing_enabled: true) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    end
  end
  let!(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def expect_contextual_help_trigger(response_body, context)
    expect(response_body).to include('bi-question-circle') # trigger icon
    Docs::ContextualHelp.for(context).each do |question|
      anchor = Docs::ContextualHelp.anchor_for(question, I18n.locale)
      url = Rails.application.routes.url_helpers.help_page_path(slug: question[:slug], anchor: anchor)
      # The slug#anchor link stays as no-JS fallback …
      expect(response_body).to include(%(href="#{url}"))
      # … while the drawer wiring opens the answer in the slide-over
      # (doc/kontexthilfe_drawer_plan.md, D4): action + frame URL without anchor,
      # plus the locale-resolved anchor as its own param (a rename of this key
      # would otherwise only be caught by the non-CI system spec).
      frame_url = Rails.application.routes.url_helpers.help_page_path(slug: question[:slug])
      expect(response_body).to include(%(data-contextual-help-drawer-url-param="#{frame_url}"))
      expect(response_body).to include(%(data-contextual-help-drawer-anchor-param="#{anchor}")) if anchor.present?
    end
    expect(response_body).to include('data-action="contextual-help-drawer#open"')
  end

  it 'Tickets: renders the trigger with the tickets questions' do
    get organisation_project_tickets_path(organisation, project)

    expect(response).to have_http_status(:ok)
    expect_contextual_help_trigger(response.body, :tickets)
  end

  it 'Wissen: renders the trigger with the knowledge questions' do
    get organisation_project_knowledge_index_path(organisation, project)

    expect(response).to have_http_status(:ok)
    expect_contextual_help_trigger(response.body, :knowledge)
  end

  # Was: the project chat page. projekt_chat_abbau removed it; the :chat help entry
  # itself stays (its two questions now point at the assistant page), and the panel
  # that shows it rides on every page rather than one of its own. Pinned on the
  # REGISTRY instead of on a route, which is what the entry is.
  it 'Chat: the help entry points at the assistant page, not the removed one' do
    entry = Docs::ContextualHelp::QUESTIONS.fetch(:chat).first

    expect(entry[:slug]).to eq('guides/ai/assistant')
  end

  it 'Inbox: renders the trigger with the inbox questions' do
    # Bare /inbox redirects to the default unread filter (NotificationsController#index) —
    # pass state_filters explicitly to land on the actual render.
    get organisation_notifications_path(organisation, state_filters: ['unread'])

    expect(response).to have_http_status(:ok)
    expect_contextual_help_trigger(response.body, :inbox)
  end

  it 'Übersicht: renders the trigger with the dashboard questions' do
    get organisation_root_path(organisation_id: organisation.id)

    expect(response).to have_http_status(:ok)
    expect_contextual_help_trigger(response.body, :dashboard)
  end

  it 'Zeiten: renders the trigger with the time_sessions questions' do
    get organisation_time_sessions_path(organisation)

    expect(response).to have_http_status(:ok)
    expect_contextual_help_trigger(response.body, :time_sessions)
  end

  it 'Abrechnungen: renders the trigger with the billing questions' do
    get organisation_time_session_groups_path(organisation)

    expect(response).to have_http_status(:ok)
    expect_contextual_help_trigger(response.body, :billing)
  end

  it 'Meetings: renders the trigger with the meetings questions' do
    get organisation_project_meetings_path(organisation, project)

    expect(response).to have_http_status(:ok)
    expect_contextual_help_trigger(response.body, :meetings)
  end

  it 'Alle Meetings (org overview): renders the trigger with the meetings questions' do
    get organisation_meetings_path(organisation)

    expect(response).to have_http_status(:ok)
    expect_contextual_help_trigger(response.body, :meetings)
  end

  it 'Personen: renders the trigger with the people questions' do
    get organisation_people_path(organisation)

    expect(response).to have_http_status(:ok)
    expect_contextual_help_trigger(response.body, :people)
  end

  it 'Dokumentation: renders the trigger with the documentation questions' do
    # No documentation set connected → the empty state renders, but the "?" trigger
    # lives in the page header and is present regardless of connection state.
    get organisation_project_documentation_index_path(organisation, project)

    expect(response).to have_http_status(:ok)
    expect_contextual_help_trigger(response.body, :documentation)
  end

  # The account form is the one help surface OUTSIDE the org scope: it is where
  # people end up when the confirmation banner puzzles them, or when a changed
  # e-mail address appears not to take effect.
  it 'Konto: renders the trigger with the account questions' do
    get edit_user_registration_path

    expect(response).to have_http_status(:ok)
    expect_contextual_help_trigger(response.body, :account)
  end

  # --- Organisation settings tabs (doc/settings_kontexthilfe_plan.md).
  #     One context per subnav tab; the "?" sits next to each tab's action button. ---
  it 'Mitglieder: renders the trigger with the settings_members questions' do
    get organisation_memberships_path(organisation)

    expect(response).to have_http_status(:ok)
    expect_contextual_help_trigger(response.body, :settings_members)
  end

  it 'Rollen/Rechte: renders the trigger with the settings_roles questions' do
    get organisation_roles_path(organisation)

    expect(response).to have_http_status(:ok)
    expect_contextual_help_trigger(response.body, :settings_roles)
  end

  it 'Name/Domain: renders the trigger with the settings_general questions' do
    get organisation_settings_path(organisation)

    expect(response).to have_http_status(:ok)
    expect_contextual_help_trigger(response.body, :settings_general)
  end

  it 'AI-Provider: renders the trigger with the settings_ai_provider questions' do
    get organisation_ai_settings_path(organisation)

    expect(response).to have_http_status(:ok)
    expect_contextual_help_trigger(response.body, :settings_ai_provider)
  end

  it 'AI Sync Status: renders the trigger with the settings_ai_sync questions' do
    get organisation_ai_sync_status_path(organisation)

    expect(response).to have_http_status(:ok)
    expect_contextual_help_trigger(response.body, :settings_ai_sync)
  end

  it 'Chat-Personas: renders the trigger with the settings_prompt_personas questions' do
    get organisation_prompt_personas_path(organisation)

    expect(response).to have_http_status(:ok)
    expect_contextual_help_trigger(response.body, :settings_prompt_personas)
  end

  it 'Import Data: renders the trigger with the settings_import questions' do
    # The page only exists for organisations whose operator flag is on; without it
    # CodebaseImportFilePolicy refuses the request and there is no page to help with.
    organisation.update!(data_import_enabled: true)
    get organisation_codebase_import_files_path(organisation)

    expect(response).to have_http_status(:ok)
    expect_contextual_help_trigger(response.body, :settings_import)
  end

  it 'Darstellung: renders the trigger with the settings_appearance questions' do
    get organisation_appearance_path(organisation)

    expect(response).to have_http_status(:ok)
    expect_contextual_help_trigger(response.body, :settings_appearance)
  end

  # The "?" takes the height of its neighbours in the row (F40 of the
  # Belegungstabelle): 40 px only beside the 40 px groove of the view switch
  # (F8; the 30 px icon pair of the tickets is none) or the big gear, the quiet 28 px trigger beside a "···" or the members search, and
  # otherwise the 32 px of the head buttons (F1/F2). Until 2026-11-10 it was
  # 40 px everywhere, a box bigger than "+" and "Glossar" beside it.
  describe 'the size of the trigger follows its row' do
    def help_triggers(body)
      label = I18n.t('components.contextual_help.label')
      Nokogiri::HTML(body).css("[data-controller='dropdown'] > [title='#{label}']")
    end

    def form_of(trigger)
      classes = trigger['class'].to_s.split
      return :quiet if classes.include?('more-menu__trigger')
      return :large if classes.include?('h-10')
      return :medium if classes.include?('h-8')

      :unknown
    end

    {
      'Tickets' => [:medium, -> { organisation_project_tickets_path(organisation, project) }],
      'Zeiten' => [:large, -> { organisation_time_sessions_path(organisation) }],
      'Übersicht' => [:large, -> { organisation_root_path(organisation_id: organisation.id) }],
      'Meetings' => [:medium, -> { organisation_project_meetings_path(organisation, project) }],
      'Alle Meetings' => [:medium, -> { organisation_meetings_path(organisation) }],
      'Personen' => [:medium, -> { organisation_people_path(organisation) }],
      'Dokumentation' => [:medium, -> { organisation_project_documentation_index_path(organisation, project) }],
      'Abrechnungen' => [:medium, -> { organisation_time_session_groups_path(organisation) }],
      'Wissen' => [:medium, -> { organisation_project_knowledge_index_path(organisation, project) }],
      'Rollen/Rechte' => [:medium, -> { organisation_roles_path(organisation) }],
      'Name/Domain' => [:medium, -> { organisation_settings_path(organisation) }],
      'Konto' => [:medium, -> { edit_user_registration_path }],
      'Inbox' => [:quiet, -> { organisation_notifications_path(organisation, state_filters: ['unread']) }],
      'Mitglieder' => [:quiet, -> { organisation_memberships_path(organisation) }]
    }.each do |page_name, (form, path)|
      it "#{page_name}: #{form}" do
        get instance_exec(&path)

        expect(response).to have_http_status(:ok)
        triggers = help_triggers(response.body)
        expect(triggers).not_to be_empty
        expect(triggers.map { |trigger| form_of(trigger) }.uniq).to eq([form])
      end
    end
  end

  context 'when the member is not an admin (Mitglieder tab)' do
    # D2 (doc/settings_kontexthilfe_plan.md): the "?" trigger sits OUTSIDE the
    # `if can_manage_members` branch, so it renders even without management rights
    # (non-admins still see the scoped members list). Guards against the trigger
    # being moved back inside the admin-only block.
    let(:plain_role) { create(:role, organisation: organisation) }
    let!(:membership) do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation, role: plain_role, active: true)
      end
    end

    it 'still renders the "?" trigger with the settings_members questions' do
      get organisation_memberships_path(organisation)

      expect(response).to have_http_status(:ok)
      expect_contextual_help_trigger(response.body, :settings_members)
    end
  end
end
