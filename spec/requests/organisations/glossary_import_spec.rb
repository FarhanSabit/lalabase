# frozen_string_literal: true

require 'rails_helper'

# The import of a pasted list into the glossary, on its page (K5a): the button
# in the head of the list, the import lane (?new=import), the check (a dry run
# of Actors::ImportGlossaryTerms in the lane frame, nothing written) and the
# import itself, which lands on the list with the counts as its notice. Every
# reader of the glossary may import: with manage_glossary the new terms are
# confirmed, with view_glossary only they are proposals. Without the right
# every step answers 403 and nothing is written. Invented words and names only.
RSpec.describe 'Organisations::Glossary import', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def role_with(*glossary_actions)
    role = create(:role, organisation: organisation)
    glossary_actions.each { |action| create(:permission, role: role, category: 'glossary', action: action, allowed: true) }
    role
  end

  def member_with(role)
    user = create(:user, first_name: 'Anna', last_name: "Beispiel#{SecureRandom.hex(2)}")
    create(:membership, user: user, organisation: organisation, role: role)
    user
  end

  let(:viewer) { member_with(role_with('view_glossary')) }
  let(:manager) { member_with(role_with('manage_glossary')) }
  let(:nobody) { member_with(role_with) }

  let(:frame_id) { Organisations::GlossaryController::DETAIL_FRAME_ID }
  let(:frame_headers) { { 'Turbo-Frame' => frame_id } }
  let(:gi) { 'views.organisations.glossary.import' }
  let(:ci) { 'controllers.glossary.import' }

  # The check, as the lane sends it: inside the lane frame.
  def check_list(text, **params)
    post import_preview_organisation_glossary_terms_path(organisation),
         params: { import: { text: text } }.merge(params), headers: frame_headers
  end

  # The import, as the check sends it: it leaves the frame (_top).
  def import_list(text, **params)
    post import_organisation_glossary_terms_path(organisation), params: { import: { text: text } }.merge(params)
  end

  def terms
    GlossaryTerm.unscoped.where(organisation_id: organisation.id)
  end

  # Every term of every organisation, with what an import could change.
  def glossary_state
    GlossaryTerm.unscoped.order(:id).pluck(:id, :organisation_id, :term, :status, :category, :created_by_id, :lock_version)
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def category_name(key)
    I18n.t(key, scope: 'views.organisations.glossary.categories')
  end

  def verdict(key)
    I18n.t("#{gi}.verdicts.#{key}")
  end

  # [number, spelling, category, verdict] of every row of the check.
  def checked_lines
    page.css('[data-glossary-import-line]').map { |row| row.css('td').map { |cell| cell.text.squish } }
  end

  # The counters on top of the check, by verdict.
  def checked_counts
    page.css('[data-glossary-import-count]').to_h { |item| [item['data-glossary-import-count'], item.text.squish] }
  end

  def import_form
    page.at_css(%(form[action="#{import_organisation_glossary_terms_path(organisation)}"]))
  end

  def textarea
    page.at_css('textarea[name="import[text]"]')
  end

  # What the textarea holds: ActionView writes a line break after the opening
  # tag, which the HTML parser drops.
  def textarea_text
    textarea.text.delete_prefix("\n")
  end

  def notice(*parts)
    I18n.t("#{ci}.success", summary: parts.map { |key, count| I18n.t("#{ci}.counts.#{key}", count: count) }.to_sentence)
  end

  describe 'the button in the head of the list' do
    { 'view_glossary' => :viewer, 'manage_glossary' => :manager }.each do |right, reader|
      [nil, 'mobile'].each do |viewport|
        it "is there for a reader with #{right} (#{viewport || 'desktop'}) and opens the import lane" do
          sign_in public_send(reader)

          get organisation_glossary_terms_path(organisation, viewport: viewport)

          expect(response).to have_http_status(:ok)
          link = page.at_css('a[data-glossary-import-link]')
          expect(link).to be_present
          expect(link.text.squish).to eq(I18n.t("#{gi}.open"))
          expect(link['href']).to eq(organisation_glossary_terms_path(organisation, new: 'import', viewport: viewport))
          expect(link['data-controller']).to eq('lane-link')
          expect(JSON.parse(link['data-lane-link-set-value'])).to eq('new' => 'import')
          expect(link['data-lane-link-frame-value']).to eq(frame_id)
          expect(link['data-lane-link-url-value']).to eq(organisation_glossary_terms_path(organisation, new: 'import'))
        end
      end
    end
  end

  describe 'the import lane' do
    before { sign_in viewer }

    it 'opens on a full visit of ?new=import, beside the list' do
      create(:glossary_term, organisation: organisation, term: 'Zorbel')

      get organisation_glossary_terms_path(organisation, new: 'import')

      expect(response).to have_http_status(:ok)
      wrapper = page.at_css('.glossary-page')
      expect(wrapper['class']).to include('show-content')
      # The server opened what the address names: layout-toggle takes nothing out.
      expect(wrapper['data-layout-toggle-unresolved-selection-value']).to be_nil
      expect(page.at_css("turbo-frame##{frame_id} .glossary-content textarea[name='import[text]']")).to be_present
      expect(page.css('[data-glossary-row]').map { |row| row.at_css('.people-row__name').text }).to eq(['Zorbel'])
    end

    it 'answers a lane frame request with the lane alone' do
      get organisation_glossary_terms_path(organisation, new: 'import'), headers: frame_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to start_with(%(<turbo-frame id="#{frame_id}">))
      expect(response.body).not_to include('glossary-tools')
      expect(textarea).to be_present
      expect(textarea['id']).to eq('glossary_import_text')
      form = textarea.ancestors('form').first
      expect(form['action']).to eq(import_preview_organisation_glossary_terms_path(organisation))
    end

    it 'names the line form, the categories by name and the limit' do
      get organisation_glossary_terms_path(organisation, new: 'import'), headers: frame_headers

      text = page.text.squish
      expect(text).to include(I18n.t("#{gi}.hint"))
      expect(text).to include(*GlossaryTerm::CATEGORIES.map { |key| category_name(key) })
      expect(text).to include(I18n.t("#{gi}.limit", max: Actors::ImportGlossaryTerms::MAX_LINES))
    end

    it 'carries the filters along in the form' do
      get organisation_glossary_terms_path(organisation, new: 'import', category: 'product'), headers: frame_headers

      expect(textarea.ancestors('form').first.at_css('input[type="hidden"][name="category"]')['value']).to eq('product')
    end

    it 'renders on the phone, the lane instead of the list' do
      get organisation_glossary_terms_path(organisation, new: 'import', viewport: 'mobile')

      expect(response).to have_http_status(:ok)
      expect(page.css('.people-mobile-grid')).to be_present
      expect(page.css('.mobile-list-view')).to be_empty
      expect(page.at_css(".mobile-detail-view turbo-frame##{frame_id} textarea[name='import[text]']")).to be_present
      expect(textarea.ancestors('form').first.at_css('input[type="hidden"][name="viewport"]')['value']).to eq('mobile')
    end
  end

  describe 'the check with manage_glossary' do
    # Zorbel without a category (line 2 would give it one), Quarnix rejected.
    before do
      create(:glossary_term, organisation: organisation, term: 'Zorbel')
      create(:glossary_term, :rejected, organisation: organisation, term: 'Quarnix')
      sign_in manager
    end

    let(:text) { "Zorbel-Hub;product\nzorbel;place\nWub;#{category_name('company')}\n\nwub\nQuarnix\n;place" }

    it 'shows the counts and a verdict for every line in the lane frame, and writes nothing' do
      before = glossary_state

      check_list(text)

      expect(response).to have_http_status(:ok)
      expect(response.body).to start_with(%(<turbo-frame id="#{frame_id}">))
      expect(glossary_state).to eq(before)
      expect(checked_lines).to eq(
        [
          ['1', 'Zorbel-Hub', category_name('product'), verdict(:new)],
          ['2', 'zorbel', category_name('place'), verdict(:existing)],
          ['3', 'Wub', category_name('company'), verdict(:new)],
          ['5', 'wub', '', verdict(:duplicate)],
          ['6', 'Quarnix', '', verdict(:rejected)],
          ['7', ';place', '', verdict(:invalid)]
        ]
      )
      expect(checked_counts).to eq(
        'new' => I18n.t("#{gi}.counts.new", count: 2),
        'existing' => I18n.t("#{gi}.counts.existing", count: 1),
        'duplicate' => I18n.t("#{gi}.counts.duplicate", count: 1),
        'invalid' => I18n.t("#{gi}.counts.invalid", count: 1),
        'rejected' => I18n.t("#{gi}.counts.rejected", count: 1),
        'categorized' => I18n.t("#{gi}.counts.categorized", count: 1)
      )
      expect(page.css('[data-glossary-import-proposals]')).to be_empty
    end

    it 'sends the text on to the import, which leaves the frame, and offers the way back' do
      check_list(text, category: 'person')

      expect(import_form['data-turbo-frame']).to eq('_top')
      expect(import_form.at_css('input[type="hidden"][name="import[text]"]')['value']).to eq(text)
      expect(import_form.at_css('input[type="hidden"][name="category"]')['value']).to eq('person')
      submit = import_form.css('button[type="submit"]').reject { |button| button['formaction'] }
      expect(submit.map { |button| button.text.squish }).to eq([I18n.t("#{gi}.submit")])
      back = import_form.at_css('button[type="submit"][formaction]')
      expect(back['formaction']).to eq(import_preview_organisation_glossary_terms_path(organisation))
      expect([back['name'], back['value'], back['data-turbo-frame']]).to eq(['edit', '1', frame_id])
      expect(back.text.squish).to eq(I18n.t("#{gi}.back"))
    end

    it 'goes back from the check to the textarea with the text kept, and writes nothing' do
      before = glossary_state

      check_list(text, edit: '1')

      expect(response).to have_http_status(:ok)
      expect(textarea_text).to eq(text)
      expect(page.css('[data-glossary-import-line]')).to be_empty
      expect(glossary_state).to eq(before)
    end

    it 'cuts a long line it cannot read' do
      check_list("#{'Z' * 300}\nWub")

      spelling = checked_lines.first[1]
      expect(spelling.length).to be < 100
      expect(spelling).to start_with('ZZZ')
      expect(checked_lines.map(&:last)).to eq([verdict(:invalid), verdict(:new)])
    end
  end

  # The column shows a category only where the import gives it to the term: a
  # new term, or a term the glossary has without one (with manage_glossary).
  # A category the import drops shows nothing.
  describe 'the category column of the check' do
    it 'shows nothing for a term that keeps its own category' do
      create(:glossary_term, organisation: organisation, term: 'Wub', category: 'company')
      sign_in manager

      check_list('Wub;product')

      expect(checked_lines).to eq([['1', 'Wub', '', verdict(:existing)]])
    end

    it 'shows nothing for a duplicate line' do
      sign_in manager

      check_list("Zorbel;company\nzorbel;product")

      expect(checked_lines).to eq([['1', 'Zorbel', category_name('company'), verdict(:new)], ['2', 'zorbel', '', verdict(:duplicate)]])
    end

    it 'shows nothing for a term the glossary has with view_glossary only, and the category of a new term' do
      create(:glossary_term, organisation: organisation, term: 'Zorbel')
      sign_in viewer

      check_list("zorbel;product\nWub;company")

      expect(checked_lines).to eq([['1', 'zorbel', '', verdict(:existing)], ['2', 'Wub', category_name('company'), verdict(:new)]])
    end
  end

  describe 'the import with manage_glossary' do
    before { sign_in manager }

    it 'writes 200 lines "Term;category" as 200 confirmed terms with their category and names the count' do
      categories = GlossaryTerm::CATEGORIES
      lines = (1..200).to_h { |n| ["Zorbel #{n}", categories[n % categories.size]] }

      import_list(lines.map { |term, category| "#{term};#{category}" }.join("\n"))

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(organisation_glossary_terms_path(organisation))
      expect(terms.to_h { |term| [term.term, term.category] }).to eq(lines)
      expect(terms.distinct.pluck(:status, :created_by_id)).to eq([['confirmed', manager.id]])
      expect(flash[:notice]).to eq('Liste importiert: 200 Begriffe angelegt.')
    end

    it 'names the counts in English for a user who reads English' do
      manager.update!(language_preference: 'en')
      create(:glossary_term, organisation: organisation, term: 'Zorbel')

      import_list("Wub;product\nzorbel\nwub")

      expect(flash[:notice]).to eq('List imported: 1 term created, 1 already there, and 1 twice in the list.')
    end

    it 'keeps the filters and the phone view on the way back to the list' do
      import_list('Wub', status: 'proposed', viewport: 'mobile')

      expect(response).to redirect_to(organisation_glossary_terms_path(organisation, status: 'proposed', viewport: 'mobile'))
    end

    # The actor gives a term without a category the one its line names,
    # whatever its status, and never changes a status.
    it 'names an existing term and a duplicate line in the check and counts them in the notice; a rejected term stays rejected' do
      existing = create(:glossary_term, :proposed, organisation: organisation, term: 'Zorbel')
      rejected = create(:glossary_term, :rejected, organisation: organisation, term: 'Quarnix')
      text = "ZORBEL;product\nWub\nwub\nquarnix"

      check_list(text)
      expect(checked_lines.map { |line| [line[1], line[3]] }).to eq(
        [['ZORBEL', verdict(:existing)], ['Wub', verdict(:new)], ['wub', verdict(:duplicate)], ['quarnix', verdict(:rejected)]]
      )

      import_list(text)
      expect(flash[:notice]).to eq(notice([:created, 1], [:categorized, 1], [:existing, 1], [:rejected, 1], [:duplicate, 1]))
      expect(existing.reload.slice(:term, :status, :category)).to eq('term' => 'Zorbel', 'status' => 'proposed', 'category' => 'product')
      expect(rejected.reload.slice(:status, :category)).to eq('status' => 'rejected', 'category' => nil)
      expect(terms.order(:normalized_term).pluck(:term)).to eq(%w[Quarnix Wub Zorbel])
    end
  end

  describe 'with view_glossary only' do
    before { sign_in viewer }

    it 'says in the lane and in the check that the terms will be proposals' do
      get organisation_glossary_terms_path(organisation, new: 'import'), headers: frame_headers
      expect(page.at_css('[data-glossary-import-proposals]').text.squish).to eq(I18n.t("#{gi}.proposals"))

      check_list('Zorbel')
      expect(page.at_css('[data-glossary-import-proposals]').text.squish).to eq(I18n.t("#{gi}.proposals"))
      expect(terms).to be_empty
    end

    it 'imports the terms as proposals with their creator and names them in the notice' do
      import_list("Zorbel;product\nWub")

      expect(terms.order(:normalized_term).pluck(:term, :category, :status, :created_by_id))
        .to eq([['Wub', nil, 'proposed', viewer.id], ['Zorbel', 'product', 'proposed', viewer.id]])
      expect(flash[:notice]).to eq(notice([:proposed, 2]))
    end

    it 'never confirms or categorizes a term the glossary has' do
      term = create(:glossary_term, :proposed, organisation: organisation, term: 'Zorbel')

      import_list('zorbel;product')

      expect(term.reload.slice(:status, :category, :lock_version)).to eq('status' => 'proposed', 'category' => nil, 'lock_version' => 0)
      expect(flash[:notice]).to eq(notice([:existing, 1]))
    end
  end

  describe 'a status changed between the lookup and the category lock' do
    before { sign_in manager }

    # The lookup returns its original snapshot; the real lock sees the write.
    # The preview rolls this write back too, so reload before repeating it
    # on the import request.
    def change_term_after_lookup(term, **attributes)
      allow_any_instance_of(Actors::ImportGlossaryTerms).to receive(:existing_terms).and_wrap_original do |original, *arguments|
        known = original.call(*arguments)
        term.reload.update!(attributes)
        known
      end
    end

    [['confirmed', 'rejected', :rejected], ['rejected', 'confirmed', :existing]].each do |old_status, new_status, current_verdict|
      it "reports #{old_status} -> #{new_status} in the check and import notice while applying the category", :aggregate_failures do
        term = create(:glossary_term, organisation: organisation, term: 'Zorbel', status: old_status)
        change_term_after_lookup(term, status: new_status)
        before = glossary_state

        check_list('zorbel;product')

        expect(response).to have_http_status(:ok)
        expect(checked_lines).to eq([['1', 'zorbel', category_name('product'), verdict(current_verdict)]])
        expect(checked_counts).to include(
          'existing' => I18n.t("#{gi}.counts.existing", count: current_verdict == :existing ? 1 : 0),
          'rejected' => I18n.t("#{gi}.counts.rejected", count: current_verdict == :rejected ? 1 : 0),
          'categorized' => I18n.t("#{gi}.counts.categorized", count: 1)
        )
        expect(glossary_state).to eq(before)

        import_list('zorbel;product')

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(organisation_glossary_terms_path(organisation))
        expect(flash[:notice]).to eq(notice([:categorized, 1], [current_verdict, 1]))
        expect(term.reload.slice(:term, :status, :category))
          .to eq('term' => 'Zorbel', 'status' => new_status, 'category' => 'product')
      end
    end

    it 'reports the current status even when another writer already assigned the category', :aggregate_failures do
      term = create(:glossary_term, organisation: organisation, term: 'Zorbel')
      change_term_after_lookup(term, term: 'ZORBEL', status: 'rejected', category: 'company')
      before = glossary_state

      check_list('zorbel;product')

      expect(response).to have_http_status(:ok)
      expect(checked_lines).to eq([['1', 'zorbel', '', verdict(:rejected)]])
      expect(checked_counts).to include(
        'existing' => I18n.t("#{gi}.counts.existing", count: 0),
        'rejected' => I18n.t("#{gi}.counts.rejected", count: 1)
      )
      expect(checked_counts).not_to have_key('categorized')
      expect(glossary_state).to eq(before)

      import_list('zorbel;product')

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(organisation_glossary_terms_path(organisation))
      expect(flash[:notice]).to eq(notice([:rejected, 1]))
      expect(term.reload.slice(:term, :status, :category, :lock_version))
        .to eq('term' => 'ZORBEL', 'status' => 'rejected', 'category' => 'company', 'lock_version' => 1)
    end
  end

  describe 'a term renamed between the lookup and the category lock' do
    let(:text) { "Zorbel;product\nWub;company" }

    before do
      term = create(:glossary_term, organisation: organisation, term: 'Zorbel')
      sign_in manager

      allow_any_instance_of(Actors::ImportGlossaryTerms).to receive(:existing_terms).and_wrap_original do |original, *arguments|
        known = original.call(*arguments)
        term.update!(term: 'Quarnix')
        known
      end
    end

    it 'refuses the check with 422, the translated error and the submitted text in the lane frame' do
      check_list(text)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to start_with(%(<turbo-frame id="#{frame_id}">))
      expect(page.at_css('.glossary-page')).to be_nil
      expect(page.at_css('.glossary-content [role="alert"]').text.squish).to eq(I18n.t('services.actors.stale_object'))
      expect(textarea_text).to eq(text)
    end

    it 'refuses the import with 422, the translated error and the submitted text beside the full list' do
      import_list(text)

      expect(response).to have_http_status(:unprocessable_content)
      expect(page.at_css('.glossary-page')['class']).to include('show-content')
      expect(page.css('[data-glossary-row]').map { |row| row.at_css('.people-row__name').text }).to eq(['Zorbel'])
      expect(page.at_css('.glossary-content [role="alert"]').text.squish).to eq(I18n.t('services.actors.stale_object'))
      expect(textarea_text).to eq(text)
    end
  end

  describe 'a list the import refuses' do
    before { sign_in manager }

    let(:too_long) { (1..501).map { |n| "Quarnix #{n}" }.join("\n") }

    it 'refuses the check of 501 lines with 422 and the reason in the lane, the text kept, and writes nothing' do
      check_list(too_long)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to start_with(%(<turbo-frame id="#{frame_id}">))
      expect(page.at_css('.glossary-content [role="alert"]').text.squish).to eq(I18n.t("#{ci}.too_many_lines", max: 500))
      expect(textarea_text).to eq(too_long)
      expect(terms).to be_empty
    end

    it 'refuses the import of 501 lines with 422: the page with the import open, the reason and the text' do
      import_list(too_long)

      expect(response).to have_http_status(:unprocessable_content)
      expect(page.at_css('.glossary-page')['class']).to include('show-content')
      expect(page.at_css('.glossary-content [role="alert"]').text.squish).to eq(I18n.t("#{ci}.too_many_lines", max: 500))
      expect(textarea_text).to eq(too_long)
      expect(terms).to be_empty
    end

    it 'refuses the check of a list without a term with 422 and the reason in the lane' do
      check_list(" \n\t\n")

      expect(response).to have_http_status(:unprocessable_content)
      expect(page.at_css('.glossary-content [role="alert"]').text.squish).to eq(I18n.t("#{ci}.empty"))
      expect(terms).to be_empty
    end

    it 'refuses the import of a list without a term with 422 and the reason in the lane' do
      import_list('')

      expect(response).to have_http_status(:unprocessable_content)
      expect(page.at_css('.glossary-content [role="alert"]').text.squish).to eq(I18n.t("#{ci}.empty"))
      expect(terms).to be_empty
    end

    # params.expect: none of these reaches the actor.
    {
      'an import that is no hash' => { import: 'Zorbel' },
      'a text that is a list' => { import: { text: ['Zorbel'] } },
      'a text that is a hash' => { import: { text: { term: 'Zorbel' } } },
      'an import without a text' => { import: { term: 'Zorbel' } }
    }.each do |shape, params|
      it "answers 400 to #{shape} and writes nothing" do
        post import_organisation_glossary_terms_path(organisation), params: params

        expect(response).to have_http_status(:bad_request)
        expect(terms).to be_empty
      end
    end

    # A key without a value comes as nil, which the actor reads as an empty text.
    it 'refuses a text sent without a value as empty' do
      post import_organisation_glossary_terms_path(organisation), params: 'import[text]',
                                                                  headers: { 'CONTENT_TYPE' => 'application/x-www-form-urlencoded' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(page.at_css('.glossary-content [role="alert"]').text.squish).to eq(I18n.t("#{ci}.empty"))
      expect(terms).to be_empty
    end
  end

  describe 'without view_glossary' do
    before { sign_in nobody }

    it 'answers 403 on the check and writes nothing' do
      before = glossary_state

      check_list('Zorbel')

      expect(response).to have_http_status(:forbidden)
      expect(glossary_state).to eq(before)
    end

    it 'answers 403 on the import and writes nothing' do
      create(:glossary_term, organisation: organisation, term: 'Wub')
      before = glossary_state

      import_list("Zorbel\nwub;product")

      expect(response).to have_http_status(:forbidden)
      expect(glossary_state).to eq(before)
    end

    it 'answers 403 on the import lane, in the frame and on a full visit' do
      get organisation_glossary_terms_path(organisation, new: 'import'), headers: frame_headers
      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include('import[text]')

      get organisation_glossary_terms_path(organisation, new: 'import')
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'another organisation' do
    it 'has a term that is neither counted nor touched' do
      foreign = ActsAsTenant.with_tenant(other_organisation) do
        create(:glossary_term, organisation: other_organisation, term: 'Zorbel')
      end
      foreign_state = GlossaryTerm.unscoped.find(foreign.id).slice(:term, :status, :category, :lock_version)
      sign_in manager

      check_list('zorbel;product')
      expect(checked_lines.map(&:last)).to eq([verdict(:new)])

      import_list('zorbel;product')
      expect(flash[:notice]).to eq(notice([:created, 1]))
      expect(terms.pluck(:term, :category)).to eq([%w[zorbel product]])
      expect(GlossaryTerm.unscoped.find(foreign.id).slice(:term, :status, :category, :lock_version)).to eq(foreign_state)
    end
  end

  # Prosopite watches every example; the check reads the glossary once,
  # however many lines.
  describe 'queries' do
    it 'checks 200 lines without an N+1' do
      Prosopite.pause do
        (1..5).each { |index| create(:glossary_term, organisation: organisation, term: "Zorbel #{index * 40}") }
      end
      sign_in manager

      check_list((1..200).map { |n| "Zorbel #{n};product" }.join("\n"))

      expect(response).to have_http_status(:ok)
      expect(page.css('[data-glossary-import-line]').size).to eq(200)
      expect(checked_counts['existing']).to eq(I18n.t("#{gi}.counts.existing", count: 5))
    end
  end

  # The profile language, which every request of a signed-in user follows
  # (a locale in the body of a POST is no choice of language).
  %w[de en].each do |locale|
    it "renders the button, the lane and the check in #{locale} without a missing text" do
      viewer.update!(language_preference: locale)
      sign_in viewer

      get organisation_glossary_terms_path(organisation)
      I18n.with_locale(locale) { expect(page.at_css('a[data-glossary-import-link]').text.squish).to eq(I18n.t("#{gi}.open")) }

      get organisation_glossary_terms_path(organisation, new: 'import'), headers: frame_headers
      expect(response.body).not_to include('translation missing', 'Translation missing')
      I18n.with_locale(locale) { expect(page.text).to include(I18n.t("#{gi}.hint")) }

      check_list("Zorbel\nzorbel\n;x")
      expect(response.body).not_to include('translation missing', 'Translation missing')
      I18n.with_locale(locale) do
        expect(page.text).to include(I18n.t("#{gi}.verdicts.duplicate"), I18n.t("#{gi}.counts.invalid", count: 1))
      end
    end
  end
end
