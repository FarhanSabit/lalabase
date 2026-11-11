# frozen_string_literal: true

require 'rails_helper'

# The people directory page and its writes. Every action against the right
# (PersonPolicy, D7): 403 without it, view_people reads but never writes,
# manage_people writes (a guest role too), an account admin needs no row, and
# another organisation answers 404.
RSpec.describe 'Organisations::People', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def role_with(*actions, billable: true, title: nil)
    role = create(:role, organisation: organisation, billable: billable, **{ title: title }.compact)
    actions.each { |action| create(:permission, role: role, category: 'people', action: action, allowed: true) }
    role
  end

  def member_with(role, first_name: 'Max')
    user = create(:user, first_name: first_name, last_name: "Muster#{SecureRandom.hex(2)}")
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    user
  end

  let(:admin) { member_with(role_with(title: Role::ACCOUNT_ADMIN_TITLE)) }
  let(:viewer) { member_with(role_with('view_people')) }
  let(:manager) { member_with(role_with('manage_people')) }
  let(:guest_manager) { member_with(role_with('manage_people', billable: false)) }
  let(:nobody) { member_with(role_with) }
  let!(:person) { create(:person, organisation: organisation, name: 'Doris Dienstleister', phone: '+49 30 1234567') }

  let(:frame_headers) { { 'Turbo-Frame' => Organisations::PeopleController::DETAIL_FRAME_ID } }
  let(:valid_params) { { person: { name: 'Erika Beispiel', function: 'Administratorin' } } }

  describe 'without the right' do
    before { sign_in nobody }

    it 'answers 403 on every action and changes nothing' do
      get organisation_people_path(organisation)
      expect(response).to have_http_status(:forbidden)

      get organisation_person_path(organisation, person), headers: frame_headers
      expect(response).to have_http_status(:forbidden)

      get new_organisation_person_path(organisation), headers: frame_headers
      expect(response).to have_http_status(:forbidden)

      get edit_organisation_person_path(organisation, person), headers: frame_headers
      expect(response).to have_http_status(:forbidden)

      expect { post organisation_people_path(organisation), params: valid_params }.not_to change(Person, :count)
      expect(response).to have_http_status(:forbidden)

      patch organisation_person_path(organisation, person), params: { person: { phone: '0' } }
      expect(response).to have_http_status(:forbidden)

      expect { delete organisation_person_path(organisation, person) }.not_to change(Person, :count)
      expect(response).to have_http_status(:forbidden)
      expect(person.reload.phone).to eq('+49 30 1234567')
    end

    it 'shows no menu entry in the sidebar' do
      get organisation_root_path(organisation)
      follow_redirect! while response.redirect?

      expect(response.body).to include(I18n.t('navigation.all_organisations'))
      expect(response.body).not_to include(organisation_people_path(organisation))
    end

    it 'shows no entry on the mobile "more" page' do
      get organisation_mobile_more_path(organisation)

      expect(response.body).to include(I18n.t('mobile.more'))
      expect(response.body).not_to include(organisation_people_path(organisation))
    end
  end

  describe 'with view_people only' do
    before { sign_in viewer }

    it 'shows the list and the person, without write controls' do
      get organisation_people_path(organisation, person_id: person.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Doris Dienstleister', '+49 30 1234567')
      expect(response.body).not_to include(new_organisation_person_path(organisation))
      expect(response.body).not_to include(edit_organisation_person_path(organisation, person))
      expect(Nokogiri::HTML(response.body).css('.people-lane__head .more-menu')).to be_empty
    end

    it 'shows the person in the lane frame' do
      get organisation_person_path(organisation, person), headers: frame_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(<turbo-frame id="#{Organisations::PeopleController::DETAIL_FRAME_ID}">), 'Doris Dienstleister')
    end

    it 'is refused every write with 403' do
      expect { post organisation_people_path(organisation), params: valid_params }.not_to change(Person, :count)
      expect(response).to have_http_status(:forbidden)

      patch organisation_person_path(organisation, person), params: { person: { phone: '0' } }
      expect(response).to have_http_status(:forbidden)

      expect { delete organisation_person_path(organisation, person) }.not_to change(Person, :count)
      expect(response).to have_http_status(:forbidden)

      get new_organisation_person_path(organisation), headers: frame_headers
      expect(response).to have_http_status(:forbidden)
    end

    it 'shows the menu entry in the sidebar' do
      get organisation_root_path(organisation)
      follow_redirect! while response.redirect?

      expect(response.body).to include(%(href="#{organisation_people_path(organisation)}"), I18n.t('navigation.people'))
    end

    it 'shows the entry on the mobile "more" page' do
      get organisation_mobile_more_path(organisation)

      expect(response.body).to include(%(href="#{organisation_people_path(organisation)}"))
    end
  end

  shared_examples 'may write' do
    it 'creates a person and lands on the list with it open' do
      expect { post organisation_people_path(organisation), params: valid_params.merge(q: 'erika') }.to change(Person, :count).by(1)

      created = Person.find_by!(name: 'Erika Beispiel')
      expect(response).to redirect_to(organisation_people_path(organisation, person_id: created.id, q: 'erika'))
      expect(created.creator_id).to eq(writer.id)
    end

    it 'updates a person' do
      patch organisation_person_path(organisation, person),
            params: { person: { phone: '0', lock_version: person.lock_version } }

      expect(response).to redirect_to(organisation_people_path(organisation, person_id: person.id))
      expect(person.reload.phone).to eq('0')
    end

    it 'deletes a person' do
      expect { delete organisation_person_path(organisation, person) }.to change(Person, :count).by(-1)
      expect(response).to redirect_to(organisation_people_path(organisation))
    end

    it 'opens the form in the lane' do
      get new_organisation_person_path(organisation), headers: frame_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="person_name"', I18n.t('views.organisations.people.form.shared_hint'))
    end
  end

  describe 'with manage_people' do
    let(:writer) { manager }

    before { sign_in manager }

    include_examples 'may write'
  end

  describe 'a guest role (billable: false) with manage_people' do
    let(:writer) { guest_manager }

    before { sign_in guest_manager }

    include_examples 'may write'
  end

  describe 'an account admin without any permission row' do
    let(:writer) { admin }

    before do
      expect(Permission.where(category: 'people', role: admin.memberships.first.role)).to be_empty
      sign_in admin
    end

    include_examples 'may write'
  end

  describe 'another organisation' do
    let(:foreign_person) do
      ActsAsTenant.with_tenant(other_organisation) { create(:person, organisation: other_organisation) }
    end

    before { sign_in admin }

    # One request per example: after a 404 the test session is signed out.
    it 'answers 404 for show of a person of another organisation' do
      get organisation_person_path(organisation, foreign_person), headers: frame_headers

      expect(response).to have_http_status(:not_found)
    end

    it 'answers 404 for update and leaves the row alone' do
      patch organisation_person_path(organisation, foreign_person), params: { person: { phone: '0' } }

      expect(response).to have_http_status(:not_found)
      expect(Person.unscoped.find(foreign_person.id).phone).to be_nil
    end

    it 'answers 404 for destroy and keeps the row' do
      delete organisation_person_path(organisation, foreign_person)

      expect(response).to have_http_status(:not_found)
      expect(Person.unscoped.exists?(foreign_person.id)).to be(true)
    end

    # The app's rule for an organisation the user is not a member of (every
    # page, ApplicationController#load_tenant_from_session): to the picker,
    # nothing of the other organisation rendered.
    it 'sends the page of an organisation the user is not in to the organisation picker' do
      foreign_person
      get organisation_people_path(other_organisation)

      expect(response).to redirect_to(select_organisation_path)
    end
  end

  describe 'the lane' do
    before { sign_in manager }

    it 'opens a person on a full visit with ?person_id=' do
      get organisation_people_path(organisation, person_id: person.id)

      expect(response.body).to include('show-content', 'Doris Dienstleister', 'selected-row')
    end

    it 'opens the form on a full visit with ?new=person' do
      get organisation_people_path(organisation, new: 'person')

      expect(response.body).to include('id="person_name"')
    end

    it 'answers a lane request of the index with the lane alone' do
      get organisation_people_path(organisation, person_id: person.id), headers: frame_headers

      expect(response.body).to start_with(%(<turbo-frame id="#{Organisations::PeopleController::DETAIL_FRAME_ID}">))
      expect(response.body).to include('Doris Dienstleister')
    end

    it 'sends a full visit of show to the index with the person open' do
      get organisation_person_path(organisation, person)

      expect(response).to redirect_to(organisation_people_path(organisation, person_id: person.id))
    end

    it 'renders the mobile list and detail one after the other' do
      get organisation_people_path(organisation, person_id: person.id, viewport: 'mobile')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('people-mobile-grid', 'Doris Dienstleister')
    end

    it 'shows the form again with the reason when the save is refused' do
      post organisation_people_path(organisation), params: { person: { name: '' } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('id="person_name"')
    end

    it 'shows the current values and the stale message when someone else saved first' do
      stale_version = person.lock_version
      person.update!(phone: 'from the other side')

      patch organisation_person_path(organisation, person), params: { person: { phone: 'mine', lock_version: stale_version } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(CGI.escapeHTML(I18n.t('controllers.people.update.stale')), 'from the other side')
      expect(person.reload.phone).to eq('from the other side')
    end

    it 'shows a duplicate hint for a row with the same name' do
      twin = create(:person, organisation: organisation, name: 'doris  DIENSTLEISTER')

      get organisation_person_path(organisation, person), headers: frame_headers

      expect(response.body).to include(I18n.t('views.organisations.people.show.duplicate_prefix'),
                                       "person_id=#{twin.id}")
    end

    it 'lists the history without values' do
      patch organisation_person_path(organisation, person), params: { person: { phone: '0', lock_version: person.lock_version } }

      get organisation_person_path(organisation, person), headers: frame_headers

      expect(response.body).to include(I18n.t('views.organisations.people.history.title'))
    end

    # The redesign of 29.10.2026: the history folds into the line of who
    # created the row, with the number of changes in its own plural.
    it 'folds the history into one line that counts the changes' do
      created = I18n.t('views.organisations.people.show.created_at', date: I18n.l(person.created_at.to_date, format: :default))

      get organisation_person_path(organisation, person), headers: frame_headers
      lane = Nokogiri::HTML(response.body)
      expect(lane.at_css('.people-footer').text).to include(created)
      expect(lane.at_css('details.people-history')).to be_nil

      patch organisation_person_path(organisation, person), params: { person: { phone: '0', lock_version: person.reload.lock_version } }
      get organisation_person_path(organisation, person), headers: frame_headers
      summary = Nokogiri::HTML(response.body).at_css('details.people-history > summary').text.squish
      expect(summary).to include(created, I18n.t('views.organisations.people.history.changes', count: 1))
      expect(I18n.t('views.organisations.people.history.changes', count: 1)).not_to eq(I18n.t('views.organisations.people.history.changes', count: 2))
    end

    it 'puts delete behind the "···" menu, with its confirmation' do
      get organisation_person_path(organisation, person), headers: frame_headers

      menu = Nokogiri::HTML(response.body).at_css('.people-lane__head details.more-menu')
      button = menu.at_css('button.more-menu__danger')
      expect(button.text.strip).to eq(I18n.t('views.organisations.people.show.delete'))
      expect(button.ancestors('form').first['data-turbo-confirm'])
        .to eq(I18n.t('views.organisations.people.show.delete_confirm', name: 'Doris Dienstleister'))
    end

    it 'names what the person is and the company under the name, not as a line' do
      person.update!(company: 'Hoster GmbH')

      get organisation_person_path(organisation, person), headers: frame_headers
      lane = Nokogiri::HTML(response.body)

      expect(lane.at_css('.people-identity__line').text.strip)
        .to eq("#{I18n.t('views.organisations.people.show.kind.contact')} · Hoster GmbH")
      expect(lane.css('.people-fields__row dt').map { |dt| dt.text.strip }).not_to include(Person.human_attribute_name(:company))
    end

    it 'filters and searches the list' do
      get organisation_people_path(organisation, kind: 'contacts', q: 'dienst')

      expect(response.body).to include('Doris Dienstleister')
      expect(response.body).not_to include(CGI.escapeHTML(manager.display_name))
    end
  end

  # Often only "Herr Müller" or "Frau Müller" is known. The salutation is free
  # text; the form suggests the usual ones as a grey example only.
  describe 'the salutation' do
    before { sign_in manager }

    it 'saves it from the form and shows it in the lane' do
      patch organisation_person_path(organisation, person),
            params: { person: { salutation: 'Frau Dr.', lock_version: person.lock_version } }
      expect(person.reload.salutation).to eq('Frau Dr.')

      get organisation_person_path(organisation, person), headers: frame_headers

      expect(response.body).to include(Person.human_attribute_name(:salutation), 'Frau Dr.')
    end

    it 'offers a free text field with the suggestions as placeholder' do
      get edit_organisation_person_path(organisation, person), headers: frame_headers

      field = Nokogiri::HTML(response.body).at_css('input#person_salutation')
      expect(field).to be_present
      expect(field['type']).to eq('text')
      expect(field['placeholder']).to eq(I18n.t('views.organisations.people.form.placeholders.salutation'))
    end

    it 'shows no salutation line for a person without one' do
      get organisation_person_path(organisation, person), headers: frame_headers

      expect(response.body).to include('Doris Dienstleister')
      expect(response.body).not_to include(">#{Person.human_attribute_name(:salutation)}<")
    end
  end

  # Up to ten labelled details (PersonDetail). The form sends them as an
  # indexed hash next to a marker; the lane shows them after the phone.
  describe 'the additional details' do
    before { sign_in manager }

    def row(kind, value, label: '')
      { kind: kind, label: label, value: value }
    end

    def details_params(*rows)
      rows.each_with_index.to_h { |entry, index| [index.to_s, entry] }.merge(PersonDetail::FORM_MARKER => '1')
    end

    def patch_details(target, details, **extra)
      patch organisation_person_path(organisation, target),
            params: { person: { additional_details: details, lock_version: target.reload.lock_version, **extra } }
    end

    def lane_html(target = person)
      get organisation_person_path(organisation, target), headers: frame_headers
      expect(response).to have_http_status(:ok)
      Nokogiri::HTML(response.body)
    end

    it 'saves them from the form and shows each kind in the lane' do
      patch_details(person, details_params(row('phone', '+49 30 1234568', label: 'Fax'),
                                           row('email', 'erika@example.com', label: 'Privat'),
                                           row('url', 'https://example.com', label: 'Website'),
                                           row('date', '1980-02-29', label: 'Geburtstag'),
                                           row('address', "Musterstraße 1\r\n12345 Berlin", label: 'Büro'),
                                           row('text', 'nur vormittags', label: 'Erreichbar')))
      expect(response).to redirect_to(organisation_people_path(organisation, person_id: person.id))
      expect(person.reload.additional_details.pluck('kind')).to eq(%w[phone email url date address text])

      lane = lane_html
      expect(lane.at_css('a[href="tel:+49301234568"]').text).to include('+49 30 1234568')
      expect(lane.at_css('a[href="mailto:erika@example.com"]')).to be_present
      web = lane.at_css('a[href="https://example.com"]')
      expect([web['target'], web['rel']]).to eq(['_blank', 'noopener noreferrer'])
      expect(lane.text).to include('Fax', 'Geburtstag', I18n.l(Date.new(1980, 2, 29), format: :long), 'nur vormittags')
      expect(lane.to_html).to include('Musterstraße 1<br>12345 Berlin')
    end

    it 'formats the date in the reader\'s language' do
      person.update!(additional_details: [row('date', '1980-02-29', label: 'Geburtstag')])
      manager.update!(language_preference: 'en')

      text = lane_html.text

      expect(text).to include(I18n.l(Date.new(1980, 2, 29), format: :long, locale: :en))
    end

    it 'shows the details as tap targets on a phone, named by their label' do
      person.update!(additional_details: [row('phone', '+49 170 1234567', label: 'Mobil')])

      get organisation_people_path(organisation, person_id: person.id, viewport: 'mobile')

      tap = Nokogiri::HTML(response.body).at_css('a.people-tap[href="tel:+491701234567"]')
      expect(tap).to be_present
      expect(tap.text).to include('+49 170 1234567', 'Mobil')
    end

    it 'opens a web address on a phone in a new tab without the opener' do
      person.update!(additional_details: [row('url', 'https://example.com', label: 'Website')])

      get organisation_people_path(organisation, person_id: person.id, viewport: 'mobile')

      tap = Nokogiri::HTML(response.body).at_css('a.people-tap[href="https://example.com"]')
      expect([tap['target'], tap['rel']]).to eq(['_blank', 'noopener noreferrer'])
    end

    it 'shows no detail line for a person without details' do
      fields = lane_html.css('.people-fields__row dt').map { |dt| dt.text.strip }

      expect(fields).to eq(%i[email phone function].map { |field| Person.human_attribute_name(field) })
    end

    # The redesign of 29.10.2026: the ways to reach a person come first, an
    # added phone or email among them; the label names the value, no icon.
    it 'puts the ways to reach the person first, without icons' do
      person.update!(additional_details: [row('text', 'nur vormittags', label: 'Erreichbar'), row('phone', '+49 30 1234568', label: 'Fax')])

      lane = lane_html
      fields = lane.css('.people-fields__row dt').map { |dt| dt.text.strip }

      expect(fields).to eq([Person.human_attribute_name(:email), Person.human_attribute_name(:phone), 'Fax',
                            Person.human_attribute_name(:function), 'Erreichbar'])
      expect(lane.css('.people-fields i')).to be_empty
    end

    it 'clears them when only the marker is sent (the last one removed)' do
      person.update!(additional_details: [row('text', 'weg')])

      patch_details(person, { PersonDetail::FORM_MARKER => '1' })

      expect(response).to have_http_status(:see_other)
      expect(person.reload.additional_details).to eq([])
    end

    it 'leaves them alone when a save does not name them' do
      person.update!(additional_details: [row('text', 'bleibt')])

      patch organisation_person_path(organisation, person),
            params: { person: { function: 'IT', lock_version: person.lock_version } }

      expect(person.reload.function).to eq('IT')
      expect(person.additional_details).to eq([{ 'kind' => 'text', 'label' => '', 'value' => 'bleibt' }])
    end

    it 'refuses a javascript: url with the form and its reason, and saves nothing' do
      patch_details(person, details_params(row('url', 'javascript:alert(1)', label: 'Web')), phone: '+49 30 0')

      expect(response).to have_http_status(:unprocessable_content)
      reason = I18n.t('activerecord.errors.models.person.attributes.additional_details.invalid_url', position: 1)
      expect(response.body).to include('id="person_name"', CGI.escapeHTML(reason))
      expect(person.reload.additional_details).to eq([])
      expect(person.phone).to eq('+49 30 1234567')
    end

    # Review round 2, finding 1: a kind switch in the browser can empty a value
    # (a date field and "im Mai"). A row that keeps its label is named, not lost.
    it 'refuses a row with a label but no value, with its position' do
      person.update!(additional_details: [row('text', 'bleibt')])

      patch_details(person, details_params(row('text', 'bleibt'), row('date', '', label: 'Geburtstag')))

      expect(response).to have_http_status(:unprocessable_content)
      reason = I18n.t('activerecord.errors.models.person.attributes.additional_details.value_missing', position: 2)
      expect(response.body).to include(CGI.escapeHTML(reason))
      expect(person.reload.additional_details).to eq([{ 'kind' => 'text', 'label' => '', 'value' => 'bleibt' }])
    end

    it 'shows a refused date that is no date in a text field, marked invalid in its numbered row' do
      patch_details(person, details_params(row('text', 'ok'), row('date', 'im Mai', label: 'Geburtstag')))

      expect(response).to have_http_status(:unprocessable_content)
      rows = Nokogiri::HTML(response.body).css('[data-person-details-target="list"] [data-person-details-target="row"]')
      value = rows[1].at_css('[data-person-details-value]')
      expect([value['type'], value['value'], value['aria-invalid']]).to eq(['text', 'im Mai', 'true'])
      expect(rows[0].at_css('[data-person-details-value]')['aria-invalid']).to be_nil
      expect(rows.pluck('aria-label')).to eq([1, 2].map { |n| I18n.t('views.organisations.people.form.detail_position', position: n) })
    end

    it 'refuses an eleventh detail' do
      patch_details(person, details_params(*Array.new(PersonDetail::MAX + 1) { row('text', 'x') }))

      expect(response).to have_http_status(:unprocessable_content)
      expect(person.reload.additional_details).to eq([])
    end

    it 'escapes a script in a label or a value' do
      person.update!(additional_details: [row('text', '<script>alert(1)</script>', label: '<script>alert(2)</script>'),
                                          row('address', "<script>alert(3)</script>\nZeile")])

      body = lane_html.to_html

      expect(body).not_to include('<script>alert(')
      expect(body).to include('&lt;script&gt;alert(1)&lt;/script&gt;', '&lt;script&gt;alert(2)&lt;/script&gt;',
                              '&lt;script&gt;alert(3)&lt;/script&gt;<br>Zeile')
    end

    it 'never answers a hand-made shape with a 500, and keeps the stored details' do
      person.update!(additional_details: [row('text', 'bleibt')])
      shapes = [
        'a string', %w[an array], { '0' => 'not a hash' }, { '0' => { 'kind' => { 'x' => 'y' }, 'value' => ['v'] } },
        { 'abc' => row('text', 'not numeric') }, { '0' => { 'kind' => 'text', 'value' => 'ok', 'evil' => 'x' } }
      ]

      # One request per shape; the loop is not an N+1 of the page.
      Prosopite.pause do
        shapes.each do |shape|
          patch organisation_person_path(organisation, person),
                params: { person: { additional_details: shape, lock_version: person.reload.lock_version } }
          expect(response.status).to be < 500, shape.inspect
        end
      end
      expect(person.reload.additional_details).to eq([{ 'kind' => 'text', 'label' => '', 'value' => 'ok' }])
    end

    it 'writes "Weitere Angaben" into the history, without values' do
      patch_details(person, details_params(row('phone', '+49 30 5550000', label: 'Fax geheim')))

      I18n.with_locale(:de) do
        history = lane_html.text

        expect(history).to include('Weitere Angaben')
        expect(history).not_to include('Fax geheim geändert')
      end
      expect(Activity.where(trackable: person).to_a.to_json).not_to include('5550000')
    end

    describe 'in the form' do
      let(:stored) do
        [{ 'kind' => 'phone', 'label' => 'Fax', 'value' => '+49 30 1234568' },
         { 'kind' => 'date', 'label' => 'Geburtstag', 'value' => '1980-02-29' },
         { 'kind' => 'address', 'label' => 'Büro', 'value' => "Musterstraße 1\n12345 Berlin" }]
      end

      def form_html
        get edit_organisation_person_path(organisation, person), headers: frame_headers
        expect(response).to have_http_status(:ok)
        Nokogiri::HTML(response.body)
      end

      # The fields a browser without JavaScript sends: everything named in the
      # form, outside the template, enabled.
      def submitted_fields(html)
        html.css('form.people-form input[name], form.people-form select[name], form.people-form textarea[name]')
            .reject { |node| node.ancestors('template').any? || node['disabled'] || node['type'] == 'submit' }
            .map { |node| [node['name'], node.name == 'select' ? node.at_css('option[selected]')&.[]('value') : (node['value'] || node.text)] }
      end

      before { person.update!(additional_details: stored) }

      it 'renders the stored rows with the field of their kind, the marker and an empty template' do
        html = form_html
        rows = html.css('[data-person-details-target="list"] [data-person-details-target="row"]')

        expect(rows.size).to eq(3)
        expect(rows[0].at_css('select option[selected]')['value']).to eq('phone')
        expect(rows[0].at_css('input[data-person-details-value]').attributes.slice('type', 'value').transform_values(&:value))
          .to eq('type' => 'tel', 'value' => '+49 30 1234568')
        expect(rows[0].at_css('input[data-person-details-label]')['list']).to eq('person-detail-suggestions-phone')
        expect(rows[1].at_css('input[data-person-details-value]')['type']).to eq('date')
        expect(rows[2].at_css('textarea[data-person-details-value]').text).to include("Musterstraße 1\n12345 Berlin")
        expect(html.at_css("input[type=hidden][name='person[additional_details][#{PersonDetail::FORM_MARKER}]']")).to be_present
        expect(html.at_css('template[data-person-details-target="template"]').inner_html).to include('person[additional_details][__INDEX__][kind]')
      end

      it 'hands the limit and the kinds to the controller from PersonDetail' do
        section = form_html.at_css('[data-controller="person-details"]')
        kinds = JSON.parse(section['data-person-details-kinds-value'])

        expect(section['data-person-details-max-value']).to eq(PersonDetail::MAX.to_s)
        expect(kinds.keys).to eq(PersonDetail::KINDS)
        expect(kinds['address']).to include('input' => 'textarea', 'maxlength' => PersonDetail::MAX_ADDRESS_LENGTH)
      end

      it 'offers the label suggestions of every kind and a translated remove button' do
        html = form_html

        expect(html.css('datalist#person-detail-suggestions-phone option').pluck('value')).to include('Mobil', 'Fax')
        expect(html.css('[data-person-details-target="list"] button[data-action="person-details#remove"]').pluck('aria-label').uniq)
          .to eq([I18n.t('views.organisations.people.form.remove_detail')])
      end

      it 'saves the stored rows unchanged when sent as rendered (without JavaScript)' do
        query = Rack::Utils.parse_nested_query(URI.encode_www_form(submitted_fields(form_html)))

        patch organisation_person_path(organisation, person), params: query

        expect(response).to have_http_status(:see_other)
        expect(person.reload.additional_details).to eq(stored)
      end

      it 'shows the refused rows again, with the reason' do
        patch_details(person, details_params(row('url', 'ftp://example.com', label: 'Server')))

        expect(response).to have_http_status(:unprocessable_content)
        value = Nokogiri::HTML(response.body).at_css('[data-person-details-target="list"] input[data-person-details-value]')
        expect(value['value']).to eq('ftp://example.com')
        expect(person.reload.additional_details).to eq(stored)
      end
    end

    it 'answers 404 for the details of a person of another organisation and changes nothing' do
      foreign = ActsAsTenant.with_tenant(other_organisation) { create(:person, organisation: other_organisation) }
      sign_in admin

      patch organisation_person_path(organisation, foreign),
            params: { person: { additional_details: details_params(row('text', 'fremd')) } }

      expect(response).to have_http_status(:not_found)
      expect(Person.unscoped.find(foreign.id).additional_details).to eq([])
    end
  end

  # Review round 1, finding 1: the form only offered ACTIVE members, so the row
  # of a deactivated member showed "Kein Mitglied" selected, and any save (only
  # the phone changed) dropped the link without anybody noticing.
  describe 'a row linked to a deactivated member' do
    let(:former) { member_with(role_with, first_name: 'Frieda') }
    let!(:linked) { create(:person, organisation: organisation, user: former, name: 'Frieda Former') }

    before do
      Membership.find_by(user: former, organisation: organisation).update!(active: false)
      sign_in admin
    end

    # Review of PR #64: the link of a deactivated member is fixed (SavePerson),
    # so the form offers no select to change it.
    it 'leaves the member select out of the edit form' do
      get edit_organisation_person_path(organisation, linked), headers: frame_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Frieda Former')
      expect(response.body).not_to include('name="person[user_id]"')
    end

    it 'keeps the link when the form is saved with its own values' do
      patch organisation_person_path(organisation, linked),
            params: { person: { user_id: former.id, phone: '1', lock_version: linked.lock_version } }

      expect(linked.reload.user_id).to eq(former.id)
      expect(linked.phone).to eq('1')
    end
  end

  # Review round 1, finding 2: one users query per contact row that still
  # points at a former member.
  it 'loads the list without one query per contact linked to a former member' do
    formers = Array.new(3) { |index| member_with(role_with, first_name: "Ehemalig#{index}") }
    formers.each { |former| create(:person, organisation: organisation, user: former) }
    Membership.where(user: formers, organisation: organisation).update_all(active: false)
    sign_in admin

    get organisation_people_path(organisation)

    expect(response).to have_http_status(:ok)
  end

  # Review round 1, finding 3: the policy scope and visible_record? each hid
  # the row of a member the reader cannot see, and no request pinned either.
  describe 'a row linked to a member the writer cannot see' do
    let(:project) { create(:project, organisation: organisation) }
    let(:stranger) { member_with(role_with, first_name: 'Sven') }
    let!(:hidden_row) { create(:person, organisation: organisation, user: stranger, phone: 'secret') }

    before do
      create(:project_permission, user: manager, project: project, tickets_access: :read_only)
      create(:project_permission, user: stranger, project: create(:project, organisation: organisation),
                                  tickets_access: :read_only)
      sign_in manager
    end

    it 'answers 404 for show' do
      get organisation_person_path(organisation, hidden_row), headers: frame_headers

      expect(response).to have_http_status(:not_found)
    end

    it 'answers 404 for update and leaves the row alone' do
      patch organisation_person_path(organisation, hidden_row), params: { person: { phone: '0' } }

      expect(response).to have_http_status(:not_found)
      expect(hidden_row.reload.phone).to eq('secret')
    end

    it 'answers 404 for destroy and keeps the row' do
      delete organisation_person_path(organisation, hidden_row)

      expect(response).to have_http_status(:not_found)
      expect(Person.exists?(hidden_row.id)).to be(true)
    end

    # Review round 1, finding 4: the member select must offer only what the
    # members page shows this reader, and only active members.
    it 'offers only visible, active members in the form' do
      colleague = member_with(role_with, first_name: 'Carla')
      create(:project_permission, user: colleague, project: project, tickets_access: :read_only)
      former = member_with(role_with, first_name: 'Fritz')
      create(:project_permission, user: former, project: project, tickets_access: :read_only)
      Membership.find_by(user: former, organisation: organisation).update!(active: false)

      get new_organisation_person_path(organisation), headers: frame_headers

      expect(response.body).to include(%(value="#{colleague.id}"), %(value="#{manager.id}"))
      expect(response.body).not_to include(%(value="#{stranger.id}"))
      expect(response.body).not_to include(%(value="#{former.id}"))
    end
  end

  # Review round 2, finding 1: "Angaben ergänzen" must name the member in the
  # PAGE address too: below the lane width and on a reload only that is used.
  it 'puts the member into the page address of "Angaben ergänzen"' do
    sign_in admin
    member = member_with(role_with, first_name: 'Ohne')

    get member_organisation_people_path(organisation, member.id), headers: frame_headers

    expect(response.body).to include(CGI.escapeHTML({ new: 'person', user_id: member.id }.to_json),
                                     "user_id=#{member.id}", I18n.t('views.organisations.people.show.add_details'))
  end

  it 'opens the form with the member chosen on a full visit with ?new=person&user_id=' do
    sign_in admin
    member = member_with(role_with, first_name: 'Ohne')

    get organisation_people_path(organisation, new: 'person', user_id: member.id)

    expect(response.body).to include(%(type="hidden" value="#{member.id}" name="person[user_id]"))
    expect(response.body[/<input[^>]*id="person_name"[^>]*>/]).to include('readonly', CGI.escapeHTML(member.display_name))
  end

  # Review round 2, finding 2: a raw user_id in the address named any account
  # in the member select, also one the reader may not see or of another org.
  describe 'a raw user_id in the address of the new form' do
    let(:project) { create(:project, organisation: organisation) }
    let(:stranger) { member_with(role_with, first_name: 'Verborgen') }
    let(:outsider) { create(:user, first_name: 'Fremdorga', last_name: 'Nisation') }

    before do
      create(:project_permission, user: manager, project: project, tickets_access: :read_only)
      create(:project_permission, user: stranger, project: create(:project, organisation: organisation),
                                  tickets_access: :read_only)
      create(:membership, user: outsider, organisation: other_organisation)
      sign_in manager
    end

    it 'does not name a member the reader cannot see' do
      get new_organisation_person_path(organisation, user_id: stranger.id), headers: frame_headers

      expect(response.body).not_to include('Verborgen', stranger.id)
    end

    it 'does not name an account of another organisation' do
      get organisation_people_path(organisation, new: 'person', user_id: outsider.id)

      expect(response.body).not_to include('Fremdorga', outsider.id)
    end
  end

  # Review round 2, finding 3: a row whose member was deactivated is a contact;
  # list and lane show the row's own name, not the account's current one.
  it 'shows the row name, not the account, for a row of a deactivated member' do
    former = member_with(role_with, first_name: 'Alt')
    create(:person, organisation: organisation, user: former, name: 'Alt Name')
    Membership.find_by(user: former, organisation: organisation).update!(active: false)
    former.update!(first_name: 'Neu', last_name: 'Anders')
    row = Person.find_by!(user: former)
    sign_in admin

    get organisation_people_path(organisation, person_id: row.id)

    expect(response.body).to include('Alt Name')
    expect(response.body).not_to include('Neu Anders')
  end

  # Review round 2, finding 5: a hand-made request without a usable
  # lock_version must not crash.
  it 'answers a missing lock_version as a stale save, not with an error' do
    sign_in admin

    patch organisation_person_path(organisation, person), params: { person: { phone: '0', lock_version: '' } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(person.reload.phone).to eq('+49 30 1234567')
  end

  # Review round 2, finding 6: a linked row shows the member's name; its own
  # name field is read only there.
  it 'shows the name field read only for a linked row' do
    linked = create(:person, organisation: organisation, user: viewer, name: 'Kopie')
    sign_in admin

    get edit_organisation_person_path(organisation, linked), headers: frame_headers

    expect(response.body).to match(/<input[^>]*readonly="readonly"[^>]*id="person_name"|<input[^>]*id="person_name"[^>]*readonly="readonly"/)
  end

  # Review round 3, finding 1: the member select named the CURRENT account of
  # a deactivated member, also to a reader who may not see that member. Since
  # the review of S1 (decision A) such a reader does not get the row at all,
  # and since the review of PR #64 the form has no select for this row. What
  # stays: the form names the row, never the account.
  it 'names the row of a deactivated member by its own name, not the account' do
    project = create(:project, organisation: organisation)
    create(:project_permission, user: manager, project: project, tickets_access: :read_only)
    hidden = member_with(role_with, first_name: 'Kopie')
    create(:project_permission, user: hidden, project: project, tickets_access: :read_only)
    row = create(:person, organisation: organisation, user: hidden, name: 'Kopie Name')
    Membership.find_by(user: hidden, organisation: organisation).update!(active: false)
    hidden.update!(first_name: 'Geheim', last_name: 'Neuname')
    sign_in manager

    get edit_organisation_person_path(organisation, row), headers: frame_headers

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Kopie Name')
    expect(response.body).not_to include('Neuname')
  end

  # Review round 3, finding 2: the name of a former member's row is the only
  # name shown, so it stays editable.
  it 'keeps the name field editable for the row of a former member' do
    former = member_with(role_with, first_name: 'Alt')
    row = create(:person, organisation: organisation, user: former, name: 'Alt Name')
    Membership.find_by(user: former, organisation: organisation).update!(active: false)
    sign_in admin

    get edit_organisation_person_path(organisation, row), headers: frame_headers

    expect(response.body[/<input[^>]*id="person_name"[^>]*>/]).not_to include('readonly')
  end

  # Review round 3, finding 3: ?user_id= only preselects a member without a row
  # who is active.
  describe 'preselecting a member through the address' do
    before { sign_in admin }

    # The member select is there, with nothing chosen (the kind selects of the
    # additional details have a choice of their own).
    def expect_no_member_preselected
      select = Nokogiri::HTML(response.body).at_css('select[name="person[user_id]"]')
      expect(select).to be_present
      expect(select.css('option[selected]')).to be_empty
    end

    it 'does not preselect a member who already has a row' do
      taken = member_with(role_with, first_name: 'Vergeben')
      create(:person, organisation: organisation, user: taken)

      get new_organisation_person_path(organisation, user_id: taken.id), headers: frame_headers

      expect_no_member_preselected
      expect(response.body[/<input[^>]*id="person_name"[^>]*>/]).not_to include('readonly')
    end

    it 'does not preselect a deactivated member' do
      former = member_with(role_with, first_name: 'Inaktiv')
      Membership.find_by(user: former, organisation: organisation).update!(active: false)

      get new_organisation_person_path(organisation, user_id: former.id), headers: frame_headers

      expect_no_member_preselected
    end
  end

  # Review round 3, finding 4: the address rules of user_id (form group, the
  # "+" takes it away, an unopened one is dropped).
  it 'wires user_id as part of the lane form state' do
    sign_in admin

    get organisation_people_path(organisation, user_id: 'x')

    expect(response.body).to include(CGI.escapeHTML('"form":["new","user_id"]'),
                                     CGI.escapeHTML('["person_id","member_id","user_id"]'),
                                     CGI.escapeHTML('{"user_id":"x"}'))
  end

  # Review round 3, findings 5 and 6: hand-made lock versions.
  it 'creates a person even when the request carries an unusable lock_version' do
    sign_in admin

    expect do
      post organisation_people_path(organisation), params: { person: { name: 'Neu Person', lock_version: '' } }
    end.to change(Person, :count).by(1)
  end

  it 'answers a lock_version beyond the column as a stale save' do
    sign_in admin

    patch organisation_person_path(organisation, person),
          params: { person: { phone: '0', lock_version: '99999999999999999999' } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(person.reload.phone).to eq('+49 30 1234567')
  end

  # Review round 3, finding 7: a duplicate opens like a row, with its own
  # address, not inside the frame alone.
  it 'links a duplicate to the page address of that person' do
    twin = create(:person, organisation: organisation, name: 'Doris Dienstleister')
    sign_in admin

    get organisation_person_path(organisation, person), headers: frame_headers

    link = response.body[/<a[^>]*href="[^"]*person_id=#{twin.id}[^"]*"[^>]*>/]
    expect(link).to include('data-turbo-frame="_top"')
  end

  # The design of 26.10.2026: a member without a row of their own opens in
  # the lane too (?member_id=), with name and email from the account.
  describe 'the lane of a member without a row' do
    let(:project) { create(:project, organisation: organisation) }
    let(:colleague) { member_with(role_with, first_name: 'Kolja') }
    let(:stranger) { member_with(role_with, first_name: 'Sven') }

    before do
      create(:project_permission, user: viewer, project: project, tickets_access: :read_only)
      create(:project_permission, user: colleague, project: project, tickets_access: :read_only)
      create(:project_permission, user: stranger, project: create(:project, organisation: organisation),
                                  tickets_access: :read_only)
    end

    it 'shows the account name, email and what is missing' do
      sign_in viewer

      get member_organisation_people_path(organisation, colleague.id), headers: frame_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(CGI.escapeHTML(colleague.display_name), colleague.email,
                                       I18n.t('views.organisations.people.show.read_only'))
      expect(response.body).not_to include(I18n.t('views.organisations.people.show.add_details'))
    end

    it 'answers 404 for a member the reader cannot see' do
      sign_in viewer

      get member_organisation_people_path(organisation, stranger.id), headers: frame_headers

      expect(response).to have_http_status(:not_found)
    end

    it 'answers 403 without the right' do
      sign_in nobody

      get member_organisation_people_path(organisation, colleague.id), headers: frame_headers

      expect(response).to have_http_status(:forbidden)
    end

    it 'opens the row of a member who has one' do
      row = create(:person, organisation: organisation, user: colleague, function: 'Netzwerk')
      sign_in viewer

      get member_organisation_people_path(organisation, colleague.id)

      expect(response).to redirect_to(organisation_people_path(organisation, person_id: row.id))
    end

    it 'opens on a full visit with ?member_id= and marks the row' do
      sign_in viewer

      get organisation_people_path(organisation, member_id: colleague.id)

      expect(response.body).to include('show-content', CGI.escapeHTML(I18n.t('views.organisations.people.show.bare_text', first_name: colleague.display_name)))
      expect(response.body).to match(/class="people-row selected-row"[^>]*>|data-list-row-id-value="#{colleague.id}"[^>]*class="people-row selected-row"/)
    end

    it 'drops an unreadable ?member_id= from the address' do
      sign_in viewer

      get organisation_people_path(organisation, member_id: stranger.id)

      expect(response.body).not_to include('show-content')
      expect(response.body).to include(CGI.escapeHTML({ member_id: stranger.id }.to_json))
    end
  end

  # 29.10.2026: the "+" of the people page is the square primary button of
  # "Alle Meetings" and "Zeiten", in the shared title box, not a text button.
  it 'offers "Person anlegen" as the square "+" of the title box' do
    sign_in admin

    get organisation_people_path(organisation)

    add = Nokogiri::HTML(response.body).at_css(".people-head a[title='#{I18n.t('views.organisations.people.index.new_person')}']")
    expect(add.at_css('svg')).to be_present
    expect(add.text.strip).to be_empty
    expect(add['data-lane-link-url-value']).to eq(new_organisation_person_path(organisation))
  end

  # The counts stand at the tabs only (since 2026-11-11 the tabs of the
  # ticket list's bar, before that pills); the line under the title names the
  # organisation, as on "Alle Meetings" and the inbox, and counts nothing.
  it 'counts all people, members and contacts at the tabs only' do
    sign_in admin
    admin

    get organisation_people_path(organisation, kind: 'contacts')

    members = Membership.where(organisation: organisation, active: true).count
    page = Nokogiri::HTML(response.body)
    counts = page.css('#people_list_tabs .people-pill__count').map { |count| count.text.strip }
    expect(counts).to eq([(members + 1).to_s, members.to_s, '1'])
    expect(page.css('.people-head p').map { |line| line.text.strip }).to eq([organisation.name])
  end

  describe 'the row of an active member' do
    let!(:row) { create(:person, organisation: organisation, user: viewer, function: 'IT', email: 'alt@example.com') }

    before { sign_in admin }

    it 'offers to remove the added details, not to delete the person' do
      get organisation_person_path(organisation, row), headers: frame_headers

      expect(response.body).to include(I18n.t('views.organisations.people.show.remove_details'))
      expect(response.body).not_to include(">#{I18n.t('views.organisations.people.show.delete')}<")
      # Review round 2, finding 3: the confirmation names what goes, the
      # additional details included.
      confirm = I18n.t('views.organisations.people.show.remove_details_confirm', name: viewer.display_name)
      expect(Nokogiri::HTML(response.body).css('[data-turbo-confirm]').pluck('data-turbo-confirm')).to include(confirm)
      expect(confirm.downcase).to include(Person.human_attribute_name(:company).downcase,
                                          Person.human_attribute_name(:additional_details).downcase)
    end

    it 'shows the email of the account, and locks name and email in the form' do
      get edit_organisation_person_path(organisation, row), headers: frame_headers

      expect(response.body[/<input[^>]*id="person_email"[^>]*>/]).to include('readonly', viewer.email)
      expect(response.body).not_to include('name="person[user_id]"')
    end

    it 'keeps the link when the form is saved' do
      patch organisation_person_path(organisation, row), params: { person: { function: 'Netz', lock_version: row.lock_version } }

      expect(row.reload.user_id).to eq(viewer.id)
      expect(row.function).to eq('Netz')
    end
  end

  # External review of 26.10.2026.
  describe 'on a phone' do
    before { sign_in admin }

    it 'keeps the phone view when a save is refused' do
      post organisation_people_path(organisation), params: { person: { name: '' }, viewport: 'mobile' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('people-mobile-grid', 'name="viewport"')
    end

    it 'carries the phone view into the edit form of the lane' do
      get organisation_people_path(organisation, person_id: person.id, viewport: 'mobile')

      expect(response.body).to include(edit_organisation_person_path(organisation, person, viewport: 'mobile'))
    end

    it 'lands on the phone view after a save' do
      patch organisation_person_path(organisation, person),
            params: { person: { phone: '0', lock_version: person.lock_version }, viewport: 'mobile' }

      expect(response).to redirect_to(organisation_people_path(organisation, person_id: person.id, viewport: 'mobile'))
    end
  end

  it 'keeps the member select when a link is refused (the member has a row already)' do
    taken = member_with(role_with, first_name: 'Vergeben')
    create(:person, organisation: organisation, user: taken)
    sign_in admin

    patch organisation_person_path(organisation, person),
          params: { person: { user_id: taken.id, lock_version: person.lock_version } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include('name="person[user_id]"')
    expect(response.body[/<input[^>]*id="person_name"[^>]*>/]).not_to include('readonly')
  end

  it 'opens a row from the keyboard (Enter and Space)' do
    sign_in admin

    get organisation_people_path(organisation)

    row = response.body[/<li[^>]*data-list-row-id-value="#{person.id}"[^>]*>/]
    expect(row).to include(CGI.escapeHTML('keydown.enter->list-row#click'), CGI.escapeHTML('keydown.space->list-row#click'))
  end

  # Review of db1b0288a: the empty lane carried the content marker, so
  # layout-toggle took it for loaded and opened an empty column on every list
  # visit and after a delete.
  it 'renders no content marker in the empty lane, only with something open' do
    sign_in admin

    get organisation_people_path(organisation)
    expect(response.body).not_to match(/class="person-content/)

    get organisation_people_path(organisation, person_id: person.id)
    expect(response.body).to match(/class="person-content/)
  end

  # Review round 4.
  describe 'names of members the reader cannot see' do
    let(:project) { create(:project, organisation: organisation) }
    let(:hidden_writer) { member_with(role_with('manage_people'), first_name: 'Geheim') }

    before do
      create(:project_permission, user: manager, project: project, tickets_access: :read_only)
      create(:project_permission, user: hidden_writer, project: create(:project, organisation: organisation),
                                  tickets_access: :read_only)
    end

    it 'shows neither the creator nor the editor by name' do
      row = Current.set(user: hidden_writer) { create(:person, organisation: organisation, creator: hidden_writer) }
      Current.set(user: hidden_writer) { row.update!(phone: '1') }
      sign_in manager

      get organisation_person_path(organisation, row), headers: frame_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('Geheim')
      expect(response.body).to include(I18n.t('views.organisations.people.history.updated', actor: I18n.t('views.organisations.people.show.someone'),
                                                                                            fields: Person.human_attribute_name(:phone)))
    end
  end

  it 'keeps the phone view in a lane frame (show after "Abbrechen")' do
    sign_in admin

    get organisation_person_path(organisation, person, viewport: 'mobile'), headers: frame_headers

    expect(response.body).not_to include('data-lane-close')
  end

  it 'names the member of the hint through the name display setting' do
    reader = admin
    reader.preference_store.set!('name_display', 'initial_last')
    member = member_with(role_with, first_name: 'Carla')
    sign_in reader

    get member_organisation_people_path(organisation, member.id), headers: frame_headers

    expect(response.body).not_to include('wofür Carla')
  end

  it 'shows the member select again when a new row asks for a member who has one' do
    taken = member_with(role_with, first_name: 'Vergeben')
    create(:person, organisation: organisation, user: taken)
    sign_in admin

    post organisation_people_path(organisation), params: { person: { name: 'X', user_id: taken.id } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include('name="person[user_id]"')
    expect(response.body).not_to include(%(type="hidden" value="#{taken.id}"))
  end

  it 'opens no form for ?new=person without the right to write' do
    sign_in viewer

    get organisation_people_path(organisation, new: 'person')

    expect(response.body).not_to include('id="person_name"')
  end

  it 'sends ?member_id= of a member with a row to that row' do
    row = create(:person, organisation: organisation, user: viewer)
    sign_in admin

    get organisation_people_path(organisation, member_id: viewer.id)

    expect(response).to redirect_to(organisation_people_path(organisation, person_id: row.id))
  end

  it 'answers a lane request of the index with the member lane' do
    member = member_with(role_with, first_name: 'Lena')
    sign_in admin

    get organisation_people_path(organisation, member_id: member.id), headers: frame_headers

    expect(response.body).to include(I18n.t('views.organisations.people.show.add_details'), member.email)
  end

  it 'shows the account email of an active member in the lane, not an old row email' do
    row = create(:person, organisation: organisation, user: viewer, email: 'alt@example.com')
    sign_in admin

    get organisation_person_path(organisation, row), headers: frame_headers

    expect(response.body).to include(viewer.email)
    expect(response.body).not_to include('alt@example.com')
  end

  # Review of S1 (28.10.2026).
  describe 'review of S1' do
    let(:project) { create(:project, organisation: organisation) }

    it 'names a visible creator and the reader themselves' do
      create(:project_permission, user: manager, project: project, tickets_access: :read_only)
      colleague = member_with(role_with('manage_people'), first_name: 'Sichtbar')
      create(:project_permission, user: colleague, project: project, tickets_access: :read_only)
      row = Current.set(user: colleague) { create(:person, organisation: organisation, creator: colleague) }
      Current.set(user: manager) { row.update!(phone: '1') }
      sign_in manager

      get organisation_person_path(organisation, row), headers: frame_headers

      expect(response.body).to include('Sichtbar')
      expect(response.body).to include(I18n.t('views.organisations.people.history.updated',
                                              actor: User.find(manager.id).display_name, fields: Person.human_attribute_name(:phone)))
    end

    # Decision A: deactivating keeps a row as hidden as the member was.
    it 'keeps the row of a deactivated member the reader cannot see out of list and lane' do
      create(:project_permission, user: viewer, project: project, tickets_access: :read_only)
      hidden = member_with(role_with, first_name: 'Versteckt')
      create(:project_permission, user: hidden, project: create(:project, organisation: organisation), tickets_access: :read_only)
      row = create(:person, organisation: organisation, user: hidden, name: 'Versteckt Mitglied', notes: 'GEHEIMNOTIZ')
      Membership.where(user: hidden, organisation: organisation).update_all(active: false)
      sign_in viewer

      get organisation_people_path(organisation)
      expect(response.body).to include('Doris Dienstleister')
      expect(response.body).not_to include('Versteckt Mitglied')

      # Only the status: the test 404 page shows the spec source, which names the note.
      get organisation_person_path(organisation, row), headers: frame_headers
      expect(response).to have_http_status(:not_found)
    end

    it 'answers a lane request with ?member_id= of a member with a row by that row, as a full visit does' do
      create(:person, organisation: organisation, user: viewer, phone: '+49 30 7654321')
      sign_in admin

      get organisation_people_path(organisation, member_id: viewer.id), headers: frame_headers

      expect(response.body).to include('+49 30 7654321')
    end

    it 'opens the row of a member who has one for ?new=person&user_id=, in the lane and on a full visit' do
      row = create(:person, organisation: organisation, user: viewer, phone: '+49 30 7654321')
      sign_in admin

      get organisation_people_path(organisation, new: 'person', user_id: viewer.id), headers: frame_headers
      expect(response.body).to include('+49 30 7654321')
      expect(response.body).not_to include('id="person_name"')

      get organisation_people_path(organisation, new: 'person', user_id: viewer.id)
      expect(response).to redirect_to(organisation_people_path(organisation, person_id: row.id))
    end
  end

  it 'has no missing translation on the page' do
    sign_in admin
    get organisation_people_path(organisation, person_id: person.id)

    expect(response.body).not_to include('translation missing', 'Translation missing')
  end
end
