# frozen_string_literal: true

require 'rails_helper'

# The search of the ticket list (`q`) must not match the text of a private
# comment the reader may not read. Both surfaces share Tickets::Filter: REST
# GET /api/v1/projects/:id/tickets and the MCP tool list_tickets.
#
# Until 2026-11-05 the search ran a pg_search scope that joined every
# comment of the ticket and never asked Post.readable_by. A hidden private
# comment made its ticket a hit, and with prefix matching its words could be
# guessed one letter at a time. The post-visibility guard did not see it: the
# join was declared in a pg_search_scope, with no `.posts` in the code.
RSpec.describe 'Ticket list search and private comments', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:reader) { create(:user) }
  let(:author) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  let(:secret_word) { 'Zebrafinanzgeheimnis' }

  before do
    ActsAsTenant.with_tenant(organisation) do
      [reader, author].each do |user|
        create(:membership, user: user, organisation: organisation, role: role, active: true)
        create(:project_permission, user: user, project: project, tickets_access: :read_write)
      end
    end
  end

  let(:pat) do
    token = build(:personal_access_token, user: reader, organisations: [organisation])
    token.token_hash = nil
    token.token_prefix = nil
    token.generate_token!
    token
  end

  # A ticket the reader can read, carrying a private comment addressed to its
  # author only: the reader may read the ticket but not that comment.
  let!(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      ticket = create(:ticket, project: project, organisation: organisation, creator: author,
                               title: 'Harmloser Titel', content: 'Eine Beschreibung mit Ananaskuchen')
      comment = create(:post, ticket: ticket, user: author, organisation: organisation, is_private: true,
                              visible_to_user: author, content: secret_word)
      expect(comment.reload.plain_text_version).to include(secret_word)
      expect(comment.readable_by?(reader)).to be(false)
      ticket
    end
  end

  def rest_ids(query)
    get "/api/v1/projects/#{project.id}/tickets", params: { q: query },
                                                  headers: { 'Authorization' => "Bearer #{pat.token}" }
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body).fetch('data').map { |row| row['id'] }
  end

  def mcp_ids(query)
    body = { jsonrpc: '2.0', id: 1, method: 'tools/call',
             params: { name: 'list_tickets', arguments: { project_id: project.id, q: query } } }.to_json
    post '/api/mcp', params: body,
                     headers: { 'Authorization' => "Bearer #{pat.token}", 'CONTENT_TYPE' => 'application/json' }
    expect(response).to have_http_status(:ok)
    result = JSON.parse(response.body).fetch('result')
    expect(result['isError']).to be_falsey
    JSON.parse(result.dig('content', 0, 'text')).fetch('data').map { |row| row['id'] }
  end

  # A pg_search join cannot ask Post.readable_by, so no search scope may join
  # comments. Read from the declarations, not from one scope: a second scope
  # with the same join would leak through whichever caller picks it. A search
  # over readable comments joins them itself (TicketSearchQuery).
  it 'no pg_search scope in app/models joins comments' do
    offenders = Rails.root.glob('app/models/**/*.rb').flat_map do |path|
      source = path.read.lines.reject { |line| line.lstrip.start_with?('#') }.join
      source.scan(/pg_search_scope\s+:\w+.*?(?=\n\s*\n|\z)/m)
            .select { |declaration| declaration.match?(/associated_against:\s*\{[^}]*\bposts\b/m) }
            .map { |declaration| "#{path.relative_path_from(Rails.root)}: #{declaration.lines.first.strip}" }
    end
    expect(offenders).to be_empty
  end

  %i[rest_ids mcp_ids].each do |surface|
    describe "via #{surface == :rest_ids ? 'REST' : 'MCP'}" do
      # The search works: the same ticket is a hit by its title and its
      # description, so an empty answer below is about the comment.
      it 'finds the ticket by its title and by its description' do
        expect(send(surface, 'Harmloser')).to eq([ticket.id])
        expect(send(surface, 'Ananaskuchen')).to eq([ticket.id])
      end

      it 'does not find the ticket by a word only a hidden private comment holds' do
        expect(send(surface, secret_word)).to be_empty
      end

      it 'does not find it by a prefix of that word either' do
        expect(send(surface, secret_word.first(6))).to be_empty
      end
    end
  end
end
