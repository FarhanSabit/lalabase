# frozen_string_literal: true

require 'rails_helper'

# The review list of the glossary extraction on the glossary page (K5b): the
# pill "Prüfliste (n)" above the terms, the proposals view (?view=proposals)
# with its status pills, a proposal in the lane, and the decisions on it
# (accept, merge into a term or into another proposal, dismiss, restore).
#
# Every reader with view_glossary sees the list and the lane; only
# manage_glossary decides, refused with 403 before anything is looked up. A
# proposal of another organisation is no proposal (404). A snippet stands only
# for a reader of its source, asked when the lane renders: the run read the
# source with the rights of the account that started it, which says nothing
# about the reader. A private comment never shows its text, also not to an
# account admin. Invented words and names only.
RSpec.describe 'Organisations::Glossary proposals', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def role_with(*glossary_actions, title: nil)
    role = create(:role, organisation: organisation, **{ title: title }.compact)
    glossary_actions.each { |action| create(:permission, role: role, category: 'glossary', action: action, allowed: true) }
    role
  end

  def member_with(role)
    user = create(:user, first_name: 'Anna', last_name: "Beispiel#{SecureRandom.hex(2)}")
    create(:membership, user: user, organisation: organisation, role: role)
    user
  end

  def grant(user, project, **areas)
    create(:project_permission, user: user, project: project, **areas)
  end

  let(:admin) { member_with(role_with(title: Role::ACCOUNT_ADMIN_TITLE)) }
  let(:viewer) { member_with(role_with('view_glossary')) }
  let(:manager) { member_with(role_with('manage_glossary')) }
  let(:nobody) { member_with(role_with) }
  let(:author) { member_with(role_with) }

  let(:open_project) { create(:project, organisation: organisation, name: 'Projekt Ahorn') }
  let(:closed_project) { create(:project, organisation: organisation, name: 'Projekt Birke') }
  let(:open_ticket) { create(:ticket, organisation: organisation, project: open_project, creator: author, title: 'Anfrage Ahorn') }
  let(:closed_ticket) { create(:ticket, organisation: organisation, project: closed_project, creator: author, title: 'Anfrage Birke') }

  let!(:proposal) do
    create(:glossary_proposal, organisation: organisation, term: 'Zorbel-Hub', category: 'product',
                               variants: ['Zorbelhub', 'zorbel hub'], hint: 'Ein erfundener Produktname.', occurrences: 7)
  end
  let!(:open_source) do
    create(:glossary_proposal_source, organisation: organisation, glossary_proposal: proposal, project: open_project,
                                      source: open_ticket, snippet: 'Der Zorbel-Hub steht im Ticket aus Ahorn.', occurrences: 4)
  end
  let!(:closed_source) do
    create(:glossary_proposal_source, organisation: organisation, glossary_proposal: proposal, project: closed_project,
                                      source: closed_ticket, snippet: 'Geheim: der Zorbelhub aus Birke.', occurrences: 3)
  end
  let!(:small_proposal) { create(:glossary_proposal, organisation: organisation, term: 'Wub', occurrences: 2) }
  let!(:accepted_proposal) { create(:glossary_proposal, :accepted, organisation: organisation, term: 'Quarnix', occurrences: 5) }
  let!(:dismissed_proposal) { create(:glossary_proposal, :dismissed, organisation: organisation, term: 'Plumbix', occurrences: 9) }

  let(:frame_id) { Organisations::GlossaryController::DETAIL_FRAME_ID }
  let(:frame_headers) { { 'Turbo-Frame' => frame_id } }
  let(:gp) { 'views.organisations.glossary.proposals' }
  let(:cp) { 'controllers.glossary.proposals' }

  def page
    Nokogiri::HTML(response.body)
  end

  def review_list(**params)
    get organisation_glossary_terms_path(organisation, view: 'proposals', **params)
  end

  def lane_of(target = proposal, **params)
    get proposal_organisation_glossary_terms_path(organisation, proposal_id: target.id, view: 'proposals', **params),
        headers: frame_headers
  end

  def listed
    page.css('[data-glossary-proposal-row] .people-row__name').map(&:text)
  end

  def row_of(term)
    page.css('[data-glossary-proposal-row]').find { |row| row.at_css('.people-row__name').text == term }
  end

  def source_node(source)
    page.at_css(%([data-glossary-proposal-source="#{source.id}"]))
  end

  def snippet_of(source)
    source_node(source)&.at_css('[data-glossary-source-snippet]')&.text&.squish
  end

  def kind(key)
    I18n.t("#{gp}.show.source_kinds.#{key}")
  end

  # Every proposal of every organisation, with what a decision could change.
  def proposal_state
    GlossaryProposal.unscoped.order(:id).pluck(:id, :status, :glossary_term_id, :decided_by_id, :variants, :occurrences)
  end

  def glossary_state
    [proposal_state, GlossaryTerm.unscoped.order(:id).pluck(:id, :status), TermCorrection.unscoped.order(:id).pluck(:id)]
  end

  describe 'the pill above the terms' do
    { 'view_glossary' => :viewer, 'manage_glossary' => :manager }.each do |right, reader|
      [nil, 'mobile'].each do |viewport|
        it "names the open proposals for a reader with #{right} (#{viewport || 'desktop'}) and leads to the review list" do
          sign_in public_send(reader)

          get organisation_glossary_terms_path(organisation, viewport: viewport)

          expect(response).to have_http_status(:ok)
          pill = page.at_css('a[data-glossary-review-link]')
          expect(pill).to be_present
          expect(pill.text.squish).to eq("#{I18n.t("#{gp}.review_list")} 2")
          expect(pill.at_css('.people-pill__count').text).to eq('2')
          expect(pill['href']).to eq(organisation_glossary_terms_path(organisation, view: 'proposals', viewport: viewport))
        end
      end
    end

    it 'stands also when nothing is open, with 0' do
      GlossaryProposal.where(status: 'open').update_all(status: 'dismissed')
      sign_in viewer

      get organisation_glossary_terms_path(organisation)

      expect(page.at_css('a[data-glossary-review-link] .people-pill__count').text).to eq('0')
    end

    it 'counts no proposal of another organisation' do
      ActsAsTenant.with_tenant(other_organisation) { create(:glossary_proposal, organisation: other_organisation, term: 'Fremdling') }
      sign_in viewer

      get organisation_glossary_terms_path(organisation)

      expect(page.at_css('a[data-glossary-review-link] .people-pill__count').text).to eq('2')
    end
  end

  describe 'the review list' do
    before { sign_in viewer }

    it 'shows the open proposals, the most frequent first, when no status is given' do
      review_list

      expect(response).to have_http_status(:ok)
      expect(listed).to eq(%w[Zorbel-Hub Wub])
      open_pill = page.at_css('[data-glossary-proposal-status="open"]')
      expect(open_pill['aria-current']).to eq('true')
      expect(open_pill['href']).to eq(organisation_glossary_terms_path(organisation, view: 'proposals'))
    end

    it 'names the counts of the three statuses in their pills' do
      review_list

      counts = page.css('[data-glossary-proposal-status]').to_h do |pill|
        [pill['data-glossary-proposal-status'], pill.at_css('.people-pill__count').text]
      end
      expect(counts).to eq('open' => '2', 'accepted' => '1', 'dismissed' => '1')
    end

    { 'accepted' => %w[Quarnix], 'dismissed' => %w[Plumbix] }.each do |status, terms|
      it "filters by #{status}" do
        review_list(status: status)

        expect(listed).to eq(terms)
        expect(page.at_css(%([data-glossary-proposal-status="#{status}"]))['aria-current']).to eq('true')
      end
    end

    it 'takes a status of the terms as no status, and a status of the proposals as none in the terms view' do
      review_list(status: 'confirmed')
      expect(listed).to eq(%w[Zorbel-Hub Wub])

      create(:glossary_term, organisation: organisation, term: 'Zorbelstein')
      get organisation_glossary_terms_path(organisation, status: 'open')
      expect(page.css('[data-glossary-row] .people-row__name').map(&:text)).to eq(['Zorbelstein'])
    end

    it 'filters by category and by the project of a source' do
      review_list(category: 'product')
      expect(listed).to eq(['Zorbel-Hub'])

      review_list(project_id: closed_project.id)
      expect(listed).to eq(['Zorbel-Hub'])
      options = page.css('#glossary-project-filter option').map(&:text)
      expect(options).to include('Projekt Ahorn', 'Projekt Birke')
    end

    it 'leads back to the terms and shows no term in the review list' do
      create(:glossary_term, organisation: organisation, term: 'Zorbelstein')

      review_list(category: 'product')

      back = page.at_css('a[data-glossary-terms-link]')
      expect(back['href']).to eq(organisation_glossary_terms_path(organisation, category: 'product'))
      expect(back.text.squish).to eq(I18n.t("#{gp}.back_to_terms"))
      expect(response.body).not_to include('Zorbelstein')
    end

    it 'keeps the import and the add buttons in the head' do
      sign_in manager

      review_list

      expect(page.at_css('a[data-glossary-import-link]')).to be_present
      expect(response.body).to include(new_organisation_glossary_term_path(organisation))
    end

    # The hint stands for a reader of every source ('the hint of a proposal').
    it 'shows a row with spelling, category, spellings, hint, projects and occurrences, and opens it in the lane' do
      grant(viewer, open_project, tickets_access: :read_only)
      grant(viewer, closed_project, tickets_access: :read_only)

      review_list

      row = row_of('Zorbel-Hub')
      expect(row.at_css('.people-badge').text).to eq(I18n.t('views.organisations.glossary.categories.product'))
      expect(row.at_css('[data-glossary-proposal-variants]').text.squish)
        .to eq(I18n.t("#{gp}.variants", forms: 'Zorbelhub, zorbel hub'))
      expect(row.at_css('[data-glossary-proposal-hint]').text.squish).to eq('Ein erfundener Produktname.')
      # The projects of the sources are part of the glossary (E3), also where
      # the reader cannot read the project.
      expect(row.at_css('[data-glossary-proposal-projects]').text.squish).to eq('Projekt Ahorn, Projekt Birke')
      expect(row.at_css('.glossary-row__count').text.squish).to start_with('7')
      expect(row['data-list-row-url-value']).to eq(proposal_organisation_glossary_terms_path(organisation, proposal_id: proposal.id))
      expect(row['data-list-row-param-value']).to eq('proposal_id')
      expect(JSON.parse(row['data-list-row-params-value'])).to eq(%w[term_id proposal_id])
      expect(row['data-list-row-frame-value']).to eq(frame_id)
    end

    it 'offers no decision to a reader with view_glossary only' do
      review_list
      expect(page.css('[data-glossary-proposal-row] form')).to be_empty

      review_list(status: 'dismissed')
      expect(page.css('[data-glossary-proposal-row] form')).to be_empty
    end

    it 'says so when there is no proposal at all, and when the selection holds none' do
      GlossaryProposal.delete_all
      review_list
      expect(page.text).to include(I18n.t("#{gp}.empty_title"))

      create(:glossary_proposal, organisation: organisation, term: 'Wub')
      review_list(category: 'person')
      expect(page.text).to include(I18n.t("#{gp}.empty_no_results"))
    end

    it 'opens the list on the phone' do
      review_list(viewport: 'mobile')

      expect(page.css('.people-mobile-grid')).to be_present
      expect(listed).to eq(%w[Zorbel-Hub Wub])
      expect(page.at_css('[data-glossary-run-bar]')).to be_present
    end
  end

  describe 'the buttons of a row with manage_glossary' do
    before { sign_in manager }

    it 'accepts and dismisses an open proposal, naming it for a screen reader' do
      review_list

      row = row_of('Zorbel-Hub')
      actions = row.css('form').pluck('action')
      expect(actions).to eq([accept_proposal_organisation_glossary_terms_path(organisation, proposal_id: proposal.id),
                             dismiss_proposal_organisation_glossary_terms_path(organisation, proposal_id: proposal.id)])
      expect(row.css('button').map { |button| button.text.squish })
        .to eq([I18n.t("#{gp}.accept"), I18n.t("#{gp}.dismiss")]
                 .map { |word| "#{word} #{I18n.t('views.organisations.glossary.quoted', text: 'Zorbel-Hub')}" })
      accept = row.css('form').first
      expect(accept.css('input[name="proposal[variants][]"]').pluck('value')).to contain_exactly('Zorbelhub', 'zorbel hub')
      expect(accept.at_css('input[name="view"]')['value']).to eq('proposals')
    end

    it 'restores a dismissed proposal and accepts none of them' do
      review_list(status: 'dismissed')

      expect(row_of('Plumbix').css('form').pluck('action'))
        .to eq([restore_proposal_organisation_glossary_terms_path(organisation, proposal_id: dismissed_proposal.id)])
    end

    it 'offers nothing on an accepted proposal' do
      review_list(status: 'accepted')

      expect(row_of('Quarnix').css('form')).to be_empty
    end
  end

  describe 'the lane' do
    before { sign_in manager }

    it 'answers the frame with the form: the spelling, the category and every spelling checked' do
      # The hint stands for a reader of every source ('the hint of a proposal').
      grant(manager, open_project, tickets_access: :read_only)
      grant(manager, closed_project, tickets_access: :read_only)

      lane_of

      expect(response).to have_http_status(:ok)
      expect(response.body).to start_with(%(<turbo-frame id="#{frame_id}">))
      form = page.at_css('form[data-glossary-proposal-form]')
      expect(form['action']).to eq(merge_proposal_organisation_glossary_terms_path(organisation, proposal_id: proposal.id))
      expect(form['data-turbo-frame']).to eq('_top')
      expect(form.at_css('input[name="proposal[term]"]')['value']).to eq('Zorbel-Hub')
      expect(form.at_css('select[name="proposal[category]"] option[selected]')['value']).to eq('product')
      boxes = form.css('input[type="checkbox"][name="proposal[variants][]"]')
      expect(boxes.map { |box| [box['value'], box['checked']] }).to eq([%w[Zorbelhub checked], ['zorbel hub', 'checked']])
      expect(form.at_css('input[name="view"]')['value']).to eq('proposals')
      expect(page.text).to include('Ein erfundener Produktname.')
    end

    it 'sends each way to its own address, accept and dismiss as PATCH' do
      lane_of

      form = page.at_css('form[data-glossary-proposal-form]')
      expect(form.at_css('input[name="_method"]')).to be_nil
      accept = form.at_css(%(button[formaction="#{accept_proposal_organisation_glossary_terms_path(organisation, proposal_id: proposal.id)}"]))
      dismiss = form.at_css(%(button[formaction="#{dismiss_proposal_organisation_glossary_terms_path(organisation, proposal_id: proposal.id)}"]))
      expect([accept['name'], accept['value'], accept.text.squish]).to eq(['_method', 'patch', I18n.t("#{gp}.accept")])
      expect([dismiss['name'], dismiss['value'], dismiss.text.squish]).to eq(['_method', 'patch', I18n.t("#{gp}.dismiss")])
      merge = form.css('button[type="submit"]').reject { |button| button['formaction'] }
      expect(merge.map { |button| button.text.squish }).to eq([I18n.t("#{gp}.show.merge_submit")])
    end

    it 'offers the confirmed terms and the other open proposals of this glossary to merge into' do
      confirmed = create(:glossary_term, organisation: organisation, term: 'Zorbel')
      create(:glossary_term, :proposed, organisation: organisation, term: 'Zorbelkern')
      ActsAsTenant.with_tenant(other_organisation) do
        create(:glossary_term, organisation: other_organisation, term: 'Zorbelfremd')
        create(:glossary_proposal, organisation: other_organisation, term: 'Wubfremd')
      end

      lane_of

      select = page.at_css('select[name="target"]')
      groups = select.css('optgroup').to_h { |group| [group['label'], group.css('option').map { |option| [option.text, option['value']] }] }
      expect(groups).to eq(
        I18n.t("#{gp}.show.merge_terms") => [['Zorbel', "term:#{confirmed.id}"]],
        I18n.t("#{gp}.show.merge_proposals") => [['Wub', "proposal:#{small_proposal.id}"]]
      )
    end

    it 'sends a full visit to the review list with the lane open' do
      get proposal_organisation_glossary_terms_path(organisation, proposal_id: proposal.id)

      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, view: 'proposals', proposal_id: proposal.id))
    end

    it 'opens on a full visit of the review list, the row marked' do
      review_list(proposal_id: proposal.id)

      expect(page.at_css('.glossary-page')['class']).to include('show-content')
      expect(page.at_css("turbo-frame##{frame_id} [data-glossary-proposal-detail]")).to be_present
      expect(row_of('Zorbel-Hub')['class']).to include('selected-row')
      expect(page.at_css('.glossary-page')['data-layout-toggle-unresolved-selection-value']).to be_nil
    end

    it 'answers a lane request of the index with the lane alone' do
      review_list(proposal_id: proposal.id)
      get organisation_glossary_terms_path(organisation, view: 'proposals', proposal_id: proposal.id), headers: frame_headers

      expect(response.body).to start_with(%(<turbo-frame id="#{frame_id}">))
      expect(page.at_css('[data-glossary-proposal-detail]')).to be_present
      expect(response.body).not_to include('glossary-tools')
    end

    it 'names an unknown proposal_id as unresolved' do
      unknown = SecureRandom.uuid

      review_list(proposal_id: unknown)

      data = page.at_css('.glossary-page')['data-layout-toggle-unresolved-selection-value']
      expect(JSON.parse(data)).to eq('proposal_id' => unknown)
    end

    it 'shows a dismissed proposal with the way back, an accepted one with its term' do
      term = create(:glossary_term, organisation: organisation, term: 'Quarnix')
      accepted_proposal.update!(glossary_term: term)

      lane_of(dismissed_proposal)
      expect(page.css('form[data-glossary-proposal-form]')).to be_empty
      expect(page.css('form').pluck('action'))
        .to eq([restore_proposal_organisation_glossary_terms_path(organisation, proposal_id: dismissed_proposal.id)])

      lane_of(accepted_proposal)
      expect(page.css('form')).to be_empty
      expect(page.at_css(%(a[href="#{organisation_glossary_terms_path(organisation, term_id: term.id)}"]))).to be_present
    end

    it 'shows no decision to a reader with view_glossary only' do
      sign_in viewer

      lane_of

      expect(response).to have_http_status(:ok)
      expect(page.css('form')).to be_empty
      expect(page.text).to include(I18n.t("#{gp}.show.read_only"), 'Zorbelhub')
    end

    it 'opens on the phone, the lane instead of the list' do
      review_list(proposal_id: proposal.id, viewport: 'mobile')

      expect(page.css('.mobile-list-view')).to be_empty
      expect(page.at_css(".mobile-detail-view turbo-frame##{frame_id} [data-glossary-proposal-detail]")).to be_present
      expect(page.at_css('form[data-glossary-proposal-form] input[name="viewport"]')['value']).to eq('mobile')
    end
  end

  # The run wrote each place with the rights of the account that started it;
  # the reader may have fewer. Only the project and the kind stand for every
  # reader of the glossary.
  describe 'the snippet of a source' do
    def source_for(record, project:, snippet:)
      create(:glossary_proposal_source, organisation: organisation, glossary_proposal: proposal, project: project,
                                        source: record, snippet: snippet)
    end

    it 'stands for a reader of the ticket, and in another project only project and kind stand' do
      grant(viewer, open_project, tickets_access: :read_only)
      sign_in viewer

      lane_of

      expect(snippet_of(open_source)).to eq('Der Zorbel-Hub steht im Ticket aus Ahorn.')
      expect(snippet_of(closed_source)).to be_nil
      expect(source_node(closed_source).text).to include('Projekt Birke', kind(:ticket))
      expect(response.body).not_to include('Geheim: der Zorbelhub aus Birke.')
    end

    it 'stands for no source to a reader without any project' do
      sign_in viewer

      lane_of

      expect([snippet_of(open_source), snippet_of(closed_source)]).to eq([nil, nil])
      expect(source_node(open_source).text).to include('Projekt Ahorn', kind(:ticket),
                                                       I18n.t("#{gp}.show.source_hidden"))
    end

    it 'stands for a public comment the reader may read, and not in a ticket the reader cannot read' do
      shown = source_for(create(:post, organisation: organisation, ticket: open_ticket, user: author, content: 'Zorbel-Hub offen'),
                         project: open_project, snippet: 'Kommentar: der Zorbel-Hub in Ahorn.')
      hidden = source_for(create(:post, organisation: organisation, ticket: closed_ticket, user: author, content: 'Zorbel-Hub zu'),
                          project: closed_project, snippet: 'Kommentar: der Zorbel-Hub in Birke.')
      grant(viewer, open_project, tickets_access: :read_only)
      sign_in viewer

      lane_of

      expect(snippet_of(shown)).to eq('Kommentar: der Zorbel-Hub in Ahorn.')
      expect(snippet_of(hidden)).to be_nil
      expect(source_node(hidden).text).to include('Projekt Birke', kind(:post))
    end

    # The run never reads a private comment; a row pointing at one (written
    # by hand here) must still never show its text, also not to its author's
    # account admin.
    it 'never stands for a private comment, also not for an account admin' do
      addressee = member_with(role_with)
      secret = create(:post, organisation: organisation, ticket: open_ticket, user: author, content: 'Zorbel-Hub privat',
                             is_private: true, visible_to_user: addressee)
      source = source_for(secret, project: open_project, snippet: 'Privat: der Zorbel-Hub unter uns.')
      sign_in admin

      lane_of

      expect(snippet_of(source)).to be_nil
      expect(source_node(source).text).to include('Projekt Ahorn', kind(:post))
      expect(response.body).not_to include('Privat: der Zorbel-Hub unter uns.')
      expect(snippet_of(open_source)).to eq('Der Zorbel-Hub steht im Ticket aus Ahorn.')
    end

    def note_in(project, snippet)
      source_for(create(:note, organisation: organisation, project: project, creator: author, title: 'Notiz'),
                 project: project, snippet: snippet)
    end

    def version_in(project, snippet)
      document = create(:document, organisation: organisation, project: project, creator: author)
      source_for(create(:document_version, organisation: organisation, document: document, title: 'Handbuch'),
                 project: project, snippet: snippet)
    end

    it 'stands for a note and a document version through their own areas, each in its project only' do
      shown_note = note_in(open_project, 'Notiz: der Zorbel-Hub in Ahorn.')
      hidden_note = note_in(closed_project, 'Notiz: der Zorbel-Hub in Birke.')
      shown_version = version_in(open_project, 'Handbuch: der Zorbel-Hub in Ahorn.')
      hidden_version = version_in(closed_project, 'Handbuch: der Zorbel-Hub in Birke.')
      grant(viewer, open_project, notes_access: :read_only, documents_access: :read_only)
      sign_in viewer

      lane_of

      expect([snippet_of(shown_note), snippet_of(shown_version)])
        .to eq(['Notiz: der Zorbel-Hub in Ahorn.', 'Handbuch: der Zorbel-Hub in Ahorn.'])
      expect([snippet_of(hidden_note), snippet_of(hidden_version)]).to eq([nil, nil])
      expect(source_node(hidden_note).text).to include('Projekt Birke', kind(:note))
      expect(source_node(hidden_version).text).to include('Projekt Birke', kind(:document_version))
      # The areas are separate: notes and documents open no ticket.
      expect(snippet_of(open_source)).to be_nil
    end

    it 'stands for a note only with the notes area, not with the documents area' do
      note = note_in(open_project, 'Notiz: nur mit Notizen.')
      version = version_in(open_project, 'Handbuch: nur mit Dokumenten.')
      grant(viewer, open_project, documents_access: :read_only)
      sign_in viewer

      lane_of

      expect([snippet_of(note), snippet_of(version)]).to eq([nil, 'Handbuch: nur mit Dokumenten.'])
    end

    it 'stands for the files of a ticket and of a public comment through their ticket' do
      comment = create(:post, organisation: organisation, ticket: open_ticket, user: author, content: 'Datei dabei')
      ticket_file = source_for(create(:ticket_document, organisation: organisation, ticket: open_ticket),
                               project: open_project, snippet: 'Ticketdatei: der Zorbel-Hub.')
      comment_file = source_for(create(:post_document, organisation: organisation, post: comment),
                                project: open_project, snippet: 'Kommentardatei: der Zorbel-Hub.')
      closed_comment = create(:post, organisation: organisation, ticket: closed_ticket, user: author, content: 'Datei zu')
      closed_ticket_file = source_for(create(:ticket_document, organisation: organisation, ticket: closed_ticket),
                                      project: closed_project, snippet: 'Ticketdatei aus Birke.')
      closed_comment_file = source_for(create(:post_document, organisation: organisation, post: closed_comment),
                                       project: closed_project, snippet: 'Kommentardatei aus Birke.')
      grant(viewer, open_project, tickets_access: :read_only)
      sign_in viewer

      lane_of

      expect([snippet_of(ticket_file), snippet_of(comment_file)]).to eq(['Ticketdatei: der Zorbel-Hub.', 'Kommentardatei: der Zorbel-Hub.'])
      expect([snippet_of(closed_ticket_file), snippet_of(closed_comment_file)]).to eq([nil, nil])
      expect(source_node(closed_comment_file).text).to include('Projekt Birke', kind(:post_document))
    end

    # A file of a private comment is as private as the comment.
    it 'never stands for the file of a private comment, also not for an account admin' do
      addressee = member_with(role_with)
      secret = create(:post, organisation: organisation, ticket: open_ticket, user: author, content: 'Datei privat',
                             is_private: true, visible_to_user: addressee)
      file = source_for(create(:post_document, organisation: organisation, post: secret),
                        project: open_project, snippet: 'Private Datei: der Zorbel-Hub.')
      sign_in admin

      lane_of

      expect(snippet_of(file)).to be_nil
      expect(source_node(file).text).to include('Projekt Ahorn', kind(:post_document))
      expect(response.body).not_to include('Private Datei: der Zorbel-Hub.')
    end

    it 'says so for a source that is gone, without its text' do
      open_ticket.destroy!
      sign_in admin

      lane_of

      node = source_node(open_source)
      expect(node.at_css('[data-glossary-source-gone]').text.squish).to eq(I18n.t("#{gp}.show.source_gone"))
      expect(snippet_of(open_source)).to be_nil
      expect(snippet_of(closed_source)).to eq('Geheim: der Zorbelhub aus Birke.')
    end
  end

  # The model wrote the hint from the snippets of the proposal's sources, read
  # with the rights of the account that started the run: for a reader of none
  # of them the sentence could repeat what such a source says ("a company to be
  # taken over"). What a row and the lane show besides stays (E3).
  describe 'the hint of a proposal' do
    let(:hint) { 'Ein erfundener Produktname.' }

    def hint_text
      page.at_css('[data-glossary-proposal-hint]')&.text&.squish
    end

    it 'stands for no reader who may read none of its sources, in the row and in the lane' do
      sign_in viewer

      review_list

      row = row_of('Zorbel-Hub')
      expect(row.at_css('.people-badge').text).to eq(I18n.t('views.organisations.glossary.categories.product'))
      expect(row.at_css('[data-glossary-proposal-variants]').text.squish).to eq(I18n.t("#{gp}.variants", forms: 'Zorbelhub, zorbel hub'))
      expect(row.at_css('[data-glossary-proposal-projects]').text.squish).to eq('Projekt Ahorn, Projekt Birke')
      expect(row.at_css('[data-glossary-proposal-hint]')).to be_nil
      expect(response.body).not_to include(hint)

      lane_of

      expect(page.at_css('.people-identity__name').text).to eq('Zorbel-Hub')
      expect(page.at_css('.people-identity__line').text).to include(I18n.t('views.organisations.glossary.categories.product'))
      expect(page.at_css('[data-glossary-proposal-variants]').text.squish).to eq(I18n.t("#{gp}.variants", forms: 'Zorbelhub, zorbel hub'))
      expect([source_node(open_source).text, source_node(closed_source).text]).to contain_exactly(
        a_string_including('Projekt Ahorn'), a_string_including('Projekt Birke')
      )
      expect(hint_text).to be_nil
      expect(response.body).not_to include(hint)
    end

    # The model read only some of the places, but which ones the proposal does
    # not keep: a reader of one of two may not have read the one it repeats.
    it 'stands for no reader of only some of its sources, in the row and in the lane' do
      grant(viewer, closed_project, tickets_access: :read_only)
      sign_in viewer

      review_list
      expect(row_of('Zorbel-Hub').at_css('[data-glossary-proposal-hint]')).to be_nil
      expect(response.body).not_to include(hint)

      lane_of
      expect(snippet_of(closed_source)).to eq('Geheim: der Zorbelhub aus Birke.')
      expect(hint_text).to be_nil
      expect(response.body).not_to include(hint)
    end

    it 'stands for a reader of every one of its sources, in the row and in the lane' do
      grant(viewer, open_project, tickets_access: :read_only)
      grant(viewer, closed_project, tickets_access: :read_only)
      sign_in viewer

      review_list
      expect(row_of('Zorbel-Hub').at_css('[data-glossary-proposal-hint]').text.squish).to eq(hint)

      lane_of
      expect(hint_text).to eq(I18n.t("#{gp}.show.hint", hint: hint))
    end

    # Without a place there is nothing to read that would let the sentence
    # stand, also for an account admin who reads every project.
    it 'stands for no reader when the proposal has no source' do
      bare = create(:glossary_proposal, organisation: organisation, term: 'Glimmox', hint: 'Ein Satz ohne Stelle.')
      sign_in admin

      review_list
      expect(row_of('Glimmox').at_css('[data-glossary-proposal-hint]')).to be_nil

      lane_of(bare)
      expect(hint_text).to be_nil
      expect(response.body).not_to include('Ein Satz ohne Stelle.')
    end

    # A private comment is readable by nobody here, so it opens no hint either,
    # also not for an account admin.
    it 'stands for no reader when its only source is a private comment' do
      secret = create(:post, organisation: organisation, ticket: open_ticket, user: author, content: 'Zorbel privat',
                             is_private: true, visible_to_user: member_with(role_with))
      private_only = create(:glossary_proposal, organisation: organisation, term: 'Kryptax', hint: 'Ein geheimer Name.')
      create(:glossary_proposal_source, organisation: organisation, glossary_proposal: private_only, project: open_project,
                                        source: secret, snippet: 'Privat: Kryptax.')
      sign_in admin

      review_list
      expect(row_of('Kryptax').at_css('[data-glossary-proposal-hint]')).to be_nil
      expect(row_of('Zorbel-Hub').at_css('[data-glossary-proposal-hint]').text.squish).to eq(hint)

      lane_of(private_only)
      expect(hint_text).to be_nil
      expect(response.body).not_to include('Ein geheimer Name.')
    end
  end

  describe 'the decisions with manage_glossary' do
    before { sign_in manager }

    def heard_forms(term)
      TermCorrection.where(glossary_term: term).order(:normalized_heard).pluck(:heard, :origin, :status)
    end

    it 'accepts with the spelling, the category and the spellings of the form, and opens the term in the terms view' do
      patch accept_proposal_organisation_glossary_terms_path(organisation, proposal_id: proposal.id),
            params: { proposal: { term: 'Zorbel Hub', category: 'company', variants: %w[Zorbel-Hub Zorbelhub] },
                      view: 'proposals', status: 'open', category: 'product' }

      term = GlossaryTerm.find_by!(normalized_term: 'zorbel hub')
      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, category: 'product', term_id: term.id))
      expect(flash[:notice]).to eq(I18n.t("#{cp}.accept.success"))
      expect([term.term, term.status, term.category]).to eq(['Zorbel Hub', 'confirmed', 'company'])
      expect(heard_forms(term)).to eq([%w[Zorbel-Hub extraction confirmed], %w[Zorbelhub extraction confirmed]])
      expect(proposal.reload.slice(:status, :glossary_term_id, :decided_by_id))
        .to eq('status' => 'accepted', 'glossary_term_id' => term.id, 'decided_by_id' => manager.id)
    end

    it 'accepts from a row with the spelling and every spelling of the proposal' do
      review_list
      form = row_of('Zorbel-Hub').css('form').first
      fields = form.css('input[type="hidden"]').reject { |input| input['name'] == 'authenticity_token' }
      params = fields.each_with_object({}) do |input, collected|
        name = input['name']
        if name.end_with?('[]')
          (collected[name.delete_suffix('[]')] ||= []) << input['value']
        else
          collected[name] = input['value']
        end
      end

      post form['action'], params: params

      term = GlossaryTerm.find_by!(normalized_term: 'zorbel-hub')
      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, term_id: term.id))
      expect(heard_forms(term).map(&:first)).to eq(['zorbel hub', 'Zorbelhub'])
    end

    it 'merges into a confirmed term: the term keeps its spelling, the proposal and its spellings become heard forms' do
      target = create(:glossary_term, organisation: organisation, term: 'Zorbel', category: 'place')

      post merge_proposal_organisation_glossary_terms_path(organisation, proposal_id: proposal.id),
           params: { target: "term:#{target.id}", proposal: { term: 'Zorbel-Hub', variants: ['Zorbelhub'] }, view: 'proposals' }

      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, term_id: target.id))
      expect(flash[:notice]).to eq(I18n.t("#{cp}.merge.success"))
      expect(target.reload.slice(:term, :category, :status)).to eq('term' => 'Zorbel', 'category' => 'place', 'status' => 'confirmed')
      expect(heard_forms(target).map(&:first)).to eq(%w[Zorbel-Hub Zorbelhub])
      expect(proposal.reload.slice(:status, :glossary_term_id)).to eq('status' => 'accepted', 'glossary_term_id' => target.id)
    end

    it 'merges into another proposal, which opens in the lane and gains the spellings and the places' do
      post merge_proposal_organisation_glossary_terms_path(organisation, proposal_id: proposal.id),
           params: { target: "proposal:#{small_proposal.id}", proposal: { term: 'Zorbel-Hub' }, view: 'proposals' }

      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, view: 'proposals', proposal_id: small_proposal.id))
      expect(GlossaryProposal.where(id: proposal.id)).not_to exist
      expect(small_proposal.reload.variants).to eq(['Zorbel-Hub', 'Zorbelhub', 'zorbel hub'])
      expect(GlossaryProposalSource.where(glossary_proposal: small_proposal).count).to eq(2)
    end

    # Only what the select of the lane offers: a confirmed term of this
    # glossary or another open proposal, found through the policy scope.
    {
      'nothing' => -> { '' },
      'a kind without an id' => -> { 'term:' },
      'a term of another organisation' => lambda {
        ActsAsTenant.with_tenant(other_organisation) { create(:glossary_term, organisation: other_organisation) }
                    .then { |term| "term:#{term.id}" }
      },
      'a proposed term' => -> { "term:#{create(:glossary_term, :proposed, organisation: organisation).id}" },
      'the proposal itself' => -> { "proposal:#{proposal.id}" },
      'an accepted proposal' => -> { "proposal:#{accepted_proposal.id}" },
      'an unknown kind' => -> { "planet:#{small_proposal.id}" },
      'a bare id' => -> { small_proposal.id }
    }.each do |label, target|
      it "refuses a merge into #{label} and changes nothing" do
        value = instance_exec(&target)
        before = glossary_state

        post merge_proposal_organisation_glossary_terms_path(organisation, proposal_id: proposal.id),
             params: { target: value, proposal: { term: 'Zorbel-Hub' }, view: 'proposals' }

        expect(response).to redirect_to(organisation_glossary_terms_path(organisation, view: 'proposals', proposal_id: proposal.id))
        expect(flash[:alert]).to eq(I18n.t("#{cp}.merge.no_target"))
        expect(glossary_state).to eq(before)
      end
    end

    it 'dismisses and restores, the list staying as it was' do
      patch dismiss_proposal_organisation_glossary_terms_path(organisation, proposal_id: proposal.id),
            params: { view: 'proposals', status: 'open' }

      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, view: 'proposals', status: 'open'))
      expect(flash[:notice]).to eq(I18n.t("#{cp}.dismiss.success"))
      expect(proposal.reload.slice(:status, :decided_by_id)).to eq('status' => 'dismissed', 'decided_by_id' => manager.id)

      patch restore_proposal_organisation_glossary_terms_path(organisation, proposal_id: proposal.id),
            params: { view: 'proposals', status: 'dismissed' }

      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, view: 'proposals', status: 'dismissed'))
      expect(flash[:notice]).to eq(I18n.t("#{cp}.restore.success"))
      expect(proposal.reload.slice(:status, :decided_by_id)).to eq('status' => 'open', 'decided_by_id' => nil)
    end

    it 'lands with the reason of the actor when someone else decided first' do
      patch dismiss_proposal_organisation_glossary_terms_path(organisation, proposal_id: accepted_proposal.id),
            params: { view: 'proposals' }
      expect(flash[:alert]).to eq(I18n.t("#{cp}.already_processed"))
      expect(accepted_proposal.reload.status).to eq('accepted')

      patch accept_proposal_organisation_glossary_terms_path(organisation, proposal_id: dismissed_proposal.id),
            params: { proposal: { term: 'Plumbix' }, view: 'proposals' }
      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, view: 'proposals', proposal_id: dismissed_proposal.id))
      expect(flash[:alert]).to eq(I18n.t("#{cp}.already_processed"))
      expect(GlossaryTerm.where(normalized_term: 'plumbix')).not_to exist
    end

    it 'keeps the phone view through a decision' do
      patch dismiss_proposal_organisation_glossary_terms_path(organisation, proposal_id: proposal.id),
            params: { view: 'proposals', viewport: 'mobile' }

      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, view: 'proposals', viewport: 'mobile'))
    end

    it 'answers a form that is no form with 400, and accepts nothing' do
      patch accept_proposal_organisation_glossary_terms_path(organisation, proposal_id: proposal.id), params: { proposal: 'Zorbel' }

      expect(response).to have_http_status(:bad_request)
      expect(proposal.reload.status).to eq('open')
    end
  end

  # [verb, path, params] of every decision on a proposal.
  def decision(name, target = proposal)
    id = target.id
    {
      'accept' => [:patch, accept_proposal_organisation_glossary_terms_path(organisation, proposal_id: id),
                   { proposal: { term: 'Zorbel-Hub', variants: ['Zorbelhub'] } }],
      'merge' => [:post, merge_proposal_organisation_glossary_terms_path(organisation, proposal_id: id),
                  { target: "proposal:#{small_proposal.id}", proposal: { term: 'Zorbel-Hub' } }],
      'dismiss' => [:patch, dismiss_proposal_organisation_glossary_terms_path(organisation, proposal_id: id), {}],
      'restore' => [:patch, restore_proposal_organisation_glossary_terms_path(organisation, proposal_id: id), {}]
    }.fetch(name)
  end

  # One example per decision: Prosopite reads requests sent from one line of
  # a loop as an N+1.
  def self.decision_names
    %w[accept merge dismiss restore]
  end

  describe 'without manage_glossary' do
    { 'view_glossary only' => :viewer, 'no glossary right' => :nobody }.each do |label, reader|
      decision_names.each do |name|
        it "refuses #{name} with 403 for #{label}, and nothing changes" do
          target = name == 'restore' ? dismissed_proposal : proposal
          sign_in public_send(reader)
          before = glossary_state
          verb, path, params = decision(name, target)

          public_send(verb, path, params: params)

          expect(response).to have_http_status(:forbidden)
          expect(glossary_state).to eq(before)
        end
      end
    end

    # The right comes before the lookup: a proposal of another organisation
    # answers 403 too, never a 404 that would tell it apart from a missing one.
    it 'refuses a decision on a proposal of another organisation with 403 before looking it up' do
      foreign = ActsAsTenant.with_tenant(other_organisation) { create(:glossary_proposal, organisation: other_organisation) }
      sign_in viewer

      patch dismiss_proposal_organisation_glossary_terms_path(organisation, proposal_id: foreign.id)

      expect(response).to have_http_status(:forbidden)
    end

    it 'answers 403 on the review list, the lane and the lane frame without view_glossary' do
      sign_in nobody

      review_list
      expect(response).to have_http_status(:forbidden)

      lane_of
      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include('Zorbel')

      get organisation_glossary_terms_path(organisation, view: 'proposals', proposal_id: proposal.id), headers: frame_headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'a proposal of another organisation' do
    let(:foreign) do
      ActsAsTenant.with_tenant(other_organisation) do
        create(:glossary_proposal, organisation: other_organisation, term: 'Fremdling').tap do |found|
          create(:glossary_proposal_source, organisation: other_organisation, glossary_proposal: found, snippet: 'Fremd.')
        end
      end
    end

    before { sign_in admin }

    def foreign_state
      ActsAsTenant.without_tenant { GlossaryProposal.unscoped.where(id: foreign.id).pluck(:status, :variants) }
    end

    # One request per example: after a 404 the test session is signed out.
    it 'is no proposal in the lane (404)' do
      lane_of(foreign)

      expect(response).to have_http_status(:not_found)
    end

    it 'is no proposal on a full visit of the review list: the lane stays closed' do
      review_list(proposal_id: foreign.id)

      expect(response.body).not_to include('Fremdling', 'Fremd.')
      expect(JSON.parse(page.at_css('.glossary-page')['data-layout-toggle-unresolved-selection-value']))
        .to eq('proposal_id' => foreign.id)
    end

    decision_names.each do |name|
      it "answers 404 for #{name} and leaves it alone" do
        before = foreign_state
        verb, path, params = decision(name, foreign)

        public_send(verb, path, params: params)

        expect(response).to have_http_status(:not_found)
        expect(foreign_state).to eq(before)
      end
    end

    it 'is no target of a merge' do
      target = "proposal:#{foreign.id}"
      before = glossary_state

      post merge_proposal_organisation_glossary_terms_path(organisation, proposal_id: proposal.id),
           params: { target: target, proposal: { term: 'Zorbel-Hub' } }

      expect(flash[:alert]).to eq(I18n.t("#{cp}.merge.no_target"))
      expect(glossary_state).to eq(before)
      expect(foreign_state).to eq([['open', []]])
    end
  end

  # Prosopite watches every example; the fixtures are built in a loop, so only
  # the requests are watched.
  describe 'queries' do
    before do
      Prosopite.pause do
        projects = Array.new(3) { |index| create(:project, organisation: organisation, name: "Projekt #{index}") }
        30.times do |index|
          found = create(:glossary_proposal, organisation: organisation, term: "Zorbelwort #{index}", category: 'domain',
                                             variants: ["Zorbel Wort #{index}"], hint: 'Erfunden.', occurrences: index + 10)
          2.times do |place|
            project = projects[(index + place) % projects.size]
            create(:glossary_proposal_source, organisation: organisation, glossary_proposal: found, project: project,
                                              source: create(:ticket, organisation: organisation, project: project, creator: author))
          end
        end
      end
    end

    it 'renders the review list of many proposals with their sources without an N+1' do
      sign_in manager

      review_list

      expect(response).to have_http_status(:ok)
      expect(page.css('[data-glossary-proposal-row]').size).to eq(32)
      expect(page.css('[data-glossary-proposal-row] form').size).to eq(64)
    end

    # One question for the sources of every listed proposal, not one per row.
    it 'renders the review list with the hints its reader may see without an N+1' do
      reader = member_with(role_with('view_glossary'))
      grant(reader, Project.find_by!(organisation: organisation, name: 'Projekt 0'), tickets_access: :read_only)
      grant(reader, Project.find_by!(organisation: organisation, name: 'Projekt 1'), tickets_access: :read_only)
      sign_in reader

      review_list

      expect(response).to have_http_status(:ok)
      # Proposal n has its sources in the projects n % 3 and (n + 1) % 3: both
      # lie in Projekt 0 and 1 for the 10 with n % 3 == 0. The other 20 have one
      # source there and one in Projekt 2, the two others none there.
      expect(page.css('[data-glossary-proposal-row] [data-glossary-proposal-hint]').size).to eq(10)
    end

    it 'renders a lane with sources of every kind without an N+1' do
      comment = create(:post, organisation: organisation, ticket: open_ticket, user: author, content: 'Zorbel')
      create(:glossary_proposal_source, organisation: organisation, glossary_proposal: proposal, project: open_project,
                                        source: comment, snippet: 'Kommentar.')
      sign_in member_with(role_with('manage_glossary'))

      lane_of

      expect(response).to have_http_status(:ok)
      expect(page.css('[data-glossary-proposal-source]').size).to eq(3)
    end
  end

  %w[de en].each do |locale|
    it "renders the review list and the lane in #{locale} without a missing text" do
      manager.update!(language_preference: locale)
      sign_in manager

      review_list(proposal_id: proposal.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('translation missing', 'Translation missing')
      I18n.with_locale(locale) do
        expect(page.text).to include(I18n.t("#{gp}.statuses.open"), I18n.t("#{gp}.show.sources_title"), I18n.t("#{gp}.accept"))
        expect(page.at_css('a[data-glossary-terms-link]').text.squish).to eq(I18n.t("#{gp}.back_to_terms"))
      end
    end
  end
end
