# frozen_string_literal: true

require 'rails_helper'

# What: the bar of the people list in a browser (user, 2026-11-11): the
#       magnifier opens the field, the list answers while typing (no Enter),
#       the person opened by a row click stays open and in the address, Escape
#       folds the empty field before it closes the lane, and a tab keeps the
#       search and the person.
# Why:  the form, the frame, layout-toggle (which writes the term into the
#       address) and the person a row click changes in the address only meet
#       in the browser alone. The request spec sees the markup, not the order
#       in which they run.
RSpec.describe 'People tab bar', type: :system do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, first_name: 'Anna', last_name: 'Beispiel') }
  let(:frame_id) { Organisations::PeopleController::DETAIL_FRAME_ID }

  before do
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
    role = create(:role, organisation: organisation, title: Role::ACCOUNT_ADMIN_TITLE)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    create(:person, organisation: organisation, name: 'Berta Erste', company: 'Deichwerk')
    create(:person, organisation: organisation, name: 'Clara Zweite', company: 'Hafenamt')
    sign_in user
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  def lane = find("turbo-frame##{frame_id}")

  def list = find("turbo-frame##{Organisations::PeopleController::LIST_FRAME_ID}")

  def open_search
    find('.people-tools button[data-fb-search-open-button]').click
    expect(page).to have_css('#people-search', visible: true)
  end

  it 'answers while typing and keeps the person opened by a row click' do
    berta = Person.find_by!(name: 'Berta Erste')
    clara = Person.find_by!(name: 'Clara Zweite')
    visit organisation_people_path(organisation, person_id: berta.id)
    expect(lane).to have_text('Berta Erste')

    find('.people-row', text: 'Clara Zweite').click
    expect(page).to have_current_path(/person_id=#{clara.id}/)
    expect(lane).to have_text('Clara Zweite')

    open_search
    find('#people-search').send_keys('Hafen')

    expect(list).to have_no_text('Berta Erste')
    expect(list).to have_text('Clara Zweite')
    expect(page).to have_current_path(/q=Hafen/)
    expect(page).to have_current_path(/person_id=#{clara.id}/)
    expect(lane).to have_text('Clara Zweite')
    expect(list).to have_css('.people-row.selected-row', text: 'Clara Zweite')
    expect(page).to have_css('#people-search:focus')

    # The tabs were drawn again with the search: a tab keeps it, and the person.
    find('#people_list_tabs a[role="tab"]', text: I18n.t('views.organisations.people.index.kinds.contacts')).click

    expect(page).to have_current_path(/kind=contacts/)
    expect(page).to have_current_path(/q=Hafen/)
    expect(page).to have_current_path(/person_id=#{clara.id}/)
    expect(lane).to have_text('Clara Zweite')
    expect(page).to have_css('[data-fb-search][data-fb-search-open]')
  end

  it 'shows the whole list again once the field is empty' do
    visit organisation_people_path(organisation, q: 'Hafen')
    expect(list).to have_no_text('Berta Erste')

    field = find('#people-search')
    field.send_keys([:command, 'a'], [:control, 'a'], :backspace)

    expect(list).to have_text('Berta Erste')
    expect(page).to have_no_current_path(/q=/)
  end

  it 'folds the empty field on Escape before the lane closes' do
    berta = Person.find_by!(name: 'Berta Erste')
    visit organisation_people_path(organisation, person_id: berta.id)
    expect(lane).to have_text('Berta Erste')

    open_search
    find('#people-search').send_keys(:escape)

    expect(page).to have_no_css('[data-fb-search][data-fb-search-open]')
    expect(page).to have_current_path(/person_id=#{berta.id}/)
    expect(page).to have_css('.people-page.show-content')

    find('body').send_keys(:escape)
    expect(page).to have_no_current_path(/person_id=/)
  end
end
