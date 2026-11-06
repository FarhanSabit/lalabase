# frozen_string_literal: true

require 'rails_helper'

# What: list_organisations and list_projects through /api/mcp: what a token sees, and
#       that what it sees opens.
# Why: The list is worth nothing if an id it names answers not_found on the next call.
#      Two owners decide here (PersonalAccessTokens::ReachListing lists, Mcp::ToolCall
#      gates), so this spec walks every listed id through the real gate, an archived
#      project of an admin included. The reach below repeats the matrix of the project
#      gate (mcp_project_reach_spec.rb), since a token-scoped tool passes no gate at all.
RSpec.describe 'MCP list_organisations and list_projects', :ci_guard, type: :request do
  let(:user) { create(:user) }
  let(:organisation) { create(:organisation, name: 'Nordlicht GmbH') }
  let(:other_organisation) { create(:organisation, name: 'Atlas AG') }
  let(:outside_organisation) { create(:organisation) }
  let(:granted) { project_in(organisation, name: 'Website') }
  let(:second) { project_in(organisation, name: 'Intern') }
  let(:other_granted) { project_in(other_organisation, name: 'Handbuch') }

  before do
    Prosopite.pause do
      make_token_owner_a_member(user, organisation, projects: [granted, second])
      make_token_owner_a_member(user, other_organisation, projects: [other_granted])
    end
  end

  def project_in(org, **attributes)
    ActsAsTenant.with_tenant(org) { create(:project, organisation: org, **attributes) }
  end

  def token_for(owner: user, **attributes)
    build(:personal_access_token, user: owner, **attributes).tap do |pat|
      pat.token_hash = nil
      pat.token_prefix = nil
      pat.generate_token!
    end
  end

  def call_tool(pat, name, **arguments)
    post '/api/mcp', params: { jsonrpc: '2.0', id: 1, method: 'tools/call',
                               params: { name: name, arguments: arguments } }.to_json,
                     headers: { 'Authorization' => "Bearer #{pat.token}", 'CONTENT_TYPE' => 'application/json' }
    response.parsed_body['result']
  end

  def rows(result)
    JSON.parse(result.dig('content', 0, 'text'))['data']
  end

  def code(result) = result.dig('_meta', 'lalabase/code')

  def make_admin(org)
    ActsAsTenant.with_tenant(org) do
      Membership.find_by!(user: user, organisation: org).update!(role: create(:admin_role, organisation: org))
    end
  end

  describe 'tools/list' do
    it 'offers both after the pinned tools, so the order of every tool before them holds' do
      pat = token_for(organisations: [organisation])
      post '/api/mcp', params: { jsonrpc: '2.0', id: 1, method: 'tools/list' }.to_json,
                       headers: { 'Authorization' => "Bearer #{pat.token}", 'CONTENT_TYPE' => 'application/json' }

      expect(response.parsed_body.dig('result', 'tools').pluck('name').last(5))
        .to eq(%w[list_organisations list_projects create_meeting get_meeting get_glossary])
    end

    it 'points the project_id of a project tool at list_projects' do
      pat = token_for(organisations: [organisation])
      post '/api/mcp', params: { jsonrpc: '2.0', id: 1, method: 'tools/list' }.to_json,
                       headers: { 'Authorization' => "Bearer #{pat.token}", 'CONTENT_TYPE' => 'application/json' }

      list_tickets = response.parsed_body.dig('result', 'tools').find { |tool| tool['name'] == 'list_tickets' }
      expect(list_tickets.dig('inputSchema', 'properties', 'project_id', 'description')).to match(/list_projects/)
    end
  end

  describe 'the reach of a token' do
    it 'shows every project of the organisations of an all-projects token' do
      pat = token_for(organisations: [organisation, other_organisation])

      expect(rows(call_tool(pat, 'list_organisations')).pluck('name')).to eq(['Atlas AG', 'Nordlicht GmbH'])
      expect(rows(call_tool(pat, 'list_projects')).pluck('id')).to eq([other_granted.id, second.id, granted.id])
    end

    it 'shows only the linked projects of a limited token, and says so' do
      pat = token_for(organisations: [organisation], project_scopes: { organisation => [granted] })

      expect(rows(call_tool(pat, 'list_organisations')).first['scope']).to eq('selected_projects')
      expect(rows(call_tool(pat, 'list_projects')).pluck('id')).to eq([granted.id])
    end

    it 'shows nothing to a limited token whose links are gone, never the whole organisation' do
      pat = token_for(organisations: [organisation], project_scopes: { organisation => [granted] })
      pat.personal_access_token_projects.delete_all

      expect(rows(call_tool(pat, 'list_projects'))).to eq([])
    end

    it 'covers every membership of an all-organisations token' do
      pat = token_for(all_organisations: true)

      expect(rows(call_tool(pat, 'list_organisations')).pluck('id')).to eq([other_organisation.id, organisation.id])
      expect(rows(call_tool(pat, 'list_projects')).size).to eq(3)
    end

    it 'stops at a deactivated membership' do
      pat = token_for(organisations: [organisation, other_organisation])
      Membership.find_by!(user: user, organisation: organisation).update!(active: false)

      expect(rows(call_tool(pat, 'list_organisations')).pluck('id')).to eq([other_organisation.id])
      expect(rows(call_tool(pat, 'list_projects')).pluck('id')).to eq([other_granted.id])
      expect(code(call_tool(pat, 'list_projects', organisation_id: organisation.id))).to eq('not_found')
    end

    it 'shows no project of an organisation outside the token' do
      pat = token_for(organisations: [organisation])

      expect(rows(call_tool(pat, 'list_projects')).pluck('id')).not_to include(other_granted.id)
      expect(code(call_tool(pat, 'list_projects', organisation_id: other_organisation.id))).to eq('not_found')
    end

    it 'does not widen the owner: an all-projects token shows what its owner may read' do
      hidden = project_in(organisation, name: 'Vertraulich')
      pat = token_for(organisations: [organisation])

      expect(rows(call_tool(pat, 'list_projects')).pluck('id')).not_to include(hidden.id)
    end

    it 'answers an empty list, not a refusal, to a member without a project' do
      stranger = create(:user)
      make_token_owner_a_member(stranger, organisation)
      result = call_tool(token_for(owner: stranger, organisations: [organisation]), 'list_projects')

      expect(result['isError']).not_to be true
      expect(rows(result)).to eq([])
    end
  end

  describe 'refusals carry the machine field' do
    let(:pat) { token_for(organisations: [organisation]) }

    it 'answers invalid_input for an organisation_id that is no UUID' do
      expect(code(call_tool(pat, 'list_projects', organisation_id: 'oops'))).to eq('invalid_input')
    end

    it 'answers invalid_input for per_page 0' do
      expect(code(call_tool(pat, 'list_projects', per_page: 0))).to eq('invalid_input')
    end

    it 'answers invalid_input for an argument of the wrong type, before the tool runs' do
      expect(code(call_tool(pat, 'list_projects', include_archived: 'yes'))).to eq('invalid_input')
    end
  end

  it 'runs for a read-only token: both are reads' do
    pat = token_for(organisations: [organisation], read_only: true)

    expect(call_tool(pat, 'list_organisations')['isError']).not_to be true
    expect(call_tool(pat, 'list_projects')['isError']).not_to be true
  end

  describe 'the list and the gate agree' do
    def expect_every_listed_id_to_open(pat, **arguments)
      ids = rows(call_tool(pat, 'list_projects', **arguments)).pluck('id')

      expect(ids).not_to be_empty
      # Paused: one list_tickets per id repeats its reads, which is this walk and not a request.
      Prosopite.pause do
        ids.each do |id|
          expect(call_tool(pat, 'list_tickets', project_id: id)['isError']).not_to be(true), "#{id} did not open"
        end
      end
      ids
    end

    it 'opens every project of an all-projects token' do
      expect_every_listed_id_to_open(token_for(organisations: [organisation, other_organisation]))
    end

    it 'opens every project of a limited token' do
      pat = token_for(organisations: [organisation], project_scopes: { organisation => [granted] })

      expect_every_listed_id_to_open(pat)
    end

    it 'opens an archived project an admin asks for' do
      make_admin(organisation)
      archived = project_in(organisation, name: 'Altbestand', archived_at: 1.day.ago)
      pat = token_for(organisations: [organisation])

      expect(expect_every_listed_id_to_open(pat, include_archived: true)).to include(archived.id)
    end

    it 'names no project a role reaches through time tracking alone, which the gate refuses' do
      stranger = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        role = create(:role, organisation: organisation)
        create(:permission, role: role, category: 'projects', action: 'read_access_time_tracking_all_projects')
        create(:membership, user: stranger, organisation: organisation, role: role, active: true)
      end
      pat = token_for(owner: stranger, organisations: [organisation])

      expect(rows(call_tool(pat, 'list_projects'))).to eq([])
      expect(code(call_tool(pat, 'list_tickets', project_id: granted.id))).to eq('not_found')
    end

    it 'names no archived project to anybody else, so nothing listed fails to open' do
      archived = project_in(organisation, name: 'Altbestand', archived_at: 1.day.ago)
      pat = token_for(organisations: [organisation])

      expect(expect_every_listed_id_to_open(pat, include_archived: true)).not_to include(archived.id)
    end
  end
end
