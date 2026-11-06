# frozen_string_literal: true

require 'rails_helper'

# What: GET /api/v1/organisations/:organisation_id/terms and the MCP tool get_glossary answer
#   the same glossary for the same data, token and arguments, and refuse alike (K4c).
# Why: two doors for one question become two answers as soon as one of them reads on its own
#   (a query without TermCorrection.effective hands out proposals that work nowhere). Both read
#   through Glossary::Lookup; this compares what reaches the wire, for a full token, a token
#   limited to some projects, a project put first, a page, and an owner without the people
#   right. Invented words and names only.
RSpec.describe 'Glossary on REST and MCP', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  def role_with(*rights)
    role = create(:role, organisation: organisation)
    rights.each do |right|
      category, action = right.split(':')
      create(:permission, role: role, category: category, action: action, allowed: true)
    end
    role
  end

  let(:anna) { create(:user, first_name: 'Anna', last_name: 'Albers', language_preference: 'en') }
  let(:gustav) { create(:user, first_name: 'Gustav', last_name: 'Glossar') }
  let(:nobody) { create(:user, first_name: 'Nora', last_name: 'Ohnerecht') }
  let(:ben) { create(:user, first_name: 'Ben', last_name: 'Berger') }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:other_project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before do
    Prosopite.pause do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: anna, organisation: organisation, role: role_with('glossary:view_glossary', 'people:view_people'))
        create(:membership, user: gustav, organisation: organisation, role: role_with('glossary:view_glossary'))
        create(:membership, user: nobody, organisation: organisation, role: role_with)
        create(:membership, user: ben, organisation: organisation, role: role_with)
        [anna, gustav, ben].each { |user| create(:project_permission, user: user, project: project, tickets_access: :read_only) }
        doris = create(:person, organisation: organisation, name: 'Doris Dienstleister')
        ben_row = create(:person, organisation: organisation, user: ben, name: 'B. Alt')

        lalabase = create(:glossary_term, organisation: organisation, term: 'Lalabase', category: 'product')
        nordlicht = create(:glossary_term, organisation: organisation, term: 'Nordlicht', category: 'company')
        proposal = create(:glossary_term, :proposed, organisation: organisation, term: 'Zirbelholz')
        create(:glossary_term, organisation: organisation, term: 'Ahornweg', category: 'place')
        correction = ->(term, heard, **attributes) { create(:term_correction, organisation: organisation, glossary_term: term, heard: heard, **attributes) }
        correction.call(lalabase, 'lala bass', replaced_count: 3, project: project, user: ben, created_at: 2.days.ago)
        correction.call(lalabase, 'Lala Bass', replaced_count: 1, project: project, person: doris, created_at: 1.day.ago)
        correction.call(lalabase, 'lala bass', replaced_count: 2, project: project, created_at: 3.days.ago)
        correction.call(lalabase, 'la la base', replaced_count: 2, project: other_project, person: ben_row)
        correction.call(lalabase, 'lala basis', replaced_count: 1)
        # A second term with forms and speakers of its own: one page reads both in the same queries.
        correction.call(nordlicht, 'nord licht', replaced_count: 2, project: project, person: doris, created_at: 2.days.ago)
        correction.call(nordlicht, 'nordlich', replaced_count: 1, project: other_project, user: ben, created_at: 1.day.ago)
        # Proposals: one at a confirmed term, one of a proposed term. Neither works anywhere.
        correction.call(lalabase, 'lalabeis', replaced_count: 9, project: project, status: 'proposed')
        correction.call(proposal, 'zirbel holz', project: project)
      end
    end
  end

  def token(owner: anna, project_scopes: {})
    build(:personal_access_token, user: owner, organisations: [organisation], project_scopes: project_scopes).tap do |pat|
      pat.token_hash = nil
      pat.token_prefix = nil
      pat.generate_token!
    end
  end

  let(:pat) { token }

  # => [status, body]
  def rest(with: pat, organisation_id: organisation.id, **query)
    get "/api/v1/organisations/#{organisation_id}/terms", params: query,
                                                          headers: { 'Authorization' => "Bearer #{with.token}" }
    [response.status, response.parsed_body]
  end

  # => the tool result
  def mcp(with: pat, organisation_id: organisation.id, **arguments)
    post '/api/mcp', params: { jsonrpc: '2.0', id: 1, method: 'tools/call',
                               params: { name: 'get_glossary',
                                         arguments: arguments.merge(organisation_id: organisation_id) } }.to_json,
                     headers: { 'Authorization' => "Bearer #{with.token}", 'CONTENT_TYPE' => 'application/json' }
    response.parsed_body['result']
  end

  def mcp_data(result)
    expect(result['isError']).to be_falsey, result.inspect
    JSON.parse(result.dig('content', 0, 'text'))
  end

  it 'answers a full token the same glossary on both, proposals left out' do
    status, body = rest

    expect(status).to eq(200)
    expect(body['data'].pluck('term')).to eq(%w[Ahornweg Lalabase Nordlicht])
    expect(body.to_json).not_to include('Zirbelholz', 'lalabeis')
    expect(mcp_data(mcp)).to eq(body)
  end

  it 'answers a token limited to some projects alike' do
    limited = token(project_scopes: { organisation => [project] })
    _, body = rest(with: limited)

    expect(body['data'].flat_map { |row| row['heard'] }.pluck('form')).to eq(['Lala Bass', 'nord licht'])
    expect(mcp_data(mcp(with: limited))).to eq(body)
  end

  it 'puts the same project first on both' do
    _, body = rest(project_id: other_project.id)

    expect(body['data'].find { |row| row['term'] == 'Lalabase' }['heard'].first['form']).to eq('la la base')
    expect(mcp_data(mcp(project_id: other_project.id))).to eq(body)
  end

  it 'pages alike' do
    _, body = rest(page: 2, per_page: 2)

    expect(body['data'].pluck('term')).to eq(%w[Nordlicht])
    expect(mcp_data(mcp(page: 2, per_page: 2))).to eq(body)
  end

  it 'names nobody on either without the people right' do
    glossary_only = token(owner: gustav)
    _, body = rest(with: glossary_only)

    expect(body['people']).to eq([])
    expect(mcp_data(mcp(with: glossary_only))).to eq(body)
  end

  it 'refuses an owner without the glossary right on both with the reason glossary_forbidden and one text' do
    refused = token(owner: nobody)
    status, body = rest(with: refused)
    result = mcp(with: refused)

    expect(status).to eq(403)
    expect(body).to include('code' => 'forbidden', 'reason' => 'glossary_forbidden')
    expect(result['_meta']).to eq('lalabase/code' => 'refused', 'lalabase/reason' => 'glossary_forbidden')
    expect(result.dig('content', 0, 'text')).to eq(body['message'])
  end

  it 'answers an organisation outside the token and a project outside it as not found on both' do
    outside_status, = rest(organisation_id: other_organisation.id)
    outside = mcp(organisation_id: other_organisation.id)
    project_status, = rest(with: token(project_scopes: { organisation => [project] }), project_id: other_project.id)
    project_result = mcp(with: token(project_scopes: { organisation => [project] }), project_id: other_project.id)

    expect([outside_status, project_status]).to eq([404, 404])
    expect([outside['_meta'], project_result['_meta']]).to all(eq('lalabase/code' => 'not_found'))
  end

  it 'refuses a page value outside its bounds as invalid input on both' do
    status, body = rest(per_page: 101)
    result = mcp(per_page: 101)

    expect([status, body['code']]).to eq([400, 'invalid_input'])
    expect(result['_meta']).to eq('lalabase/code' => 'invalid_input')
  end
end
