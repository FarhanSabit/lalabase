# frozen_string_literal: true

require 'rails_helper'

# Inbox system specs — the thin, browser-/JS-dependent layer of the
# QA matrix (see doc/inbox_qa_matrix.md). Backend/filter/pagination
# logic is covered in the request specs; here only what needs a real
# browser (Turbo frame, Stimulus, IntersectionObserver, timer).
#
# Driver switchable via ENV (see matrix docs):
#   Default              → Selenium headless (CSS/JS-faithful)
#   E2E_DRIVER=playwright → Playwright engine
RSpec.describe 'Inbox (System)', type: :system, inbox_e2e: true do
  # Pre-existing N+1 in the full-page renders (Notification → .organisation
  # per item). Not the scope of these E2E specs. Before the let!/before, so that
  # the data setup is not scanned.
  before { Prosopite.pause }
  after  { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }

  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    login_as(user, scope: :user)
  end

  def create_notification(state:, ticket:, created_at: 1.hour.ago)
    ActsAsTenant.with_tenant(organisation) do
      create(:notification,
             recipient: user, organisation: organisation,
             project: project, notifiable: ticket,
             event_type: 'ticket_assigned', channel: 'in_app', state: state,
             read_at: %i[read archived].include?(state) ? created_at : nil,
             archived_at: state == :archived ? created_at : nil,
             created_at: created_at)
    end
  end

  def inbox_path(**params)
    organisation_notifications_path(organisation, **params)
  end

  # B1 — Clicking a ticket notification loads the ticket in the pane.
  it 'lädt das Ticket im Pane beim Klick (B1)' do
    ticket = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, title: 'Login-Bug') }
    n = create_notification(state: :delivered, ticket: ticket)

    visit inbox_path(state_filters: ['unread'])
    find("[data-notification-item='#{n.id}'] a", match: :first).click

    within('#ticket_pane') do
      expect(page).to have_content('Login-Bug')
    end
  end

  # B2 — Delayed mark-as-read: after ~5s the item leaves the
  # unread filter. Generous wait time (5s timer + network).
  it 'entfernt das Item nach verzögertem Mark-as-read aus dem Unread-Filter (B2)' do
    ticket = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, title: 'Verzögert') }
    n = create_notification(state: :delivered, ticket: ticket)

    visit inbox_path(state_filters: ['unread'])
    find("[data-notification-item='#{n.id}'] a", match: :first).click

    expect(page).to have_css('#ticket_pane', text: 'Verzögert')
    # After the 5s timer elapses, the (now read) notification is gone.
    expect(page).not_to have_css("[data-notification-item='#{n.id}']", wait: 9)
  end

  # C2 — The checkbox sits where the unread dot is and shows on hover; from
  # the first tick on every row shows it, and "Alle" in the bar ticks all.
  it 'zeigt das Kästchen beim Drüberfahren und wählt über "Alle" alle Zeilen (C2)' do
    tickets = ActsAsTenant.with_tenant(organisation) { create_list(:ticket, 3, project: project) }
    notifications = tickets.each_with_index.map do |t, i|
      create_notification(state: :delivered, ticket: t, created_at: (i + 1).hours.ago)
    end

    visit inbox_path(state_filters: ['unread'])
    first_row = find("[data-notification-item='#{notifications.first.id}'] .inbox-row")
    expect(first_row).to have_no_css('.inbox-row__check', visible: true)

    first_row.hover
    first_row.find('.inbox-row__check', visible: true).click
    expect(page).to have_css('[data-inbox-bulk-select-target="bar"]', visible: true, text: '1 ausgewählt')
    expect(page).to have_css('.inbox-row__check', visible: true, count: 3)

    within('[data-inbox-bulk-select-target="bar"]') { click_button('Alle') }
    expect(page).to have_content('3 ausgewählt')
  end

  # C3 — "Auswählen" in the "···" menu (the way in without hover) shows every
  # checkbox; its actions stay disabled until a row is ticked, because without
  # ids the bulk routes act on every notification.
  it 'öffnet den Auswahlmodus über das Menü, mit gesperrten Aktionen bis zum ersten Haken (C3)' do
    ticket = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) }
    n = create_notification(state: :delivered, ticket: ticket)

    visit inbox_path(state_filters: ['unread'])
    find('.more-menu__trigger').click
    click_button('Auswählen')

    within('[data-inbox-bulk-select-target="bar"]') do
      expect(page).to have_content('0 ausgewählt')
      expect(page).to have_button('Archivieren', disabled: true)
    end
    find("[data-notification-item='#{n.id}'] .inbox-row__check").click
    expect(page).to have_button('Archivieren', disabled: false)
  end

  # C7 — Bulk archive empties the unread view → "Alles gelesen." appears.
  it 'zeigt "Alles gelesen." nachdem Bulk-Archive die Liste leert (C7)' do
    tickets = ActsAsTenant.with_tenant(organisation) { create_list(:ticket, 2, project: project) }
    notifications = tickets.each_with_index.map do |t, i|
      create_notification(state: :delivered, ticket: t, created_at: (i + 1).hours.ago)
    end

    visit inbox_path(state_filters: ['unread'])
    row = find("[data-notification-item='#{notifications.first.id}'] .inbox-row")
    row.hover
    row.find('.inbox-row__check', visible: true).click
    within('[data-inbox-bulk-select-target="bar"]') do
      click_button('Alle')
      click_button('Archivieren')
    end

    expect(page).to have_content('Alles gelesen.', wait: 6)
  end

  # D1 — The project select of the tools row submits on change, without a
  # submit button, and keeps the status view.
  it 'wendet den Projektfilter sofort an, wenn ein Projekt gewählt wird (Auto-Submit)' do
    project_b = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Calc') }
    ticket_a  = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, title: 'Aufgabe A') }
    ticket_b  = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project_b, title: 'Aufgabe B') }
    n_a = create_notification(state: :delivered, ticket: ticket_a, created_at: 1.hour.ago)
    n_b = ActsAsTenant.with_tenant(organisation) do
      create(:notification,
             recipient: user, organisation: organisation,
             project: project_b, notifiable: ticket_b,
             event_type: 'ticket_assigned', channel: 'in_app', state: :delivered,
             read_at: nil, created_at: 2.hours.ago)
    end

    visit inbox_path(state_filters: ['unread'])
    expect(page).to have_css("[data-notification-item='#{n_a.id}']")
    expect(page).to have_css("[data-notification-item='#{n_b.id}']")
    expect(page).to have_select('project_id', visible: true)

    # Pick project B — no submit button; the change must auto-submit.
    select 'Calc', from: 'project_id'

    # Auto-submit must narrow the list to project B only.
    expect(page).to have_css("[data-notification-item='#{n_b.id}']", wait: 6)
    expect(page).to have_no_css("[data-notification-item='#{n_a.id}']")
    expect(page).to have_current_path(/state_filters/)
  end

  # F4 — Endless scroll loads further pages, no duplicates.
  it 'lädt weitere Seiten via Endless-Scroll nach (F4)' do
    ticket = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) }
    60.times { |i| create_notification(state: :delivered, ticket: ticket, created_at: (i + 1).minutes.ago) }

    visit inbox_path(state_filters: ['unread'], view_mode: 'chronological')
    expect(page).to have_css('[data-notification-item]', count: 50)

    # Scroll the sentinel into the viewport → IntersectionObserver triggers loadMore.
    page.execute_script(<<~JS)
      document.querySelector('[data-neo-endless-scroll-target="sentinel"]')
              ?.scrollIntoView({ block: 'center' });
    JS

    expect(page).to have_css('[data-notification-item]', count: 60, wait: 8)
  end
end
