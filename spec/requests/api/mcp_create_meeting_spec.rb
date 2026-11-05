# frozen_string_literal: true

require 'rails_helper'

# What: create_meeting over POST /api/mcp, by the rule of POST /api/v1/organisations/:id/meetings
#   (Meetings::Intake), token-scoped because the project may be missing.
# Why: the same refusals on both surfaces, or a program learns one rule and hits another;
#   a token-scoped tool has no project gate, so the tool itself is the gate.
RSpec.describe 'MCP create_meeting', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { ActsAsTenant.with_tenant(organisation) { create(:role, organisation: organisation) } }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      create(:project_permission, user: user, project: project, meetings_access: :read_write)
    end
  end

  def build_pat(read_only: false)
    build(:personal_access_token, user: user, organisations: [organisation], read_only: read_only).tap do |pat|
      pat.token_hash = nil
      pat.token_prefix = nil
      pat.generate_token!
      pat.save!
    end
  end

  def call_tool(arguments, token: build_pat)
    post '/api/mcp', params: { jsonrpc: '2.0', id: 1, method: 'tools/call',
                               params: { name: 'create_meeting', arguments: arguments } }.to_json,
                     headers: { 'Authorization' => "Bearer #{token.token}", 'Content-Type' => 'application/json' }
    response.parsed_body['result']
  end

  def args(**overrides)
    { organisation_id: organisation.id, title: 'Abstimmung', occurred_at: '2026-11-01T10:00:00+01:00',
      transcript: "Erika: Guten Tag.\n" }.merge(overrides)
  end

  def meeting_count = ActsAsTenant.with_tenant(organisation) { Meeting.count }

  it 'creates a meeting in the named project, without the transcript in the answer' do
    result = call_tool(args(project_id: project.id))

    expect(result['isError']).to be_falsey
    text = result['content'].first['text']
    expect(JSON.parse(text)).to include('project_id' => project.id)
    expect(text).not_to include('Guten Tag')
    expect(meeting_count).to eq(1)
  end

  it 'creates a meeting in the inbox without a project' do
    organisation.update!(meeting_inbox_project: project)

    result = call_tool(args)

    expect(JSON.parse(result['content'].first['text'])).to include('in_meeting_inbox' => true)
  end

  it 'names the refusal when there is no inbox' do
    result = call_tool(args)

    expect(result['isError']).to be(true)
    expect(result['_meta'].values).to include('refused', 'meeting_inbox_missing')
    expect(meeting_count).to eq(0)
  end

  it 'refuses without the write right' do
    ActsAsTenant.with_tenant(organisation) do
      ProjectPermission.find_by!(user: user, project: project).update!(meetings_access: :read_only)
    end

    result = call_tool(args(project_id: project.id))

    expect(result['isError']).to be(true)
    expect(meeting_count).to eq(0)
  end

  it 'refuses an organisation outside the token' do
    result = call_tool(args(organisation_id: create(:organisation).id))

    expect(result['isError']).to be(true)
    expect(result['_meta'].values).to include('not_found')
  end

  it 'refuses a read-only token' do
    result = call_tool(args(project_id: project.id), token: build_pat(read_only: true))

    expect(result['isError']).to be(true)
    expect(meeting_count).to eq(0)
  end

  it 'creates one meeting for a repeated key' do
    token = build_pat
    2.times { call_tool(args(project_id: project.id, idempotency_key: 'aufnahme-1'), token: token) }

    expect(meeting_count).to eq(1)
  end

  # In dev and test the actor re-raises an unexpected error; in production it
  # returns it with its message, which may name the database. Stubbed to pin the
  # production branch: the tool answers a fixed text.
  it 'answers an unexpected failure with a fixed text, not the exception message' do
    failure = Actors::BaseActor::Result.new(
      success: false, errors: ['PG::UniqueViolation: duplicate key value violates unique constraint "meetings_pkey"'],
      code: :internal_error
    )
    allow_any_instance_of(Actors::SaveMeeting).to receive(:call).and_return(failure)

    result = call_tool(args(project_id: project.id))

    expect(result['isError']).to be(true)
    expect(result['content'].first['text']).to eq('create failed: unexpected error')
  end
end
