# frozen_string_literal: true

require 'rails_helper'

# What: the page title (h1) stands at the same place on every list page:
#       the same distance from the left edge and from the top of the main
#       column as on "Alle Meetings". The list below starts at the same left
#       edge as the title.
# Why:  until 2026-11-10 the pages built on the people head (Personen, Inbox,
#       Glossar) indented head, tools and list by another 24 px and the head
#       by 20 px from the top, on top of the main column's own padding: their
#       title stood 24 px further right and 20 px lower than everywhere else.
#       Measured in a browser, because the offset is a sum of paddings in
#       several places that no single file shows.
RSpec.describe 'Page title edge', type: :system do
  before { Prosopite.pause }
  after  { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      create(:person, organisation: organisation)
    end
    login_as(user, scope: :user)
    page.driver.browser.manage.window.resize_to(1400, 800)
  end

  # Title and first list edge relative to <main>, in whole pixels.
  def edges(path, list_selector)
    visit path
    expect(page).to have_css('main h1')
    page.evaluate_script(<<~JS)
      (function () {
        var main = document.querySelector('main').getBoundingClientRect();
        var title = document.querySelector('main h1').getBoundingClientRect();
        var list = document.querySelector(#{list_selector.to_json});
        return { title_left: Math.round(title.left - main.left),
                 title_top: Math.round(title.top - main.top),
                 list_left: list && Math.round(list.getBoundingClientRect().left - main.left) };
      })()
    JS
  end

  it 'puts the title of Personen, Inbox and Glossar where "Alle Meetings" puts it' do
    reference = edges(organisation_meetings_path(organisation), 'main h1')

    {
      'Personen' => [organisation_people_path(organisation), '.people-tools > :first-child'],
      'Inbox' => [organisation_notifications_path(organisation, state_filters: %w[read unread]), '.people-list'],
      'Glossar' => [organisation_glossary_terms_path(organisation), '.people-tools > :first-child']
    }.each do |name, (path, list_selector)|
      measured = edges(path, list_selector)

      expect([measured['title_left'], measured['title_top']])
        .to eq([reference['title_left'], reference['title_top']]), "title of #{name}: #{measured.inspect}"
      expect(measured['list_left']).to eq(measured['title_left']), "#{list_selector} of #{name}: #{measured.inspect}"
    end
  end

  # The management area has its own list in the sidebar since 2026-11-11 (the
  # user's condition: the headings stand top and left where they stand
  # everywhere). The sidebar keeps its width, so the title keeps its place.
  it 'puts the title of the management sections where "Alle Meetings" puts it, beside their own sidebar' do
    reference = edges(organisation_meetings_path(organisation), 'main h1')

    {
      'Allgemein' => organisation_settings_path(organisation),
      'Mitglieder' => organisation_memberships_path(organisation),
      'Zugriffsübersicht' => organisation_access_matrix_index_path(organisation)
    }.each do |name, path|
      measured = edges(path, 'main h1')

      expect(page).to have_css('#sidebar [data-management-nav]')
      expect([measured['title_left'], measured['title_top']])
        .to eq([reference['title_left'], reference['title_top']]), "title of #{name}: #{measured.inspect}"
    end
  end

  # The other sections. Import shows only where it is switched on for the organisation.
  it 'puts the title of Rollen und Rechte, its matrix, Archiv, Darstellung and Import where "Alle Meetings" puts it' do
    organisation.update!(data_import_enabled: true)
    reference = edges(organisation_meetings_path(organisation), 'main h1')

    {
      'Rollen und Rechte' => organisation_roles_path(organisation),
      'Rechte-Matrix' => organisation_roles_path(organisation, view: 'matrix'),
      'Archiv' => organisation_archives_path(organisation),
      'Darstellung' => organisation_appearance_path(organisation),
      'Import' => organisation_codebase_import_files_path(organisation)
    }.each do |name, path|
      measured = edges(path, 'main h1')

      expect(page).to have_css('#sidebar [data-management-nav]')
      expect([measured['title_left'], measured['title_top']])
        .to eq([reference['title_left'], reference['title_top']]), "title of #{name}: #{measured.inspect}"
    end
  end

  # A file uploaded to the organisation's import by the user.
  def import_file(*traits, **attributes)
    ActsAsTenant.with_tenant(organisation) do
      create(:codebase_import_file, *traits, organisation: organisation, user: user, **attributes)
    end
  end

  # A page below a section keeps the section's head and adds the crumb line
  # under it: its title stands where the section's stands, and the crumb starts
  # on the title's left edge. Measured at the crumb's link, the first thing the
  # line shows: a padding inside the line moves the text, not the line's box.
  # Every page below a section: the two role forms, the invitation form and the
  # eight pages of the import, each with the file it needs
  # (spec/requests/organisations/management_pages_below_spec.rb).
  it 'puts the title of the pages below a section where "Alle Meetings" puts it, and their crumb on its left edge' do
    organisation.update!(data_import_enabled: true)
    team = ActsAsTenant.with_tenant(organisation) { create(:role, organisation: organisation, title: 'Team') }
    tickets = import_file(:with_valid_tickets_xml, original_filename: 'beispiel_tickets.xml')
    users = import_file(:with_valid_users_xml, original_filename: 'beispiel_users.xml')
    times = import_file(:with_valid_time_tracking_xml, original_filename: 'beispiel_zeiten.xml')
    processed_in_project = import_file(:with_valid_tickets_xml, :processed, original_filename: 'beispiel_tickets.xml', project: project)
    processed = import_file(:with_valid_tickets_xml, :processed, original_filename: 'beispiel_tickets.xml')
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation)
      create(:imported_object, organisation: organisation, metadata: { 'import_file_id' => processed.id })
    end
    reference = edges(organisation_meetings_path(organisation), 'main h1')

    {
      'Neue Rolle' => new_organisation_role_path(organisation),
      'Rolle bearbeiten' => edit_organisation_role_path(organisation, team),
      'Mitglied einladen' => new_organisation_invitation_path(organisation),
      'CodebaseHQ Datei hochladen' => new_organisation_codebase_import_file_path(organisation),
      'Importdatei' => organisation_codebase_import_file_path(organisation, tickets),
      'User-Import Vorschau' => preview_import_organisation_codebase_import_file_path(organisation, users),
      'Ticket-Import Preview' => preview_tickets_organisation_codebase_import_file_path(organisation, tickets),
      'Projekt für Zeit-Einträge-Import auswählen' => select_project_organisation_codebase_import_file_path(organisation, times),
      'Zeit-Einträge Import Preview' => preview_time_sessions_organisation_codebase_import_file_path(organisation, times, project_id: project.id),
      'Uploads zuordnen' => assign_uploads_organisation_codebase_import_file_path(organisation, processed_in_project, project_id: project.id),
      'Import Rollback bestätigen' => rollback_organisation_codebase_import_file_path(organisation, processed)
    }.each do |name, path|
      measured = edges(path, 'main [data-section-crumb] a')

      expect(page).to have_css('#sidebar [data-management-nav]')
      expect([measured['title_left'], measured['title_top']])
        .to eq([reference['title_left'], reference['title_top']]), "title of #{name}: #{measured.inspect}"
      expect(measured['list_left']).to eq(measured['title_left']), "crumb of #{name}: #{measured.inspect}"
    end
  end

  # The distance from the crumb line down to the element under it, in whole pixels.
  def distance_under_crumb
    page.evaluate_script(<<~JS)
      (function () {
        var crumb = document.querySelector('main [data-section-crumb]');
        var next = crumb.nextElementSibling;
        while (next && !next.getClientRects().length) { next = next.nextElementSibling; }
        return next && Math.round(next.getBoundingClientRect().top - crumb.getBoundingClientRect().bottom);
      })()
    JS
  end

  # The content keeps the distance under the crumb that it has under a head
  # without one (organisations/shared/_section_crumb): 24 px under the title
  # box, 14 px under a tab bar. On the upload form and the invitation form the
  # crumb alone holds it; on the role form the form's own mt-6 would hold the
  # 24 px even without the crumb's margin.
  it 'keeps the content 24 px under the crumb, and 14 px where a tab bar stands above the crumb' do
    organisation.update!(data_import_enabled: true)

    {
      'Neue Rolle' => [new_organisation_role_path(organisation), 24],
      'CodebaseHQ Datei hochladen' => [new_organisation_codebase_import_file_path(organisation), 24],
      'Mitglied einladen' => [new_organisation_invitation_path(organisation), 14]
    }.each do |name, (path, distance)|
      visit path
      expect(page).to have_css('main [data-section-crumb]')
      measured = distance_under_crumb

      expect(measured).to eq(distance), "distance under the crumb of #{name}: #{measured.inspect} px, not #{distance}"
    end
  end

  # A file name may have no break point at all, and the crumb shows it twice:
  # as the way back on the pages below a file, as the page on the file's own
  # page. Until 2026-11-11 the way back widened the page on a phone
  # (scrollWidth 508 at 500 px on the ticket preview). The screen is the root's
  # clientWidth, not window.innerWidth: in the phone emulation innerWidth grows
  # with a page that is too wide (509 for 509).
  it 'breaks a long file name in the crumb on a phone instead of widening the page' do
    organisation.update!(data_import_enabled: true)
    file_name = 'codebase_export_beispielprojekt_tickets_vollstaendig_2026_11_11.xml'
    file = import_file(:with_valid_tickets_xml, original_filename: file_name)
    page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride', width: 390, height: 844, deviceScaleFactor: 1, mobile: true)

    {
      'the way back on the ticket preview' => [preview_tickets_organisation_codebase_import_file_path(organisation, file), 'a'],
      'the page on the file page' => [organisation_codebase_import_file_path(organisation, file), '[aria-current="page"]']
    }.each do |place, (path, selector)|
      name_selector = "main [data-section-crumb] #{selector}"
      visit path
      expect(page).to have_css(name_selector, text: file_name)
      measured = page.evaluate_script(<<~JS)
        (function () {
          var name = document.querySelector(#{name_selector.to_json}).getBoundingClientRect();
          var main = document.querySelector('main').getBoundingClientRect();
          return { page_width: document.documentElement.scrollWidth, screen_width: document.documentElement.clientWidth,
                   name_right: Math.round(name.right), main_right: Math.round(main.right) };
        })()
      JS

      expect(measured['page_width']).to be <= measured['screen_width'], "#{place}: the page is wider than the phone: #{measured.inspect}"
      expect(measured['name_right']).to be <= measured['main_right'], "#{place}: the name ends right of main: #{measured.inspect}"
    end
  ensure
    page.driver.browser.execute_cdp('Emulation.clearDeviceMetricsOverride')
  end

  # The column heads (user, 2026-11-11): Personen wears the head of "Alle
  # Meetings" (.column-head, F43), in its type and at its distance from the
  # tab row and from the ink line below. Until then it had two plain words of
  # its own, 18 px under the tab row and 2 px above the line.
  def column_head(path, head_row, label)
    visit path
    expect(page).to have_css(label)
    page.evaluate_script(<<~JS)
      (function () {
        var tabs = document.querySelector('[role="tablist"]').getBoundingClientRect();
        var row = document.querySelector(#{head_row.to_json}).getBoundingClientRect();
        var element = document.querySelector(#{label.to_json});
        var walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT,
          { acceptNode: function (n) { return n.textContent.trim() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP; } });
        var word = walker.nextNode();
        var range = document.createRange(); range.selectNodeContents(word);
        var text = range.getBoundingClientRect();
        var style = getComputedStyle(word.parentElement);
        return { above: Math.round(text.top - tabs.bottom), below: Math.round(row.bottom - text.bottom),
                 type: [style.fontFamily, style.fontSize, style.textTransform, style.letterSpacing] };
      })()
    JS
  end

  it 'puts the column heads of Personen where "Alle Meetings" puts its own, in the same type' do
    ActsAsTenant.with_tenant(organisation) { create(:meeting, organisation: organisation, project: project) }
    reference = column_head(organisation_meetings_path(organisation), 'table.meeting-table thead tr',
                            'table.meeting-table thead th:first-child')
    measured = column_head(organisation_people_path(organisation), '.people-columns', '.people-columns__link')

    expect(measured['type']).to eq(reference['type'])
    expect(measured['above']).to be_within(1).of(reference['above']), "#{measured.inspect} against #{reference.inspect}"
    expect(measured['below']).to be_within(1).of(reference['below']), "#{measured.inspect} against #{reference.inspect}"
  end
end
