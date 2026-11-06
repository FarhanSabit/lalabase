# frozen_string_literal: true

require 'rails_helper'

# What: GET /api/v1/organisations/:organisation_id/people and .../people/:id (People S3b), the
#   people directory for the terminal client, read through People::Lookup like the assistant.
# Why: a token must read no person beyond the people page of its owner and no organisation
#   beyond its reach: not an organisation outside the token, not with a token limited to some
#   projects (E1), not without the people right, not a member of a project the owner cannot
#   see, not across the two organisations of one token. Notes only on the card, never in the
#   list (E2). A missing and an invisible person answer the same 404, body included; the list
#   pages by 50 and at most 100 (E4), and a value outside is refused, not cut.
RSpec.describe 'API V1 people', :ci_guard, type: :request do
  let(:organisation) { create(:organisation, name: 'Nordlicht GmbH') }
  let(:other_organisation) { create(:organisation, name: 'Fremdfirma AG') }

  def role_in(org, *actions)
    ActsAsTenant.with_tenant(org) do
      role = create(:role, organisation: org)
      actions.each { |action| create(:permission, role: role, category: 'people', action: action, allowed: true) }
      role
    end
  end

  def member_of(org, user, role:)
    ActsAsTenant.with_tenant(org) { create(:membership, user: user, organisation: org, role: role, active: true) }
  end

  let(:user) { create(:user, first_name: 'Anna', last_name: 'Albers', email: 'anna@example.com') }
  let(:colleague) { create(:user, first_name: 'Carl', last_name: 'Kollege', email: 'carl@example.com') }
  let(:stranger) { create(:user, first_name: 'Sven', last_name: 'Fremd', email: 'sven@example.com') }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:hidden_project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:contact) do
    ActsAsTenant.with_tenant(organisation) do
      create(:person, organisation: organisation, name: 'Doris Dienstleister', salutation: 'Frau',
                      function: 'Leitung IT', department: 'Technik', company: 'Hosting AG',
                      email: 'doris@example.com', phone: '+49 30 1234567', notes: 'Nur vormittags anrufen.',
                      additional_details: [{ 'kind' => 'phone', 'label' => 'Mobil', 'value' => '+49 170 1234567' }])
    end
  end
  let(:hidden_row) { ActsAsTenant.with_tenant(organisation) { Person.find_by!(user: stranger) } }
  let(:foreign_contact) do
    ActsAsTenant.with_tenant(other_organisation) do
      create(:person, organisation: other_organisation, name: 'Olga Andere', notes: 'Fremde Notiz')
    end
  end

  before do
    Prosopite.pause do
      member_of(organisation, user, role: role_in(organisation, 'view_people'))
      plain = role_in(organisation)
      member_of(organisation, colleague, role: plain)
      member_of(organisation, stranger, role: plain)
      member_of(other_organisation, user, role: role_in(other_organisation, 'view_people'))
      ActsAsTenant.with_tenant(organisation) do
        create(:project_permission, user: user, project: project, tickets_access: :read_only)
        create(:project_permission, user: colleague, project: project, tickets_access: :read_only)
        create(:project_permission, user: stranger, project: hidden_project, tickets_access: :read_only)
        create(:person, organisation: organisation, user: colleague, name: 'C. Kollege (alt)', function: 'Einkauf',
                        email: 'alt@example.com', notes: 'Bevorzugt Mail.')
        create(:person, organisation: organisation, user: stranger, name: 'Sven Fremd', function: 'Fremdes Projekt')
      end
      contact
      foreign_contact
    end
  end

  def token(organisations: [organisation], project_scopes: {}, read_only: true, owner: user)
    build(:personal_access_token, user: owner, organisations: organisations, project_scopes: project_scopes,
                                  read_only: read_only).tap do |pat|
      pat.token_hash = nil
      pat.token_prefix = nil
      pat.generate_token!
    end
  end

  let(:pat) { token }

  def list(with: pat, organisation_id: organisation.id, **query)
    get "/api/v1/organisations/#{organisation_id}/people", params: query,
                                                           headers: { 'Authorization' => "Bearer #{with.token}" }
    response
  end

  def show(id, with: pat, organisation_id: organisation.id)
    get "/api/v1/organisations/#{organisation_id}/people/#{id}", headers: { 'Authorization' => "Bearer #{with.token}" }
    response
  end

  def body = response.parsed_body

  def names = body['data'].pluck('name')

  def not_found_body = { 'error' => 'not_found', 'code' => 'not_found' }

  describe 'the list' do
    # A read: the default token is read-only and reads.
    it 'lists the people the owner sees, sorted by name, over a read-only token' do
      expect(pat.read_only?).to be true

      expect(list).to have_http_status(:ok)
      expect(names).to eq(['Anna Albers', 'Carl Kollege', 'Doris Dienstleister'])
      expect(body['data'].pluck('id')).to eq(["member:#{user.id}", "member:#{colleague.id}", "person:#{contact.id}"])
      expect(body['meta']).to eq('page' => 1, 'per_page' => 50, 'total' => 3)
    end

    it 'carries the list fields only, never contact details or the notes' do
      list(q: 'doris')

      expect(body['data'].first.keys)
        .to contain_exactly('id', 'name', 'kind', 'function', 'department', 'company', 'last_contact')
      expect(response.body).not_to include('Nur vormittags anrufen.', 'doris@example.com', '+49 30 1234567')
    end

    it 'searches and filters as the people page does' do
      list(q: 'techn')
      expect(names).to eq(['Doris Dienstleister'])
      list(kind: 'members')
      expect(names).to eq(['Anna Albers', 'Carl Kollege'])
      list(kind: 'contacts', q: 'hosting')
      expect(names).to eq(['Doris Dienstleister'])
    end

    it 'answers no match with an empty list and its total' do
      expect(list(q: 'zzz')).to have_http_status(:ok)
      expect(body).to eq('data' => [], 'meta' => { 'page' => 1, 'per_page' => 50, 'total' => 0 })
    end

    it 'leaves out a member of a project the owner cannot see, and that member\'s row' do
      list

      expect(names).not_to include('Sven Fremd')
      expect(response.body).not_to include('Fremdes Projekt', stranger.id)
    end

    it 'refuses a kind it does not know, a query that is no text, with invalid_input' do
      list(kind: 'member')
      expect(response).to have_http_status(:bad_request)
      expect(body).to eq('error' => 'bad_request', 'code' => 'invalid_input',
                         'message' => 'kind must be one of: all, members, contacts')

      get "/api/v1/organisations/#{organisation.id}/people?q[]=doris", headers: { 'Authorization' => "Bearer #{pat.token}" }
      expect(response).to have_http_status(:bad_request)
      expect(body).to include('code' => 'invalid_input')
    end
  end

  # E4: pages of 50 by default, at most 100. A value outside is refused: a cut would hand a
  # program fewer rows than it asked for without saying so.
  describe 'paging' do
    def contacts(count)
      Prosopite.pause do
        ActsAsTenant.with_tenant(organisation) do
          count.times { |index| create(:person, organisation: organisation, name: format('Zora Zusatz %03d', index)) }
        end
      end
    end

    it 'pages the list and counts every match' do
      list(per_page: 1, page: 2)

      expect(names).to eq(['Carl Kollege'])
      expect(body['meta']).to eq('page' => 2, 'per_page' => 1, 'total' => 3)
    end

    # A form or a client that sends the parameter empty means "not set".
    it 'reads a blank page and per_page as the defaults' do
      list(page: '', per_page: '')

      expect(response).to have_http_status(:ok)
      expect(body['meta']).to eq('page' => 1, 'per_page' => 50, 'total' => 3)
    end

    # The message names the refused value, but does not mirror any amount of input back.
    it 'quotes a refused value only in part' do
      list(per_page: '9' * 5000)

      expect(response).to have_http_status(:bad_request)
      expect(body['message']).to start_with('ungültiger Wert für per_page "999')
      expect(body['message'].length).to be < 100
    end

    # One wording for every list that refuses a page value (ListPaging.strict_number), the
    # glossary's, in the token owner's language.
    it 'names the refused value in the language of the token owner' do
      list(per_page: '101')
      expect(body['message']).to eq('ungültiger Wert für per_page "101" (erwartet ist eine ganze Zahl von 1 bis 100)')

      user.update!(language_preference: 'en')
      list(page: '0')
      expect(body['message']).to eq('invalid page "0" (expected a whole number from 1 to 100000)')
    end

    it 'answers a page past the end with no rows and the total' do
      list(page: 2)

      expect(body).to eq('data' => [], 'meta' => { 'page' => 2, 'per_page' => 50, 'total' => 3 })
    end

    it 'shows 50 rows by default and 100 at most' do
      contacts(101)

      list(q: 'zusatz')
      expect(body['data'].size).to eq(50)
      expect(body['meta']).to eq('page' => 1, 'per_page' => 50, 'total' => 101)

      list(q: 'zusatz', per_page: 100)
      expect(body['data'].size).to eq(100)
      list(q: 'zusatz', per_page: 100, page: 2)
      expect(names).to eq(['Zora Zusatz 100'])
    end

    { per_page: ['101', '0', '-1', 'x', '1.5'], page: ['0', '-1', 'x', '100001'] }.each do |name, values|
      values.each do |value|
        it "refuses #{name}=#{value} with invalid_input" do
          list(name => value)

          expect(response).to have_http_status(:bad_request)
          expect(body).to include('error' => 'bad_request', 'code' => 'invalid_input')
          expect(body['message']).to include(name.to_s)
        end
      end
    end

    # A list or a nested value is no number and no text either: 400, never a 500 from code that
    # expected a string, and the message names the parameter without Ruby's insides (read in
    # English, where it starts with the parameter).
    { page: [['2'], { 'a' => '1' }], per_page: [['2'], { 'a' => '1' }], q: [['doris'], { 'a' => 'x' }] }
      .each do |name, values|
        values.each do |value|
          it "refuses #{name} given as a #{value.class.name.downcase} with invalid_input" do
            user.update!(language_preference: 'en')
            list(name => value)

            expect(response).to have_http_status(:bad_request)
            expect(body).to include('error' => 'bad_request', 'code' => 'invalid_input')
            expect(body['message']).to start_with("invalid #{name} ")
            expect(body['message']).not_to include('ActionController', 'Parameters', '[')
          end
        end
      end
  end

  describe 'the card' do
    it 'carries the card fields and the notes as stored' do
      expect(show("person:#{contact.id}")).to have_http_status(:ok)

      expect(body['data'].keys).to contain_exactly('id', 'name', 'kind', 'salutation', 'function', 'department',
                                                   'company', 'email', 'phone', 'additional_details',
                                                   'last_contact', 'notes')
      expect(body['data']).to include('name' => 'Doris Dienstleister', 'email' => 'doris@example.com',
                                      'phone' => '+49 30 1234567', 'notes' => 'Nur vormittags anrufen.',
                                      'additional_details' => [{ 'label' => 'Mobil', 'value' => '+49 170 1234567' }])
    end

    it 'answers blank notes with null' do
      ActsAsTenant.with_tenant(organisation) { contact.update!(notes: '') }

      show("person:#{contact.id}")
      expect(body['data']).to include('notes' => nil)
    end

    it 'takes a member\'s name and email from the account, the notes from the row' do
      show("member:#{colleague.id}")

      expect(body['data']).to include('id' => "member:#{colleague.id}", 'name' => 'Carl Kollege', 'kind' => 'member',
                                      'email' => 'carl@example.com', 'notes' => 'Bevorzugt Mail.')
    end

    it 'answers the email a member shows to others, never a hidden login address' do
      colleague.update!(email_visibility: 'contact', contact_email: 'carl.team@example.com')
      show("member:#{colleague.id}")
      expect(body['data']).to include('name' => 'Carl Kollege', 'email' => 'carl.team@example.com')

      colleague.update!(email_visibility: 'none')
      show("member:#{colleague.id}")
      expect(body['data']).to include('name' => 'Carl Kollege', 'email' => nil)
      expect(response.body).not_to include('carl@example.com')
    end

    it 'answers a missing, a foreign and an invisible person with the same 404' do
      ids = ["person:#{SecureRandom.uuid}", "member:#{SecureRandom.uuid}", "person:#{foreign_contact.id}",
             "person:#{hidden_row.id}", "member:#{stranger.id}"]

      answers = Prosopite.pause do
        ids.map do |id|
          show(id)
          [response.status, response.body]
        end
      end

      expect(answers.uniq).to eq([[404, not_found_body.to_json]])
    end

    %w[abc person:abc new member:12345].each do |id|
      it "refuses the id #{id} with invalid_input" do
        show(id)

        expect(response).to have_http_status(:bad_request)
        expect(body).to eq('error' => 'bad_request', 'code' => 'invalid_input',
                           'message' => 'invalid id (expected "person:<uuid>" or "member:<uuid>")')
      end
    end
  end

  # E1: only a token that reaches every project of the organisation reads its directory.
  # Outside it, limited to some projects, missing or malformed: one 404, body included.
  describe 'the organisation' do
    def expect_not_found
      expect(response).to have_http_status(:not_found)
      expect(body).to eq(not_found_body)
    end

    it 'answers an organisation outside the token like a missing one, on both endpoints' do
      outside = create(:organisation)
      member_of(outside, user, role: role_in(outside, 'view_people'))

      # Eight requests from one line read like an N+1 to Prosopite; each is one request.
      Prosopite.pause do
        [other_organisation.id, outside.id, SecureRandom.uuid, 'oops'].each do |id|
          list(organisation_id: id)
          expect_not_found
          show("person:#{contact.id}", organisation_id: id)
          expect_not_found
        end
      end
    end

    it 'answers a token limited to some projects of the organisation like an organisation outside it' do
      limited = token(project_scopes: { organisation => [project] })

      list(with: limited)
      expect_not_found
      show("person:#{contact.id}", with: limited)
      expect_not_found
    end

    # The token stops reaching an organisation in which its owner is deactivated
    # (PersonalAccessToken#organisation_scopes): a 404 like an organisation outside it.
    it 'answers a deactivated member like an organisation outside the token' do
      ActsAsTenant.with_tenant(organisation) { Membership.find_by!(user: user, organisation: organisation).update!(active: false) }

      list
      expect_not_found
      show("person:#{contact.id}")
      expect_not_found
    end

    it 'takes the organisation id in capitals as well' do
      expect(list(organisation_id: organisation.id.upcase)).to have_http_status(:ok)
    end
  end

  describe 'rights' do
    it 'answers an owner without the people right with 403 forbidden, on both endpoints' do
      plain = token(owner: colleague)

      list(with: plain)
      expect(response).to have_http_status(:forbidden)
      expect(body).to eq('error' => 'forbidden', 'code' => 'forbidden')
      show("person:#{contact.id}", with: plain)
      expect(response).to have_http_status(:forbidden)
      expect(body).to eq('error' => 'forbidden', 'code' => 'forbidden')
    end

    # Pundit asks the people right first (authorize Person, :index?) and People::Lookup asks it
    # again before it reads. A right taken away between the two is a 403 as well, never another
    # status: the first answer of view_allowed? lets Pundit pass, the second one is the
    # lookup's, and it refuses before the directory would ask a third time.
    describe 'a right lost between the two checks' do
      before { allow(PersonPolicy).to receive(:view_allowed?).and_return(true, false) }

      it 'answers the list with 403 forbidden' do
        list

        expect(response).to have_http_status(:forbidden)
        expect(body).to eq('error' => 'forbidden', 'code' => 'forbidden')
        expect(PersonPolicy).to have_received(:view_allowed?).twice
      end

      it 'answers the card with 403 forbidden' do
        show("person:#{contact.id}")

        expect(response).to have_http_status(:forbidden)
        expect(body).to eq('error' => 'forbidden', 'code' => 'forbidden')
        expect(PersonPolicy).to have_received(:view_allowed?).twice
      end
    end

    it 'asks the right before it looks at the parameters' do
      plain = token(owner: colleague)

      expect(list(with: plain, per_page: '500')).to have_http_status(:forbidden)
      expect(show('abc', with: plain)).to have_http_status(:forbidden)
    end
  end

  describe 'two organisations, one token' do
    let(:both) { token(organisations: [organisation, other_organisation]) }

    it 'lists the people of the organisation asked for and nobody of the other' do
      list(with: both)
      expect(names).to eq(['Anna Albers', 'Carl Kollege', 'Doris Dienstleister'])
      expect(response.body).not_to include('Olga Andere', foreign_contact.id)

      list(with: both, organisation_id: other_organisation.id)
      expect(names).to eq(['Anna Albers', 'Olga Andere'])
      expect(response.body).not_to include('Doris Dienstleister', contact.id)
    end

    it 'reads a person only in the organisation it belongs to' do
      show("person:#{foreign_contact.id}", with: both, organisation_id: other_organisation.id)
      expect(body['data']).to include('name' => 'Olga Andere', 'notes' => 'Fremde Notiz')

      show("person:#{foreign_contact.id}", with: both)
      expect(response).to have_http_status(:not_found)
      show("person:#{contact.id}", with: both, organisation_id: other_organisation.id)
      expect(response).to have_http_status(:not_found)
    end
  end
end
