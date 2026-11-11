# frozen_string_literal: true

require 'rails_helper'

# What: the sections without tabs and the pages below a section of the management
#       area (doc/verwaltung_seitennavigation_plan.md §4, §5 and S2):
#       - Darstellung and Import carry their tools in the head: the help, and on
#         Import the upload as the "+", outermost; Archiv names itself and has no
#         help;
#       - every page below a section (the import's upload form, a file, its
#         previews, the project choice, the rollback, the upload assignment; the
#         invitation form) keeps the section's title as its only h1 and names
#         itself in the crumb line, which leads to its parent: the import list from
#         the upload form, a file and the upload assignment; the file from its
#         previews, the project choice and the rollback; the members' list from the
#         invitation form. No back button of its own, in the head or in a row of
#         buttons at the bottom: the crumb is the way back. The page is the one
#         current item, and the sidebar keeps the section marked;
#       - the invitation form keeps the members' tabs, "Mitglieder" marked as its
#         parent.
# Why:  these pages had a head of their own (a title box or a header card with a
#       back button) or their tools in a row under the title, while every other
#       page names its section in the head and puts its tools top right.
RSpec.describe 'Management pages below a section', type: :request do
  let(:organisation) { create(:organisation, name: 'Beispiel GmbH', data_import_enabled: true) }
  let(:admin) { create(:user, first_name: 'Anna', last_name: 'Beispiel') }
  let(:import_label) { I18n.t('settings.import_data') }
  let(:help_label) { I18n.t('components.contextual_help.label') }

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

  # The row of the page head: the title, and right of it the tools and the main action.
  def head_row(doc) = doc.at_css('main h1').ancestors('.flex.flex-wrap').first

  # The questions of a help menu, as the reader sees them.
  def help_questions(context) = Docs::ContextualHelp.for(context).map { |question| I18n.t(question[:label_key]) }

  def active_section(doc) = doc.css('#sidebar [data-management-nav] a.sidebar-row--active').map { |link| link.text.squish }

  describe 'the sections' do
    it 'puts the help of Darstellung into its head, and nowhere else' do
      doc = doc_for(organisation_appearance_path(organisation))

      expect(doc.at_css('main h1').text.squish).to eq(I18n.t('settings.appearance'))
      expect(head_row(doc).at_css("[title='#{help_label}']")).to be_present
      expect(head_row(doc).text).to include(*help_questions(:settings_appearance))
      expect(doc.css("main [title='#{help_label}']").size).to eq(1)
    end

    it 'puts the help and the upload as "+" into the head of Import, the "+" outermost' do
      doc = doc_for(organisation_codebase_import_files_path(organisation))
      row = head_row(doc)

      expect(doc.at_css('main h1').text.squish).to eq(import_label)
      expect(row.text).to include(*help_questions(:settings_import))
      expect(doc.css("main [title='#{help_label}']").size).to eq(1)
      upload = row.css("a[href='#{new_organisation_codebase_import_file_path(organisation)}']")
      expect(upload.size).to eq(1)
      expect(upload.first['title']).to eq(I18n.t('views.organisations.codebase_import_files.index.new_file_btn'))
      expect(row.css('a, button').last).to eq(upload.first)
    end

    it 'names Archiv in its head and gives it no help' do
      doc = doc_for(organisation_archives_path(organisation))

      expect(doc.css('main h1').map { |h1| h1.text.squish }).to eq([I18n.t('settings.archive')])
      expect(doc.css("main [title='#{help_label}']")).to be_empty
    end
  end

  describe 'a page below a section' do
    let(:import_list) { organisation_codebase_import_files_path(organisation) }
    let(:project) { create(:project, organisation: organisation, name: 'Beispielprojekt') }

    def import_file(*traits, **attributes)
      create(:codebase_import_file, *traits, organisation: organisation, user: admin, **attributes)
    end

    def file_page(file) = organisation_codebase_import_file_path(organisation, file)

    def import_title(key) = I18n.t("views.organisations.codebase_import_files.#{key}")

    # One shape for every page below a section: the section's title as the only h1,
    # the crumb to the parent naming the page, no way back besides it, the page as
    # the one current item, the section marked in the sidebar.
    def expect_below_section(doc, section:, parent_path:, parent_label:, page:)
      expect(doc.css('main h1').map { |h1| h1.text.squish }).to eq([section])

      crumb = doc.at_css('main [data-section-crumb]')
      expect(crumb).to be_present
      back = crumb.at_css('a')
      expect(back['href']).to eq(parent_path)
      expect(back.text.delete('‹').squish).to eq(parent_label)
      expect(crumb.at_css('[aria-current="page"]').text.squish).to eq(page)

      expect(doc.css('main i.bi-arrow-left')).to be_empty
      other_ways_back = doc.css("main a[href='#{parent_path}']").reject { |link| link.ancestors('nav').any? }
      expect(other_ways_back).to be_empty

      expect(doc.css('main [aria-current="page"]').size).to eq(1)
      expect(active_section(doc)).to eq([section])
    end

    it 'the upload form leads back to the import list' do
      doc = doc_for(new_organisation_codebase_import_file_path(organisation))

      expect_below_section(doc, section: import_label, parent_path: import_list, parent_label: import_label,
                                page: import_title('new.title'))
    end

    it 'a file leads back to the import list and is named by its file name' do
      file = import_file(:with_valid_tickets_xml, original_filename: 'beispiel_tickets.xml')

      expect_below_section(doc_for(file_page(file)), section: import_label, parent_path: import_list,
                                                     parent_label: import_label, page: 'beispiel_tickets.xml')
    end

    it 'the upload assignment leads back to the import list' do
      file = import_file(:with_valid_tickets_xml, :processed, original_filename: 'beispiel_tickets.xml', project: project)
      create(:ticket, project: project, organisation: organisation)

      doc = doc_for(assign_uploads_organisation_codebase_import_file_path(organisation, file, project_id: project.id))

      expect_below_section(doc, section: import_label, parent_path: import_list, parent_label: import_label,
                                page: import_title('assign_uploads.title'))
    end

    it 'the user preview leads back to its file' do
      file = import_file(:with_valid_users_xml, original_filename: 'beispiel_users.xml')

      doc = doc_for(preview_import_organisation_codebase_import_file_path(organisation, file))

      expect_below_section(doc, section: import_label, parent_path: file_page(file), parent_label: 'beispiel_users.xml',
                                page: import_title('preview_import.title'))
    end

    # analyze_user_references looks every Codebase user up on its own, which is not
    # what this example is about (the same pause as in codebase_import_files_spec).
    it 'the ticket preview leads back to its file' do
      file = import_file(:with_valid_tickets_xml, original_filename: 'beispiel_tickets.xml')
      Prosopite.pause

      doc = doc_for(preview_tickets_organisation_codebase_import_file_path(organisation, file))

      expect_below_section(doc, section: import_label, parent_path: file_page(file), parent_label: 'beispiel_tickets.xml',
                                page: import_title('preview_tickets.title'))
    ensure
      Prosopite.resume
    end

    it 'the project choice leads back to its file' do
      file = import_file(:with_valid_time_tracking_xml, original_filename: 'beispiel_zeiten.xml')

      doc = doc_for(select_project_organisation_codebase_import_file_path(organisation, file))

      expect_below_section(doc, section: import_label, parent_path: file_page(file), parent_label: 'beispiel_zeiten.xml',
                                page: import_title('select_project.title_time'))
    end

    it 'the time entry preview leads back to its file' do
      file = import_file(:with_valid_time_tracking_xml, original_filename: 'beispiel_zeiten.xml')

      doc = doc_for(preview_time_sessions_organisation_codebase_import_file_path(organisation, file, project_id: project.id))

      expect_below_section(doc, section: import_label, parent_path: file_page(file), parent_label: 'beispiel_zeiten.xml',
                                page: import_title('preview_time_sessions.title'))
    end

    it 'the rollback leads back to its file' do
      file = import_file(:with_valid_tickets_xml, :processed, original_filename: 'beispiel_tickets.xml')
      create(:imported_object, organisation: organisation, metadata: { 'import_file_id' => file.id })

      doc = doc_for(rollback_organisation_codebase_import_file_path(organisation, file))

      expect_below_section(doc, section: import_label, parent_path: file_page(file), parent_label: 'beispiel_tickets.xml',
                                page: import_title('rollback.title'))
    end

    it 'the invitation form leads back to the members and keeps their tabs, "Mitglieder" marked as its parent' do
      members = I18n.t('settings.members')

      doc = doc_for(new_organisation_invitation_path(organisation))

      expect_below_section(doc, section: members, parent_path: organisation_memberships_path(organisation),
                                parent_label: members, page: I18n.t('organisations.invitations.new.title'))
      tabs = doc.css('main nav:not([data-section-crumb]) a')
      expect(tabs.map { |tab| tab.text.squish }).to eq([members, I18n.t('views.organisations.access_matrix.index.title')])
      expect(tabs.first['href']).to eq(organisation_memberships_path(organisation))
      expect(tabs.first['aria-current']).to eq('true')
    end
  end
end
