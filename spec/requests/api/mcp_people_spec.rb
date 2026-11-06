# frozen_string_literal: true

require 'rails_helper'

# What: find_people and get_person over POST /api/mcp (People S3b), for agents such as
#   Claude Code: the assistant's two people tools with an organisation_id, on a token.
# Why: the directory and the last contact read across a whole organisation, and the tools
#   run with a token's reach, not a project's. A token must never read people beyond what
#   its owner sees on the people page, and not beyond what the token reaches: not in an
#   organisation outside the token, not with a token limited to some projects (E1), not
#   without the people right, not a member of a project the owner cannot see, not across
#   two organisations of one token, never the notes (E2). A missing person and an invisible
#   one answer alike.
RSpec.describe 'MCP people tools', :ci_guard, type: :request do
  let(:organisation) { create(:organisation, name: 'Nordlicht GmbH') }
  let(:other_organisation) { create(:organisation, name: 'Fremdfirma AG') }
  let(:outside_organisation) { create(:organisation, name: 'Draussen KG') }

  def role_in(org, *actions)
    ActsAsTenant.with_tenant(org) do
      role = create(:role, organisation: org)
      actions.each { |action| create(:permission, role: role, category: 'people', action: action, allowed: true) }
      role
    end
  end

  def member_of(org, user, role:, active: true)
    ActsAsTenant.with_tenant(org) { create(:membership, user: user, organisation: org, role: role, active: active) }
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
                      email: 'doris@example.com', phone: '+49 30 1234567', notes: 'Geheime Notiz')
    end
  end
  let(:foreign_contact) do
    ActsAsTenant.with_tenant(other_organisation) do
      create(:person, organisation: other_organisation, name: 'Olga Andere', company: 'Fremdfirma AG',
                      notes: 'Fremde Notiz')
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

  def rpc(method, params, with: pat)
    post '/api/mcp', params: { jsonrpc: '2.0', id: 1, method: method, params: params }.to_json,
                     headers: { 'Authorization' => "Bearer #{with.token}", 'CONTENT_TYPE' => 'application/json' }
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  def call(tool, with: pat, **arguments)
    rpc('tools/call', { name: tool, arguments: arguments }, with: with)['result']
  end

  def text(result) = result.dig('content', 0, 'text')

  def data(result)
    expect(result['isError']).to be_falsey, "expected an answer, got #{result.inspect}"
    JSON.parse(text(result))
  end

  def find(with: pat, organisation_id: organisation.id, **arguments)
    call('find_people', with: with, organisation_id: organisation_id, **arguments)
  end

  def person(id, with: pat, organisation_id: organisation.id)
    call('get_person', with: with, organisation_id: organisation_id, id: id)
  end

  def expect_code(result, code)
    expect(result['isError']).to be(true), "expected #{code}, got #{result.inspect}"
    expect(result.dig('_meta', 'lalabase/code')).to eq(code)
  end

  describe 'tools/list' do
    let(:tools) { rpc('tools/list', {}).dig('result', 'tools') }

    it 'appends both tools after the time report, the pinned order of every other tool unchanged' do
      expect(tools.pluck('name')).to eq(%w[
                                          search_code_symbols list_capabilities get_project_vision
                                          get_capability_details get_symbol_details list_tickets
                                          get_ticket search_knowledge create_ticket post_comment
                                          list_notifications create_time_session mark_notification_read
                                          update_ticket summarize_time_sessions find_people get_person
                                          list_organisations list_projects create_meeting get_meeting
                                          get_glossary
                                        ])
    end

    # E3: always the organisation; no project (the token reach is the gate), no idempotency key (reads).
    it 'requires organisation_id on both, without project_id or idempotency_key' do
      find_schema = tools.find { |tool| tool['name'] == 'find_people' }['inputSchema']
      get_schema = tools.find { |tool| tool['name'] == 'get_person' }['inputSchema']

      expect(find_schema['properties'].keys).to contain_exactly('organisation_id', 'query', 'kind')
      expect(find_schema['required']).to eq(['organisation_id'])
      expect(get_schema['properties'].keys).to contain_exactly('organisation_id', 'id')
      expect(get_schema['required']).to eq(%w[organisation_id id])
    end
  end

  # The version that brought the people tools, or a later one: a pin on the
  # exact number broke with the next patch (0.13.1).
  it 'reports a server version from 0.13.0 on' do
    body = rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'rspec', version: '0' } })
    expect(Gem::Version.new(body.dig('result', 'serverInfo', 'version'))).to be >= Gem::Version.new('0.13.0')
  end

  describe 'find_people' do
    # A read: the default token is read-only and reads.
    it 'lists the people the owner sees, as the assistant does, over a read-only token' do
      expect(pat.read_only?).to be true

      answer = data(find)

      expect(answer.keys).to contain_exactly('total', 'truncated', 'data')
      expect(answer['data'].pluck('name')).to eq(['Anna Albers', 'Carl Kollege', 'Doris Dienstleister'])
      expect(answer['data'].pluck('id')).to eq(["member:#{user.id}", "member:#{colleague.id}", "person:#{contact.id}"])
      expect(answer).to include('total' => 3, 'truncated' => false)
    end

    it 'carries the list fields only, never contact details or the notes' do
      result = find(query: 'doris')
      row = data(result)['data'].first

      expect(row.keys).to contain_exactly('id', 'name', 'kind', 'function', 'department', 'company', 'last_contact')
      expect(text(result)).not_to include('Geheime Notiz', 'doris@example.com', '+49 30 1234567')
    end

    it 'searches and filters as the assistant does' do
      expect(data(find(query: 'techn'))['data'].pluck('name')).to eq(['Doris Dienstleister'])
      expect(data(find(kind: 'contacts'))['data'].pluck('name')).to eq(['Doris Dienstleister'])
      expect(data(find(kind: 'members'))['data'].pluck('name')).to eq(['Anna Albers', 'Carl Kollege'])
    end

    it 'answers no match with an empty list and what to try next' do
      result = find(query: 'zzz')

      expect(result.dig('_meta', 'lalabase/kind')).to eq('ok')
      expect(data(result)).to include('total' => 0, 'data' => [])
      expect(data(result)['next_step']).to include('"techn"')
    end

    it 'leaves out a member of a project the owner cannot see, and that member\'s row' do
      result = find

      expect(data(result)['data'].pluck('name')).not_to include('Sven Fremd')
      expect(text(result)).not_to include('Fremdes Projekt', stranger.id)
    end

    # The schema names the kinds (enum), so the SDK refuses another one before the tool runs.
    it 'refuses a kind it does not know as invalid input' do
      result = find(kind: 'member')

      expect_code(result, 'invalid_input')
      expect(text(result)).to include('kind')
    end
  end

  describe 'get_person' do
    it 'reads the card the assistant reads, never the notes' do
      result = person("person:#{contact.id}")
      card = data(result)

      expect(card.keys).to contain_exactly('id', 'name', 'kind', 'salutation', 'function', 'department', 'company',
                                           'email', 'phone', 'additional_details', 'last_contact')
      expect(card).to include('name' => 'Doris Dienstleister', 'email' => 'doris@example.com', 'phone' => '+49 30 1234567')
      expect(text(result)).not_to include('Geheime Notiz')
    end

    it 'takes a member\'s email from the account' do
      expect(data(person("member:#{colleague.id}"))).to include('name' => 'Carl Kollege', 'email' => 'carl@example.com')
    end

    it 'answers the email a member shows to others, never a hidden login address' do
      colleague.update!(email_visibility: 'contact', contact_email: 'carl.team@example.com')
      expect(data(person("member:#{colleague.id}"))).to include('name' => 'Carl Kollege', 'email' => 'carl.team@example.com')

      colleague.update!(email_visibility: 'none')
      result = person("member:#{colleague.id}")
      expect(data(result)).to include('name' => 'Carl Kollege', 'email' => nil)
      expect(text(result)).not_to include('carl@example.com')
    end

    # Like get_ticket on this surface: a record that is not there is an empty answer, the same
    # for a missing, a foreign and an invisible id; not_found is kept for the organisation.
    it 'answers a missing, a foreign and an invisible person alike' do
      hidden_row = ActsAsTenant.with_tenant(organisation) { Person.find_by!(user: stranger) }
      ids = ["person:#{SecureRandom.uuid}", "person:#{foreign_contact.id}", "person:#{hidden_row.id}",
             "member:#{stranger.id}"]

      answers = Prosopite.pause { ids.map { |id| person(id) } }

      answers.zip(ids).each do |result, id|
        expect(result['isError']).to be(false)
        expect(result['_meta']).to eq('lalabase/kind' => 'empty')
        expect(text(result)).to eq("No person found for #{id}. Use an id find_people returned.")
      end
    end

    it 'refuses an id of the wrong shape as invalid input' do
      result = person('abc')

      expect_code(result, 'invalid_input')
      expect(text(result)).to include('find_people')
    end
  end

  # E1 and E3: the organisation is named, and it must be one whose every project the token reaches.
  describe 'the organisation' do
    def expect_not_reachable(result)
      expect_code(result, 'not_found')
      expect(text(result)).to eq('Organisation not found or not accessible.')
    end

    it 'is required: missing is invalid input before the tool runs, blank and malformed in the tool' do
      expect_code(call('find_people'), 'invalid_input')
      expect_code(call('get_person', id: "person:#{contact.id}"), 'invalid_input')
      expect(text(call('find_people', organisation_id: ' '))).to eq('organisation_id is required')
      expect_code(find(organisation_id: 'oops'), 'invalid_input')
      expect(text(find(organisation_id: 'oops'))).to include('invalid organisation_id')
    end

    it 'answers an organisation outside the token like a missing one, on both tools' do
      member_of(outside_organisation, user, role: role_in(outside_organisation, 'view_people'))

      expect_not_reachable(find(organisation_id: other_organisation.id))
      expect_not_reachable(find(organisation_id: outside_organisation.id))
      expect_not_reachable(find(organisation_id: SecureRandom.uuid))
      expect_not_reachable(person("person:#{foreign_contact.id}", organisation_id: other_organisation.id))
    end

    # E1: a token limited to some projects was meant to keep its holder to them; the directory
    # and the last contact read across the whole organisation.
    it 'answers a token limited to some projects of the organisation like an organisation outside it' do
      limited = token(project_scopes: { organisation => [project] })

      expect_not_reachable(find(with: limited))
      expect_not_reachable(person("person:#{contact.id}", with: limited))
    end

    # The token stops reaching an organisation in which its owner is deactivated
    # (PersonalAccessToken#organisation_scopes), so this is the answer for an organisation
    # outside it, not a refusal.
    it 'answers a deactivated member like an organisation outside the token' do
      ActsAsTenant.with_tenant(organisation) { Membership.find_by!(user: user, organisation: organisation).update!(active: false) }

      expect_not_reachable(find)
      expect_not_reachable(person("person:#{contact.id}"))
    end

    it 'opens the directory for an all-organisations token' do
      all = build(:personal_access_token, :all_organisations, user: user).tap do |pat|
        pat.token_hash = nil
        pat.token_prefix = nil
        pat.generate_token!
      end

      expect(data(find(with: all))['total']).to eq(3)
    end
  end

  describe 'rights' do
    it 'refuses an owner without the people right, on both tools' do
      plain = token(owner: colleague)

      [find(with: plain), person("person:#{contact.id}", with: plain)].each do |result|
        expect_code(result, 'refused')
        expect(result.dig('_meta', 'lalabase/reason')).to eq('people_directory')
        expect(text(result)).to include('may not see the people directory')
      end
    end

    # An id the schema cannot check: the right comes first, as in the assistant.
    it 'refuses the right before it looks at the id' do
      expect_code(person('abc', with: token(owner: colleague)), 'refused')
    end
  end

  # One token for two organisations: each answer reads its own organisation only, under its
  # own tenant.
  describe 'two organisations, one token' do
    let(:both) { token(organisations: [organisation, other_organisation]) }

    it 'lists the people of the organisation asked for and nobody of the other' do
      nordlicht = find(with: both)
      fremdfirma = find(with: both, organisation_id: other_organisation.id)

      expect(data(nordlicht)['data'].pluck('name')).to eq(['Anna Albers', 'Carl Kollege', 'Doris Dienstleister'])
      expect(text(nordlicht)).not_to include('Olga Andere', foreign_contact.id)
      expect(data(fremdfirma)['data'].pluck('name')).to eq(['Anna Albers', 'Olga Andere'])
      expect(text(fremdfirma)).not_to include('Doris Dienstleister', contact.id)
    end

    it 'reads a person only in the organisation it belongs to' do
      expect(data(person("person:#{foreign_contact.id}", with: both, organisation_id: other_organisation.id)))
        .to include('name' => 'Olga Andere')
      expect(person("person:#{foreign_contact.id}", with: both).dig('_meta', 'lalabase/kind')).to eq('empty')
      expect(person("person:#{contact.id}", with: both, organisation_id: other_organisation.id)
               .dig('_meta', 'lalabase/kind')).to eq('empty')
    end
  end

  # The citations are the chat's rights gate; MCP has no chat reader to gate.
  describe 'without a chat' do
    def run(tool, args)
      context = Lalabase::Tools::Context.new(actor: User.find(user.id), organisation: nil, project: nil, chat: nil,
                                             authorization: Lalabase::Tools::AuthorizationRecorder.new, reach: pat.reach)
      tool.execute(args: args, context: context)
    end

    it 'cites nothing and marks its authorization' do
      listed = run(Lalabase::Tools::McpFindPeople, organisation_id: organisation.id)
      read = run(Lalabase::Tools::McpGetPerson, organisation_id: organisation.id, id: "person:#{contact.id}")

      expect([listed, read].map(&:success?)).to eq([true, true])
      expect(listed.citations).to eq([])
      expect(read.citations).to eq([])
    end
  end
end
