# frozen_string_literal: true

require 'rails_helper'

# What: the head of "Rollen und Rechte" and of the two pages below it
#       (doc/verwaltung_seitennavigation_plan.md §5, slice S2; §7a, 1 and 3):
#       - the list of roles: the view switch (list | matrix) first in the head's
#         right group, then the help, the "+" (new role) outermost as the title
#         action. The view is a GET parameter (?view=matrix, anything else is the
#         list); the page holds the chosen view only and no script remembers a
#         choice in the browser;
#       - a new role and a role being edited: the section's head and a crumb line
#         under it ("‹ Rollen und Rechte / Neue Rolle"), no back button. The
#         crumb is the only way back to the list.
# Why:  the tools stood in a row under the head, the switch was a client-side
#       toggle whose inline script kept the choice in the browser, and the role
#       forms carried a title of their own with a back arrow, unlike every other
#       page of the management area.
RSpec.describe 'Roles head', type: :request do
  let(:organisation) { create(:organisation, name: 'Beispiel GmbH') }
  let(:admin) { create(:user, first_name: 'Anna', last_name: 'Beispiel') }
  let(:help_trigger) { "[data-controller='dropdown'] > [title='#{I18n.t('components.contextual_help.label')}']" }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, organisation: organisation, user: admin, role: create(:admin_role, organisation: organisation))
    sign_in admin
  end

  after { ActsAsTenant.current_tenant = nil }

  def doc_for(path)
    get path
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  # The row of the page head: the title on the left, the group of tools on the right.
  def title_row(doc) = doc.at_css('main h1').ancestors('.flex.flex-wrap').first

  def right_group(doc) = title_row(doc).element_children.last

  def roles_path = organisation_roles_path(organisation)

  def matrix_path = organisation_roles_path(organisation, view: 'matrix')

  # Where an element stands among all elements of the group, in document order.
  def position(group, element) = group.css('*').to_a.index(element)

  describe 'the list of roles' do
    it 'shows the list without a parameter, not the matrix, and marks the list tile' do
      doc = doc_for(roles_path)

      expect(doc.at_css('main #list-view')).to be_present
      expect(doc.at_css('main #matrix-view, main [data-matrix-head]')).to be_nil
      expect(right_group(doc).css('a[aria-current="page"]').map { |tile| tile['href'] }).to eq([roles_path])
    end

    it 'shows the matrix with ?view=matrix, not the list, and marks the matrix tile' do
      doc = doc_for(matrix_path)

      expect(doc.at_css('main #matrix-view [data-matrix-head]')).to be_present
      expect(doc.at_css('main #list-view')).to be_nil
      expect(right_group(doc).css('a[aria-current="page"]').map { |tile| tile['href'] }).to eq([matrix_path])
    end

    it 'shows the list for any other value of the parameter' do
      doc = doc_for(organisation_roles_path(organisation, view: 'bogus'))

      expect(doc.at_css('main #list-view')).to be_present
      expect(doc.at_css('main #matrix-view, main [data-matrix-head]')).to be_nil
    end

    it 'puts the view switch first in the head\'s right group, before the help' do
      doc = doc_for(roles_path)
      group = right_group(doc)
      switch = group.at_css("nav[aria-label='#{I18n.t('organisations.roles.index.view_label')}']")
      help = group.at_css(help_trigger)

      expect(switch).to be_present
      expect(help).to be_present
      expect(switch.css('a').map { |tile| tile['href'] }).to eq([roles_path, matrix_path])
      expect(position(group, switch)).to be < position(group, help)
      expect(group.at_css('a, button').ancestors).to include(switch)
      expect(doc.css("main #{help_trigger}").size).to eq(1)
    end

    it 'puts the "+" outermost as the head\'s title action, after the help, leading to a new role' do
      doc = doc_for(roles_path)
      group = right_group(doc)
      action = group.element_children.last
      plus = action.at_css("a[href='#{new_organisation_role_path(organisation)}']")

      expect(action['class']).to eq(NeoTitleBoxComponent::TITLE_ACTION_CLASSES)
      expect(plus).to be_present
      expect(plus['title']).to eq(I18n.t('views.organisations.roles.index.new_role_tooltip'))
      expect(position(group, group.at_css(help_trigger))).to be < position(group, plus)
      expect(group.css('a, button').last).to eq(plus)
    end

    it 'holds no inline script and keeps no choice in the browser, in either view' do
      [roles_path, matrix_path].each do |path|
        main = doc_for(path).at_css('main')

        expect(main.css('script:not([src])')).to be_empty, path
        expect(main.inner_html).not_to include('sessionStorage', 'localStorage')
      end
    end

    %w[de en].each do |locale|
      it "names the \"+\" and the matrix tile in #{locale}" do
        doc = doc_for(organisation_roles_path(organisation, locale: locale))
        plus = right_group(doc).at_css("a[href='#{new_organisation_role_path(organisation)}']")
        grid = right_group(doc).at_css("a[href='#{matrix_path}']")
        expect([plus, grid]).to all(be_present)

        { 'views.organisations.roles.index.new_role_tooltip' => plus['title'],
          'views.organisations.roles.index.matrix_view_tooltip' => grid['aria-label'] }.each do |key, text|
          expect(text).to eq(I18n.t(key, locale: locale, fallback: false, raise: true))
          expect(text).not_to eq(key)
        end
        expect(grid['title']).to eq(grid['aria-label'])
      end
    end
  end

  describe 'the pages below the section' do
    let(:role) { create(:role, organisation: organisation, title: 'Team') }

    def expect_section_head_with_crumb(doc, page:)
      main = doc.at_css('main')
      crumb = main.at_css('[data-section-crumb]')

      expect(main.at_css('h1').text.squish).to eq(I18n.t('settings.roles_permissions'))
      expect(main.at_css('h1').ancestors.map { |node| node['class'].to_s.split }.flatten).not_to include('pt-6')
      back = crumb.at_css("a[href='#{roles_path}']")
      expect(back).to be_present
      expect(back.text.squish).to include(I18n.t('settings.roles_permissions'))
      expect(crumb.at_css('[aria-current="page"]').text.squish).to eq(page)
      expect(main.css('i.bi-arrow-left')).to be_empty
      expect(main.css('[aria-current="page"]').size).to eq(1)
      # The crumb is the only way back: no button that only leads to the list.
      expect(main.css("a[href='#{roles_path}']").size).to eq(1)
    end

    it 'gives the new role form the head of the section and a crumb back to it' do
      expect_section_head_with_crumb(doc_for(new_organisation_role_path(organisation)), page: I18n.t('organisations.roles.new.title'))
    end

    it 'gives the edit form the head of the section and a crumb naming the role' do
      expect_section_head_with_crumb(doc_for(edit_organisation_role_path(organisation, role)), page: 'Team')
    end

    it 'keeps the stored name in the crumb when a changed name is refused' do
      ActsAsTenant.with_tenant(organisation) { create(:role, organisation: organisation, title: 'Beratung') }

      patch organisation_role_path(organisation, role), params: { role: { title: 'Beratung' } }

      expect(response).to have_http_status(:unprocessable_content)
      crumb = Nokogiri::HTML(response.body).at_css('main [data-section-crumb] [aria-current="page"]')
      expect(crumb.text.squish).to eq('Team')
    end
  end
end
