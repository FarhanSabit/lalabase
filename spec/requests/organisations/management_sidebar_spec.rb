# frozen_string_literal: true

require 'rails_helper'

# What: the management area has its own navigation in the sidebar (user,
#       2026-11-11; doc/verwaltung_seitennavigation_plan.md):
#       - while a page of the area is open the sidebar lists its sections
#         (blocks: the organisation, what it uses, the account) instead of the
#         app's entries and projects, the open section marked, also on a page
#         below it; "Rechnung" says it leads out;
#       - "‹ Zurück" leads to the app page the reader came from, the dashboard
#         without one, never to another organisation or host;
#       - each page's head is a page head: the title names the section, the
#         tools stand right of it; the members section has the access overview
#         as its second tab; the old tab row of the area is gone;
#       - switching the organisation stays in the open section where the reader
#         may manage the other one.
# Why:  the tools of a tab stood under the tab row while every other page puts
#       them top right, and the head above them named the area, not the tab.
RSpec.describe 'Management sidebar', type: :request do
  let(:organisation) { create(:organisation, name: 'Beispiel GmbH') }
  let(:other_organisation) { create(:organisation, name: 'Zweite GmbH') }
  let(:admin) { create(:user, first_name: 'Anna', last_name: 'Beispiel') }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, organisation: organisation, user: admin, role: create(:admin_role, organisation: organisation))
    sign_in admin
  end

  after { ActsAsTenant.current_tenant = nil }

  def doc_for(path, referer: nil)
    get path, headers: referer ? { 'Referer' => "http://www.example.com#{referer}" } : {}
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  def sidebar(doc) = doc.at_css('#sidebar')

  def section_words(doc) = sidebar(doc).css('[data-management-nav] a').map { |link| link.text.squish }

  def back_href(doc) = sidebar(doc).css('a').find { |link| link.text.squish == I18n.t('navigation.management_back') }&.[]('href')

  describe 'the sidebar' do
    it 'lists the sections in three blocks instead of the app, the open one marked' do
      doc = doc_for(organisation_memberships_path(organisation))

      expect(section_words(doc)).to eq(%w[organisation_settings members roles_permissions archive appearance ai billing]
        .map { |key| I18n.t("settings.#{key}") })
      expect(sidebar(doc).css('[data-management-nav] ul').size).to eq(3)
      active = sidebar(doc).css('[data-management-nav] a.sidebar-row--active').map { |link| link.text.squish }
      expect(active).to eq([I18n.t('settings.members')])
      expect(sidebar(doc).text).not_to include(I18n.t('navigation.org_dashboard'), I18n.t('navigation.projects_label'))
      billing = sidebar(doc).css('[data-management-nav] a').find { |link| link.text.squish == I18n.t('settings.billing') }
      expect(billing.at_css('i.bi-arrow-up-right')).to be_present
    end

    it 'offers the import only where the organisation has it on' do
      organisation.update!(data_import_enabled: true)

      expect(section_words(doc_for(organisation_settings_path(organisation)))).to include(I18n.t('settings.import_data'))
    end

    # The access overview and the AI usage render with an N+1 of their own (users per
    # row), which is not what this example is about.
    it 'keeps the section marked on a page below it' do
      Prosopite.pause
      { organisation_access_matrix_index_path(organisation) => 'settings.members',
        new_organisation_invitation_path(organisation) => 'settings.members',
        organisation_ai_usage_path(organisation) => 'settings.ai' }.each do |path, key|
        active = sidebar(doc_for(path)).css('[data-management-nav] a.sidebar-row--active').map { |link| link.text.squish }
        expect(active).to eq([I18n.t(key)]), path
      end
    ensure
      Prosopite.resume
    end

    it 'shows the app and its projects again outside the area' do
      doc = doc_for(organisation_notifications_path(organisation, state_filters: %w[read unread]))

      expect(sidebar(doc).at_css('[data-management-nav]')).to be_nil
      expect(sidebar(doc).text).to include(I18n.t('navigation.projects_label'))
    end
  end

  describe '‹ Zurück' do
    let(:inbox) { organisation_notifications_path(organisation, state_filters: %w[read unread]) }

    it 'leads to the app page the area was entered from, across sections' do
      doc_for(organisation_settings_path(organisation), referer: inbox)
      doc = doc_for(organisation_roles_path(organisation), referer: organisation_settings_path(organisation))

      expect(back_href(doc)).to eq(inbox)
    end

    it 'leads to the dashboard without such a page, from a foreign host or another organisation' do
      expect(back_href(doc_for(organisation_settings_path(organisation)))).to eq(organisation_root_path(organisation_id: organisation.id))

      get organisation_settings_path(organisation), headers: { 'Referer' => "http://evil.example.net#{inbox}" }
      expect(back_href(Nokogiri::HTML(response.body))).to eq(organisation_root_path(organisation_id: organisation.id))

      foreign = "/org/#{other_organisation.id}/inbox"
      expect(back_href(doc_for(organisation_settings_path(organisation), referer: foreign)))
        .to eq(organisation_root_path(organisation_id: organisation.id))
    end
  end

  describe 'the heads' do
    it 'names the section and drops the tab row of the area' do
      doc = doc_for(organisation_roles_path(organisation))

      expect(doc.at_css('main h1').text.squish).to eq(I18n.t('settings.roles_permissions'))
      main_links = doc.css('main nav a').map { |link| link.text.squish }
      expect(main_links).not_to include(I18n.t('settings.organisation_settings'), I18n.t('settings.archive'))
    end

    it 'puts the help of Allgemein into its head' do
      head = doc_for(organisation_settings_path(organisation)).at_css('main h1').ancestors('div.mb-6, div.mb-3\.5').first

      expect(head.at_css('[data-controller~="contextual-help-menu"], .contextual-help-menu, details, button')).to be_present
    end

    it 'gives the members a head with the count, the help and the "+", and the access overview as a tab' do
      doc = doc_for(organisation_memberships_path(organisation))
      title_row = doc.at_css('main h1').ancestors('.flex.flex-wrap').first

      expect(doc.at_css('main h1').text.squish).to eq(I18n.t('settings.members'))
      expect(title_row.text).to include('1')
      expect(title_row.at_css("a[href='#{new_organisation_invitation_path(organisation)}'][title='#{I18n.t('member_management.invite')}']")).to be_present
      tabs = doc.css('main nav a')
      expect(tabs.map { |tab| tab.text.squish }).to eq([I18n.t('settings.members'), I18n.t('views.organisations.access_matrix.index.title')])
      expect(tabs.first['aria-current']).to eq('page')
    end

    it 'shows the access overview under the members head, its tab marked, without a back button' do
      doc = doc_for(organisation_access_matrix_index_path(organisation))

      expect(doc.at_css('main h1').text.squish).to eq(I18n.t('settings.members'))
      expect(doc.css('main nav a[aria-current="page"]').map { |tab| tab.text.squish })
        .to eq([I18n.t('views.organisations.access_matrix.index.title')])
      expect(doc.css('main i.bi-arrow-left')).to be_empty
    end
  end

  describe 'switching the organisation' do
    before do
      ActsAsTenant.with_tenant(other_organisation) do
        create(:membership, organisation: other_organisation, user: admin, role: create(:admin_role, organisation: other_organisation))
      end
    end

    it 'stays in the open section where the reader may manage the other organisation' do
      post set_organisation_path, params: { organisation_id: other_organisation.id, section: 'members' }

      expect(response).to redirect_to(organisation_memberships_path(other_organisation))
    end

    it 'lands on the root for a section that is no section, or one the organisation does not offer' do
      post set_organisation_path, params: { organisation_id: other_organisation.id, section: 'nonsense' }
      expect(response).to redirect_to(organisation_root_path(organisation_id: other_organisation.id))

      post set_organisation_path, params: { organisation_id: other_organisation.id, section: 'import' }
      expect(response).to redirect_to(organisation_root_path(organisation_id: other_organisation.id))
    end

    it 'lands on the root where the reader may not manage the other organisation' do
      third = create(:organisation)
      ActsAsTenant.with_tenant(third) do
        create(:membership, organisation: third, user: admin, role: create(:role, organisation: third))
      end

      post set_organisation_path, params: { organisation_id: third.id, section: 'members' }

      expect(response).to redirect_to(organisation_root_path(organisation_id: third.id))
    end

    it 'carries the open section in the switcher of a management page only' do
      doc = doc_for(organisation_memberships_path(organisation))
      expect(doc.css('#sidebar form input[name="section"]').map { |input| input['value'] }.uniq).to eq(['members'])

      doc = doc_for(organisation_notifications_path(organisation, state_filters: %w[read unread]))
      expect(doc.css('#sidebar form input[name="section"]')).to be_empty
    end
  end

  it 'lists the sections on the phone\'s "Mehr" page' do
    doc = doc_for(organisation_mobile_more_path(organisation))

    expect(doc.css('[data-management-nav] a').map { |link| link.text.squish })
      .to eq(%w[organisation_settings members roles_permissions archive appearance ai billing].map { |key| I18n.t("settings.#{key}") })
  end
end
