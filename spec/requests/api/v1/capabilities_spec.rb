# frozen_string_literal: true

require 'rails_helper'

# What: GET /api/v1/me names the API version and the abilities of this server
#   (cli_rest_plan D4), from ONE list, Api::V1::Capabilities.
# Why: a REST client decides from this list which features it offers, as the
#   terminal client decides from MCP tools/list today. A capability without a
#   route makes it offer a feature that answers 404; a route without a
#   capability stays invisible to it. Both directions are pinned here.
RSpec.describe 'API V1 capabilities', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  def token(read_only:)
    build(:personal_access_token, user: user, organisations: [organisation], read_only: read_only).tap do |pat|
      pat.token_hash = nil
      pat.token_prefix = nil
      pat.generate_token!
    end
  end

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: create(:role, organisation: organisation))
    end
  end

  def me(pat)
    get '/api/v1/me', headers: { 'Authorization' => "Bearer #{pat.token}" }
    response.parsed_body['data']
  end

  it 'names the API version and the capabilities beside the existing fields' do
    data = me(token(read_only: false))
    expect(data['api_version']).to eq('1.11.0')
    expect(data['capabilities']).to eq(Api::V1::Capabilities.names)
    expect(data.keys).to include('user', 'token', 'scoped_organisations')
  end

  it 'gives a read-only token the same list (the write right is token.read_only)' do
    expect(me(token(read_only: true))['capabilities']).to eq(me(token(read_only: false))['capabilities'])
  end

  it 'names the abilities that exist today, idempotency included' do
    expect(Api::V1::Capabilities.names).to include(
      'me.show', 'organisations.list', 'projects.list', 'tickets.list', 'tickets.create', 'tickets.show',
      'tickets.update', 'tickets.attachments', 'posts.create', 'time_sessions.create',
      'notifications.list', 'notifications.mark_as_read', 'people.list', 'people.show', 'idempotency', 'error_codes',
      'meetings.create', 'tickets.by_number', 'posts.show', 'tickets.paging', 'time_sessions.book', 'posts.plain', 'knowledge.search',
      'tickets.changes', 'meetings.list', 'meetings.show', 'terms.list'
    )
  end

  describe 'every capability and every route, both ways' do
    let(:v1_routes) do
      Rails.application.routes.routes.filter_map do |route|
        path = route.path.spec.to_s.delete_suffix('(.:format)')
        # Rails routes an update as PATCH and PUT; the capability names PATCH.
        "#{route.verb.sub(/\APUT\z/, 'PATCH')} #{path}" if path.start_with?('/api/v1/') && route.verb.present?
      end.uniq
    end

    it 'points every endpoint capability at a route that exists' do
      Api::V1::Capabilities::ENDPOINTS.each do |name, (verb, path)|
        expect(v1_routes).to include("#{verb} #{path}"), "#{name}: no route #{verb} #{path}"
      end
    end

    it 'names every /api/v1 route as a capability' do
      named = Api::V1::Capabilities::ENDPOINTS.values.map { |verb, path| "#{verb} #{path}" }
      expect(v1_routes - named).to be_empty
    end

    it 'keeps feature capabilities apart from endpoints' do
      expect(Api::V1::Capabilities::FEATURES & Api::V1::Capabilities::ENDPOINTS.keys).to be_empty
    end
  end
end
