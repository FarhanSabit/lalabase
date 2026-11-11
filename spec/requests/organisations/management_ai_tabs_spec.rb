# frozen_string_literal: true

require 'rails_helper'

# What: the KI section of the management area and its tab row
#       (doc/verwaltung_seitennavigation_plan.md §2.3, §5 and S3;
#       NavigationHelper#ai_section_tabs):
#       - each of the six tab pages (Übersicht, Zugang, Verbrauch, Indexierung,
#         Chat-Personas, Protokoll) names the section in its one h1, lists the six
#         tabs in this order and marks its own tab as the one current page;
#       - each page below a tab (Eigene Konfiguration and the package switch below
#         Zugang, the persona forms below Chat-Personas) keeps that head and the
#         tabs, marks the tab as its parent and names itself in the crumb, which is
#         its one way back: no back arrow, no "Abbrechen" beside it;
#       - while AI is off, Verbrauch, Indexierung and Chat-Personas stay in the row
#         but locked: no link, a lock sign, the reason as the tooltip. Zugang and
#         Protokoll stay open, as the hub's rows do;
#       - the hub's main action stands in the head: the first open step of the
#         setup, or nothing once both are done.
# Why:  until 2026-11-11 the AI area had a header of its own (the title "KI" and a
#       crumb "‹ KI" back to the hub on every page, N1 of
#       doc/ki_bereich_navigation_plan.md: no second tab row). The user replaced it
#       with the tab row every section with pages of its own has, and the pages below
#       a tab follow the rule of every page below a section
#       (spec/requests/organisations/management_pages_below_spec.rb).
RSpec.describe 'Management: the tab row of the KI section', type: :request do
  # The six tabs in their order: the page's name in this file, the key of the tab's
  # label under views.organisations.ai_overview, the page's route, and whether the tab
  # waits for AI. Written out here rather than read from NavigationHelper::AI_SECTION_TABS,
  # so a changed order or a lost lock there turns this file red.
  tab_pages = [
    ['the hub', 'pages.overview', :organisation_ai_overview_path, false],
    ['Zugang', 'pages.access', :organisation_ai_settings_path, false],
    ['Verbrauch', 'usage.title', :organisation_ai_usage_path, true],
    ['Indexierung', 'pages.index', :organisation_ai_sync_status_path, true],
    ['Chat-Personas', 'pages.personas', :organisation_prompt_personas_path, true],
    ['Protokoll', 'protocol.title', :organisation_ai_protocol_path, false]
  ]

  let(:six_tabs) { tab_pages }
  let(:ai_on) { true }
  let(:organisation) { create(:organisation, name: 'Beispiel GmbH', ai_enabled: ai_on) }
  let(:admin) { create(:user, first_name: 'Anna', last_name: 'Beispiel') }
  let(:section) { I18n.t('settings.ai') }

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, organisation: organisation, user: admin,
                          role: create(:admin_role, organisation: organisation), active: true)
    end
    sign_in admin
  end

  def ai_t(key, **) = I18n.t("views.organisations.ai_overview.#{key}", **)

  def doc_for(path)
    get path
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  # The head names the section on every page of it, in the page's one h1.
  def expect_section_head(doc)
    expect(doc.css('main h1').map { |h1| h1.text.squish }).to eq([section])
  end

  # The tab row: the nav in main named after the section (organisations/shared/_subnav).
  def tab_row(doc)
    rows = doc.css("main nav[aria-label='#{section}']")
    expect(rows.size).to eq(1), "expected one tab row named #{section.inspect} in main, found #{rows.size}"
    rows.first
  end

  # Each tab as the reader meets it: a link, or the span of a locked tab.
  def tabs(doc) = tab_row(doc).css('li').map { |item| item.element_children.first }

  # A tab's own words. A locked tab repeats its reason for screen readers, in an
  # element of its own, which this leaves out.
  def label_of(tab) = tab.xpath('text()').text.squish

  def marked_tabs(doc) = tabs(doc).select { |tab| tab['aria-current'] }.map { |tab| [label_of(tab), tab['aria-current']] }

  # The six tabs in their order, each a link to its page, and while AI is off the
  # three that wait for it locked: no link, the lock, the reason as the tooltip.
  def expect_six_tabs(doc)
    row = tabs(doc)
    expect(row.map { |tab| label_of(tab) }).to eq(six_tabs.map { |(_, label_key)| ai_t(label_key) })

    row.zip(six_tabs).each do |tab, (_, label_key, route, needs_ai)|
      label = ai_t(label_key)
      if needs_ai && !ai_on
        expect(tab.name).to eq('span'), "#{label} is <#{tab.name}> while AI is off, not a locked <span>"
        expect(tab.css('a, [href]')).to be_empty, "#{label} leads somewhere while AI is off"
        expect(tab.at_css('i.bi-lock')).to be_present, "#{label} carries no lock while AI is off"
        expect(tab['title']).to eq(ai_t('tabs.locked')), "#{label} does not say why it is locked"
      else
        expect(tab.name).to eq('a'), "#{label} is no link#{' while AI is off' unless ai_on}"
        expect(tab['href']).to eq(public_send(route, organisation))
        expect(tab.at_css('i.bi-lock')).to be_nil, "#{label} carries a lock"
      end
    end
  end

  describe 'the six tab pages' do
    # With AI off the hub keeps its locked rows visible, so a prospect sees what they
    # would get, and the tabs do the same. Opened by its URL, a locked tab's page marks
    # its tab as the open one all the same.
    { true => 'with AI on, every tab a link', false => 'with AI off, three tabs locked' }.each do |on, state|
      context state do
        let(:ai_on) { on }

        tab_pages.each do |name, label_key, route|
          it "#{name} names the section, lists the six tabs and is its own open tab" do
            doc = doc_for(public_send(route, organisation))

            expect_section_head(doc)
            expect_six_tabs(doc)
            expect(marked_tabs(doc)).to eq([[ai_t(label_key), 'page']])
            expect(doc.css('main [aria-current="page"]').size).to eq(1)
          end
        end
      end
    end
  end

  describe 'a page below a tab' do
    let(:access) { ai_t('pages.access') }
    let(:personas) { ai_t('pages.personas') }

    # One shape for every page below a tab: the section's head and the six tabs, the
    # parent tab marked as the parent ("true", not "page"), the crumb back to the
    # parent naming the page, the page as the one current item, no other way back,
    # and the section still marked in the sidebar.
    def expect_below_tab(doc, parent:, crumb_path:, page:)
      expect_section_head(doc)
      expect_six_tabs(doc)
      expect(marked_tabs(doc)).to eq([[parent, 'true']])

      crumb = doc.at_css('main [data-section-crumb]')
      expect(crumb).to be_present
      back = crumb.at_css('a')
      expect(back['href']).to eq(crumb_path)
      expect(back.text.delete('‹').squish).to eq(parent)
      expect(crumb.at_css('[aria-current="page"]').text.squish).to eq(page)
      expect(doc.css('main [aria-current="page"]').size).to eq(1)

      expect(doc.css('main i.bi-arrow-left')).to be_empty
      others = other_ways_back(doc, crumb_path)
      expect(others).to be_empty, "a second way back besides the crumb: #{others.inspect}"
      expect(doc.css('#sidebar [data-management-nav] a.sidebar-row--active').map { |link| link.text.squish })
        .to eq([section])
    end

    # The links in main to the crumb's target outside the crumb and the tab row, by
    # their text. Query aside: an "Abbrechen" that carries a parameter leads back too.
    def other_ways_back(doc, crumb_path)
      parent = crumb_path.split('?').first
      doc.css('main a[href]').select { |link| link['href'].split('?').first == parent }
         .reject { |link| link.ancestors('nav').any? }
         .map { |link| link.text.squish }
    end

    it 'Eigene Konfiguration stands below Zugang' do
      doc = doc_for(organisation_ai_configuration_path(organisation))

      expect_below_tab(doc, parent: access, crumb_path: organisation_ai_settings_path(organisation),
                            page: ai_t('configuration.title'))
    end

    # The dialog opens only for a package whose search runs in another vector space
    # than the organisation's today (AiSettingsController#confirm_package): the
    # system's lane is text-embedding-3-small at 1536 dimensions, the package's
    # another model at 3072. Its crumb leads onto the pane the card stood in, so it
    # carries package_mode, while the tab Zugang leads to the page as such.
    it 'the package switch stands below Zugang and leads back onto the pane it came from' do
      create(:ai_credential, :active, provider: 'openai', region: 'eu', company_domicile: 'eu')
      target = create(:ai_package, :with_tiers, active: true, embedding_model: 'text-embedding-3-large',
                                                embedding_dims: 3072)

      doc = doc_for(confirm_package_organisation_ai_settings_path(organisation, ai_package_id: target.id,
                                                                                package_mode: 'packages'))

      expect_below_tab(doc, parent: access,
                            crumb_path: organisation_ai_settings_path(organisation, package_mode: 'packages'),
                            page: ai_t('pages.switch'))
    end

    it 'the new persona form stands below Chat-Personas' do
      doc = doc_for(new_organisation_prompt_persona_path(organisation))

      expect_below_tab(doc, parent: personas, crumb_path: organisation_prompt_personas_path(organisation),
                            page: I18n.t('views.organisations.prompt_personas.new.title'))
    end

    it 'the edit form of a persona of the organisation stands below Chat-Personas' do
      persona = create(:prompt_persona, organisation: organisation, key: 'beispiel_stil')

      doc = doc_for(edit_organisation_prompt_persona_path(organisation, persona))

      expect_below_tab(doc, parent: personas, crumb_path: organisation_prompt_personas_path(organisation),
                            page: I18n.t('views.organisations.prompt_personas.edit.title', key: 'beispiel_stil'))
    end

    # Opened by its URL while AI is off, a persona form sits below a locked tab: the
    # tab stays locked and still says it is the form's parent.
    context 'with AI off' do
      let(:ai_on) { false }

      it 'the new persona form keeps its locked parent marked' do
        doc = doc_for(new_organisation_prompt_persona_path(organisation))

        expect_below_tab(doc, parent: personas, crumb_path: organisation_prompt_personas_path(organisation),
                              page: I18n.t('views.organisations.prompt_personas.new.title'))
      end
    end
  end

  # The hub answers "muss ich etwas tun?" with one main action in the head, the first
  # open step of the setup in the order of the Zugang plan: choose the access, then
  # throw the switch. The hub carries no other tool in its head, so its controls are
  # the main action or nothing.
  describe "the hub's main action" do
    let(:ai_on) { false }

    # The controls of the head's row (the title, right of it the tools and the main
    # action outermost), as [label, where it leads or posts to].
    def head_controls(doc)
      doc.at_css('main h1').ancestors('.flex.flex-wrap').first.css('a, button').map do |control|
        [control.text.squish, control['href'] || control.ancestors('form').first&.[]('action')]
      end
    end

    def choose_access
      organisation.update!(ai_package: create(:ai_package, :with_tiers, active: true))
    end

    it 'is "Zugang einrichten" while no access is chosen' do
      doc = doc_for(organisation_ai_overview_path(organisation))

      expect(head_controls(doc)).to eq([[ai_t('actions.set_up_access'), organisation_ai_settings_path(organisation)]])
    end

    it 'is "KI einschalten" once the access is chosen and AI is off' do
      choose_access

      doc = doc_for(organisation_ai_overview_path(organisation))

      expect(head_controls(doc)).to eq([[ai_t('actions.switch_on'), activate_organisation_ai_settings_path(organisation)]])
    end

    context 'with AI on' do
      let(:ai_on) { true }

      it 'is gone once the access is chosen and AI is on' do
        choose_access

        doc = doc_for(organisation_ai_overview_path(organisation))

        expect(head_controls(doc)).to eq([])
      end
    end
  end
end
