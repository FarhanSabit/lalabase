# frozen_string_literal: true

require 'rails_helper'

# What: NavigationHelper — the org-nav permission gates + the single source for the settings tabs.
# Type: Helper (unit) spec.
# Why:  The request spec can only reach realizable permission states; this pins the LOGIC the plan
#       cares about but that a stored Permission cannot express, at the DECISION POINTS:
#         - can_invite_to_organisation? is a STRICT SUBSET of can_manage_organisation?, and each
#           whitelisted action lands in the right gate (positive iteration — catches a shrunk list);
#         - the settings-tab set is a fixed contract (keys, order, controller, path), asserted
#           DECOUPLED from SETTINGS_TABS so a reorder/rename/removal breaks a test rather than
#           silently drifting the subnav + the sidebar active-state that both derive from it.
RSpec.describe NavigationHelper, type: :helper do
  # Actions that grant management but NOT invite (the strict-subset boundary), and the two that
  # grant BOTH. Locals (not constants) so they drive example generation without leaking a constant;
  # hardcoded on purpose — mirroring the helper's own lists would make the test tautological, an
  # explicit restatement is what turns a shrunk gate list into a red test.
  management_only_actions = %w[change_user_roles see_roles modify_roles]
  invite_also_actions     = %w[manage_users create_users]

  describe 'organisation permission gates' do
    let(:organisation) { build_stubbed(:organisation) }
    let(:current_user) { instance_double(User) }

    before do
      allow(helper).to receive(:current_user).and_return(current_user)
      allow(current_user).to receive(:account_admin_in?).with(organisation).and_return(false)
      # Default: no accounts permission unless a spec grants a specific one.
      allow(current_user).to receive(:has_permission_in_organisation?).and_return(false)
    end

    def grant(action)
      allow(current_user).to receive(:has_permission_in_organisation?)
        .with(organisation, 'accounts', action).and_return(true)
    end

    management_only_actions.each do |action|
      it "grants management but NOT invite via accounts/#{action} (strict subset)" do
        grant(action)
        expect(helper.can_manage_organisation?(organisation)).to be(true)
        expect(helper.can_invite_to_organisation?(organisation)).to be(false)
      end
    end

    invite_also_actions.each do |action|
      it "grants BOTH management and invite via accounts/#{action}" do
        grant(action)
        expect(helper.can_manage_organisation?(organisation)).to be(true)
        expect(helper.can_invite_to_organisation?(organisation)).to be(true)
      end
    end

    it 'grants nothing to a member with no accounts permission' do
      expect(helper.can_manage_organisation?(organisation)).to be(false)
      expect(helper.can_invite_to_organisation?(organisation)).to be(false)
    end

    it 'grants both to an account admin regardless of individual permissions' do
      allow(current_user).to receive(:account_admin_in?).with(organisation).and_return(true)

      expect(helper.can_manage_organisation?(organisation)).to be(true)
      expect(helper.can_invite_to_organisation?(organisation)).to be(true)
    end

    it 'is false for a signed-out visitor' do
      allow(helper).to receive(:current_user).and_return(nil)

      expect(helper.can_manage_organisation?(organisation)).to be(false)
      expect(helper.can_invite_to_organisation?(organisation)).to be(false)
    end
  end

  # The times area (the one time list and the billings): same contract as the
  # settings tabs, same reason. The subnav renders TIMES_TABS and the sidebar
  # entry "Zeiten" derives its highlight from the same list.
  describe 'times tabs are a fixed contract' do
    let(:expected_key_to_controller) do
      { times: 'time_sessions', billings: 'time_session_groups' }
    end

    it 'has exactly these keys, in this order, on these controllers' do
      expect(described_class::TIMES_TABS.map { |tab| [tab[:key], tab[:controller_name]] })
        .to eq(expected_key_to_controller.to_a)
    end

    it 'lights the times section on each tab controller and nowhere else' do
      expected_key_to_controller.each_value do |controller|
        allow(helper).to receive(:controller_name).and_return(controller)
        expect(helper.times_section_active?).to be(true), "expected active on '#{controller}'"
      end

      %w[projects tickets organisation_settings].each do |controller|
        allow(helper).to receive(:controller_name).and_return(controller)
        expect(helper.times_section_active?).to be(false), "unexpectedly active on '#{controller}'"
      end
    end
  end

  describe '#meetings_section_active?' do
    it 'lights "Alle Meetings" on that page and on the glossary, nowhere else' do
      %w[meetings_overview glossary].each do |controller|
        allow(helper).to receive(:controller_name).and_return(controller)
        expect(helper.meetings_section_active?).to be(true), "expected active on '#{controller}'"
      end

      %w[meetings people time_sessions projects].each do |controller|
        allow(helper).to receive(:controller_name).and_return(controller)
        expect(helper.meetings_section_active?).to be(false), "unexpectedly active on '#{controller}'"
      end
    end
  end

  describe 'settings tabs are a fixed contract' do
    # Explicit, DECOUPLED expectation (key => controller_name), in tab-bar order. The subnav renders
    # these and management_section_active? derives its controller list from the SAME source; pinning
    # them here means a reorder, rename, removal, or wrong controller mapping breaks a test.
    let(:expected_key_to_controller) do
      {
        general: 'organisation_settings',
        members: 'memberships',
        roles: 'roles',
        archive: 'archives',
        appearance: 'appearances',
        ai: 'ai_overviews',
        import: 'codebase_import_files',
        billing: 'billing'
      }
    end

    it 'maps exactly these eight keys to these controllers, in this order' do
      actual = NavigationHelper::SETTINGS_TABS.map { |tab| [tab[:key], tab[:controller_name]] }
      expect(actual).to eq(expected_key_to_controller.to_a)
    end

    it 'lights the management section on each tab controller and nowhere else' do
      expected_key_to_controller.each_value do |controller|
        allow(helper).to receive(:controller_name).and_return(controller)
        expect(helper.management_section_active?).to be(true), "expected active on '#{controller}'"
      end

      allow(helper).to receive(:controller_name).and_return('projects')
      expect(helper.management_section_active?).to be(false)
    end

    # THE trap of the S2 move (doc/ki_bereich_navigation_plan.md §7): the three AI pages
    # used to be tabs, so management_section_active? saw them through SETTINGS_TABS.
    # Collapsing them behind one "KI" tab drops them out of that list — and without
    # AI_AREA_CONTROLLERS the sidebar's "Verwaltung" highlight would switch off across
    # the entire new area while the user is standing in the middle of it. Pinned per
    # controller, not as a set comparison, so the failure names the page that went dark.
    it 'keeps the management section lit on every page BEHIND the KI tab' do
      %w[ai_settings ai_sync_statuses prompt_personas ai_usages ai_protocols ai_configurations].each do |controller|
        allow(helper).to receive(:controller_name).and_return(controller)
        expect(helper.management_section_active?).to be(true), "sidebar went dark on '#{controller}'"
        expect(helper.management_section_key).to eq(:ai)
      end
    end

    # The sidebar lists the sections while the area is open (2026-11-11): a page below a
    # section marks that section, so the access overview and the invitation form mark
    # the members.
    it 'names the section of a page below one' do
      { 'access_matrix' => :members, 'invitations' => :members, 'memberships' => :members,
        'organisation_settings' => :general, 'projects' => nil }.each do |controller, key|
        allow(helper).to receive(:controller_name).and_return(controller)
        expect(helper.management_section_key).to eq(key), controller
      end
    end

    it 'gives every section a sign and a block, the account last and leading out' do
      tabs = NavigationHelper::SETTINGS_TABS
      expect(tabs.map { |tab| tab[:icon] }).to all(start_with('bi-'))
      expect(tabs.map { |tab| tab[:group] }.chunk_while { |a, b| a == b }.map(&:first)).to eq(%i[organisation uses account])
      expect(tabs.select { |tab| tab[:leaves] }.map { |tab| tab[:key] }).to eq([:billing])
    end

    it 'resolves each tab to its real settings route with a present label' do
      organisation = create(:organisation, data_import_enabled: true)
      tabs = helper.organisation_settings_tabs(organisation)

      expect(tabs.map { |tab| tab[:key] }).to eq(expected_key_to_controller.keys)
      expect(tabs.map { |tab| tab[:label] }).to all(be_present)
      expect(tabs.to_h { |tab| [tab[:key], tab[:path]] }).to eq(
        general: organisation_settings_path(organisation),
        members: organisation_memberships_path(organisation),
        roles: organisation_roles_path(organisation),
        archive: organisation_archives_path(organisation),
        appearance: organisation_appearance_path(organisation),
        ai: organisation_ai_overview_path(organisation),
        import: organisation_codebase_import_files_path(organisation),
        billing: organisation_billing_path(organisation)
      )
    end

    # `all(be_present)` above cannot see a MISSING English key: config/initializers/i18n.rb
    # sets fallbacks = [:de], so an absent en translation silently renders the German one
    # and be_present is satisfied. The new tab is therefore pinned on the literal word per
    # locale. (Doing the same for the other seven is a change of its own.)
    it 'spells the archive tab in the viewer locale, not in the German fallback' do
      organisation = create(:organisation)

      de = I18n.with_locale(:de) { helper.organisation_settings_tabs(organisation) }
      en = I18n.with_locale(:en) { helper.organisation_settings_tabs(organisation) }

      expect(de.find { |tab| tab[:key] == :archive }[:label]).to eq('Archiv')
      expect(en.find { |tab| tab[:key] == :archive }[:label]).to eq('Archive')
    end

    # The import tab is `gate:`d on an operator flag that is OFF for every new
    # organisation. Asserted on the KEY LIST rather than on the absence of one entry,
    # so a gate that accidentally swallowed a neighbouring tab would fail here too.
    it 'drops the gated import tab for an organisation whose flag is off, keeping the rest' do
      organisation = create(:organisation)
      expect(organisation.data_import_enabled?).to be(false), 'expected the flag to default to off'

      keys = helper.organisation_settings_tabs(organisation).map { |tab| tab[:key] }

      expect(keys).to eq(expected_key_to_controller.keys - [:import])
    end
  end

  # The AI section's own tab row (doc/verwaltung_seitennavigation_plan.md S3): the hub
  # first, then its pages. Pinned on literal routes and literal words per locale, DECOUPLED
  # from AI_SECTION_TABS, so a reorder, a wrong route or a missing English key breaks a
  # test (be_present cannot see the last one: fallbacks = [:de]).
  describe '#ai_section_tabs' do
    # The factory switches AI on for every organisation; the lock is the case here.
    let(:organisation) { create(:organisation, :ai_disabled) }

    def keys(tabs) = tabs.map { |tab| tab[:key] }

    it 'lists the six pages of the section in this order, each on its route' do
      tabs = helper.ai_section_tabs(organisation)

      expect(tabs.map { |tab| [tab[:key], tab[:path]] }).to eq(
        [
          [:overview, organisation_ai_overview_path(organisation)],
          [:access, organisation_ai_settings_path(organisation)],
          [:usage, organisation_ai_usage_path(organisation)],
          [:index, organisation_ai_sync_status_path(organisation)],
          [:personas, organisation_prompt_personas_path(organisation)],
          [:protocol, organisation_ai_protocol_path(organisation)]
        ]
      )
    end

    it 'names every tab in the viewer locale, not in the German fallback' do
      de = I18n.with_locale(:de) { helper.ai_section_tabs(organisation) }
      en = I18n.with_locale(:en) { helper.ai_section_tabs(organisation) }

      expect(de.map { |tab| tab[:label] }).to eq(%w[Übersicht Zugang Verbrauch Indexierung Chat-Personas Protokoll])
      expect(en.map { |tab| tab[:label] }).to eq(['Overview', 'Access', 'Usage', 'Indexing', 'Chat personas', 'Protocol'])
    end

    # As the hub's rows (§7a, 2): with AI off a prospect still sees what the section holds.
    # Zugang and Protokoll stay open: the access is set up BEFORE switching on, and the
    # protocol keeps the record of a switch-off.
    it 'locks Verbrauch, Indexierung and Chat-Personas while AI is off, each with the reason' do
      de = I18n.with_locale(:de) { helper.ai_section_tabs(organisation) }
      en = I18n.with_locale(:en) { helper.ai_section_tabs(organisation) }

      locked = de.select { |tab| tab[:locked] }
      expect(keys(locked)).to eq(%i[usage index personas])
      expect(locked.map { |tab| tab[:locked] }).to all(be(true))
      expect(keys(de.reject { |tab| tab[:locked] })).to eq(%i[overview access protocol])

      expect(de.filter_map { |tab| tab[:locked_title] }).to eq(['Öffnet sich, sobald die KI eingeschaltet ist'] * 3)
      expect(en.filter_map { |tab| tab[:locked_title] }).to eq(['Opens once AI is switched on'] * 3)
    end

    it 'opens every tab once AI is on' do
      tabs = helper.ai_section_tabs(create(:organisation, ai_enabled: true))

      expect(keys(tabs)).to eq(%i[overview access usage index personas protocol])
      expect(tabs.select { |tab| tab[:locked] }).to be_empty
      expect(tabs.filter_map { |tab| tab[:locked_title] }).to be_empty
    end

    # Every page of the section renders this row, so it must stay free: the lock reads the
    # column, and no policy per tab is asked (all six pages answer account_admin?).
    it 'decides the lock on the column ai_enabled alone, without a query' do
      org = organisation # created before the capture starts

      expect(capture_sql { helper.ai_section_tabs(org) }).to be_empty
    end
  end
end
