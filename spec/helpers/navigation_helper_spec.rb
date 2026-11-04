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
        ai: 'ai_overviews',
        import: 'codebase_import_files',
        appearance: 'appearances',
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
      %w[ai_settings ai_sync_statuses prompt_personas].each do |controller|
        allow(helper).to receive(:controller_name).and_return(controller)
        expect(helper.management_section_active?).to be(true), "sidebar went dark on '#{controller}'"
      end
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
        ai: organisation_ai_overview_path(organisation),
        import: organisation_codebase_import_files_path(organisation),
        appearance: organisation_appearance_path(organisation),
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
end
