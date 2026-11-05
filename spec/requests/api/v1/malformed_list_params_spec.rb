# frozen_string_literal: true

require 'rails_helper'

# What: list parameters a client can type that used to answer a 500 on /api/v1.
# Type: Request spec.
# Why:  Found in the API review of 2026-11-05. Each of these raised past the
#       controller: a page whose offset leaves PostgreSQL's bigint, a page sent
#       as a list (`page[]=1`, `.to_i` on an Array), a date bound with a year
#       PostgreSQL cannot store, the search together with a tag filter (GROUP BY
#       against the search's rank column), and a time session that is a string
#       instead of an object. Each is an answer now: 400 for what is malformed,
#       the list for what is merely unusable, as the list always treated it.
RSpec.describe 'API V1 malformed list parameters', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let!(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: user, title: 'Login bricht ab')
    end
  end
  let(:pat) do
    pat = build(:personal_access_token, user: user, organisations: [organisation], read_only: false)
    pat.token_hash = nil
    pat.token_prefix = nil
    pat.generate_token!
    pat
  end
  let(:headers) { { 'Authorization' => "Bearer #{pat.token}" } }

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      create(:project_permission, user: user, project: project, tickets_access: :read_write)
      create(:time_session_permission, user: user, project: project, can_create_own: true, can_view_own: true)
    end
  end

  def body
    JSON.parse(response.body)
  end

  def expect_bad_request
    expect(response).to have_http_status(:bad_request)
    expect(body['error']).to eq('bad_request')
    expect(body['code']).to eq('invalid_input')
  end

  describe 'GET /api/v1/projects/:project_id/tickets' do
    let(:path) { "/api/v1/projects/#{project.id}/tickets" }

    it 'answers the search together with a tag filter' do
      ActsAsTenant.with_tenant(organisation) do
        tag = create(:tag, name: 'bug', organisation: organisation)
        create(:tagging, tag: tag, taggable: ticket)
      end
      get path, params: { q: 'Login', tag: 'bug' }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(body['data'].map { |row| row['id'] }).to eq([ticket.id])
      expect(body.dig('meta', 'total')).to eq(1)
    end

    it 'ignores a date bound PostgreSQL cannot store' do
      get path, params: { from: '999999999-01-01' }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(body['data'].map { |row| row['id'] }).to eq([ticket.id])
    end

    it 'refuses a page no list has' do
      get path, params: { page: '99999999999999999999' }, headers: headers
      expect_bad_request
    end

    it 'refuses a page sent as a list' do
      get "#{path}?page[]=1", headers: headers
      expect_bad_request
    end
  end

  describe 'GET /api/v1/tickets/:ticket_id/time_sessions' do
    let(:path) { "/api/v1/tickets/#{ticket.id}/time_sessions" }

    it 'still pages with a usable value' do
      get path, params: { page: '2', per_page: '5' }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(body['meta']).to include('page' => 2, 'per_page' => 5)
    end

    it 'refuses a page no list has' do
      get path, params: { page: '99999999999999999999' }, headers: headers
      expect_bad_request
    end

    it 'refuses a per_page sent as a hash' do
      get "#{path}?per_page[x]=1", headers: headers
      expect_bad_request
    end
  end

  describe 'GET /api/v1/time_sessions/open' do
    it 'refuses a page no list has' do
      get '/api/v1/time_sessions/open', params: { page: '99999999999999999999' }, headers: headers
      expect_bad_request
    end

    it 'refuses a page sent as a list' do
      get '/api/v1/time_sessions/open?page[]=1', headers: headers
      expect_bad_request
    end
  end

  describe 'POST /api/v1/tickets/:ticket_id/time_sessions' do
    ['x', ['a'], 30].each do |value|
      it "refuses a time_session that is #{value.inspect}, and books nothing" do
        expect do
          post "/api/v1/tickets/#{ticket.id}/time_sessions", params: { time_session: value }.to_json,
                                                             headers: headers.merge('CONTENT_TYPE' => 'application/json')
        end.not_to(change { ActsAsTenant.without_tenant { TimeSession.count } })
        expect(response).to have_http_status(:bad_request)
        expect(body['error']).to eq('bad_request')
      end
    end
  end
end
