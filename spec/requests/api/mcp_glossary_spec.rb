# frozen_string_literal: true

require 'rails_helper'

# What: get_glossary over POST /api/mcp (K4c), the glossary of an organisation for a program
#   behind a token, read through Glossary::Lookup like GET /api/v1/organisations/:id/terms.
# Why: the tool runs with a token's reach, not a project's. It must answer only what works
#   (confirmed terms, confirmed heard forms), only to an owner with the glossary right (refused,
#   reason glossary_forbidden), never an organisation beyond the token (one not_found for
#   outside, foreign, missing and malformed), the heard forms only of the token's projects, and
#   speakers only with the people right. It sits last on tools/list, so every pinned tool keeps
#   its place. Invented words and names only.
RSpec.describe 'MCP get_glossary', :ci_guard, type: :request do
  let(:organisation) { create(:organisation, name: 'Nordlicht GmbH') }
  let(:other_organisation) { create(:organisation, name: 'Zweitfirma AG') }
  let(:foreign_organisation) { create(:organisation, name: 'Fremdfirma AG') }

  def role_in(org, *rights)
    ActsAsTenant.with_tenant(org) do
      role = create(:role, organisation: org)
      rights.each do |right|
        category, action = right.split(':')
        create(:permission, role: role, category: category, action: action, allowed: true)
      end
      role
    end
  end

  def member_of(org, user, role:)
    ActsAsTenant.with_tenant(org) { create(:membership, user: user, organisation: org, role: role, active: true) }
  end

  let(:anna) { create(:user, first_name: 'Anna', last_name: 'Albers', email: 'anna@example.com', language_preference: 'en') }
  let(:gustav) { create(:user, first_name: 'Gustav', last_name: 'Glossar', email: 'gustav@example.com') }
  let(:nobody) { create(:user, first_name: 'Nora', last_name: 'Ohnerecht', email: 'nora@example.com', language_preference: 'en') }
  let(:ben) { create(:user, first_name: 'Ben', last_name: 'Berger', email: 'ben@example.com') }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Ahorn') } }
  let(:other_project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Birke') } }
  let(:doris) { ActsAsTenant.with_tenant(organisation) { create(:person, organisation: organisation, name: 'Doris Dienstleister') } }
  let(:lalabase) { ActsAsTenant.with_tenant(organisation) { create(:glossary_term, organisation: organisation, term: 'Lalabase', category: 'product') } }

  def heard(term, form, replaced: 1, **attributes)
    ActsAsTenant.with_tenant(term.organisation) do
      create(:term_correction, organisation: term.organisation, glossary_term: term, heard: form,
                               replaced_count: replaced, **attributes)
    end
  end

  before do
    Prosopite.pause do
      member_of(organisation, anna, role: role_in(organisation, 'glossary:view_glossary', 'people:view_people'))
      member_of(organisation, gustav, role: role_in(organisation, 'glossary:view_glossary'))
      member_of(organisation, nobody, role: role_in(organisation))
      member_of(organisation, ben, role: role_in(organisation))
      member_of(other_organisation, anna, role: role_in(other_organisation, 'glossary:view_glossary'))
      ActsAsTenant.with_tenant(organisation) do
        [anna, gustav, ben].each { |user| create(:project_permission, user: user, project: project, tickets_access: :read_only) }
        create(:glossary_term, :proposed, organisation: organisation, term: 'Zirbelholz')
      end
      heard(lalabase, 'lala bass', replaced: 3, project: project, user: ben)
      heard(lalabase, 'la la base', replaced: 2, project: other_project, person: doris)
      heard(lalabase, 'lala basis', replaced: 1)
      heard(lalabase, 'lalabeis', replaced: 9, project: project, status: 'proposed')
    end
  end

  def token(owner: anna, organisations: [organisation], project_scopes: {})
    build(:personal_access_token, user: owner, organisations: organisations, project_scopes: project_scopes).tap do |pat|
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

  def glossary(with: pat, **arguments)
    rpc('tools/call', { name: 'get_glossary', arguments: { organisation_id: organisation.id }.merge(arguments) }, with: with)['result']
  end

  def text(result) = result.dig('content', 0, 'text')

  def data(result)
    expect(result['isError']).to be_falsey, "expected an answer, got #{result.inspect}"
    expect(result['_meta']).to eq('lalabase/kind' => 'ok')
    JSON.parse(text(result))
  end

  def forms(answer) = answer['data'].find { |row| row['term'] == 'Lalabase' }['heard']

  def refusal(result)
    expect(result['isError']).to be(true), "expected a refusal, got #{result.inspect}"
    [result['_meta'], text(result)]
  end

  describe 'tools/list' do
    let(:tools) { rpc('tools/list', {}).dig('result', 'tools') }

    it 'offers get_glossary last, so the order of every tool before it holds' do
      expect(tools.pluck('name').last(2)).to eq(%w[get_meeting get_glossary])
    end

    # A read on a token: the organisation always, the project only as an order, pages; no project_id
    # injected as a gate and no idempotency key. The bounds of the pages are named, not enforced by
    # the schema: the reader refuses them after the right, as REST does (review round 1 of #124).
    it 'takes the organisation, a project to put first and pages' do
      schema = tools.find { |tool| tool['name'] == 'get_glossary' }['inputSchema']

      expect(schema['properties'].keys).to eq(%w[organisation_id project_id page per_page])
      expect(schema['required']).to eq(['organisation_id'])
      expect(schema.dig('properties', 'per_page')).to eq('type' => 'integer', 'description' => 'Terms per page, from 1 to 100 (default 50).')
      expect(schema.dig('properties', 'page').keys).to eq(%w[type description])
      expect(schema.dig('properties', 'project_id', 'description')).to match(/come first/)
    end
  end

  it 'reports a server version from 0.18.0 on' do
    body = rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'rspec', version: '0' } })
    expect(Gem::Version.new(body.dig('result', 'serverInfo', 'version'))).to be >= Gem::Version.new('0.18.0')
  end

  describe 'an answer' do
    it 'reads the confirmed terms with their confirmed heard forms over a read-only token' do
      expect(pat.read_only?).to be true
      answer = data(glossary)

      expect(answer['data'].pluck('term')).to eq(%w[Lalabase])
      expect(forms(answer)).to eq(
        [{ 'form' => 'lala bass', 'count' => 3, 'speakers' => [{ 'ref' => "member:#{ben.id}", 'count' => 3 }] },
         { 'form' => 'la la base', 'count' => 2, 'speakers' => [{ 'ref' => "person:#{doris.id}", 'count' => 2 }] },
         { 'form' => 'lala basis', 'count' => 1, 'speakers' => [] }]
      )
      expect(answer['people']).to eq([{ 'ref' => "member:#{ben.id}", 'name' => 'Ben Berger' },
                                      { 'ref' => "person:#{doris.id}", 'name' => 'Doris Dienstleister' }])
      expect(answer['meta']).to eq('page' => 1, 'per_page' => 50, 'total' => 1)
      expect(text(glossary)).not_to include('Zirbelholz', 'lalabeis')
    end

    it 'puts the heard forms of project_id first' do
      expect(forms(data(glossary(project_id: other_project.id))).pluck('form')).to eq(['la la base', 'lala bass', 'lala basis'])
    end

    it 'gives a token limited to some projects the forms of its projects only, and the people of those' do
      answer = data(glossary(with: token(project_scopes: { organisation => [project] })))

      expect(forms(answer).pluck('form')).to eq(['lala bass'])
      expect(answer['people'].pluck('ref')).to eq(["member:#{ben.id}"])
    end

    it 'names nobody without the people right' do
      answer = data(glossary(with: token(owner: gustav)))

      expect(forms(answer).pluck('speakers')).to all(eq([]))
      expect(answer['people']).to eq([])
    end

    it 'pages the terms' do
      answer = data(glossary(page: 2, per_page: 1))

      expect(answer).to eq('data' => [], 'people' => [], 'meta' => { 'page' => 2, 'per_page' => 1, 'total' => 1 })
    end

    # JSON Schema's integer takes 2.0, and so does the SDK; the tool reads it as 2 (review round 3 of #124).
    it 'reads a whole number sent as 1.0 as that number' do
      expect(data(glossary(page: 1.0, per_page: 50.0))['meta']).to eq('page' => 1, 'per_page' => 50, 'total' => 1)
    end
  end

  describe 'refusals' do
    it 'refuses an owner without the glossary right with the reason glossary_forbidden, in their language' do
      expect(refusal(glossary(with: token(owner: nobody))))
        .to eq([{ 'lalabase/code' => 'refused', 'lalabase/reason' => 'glossary_forbidden' },
                'You may not read the glossary of this organisation.'])
    end

    it 'answers an organisation outside the token, a foreign, a missing and a malformed one alike: not_found' do
      outside = refusal(glossary(organisation_id: other_organisation.id))
      foreign = refusal(glossary(organisation_id: foreign_organisation.id))
      missing = refusal(glossary(organisation_id: SecureRandom.uuid))
      malformed = refusal(glossary(organisation_id: 'oops'))

      expect([outside, foreign, missing, malformed])
        .to all(eq([{ 'lalabase/code' => 'not_found' }, 'Organisation not found or not accessible.']))
    end

    it 'answers a deactivated member like an organisation outside the token' do
      deactivated = token
      ActsAsTenant.with_tenant(organisation) { Membership.find_by!(user: anna, organisation: organisation).update!(active: false) }

      expect(refusal(glossary(with: deactivated)).first).to eq('lalabase/code' => 'not_found')
    end

    it 'answers a project_id outside the organisation, outside the token, missing or malformed alike: not_found' do
      foreign = ActsAsTenant.with_tenant(foreign_organisation) { create(:project, organisation: foreign_organisation) }
      limited = token(project_scopes: { organisation => [project] })

      answers = [
        refusal(glossary(project_id: foreign.id)),
        refusal(glossary(with: limited, project_id: other_project.id)),
        refusal(glossary(project_id: SecureRandom.uuid)),
        refusal(glossary(project_id: 'oops'))
      ]
      expect(answers).to all(eq([{ 'lalabase/code' => 'not_found' }, 'Project not found or not accessible.']))
    end

    it 'refuses page values outside their bounds, an empty organisation_id and an unknown argument as invalid_input' do
      too_many = refusal(glossary(per_page: 101)).first
      page_zero = refusal(glossary(page: 0)).first
      as_text = refusal(glossary(per_page: '2')).first
      blank = refusal(glossary(organisation_id: ' '))
      unknown = refusal(glossary(query: 'lala'))

      expect([too_many, page_zero, as_text]).to all(eq('lalabase/code' => 'invalid_input'))
      expect(text(glossary(per_page: 101))).to eq('invalid per_page "101" (expected a whole number from 1 to 100)')
      expect(blank).to eq([{ 'lalabase/code' => 'invalid_input' }, 'organisation_id is required'])
      expect(unknown).to eq([{ 'lalabase/code' => 'invalid_input' }, 'unknown arguments: query'])
    end
  end
end
