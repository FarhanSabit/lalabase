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

  it 'returns from management to the Inbox selection visible when the invitation link was opened' do
    page.current_window.resize_to(1440, 1000)
    ticket = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, title: 'Ausgewähltes Ticket') }
    notification = create_notification(state: :read, ticket: ticket)

    visit inbox_path(state_filters: %w[read unread])
    expect(page).to have_css('.layout.hide-content')
    find("[data-notification-item='#{notification.id}'] a.inbox-row__link").click
    expect(page).to have_css('#ticket_pane', text: 'Ausgewähltes Ticket')
    expect(page).to have_current_path(/notification=#{notification.id}/)
    selected_path = URI.parse(page.current_url).request_uri

    find('#sidebar details[data-controller="details-autoclose"] > summary').click
    find("#sidebar a[href='#{new_organisation_invitation_path(organisation)}']").click
    expect(page).to have_css('#sidebar [data-management-nav]')
    find("#sidebar a[href='#{organisation_roles_path(organisation)}']").click
    expect(page).to have_current_path(organisation_roles_path(organisation))

    back = find('#sidebar a', text: I18n.t('navigation.management_back'), exact_text: true)
    expect(URI.parse(back[:href]).request_uri).to eq(selected_path)
    back.click
    expect(page).to have_current_path(selected_path)
    expect(page).to have_css('#ticket_pane', text: 'Ausgewähltes Ticket')
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

  # C9 — The "···" of a row stands in the place of the time on hover and acts
  # on that row without opening it; the lane keeps the notification it shows.
  it 'archiviert eine Zeile über ihr Menü, ohne die offene Bahn zu wechseln (C9)' do
    open_ticket = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, title: 'Offen in der Bahn') }
    other_ticket = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, title: 'Nur in der Liste') }
    open_one = create_notification(state: :delivered, ticket: open_ticket, created_at: 1.hour.ago)
    other = create_notification(state: :delivered, ticket: other_ticket, created_at: 2.hours.ago)

    visit inbox_path(state_filters: ['unread'], notification: open_one.id)
    expect(page).to have_css('#ticket_pane', text: 'Offen in der Bahn')
    row = find("[data-notification-item='#{other.id}'] .inbox-row")
    expect(row).to have_no_css('.inbox-row__menu summary', visible: true)
    expect(row).to have_css('.inbox-row__time', visible: true)

    row.hover
    expect(row).to have_no_css('.inbox-row__time', visible: true)
    row.find('.inbox-row__menu summary', visible: true).click
    row.click_button('Archivieren')

    expect(page).to have_no_css("[data-notification-item='#{other.id}']")
    expect(other.reload).to be_state_archived
    expect(page).to have_css('#ticket_pane', text: 'Offen in der Bahn')
    within('#inbox_pane_status_pills') { expect(page).to have_button('Als gelesen') }
  end

  # C10 — The search answers while typing, without Enter: only the list
  # reloads, the field keeps its focus and its letters; an empty field shows
  # the whole view again; a status link clicked afterwards keeps the search.
  it 'sucht beim Tippen, ohne Enter, und behält dabei den Fokus (C10)' do
    hit = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, title: 'Exportfehler') }
    miss = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, title: 'Startseite') }
    create_notification(state: :delivered, ticket: hit, created_at: 1.hour.ago)
    create_notification(state: :read, ticket: miss, created_at: 2.hours.ago)

    visit inbox_path
    expect(page).to have_css('.inbox-row__title', text: 'Startseite')

    find('[data-fb-search-open-button]').click
    field = find('#inbox-search')
    field.send_keys('Export')
    expect(page).to have_no_css('.inbox-row__title', text: 'Startseite')
    expect(page).to have_css('.inbox-row__title', text: 'Exportfehler')
    expect(page).to have_current_path(/search=Export/)
    expect(page.evaluate_script('document.activeElement.id')).to eq('inbox-search')
    expect(find('#inbox-search').value).to eq('Export')

    find('#inbox-search').send_keys(*Array.new('Export'.length, :backspace))
    expect(find('#inbox-search').value).to eq('')
    expect(page).to have_css('.inbox-row__title', text: 'Startseite')

    find('#inbox-search').send_keys('Start')
    expect(page).to have_no_css('.inbox-row__title', text: 'Exportfehler')
    click_link 'Gelesen'
    expect(page).to have_current_path(/search=Start/)
    expect(page).to have_css('.inbox-row__title', text: 'Startseite')
  end

  # C11 — The search is the ticket list's: a magnifier at the right end of the
  # tab row that grows into the field and takes the focus; Escape folds an
  # empty field back, and the focus returns to the magnifier.
  it 'öffnet die Suche über die Lupe und klappt sie leer mit Escape zu (C11)' do
    visit inbox_path
    expect(page).to have_no_css('#inbox-search', visible: true)

    find('[data-fb-search-open-button]').click
    expect(page).to have_css('#inbox-search', visible: true)
    expect(page.evaluate_script('document.activeElement.id')).to eq('inbox-search')

    find('#inbox-search').send_keys(:escape)
    expect(page).to have_no_css('#inbox-search', visible: true)
    expect(page.evaluate_script("document.activeElement.hasAttribute('data-fb-search-open-button')")).to be(true)
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
    find('.people-head summary.more-menu__trigger').click
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

  # L1 — The lane has a way out. The ✕ of its head shuts it in place, takes the
  # open notification out of the address and the tint off its row; Back opens
  # the ticket again. Until then an open lane could only be left by leaving
  # the page, and with the assistant beside it the list was gone.
  it 'schließt die Bahn über das ✕ und öffnet sie mit Zurück wieder (L1)' do
    ticket = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, title: 'Bahn-Ticket') }
    n = create_notification(state: :read, ticket: ticket)

    visit inbox_path(state_filters: %w[read unread])
    expect(page).to have_css('.layout.hide-content')
    find("[data-notification-item='#{n.id}'] a.inbox-row__link").click

    expect(page).to have_css('#ticket_pane', text: 'Bahn-Ticket')
    expect(page).to have_css('.layout.show-content')
    expect(page).to have_css("[data-notification-item='#{n.id}'] .inbox-row.selected-row")
    expect(page).to have_current_path(/notification=#{n.id}/)

    find('#ticket_pane [data-lane-close]').click

    expect(page).to have_css('.layout.hide-content')
    expect(page).to have_no_css('.inbox-row.selected-row')
    expect(page).to have_no_current_path(/notification=/)
    expect(page).to have_current_path(/state_filters/)

    page.go_back

    expect(page).to have_css('.layout.show-content')
    expect(page).to have_css('#ticket_pane', text: 'Bahn-Ticket')
    expect(page).to have_css("[data-notification-item='#{n.id}'] .inbox-row.selected-row")
  end

  # L2 — Escape shuts the lane, as on the other list pages.
  it 'schließt die Bahn mit Escape (L2)' do
    ticket = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, title: 'Escape-Ticket') }
    n = create_notification(state: :read, ticket: ticket)

    visit inbox_path(state_filters: %w[read unread], notification: n.id)
    expect(page).to have_css('.layout.show-content')
    expect(page).to have_css('#ticket_pane', text: 'Escape-Ticket')

    find('body').send_keys(:escape)

    expect(page).to have_css('.layout.hide-content')
    expect(page).to have_no_current_path(/notification=/)
  end

  # L3 — A lane shut before the five seconds are up leaves the notification
  # unread: the ticket is hidden by a class and stays in the page, so the
  # timer asks whether it is still in view.
  it 'markiert nicht als gelesen, wenn die Bahn vor Ablauf der Frist geschlossen wurde (L3)' do
    ticket = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, title: 'Kurzer Blick') }
    n = create_notification(state: :delivered, ticket: ticket)

    visit inbox_path(state_filters: ['unread'])
    find("[data-notification-item='#{n.id}'] a.inbox-row__link").click
    expect(page).to have_css('#ticket_pane', text: 'Kurzer Blick')
    find('#ticket_pane [data-lane-close]').click
    expect(page).to have_css('.layout.hide-content')

    sleep 6.5 # past the 5s timer of the hidden ticket
    expect(n.reload.state).to eq('delivered')
    expect(page).to have_css("[data-notification-item='#{n.id}']")
  end

  # C8 — A stream redraws the list while a selection stands (the delayed
  # mark-read of the open ticket). The tick and the count stay with the row.
  it 'behält die Auswahl, wenn ein Stream die Liste neu zeichnet (C8)' do
    opened_ticket, ticked_ticket = ActsAsTenant.with_tenant(organisation) { create_list(:ticket, 2, project: project) }
    opened = create_notification(state: :delivered, ticket: opened_ticket, created_at: 1.hour.ago)
    ticked = create_notification(state: :delivered, ticket: ticked_ticket, created_at: 2.hours.ago)

    visit inbox_path(state_filters: %w[read unread], view_mode: 'chronological')
    find("[data-notification-item='#{ticked.id}'] .inbox-row").hover
    find("[data-notification-item='#{ticked.id}'] .inbox-row__check").check
    expect(page).to have_css('[data-inbox-bulk-select-target="count"]', text: '1')

    find("[data-notification-item='#{opened.id}'] a.inbox-row__link").click
    # The delayed mark-read answers with the whole list: the opened row comes back read.
    expect(page).to have_no_css("[data-notification-item='#{opened.id}'] .inbox-row--unread", wait: 9)

    expect(page).to have_checked_field(class: 'inbox-row__check', count: 1)
    expect(find("[data-notification-item='#{ticked.id}'] .inbox-row__check")).to be_checked
    expect(page).to have_css("[data-notification-item='#{ticked.id}'] .inbox-row--checked")
    expect(page).to have_css('[data-inbox-bulk-select-target="count"]', text: '1')
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
