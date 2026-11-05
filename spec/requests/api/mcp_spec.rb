# frozen_string_literal: true

require 'rails_helper'

# M1 request spec for the stateless MCP endpoint (POST /api/mcp).
# Verifies: PAT auth, the JSON-RPC handshake, tools/list (incl. injected
# project_id + camelCase inputSchema), an in-scope tools/call, and that an
# out-of-scope project is reported exactly like a missing one (no leak).
RSpec.describe 'API MCP endpoint', type: :request do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  let(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  let!(:capability) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_capability, project: project, organisation: organisation, name: 'Billing')
    end
  end

  # A project the token is NOT scoped to (different org).
  let(:foreign_project) do
    ActsAsTenant.with_tenant(other_organisation) { create(:project, organisation: other_organisation) }
  end

  def build_pat(read_only:)
    token = build(:personal_access_token, user: user, organisations: [organisation], read_only: read_only)
    token.token_hash = nil
    token.token_prefix = nil
    token.generate_token!
    token
  end

  # Default token is read-only (the column default) — fine for the read tools.
  let(:pat) { build_pat(read_only: true) }
  # Writable token for the write-tool examples.
  let(:write_pat) { build_pat(read_only: false) }

  def auth_headers(token = pat.token)
    { 'Authorization' => "Bearer #{token}", 'CONTENT_TYPE' => 'application/json' }
  end

  def rpc(method, params = {}, id: 1)
    { jsonrpc: '2.0', id: id, method: method, params: params }.to_json
  end

  def post_mcp(body, headers: auth_headers)
    post '/api/mcp', params: body, headers: headers
    response.body.present? ? JSON.parse(response.body) : nil
  end

  # tools/call helpers: return the JSON-RPC `result` object, or parse the tool's
  # text content as JSON (the ticket tools emit a JSON document as their text).
  def tool_result(name, arguments)
    post_mcp(rpc('tools/call', { name: name, arguments: arguments }))['result']
  end

  def tool_json(name, arguments)
    JSON.parse(tool_result(name, arguments).dig('content', 0, 'text'))
  end

  # Same as tool_result/tool_json but authenticated as a specific PAT object.
  def tool_result_as(pat_record, name, arguments)
    post_mcp(rpc('tools/call', { name: name, arguments: arguments }),
             headers: auth_headers(pat_record.token))['result']
  end

  # The code tools (list_capabilities & co.) also need the owner's repository
  # rights, not just the token scope (see 'code tools and the owner's
  # repository rights').
  def grant_code_read!
    ActsAsTenant.with_tenant(organisation) do
      create(:project_repository, project: project)
      project_permission.update!(chats_access: :read_only)
    end
  end

  def tool_json_as(pat_record, name, arguments)
    JSON.parse(tool_result_as(pat_record, name, arguments).dig('content', 0, 'text'))
  end

  # Counts tenant-scoped records from the tenant-less test thread (the request
  # sets + resets the tenant internally, so a bare Ticket.count would raise).
  def count_without_tenant(model)
    ActsAsTenant.without_tenant { model.count }
  end

  describe 'authentication' do
    it 'returns 401 without an Authorization header' do
      post '/api/mcp', params: rpc('tools/list'), headers: { 'CONTENT_TYPE' => 'application/json' }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns 401 for an invalid bearer token' do
      post '/api/mcp', params: rpc('tools/list'),
                       headers: { 'Authorization' => 'Bearer lalab_pat_nope', 'CONTENT_TYPE' => 'application/json' }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'initialize handshake' do
    it 'negotiates a protocol version' do
      body = post_mcp(rpc('initialize', {
                            protocolVersion: '2025-06-18',
                            capabilities: {},
                            clientInfo: { name: 'rspec', version: '0' }
                          }))
      expect(response).to have_http_status(:ok)
      expect(body.dig('result', 'protocolVersion')).to be_present
    end

    # Pins the advertised server identity (M4). The version is the MCP SURFACE
    # version (Dispatcher::SERVER_VERSION), independent of the app version, and
    # evolves additive-only — bump it when adding tools/fields, never break args.
    it 'advertises the lalabase server identity + version' do
      body = post_mcp(rpc('initialize', {
                            protocolVersion: '2025-06-18', capabilities: {},
                            clientInfo: { name: 'rspec', version: '0' }
                          }))
      expect(body.dig('result', 'serverInfo', 'name')).to eq('lalabase')
      expect(body.dig('result', 'serverInfo', 'version')).to eq(Mcp::Dispatcher::SERVER_VERSION)
    end
  end

  # The JSON-RPC error codes are part of the wire contract MCP clients rely on.
  # Pinning them guards against a silent change on an `mcp` gem upgrade (M4).
  describe 'JSON-RPC error contract' do
    it 'returns method-not-found (-32601) for an unknown JSON-RPC method' do
      body = post_mcp(rpc('does/not/exist'))
      expect(body.dig('error', 'code')).to eq(-32_601)
    end

    it 'returns invalid-params (-32602) for an unknown tool name' do
      body = post_mcp(rpc('tools/call', { name: 'no_such_tool', arguments: { project_id: project.id } }))
      expect(body.dig('error', 'code')).to eq(-32_602)
    end

    it 'reports a tool input-validation failure as a clean tool error, not a protocol error' do
      # Missing the required project_id: the SDK validates against the inputSchema
      # and returns an isError tool result (not a JSON-RPC error), so the client
      # sees a recoverable tool failure rather than a transport-level fault.
      body = post_mcp(rpc('tools/call', { name: 'list_capabilities', arguments: {} }))
      expect(body).not_to have_key('error')
      expect(body.dig('result', 'isError')).to be true
    end
  end

  describe 'tools/list' do
    it 'advertises the read tools with project_id injected and camelCase inputSchema' do
      body = post_mcp(rpc('tools/list'))
      tools = body.dig('result', 'tools')
      names = tools.map { |t| t['name'] }

      expect(names).to include('list_capabilities', 'search_code_symbols', 'get_project_vision')

      list_cap = tools.find { |t| t['name'] == 'list_capabilities' }
      expect(list_cap).to have_key('inputSchema') # SDK emits camelCase on the wire
      expect(list_cap).not_to have_key('input_schema')
      expect(list_cap.dig('inputSchema', 'properties')).to have_key('project_id')
      expect(list_cap.dig('inputSchema', 'required')).to include('project_id')
    end

    it 'advertises project_id as optional on a token-scoped tool that reads it (list_notifications)' do
      tools = post_mcp(rpc('tools/list')).dig('result', 'tools')
      tool = tools.find { |t| t['name'] == 'list_notifications' }
      expect(tool.dig('inputSchema', 'properties')).to have_key('project_id')
      expect(Array(tool.dig('inputSchema', 'required'))).not_to include('project_id')
    end

    it 'does not advertise project_id on a token-scoped tool that addresses one row (mark_notification_read)' do
      tools = post_mcp(rpc('tools/list')).dig('result', 'tools')
      tool = tools.find { |t| t['name'] == 'mark_notification_read' }
      expect(tool.dig('inputSchema', 'properties')).not_to have_key('project_id')
      expect(tool.dig('inputSchema', 'required')).to eq(['notification_id'])
    end

    # The idempotency key is injected by mutating?, independent of the scope
    # mode: nesting that block into the project branch would drop it from the
    # token-scoped write without any call failing (the SDK accepts the argument).
    it 'advertises idempotency_key on the token-scoped write and not on the token-scoped read' do
      tools = post_mcp(rpc('tools/list')).dig('result', 'tools')
      mark = tools.find { |t| t['name'] == 'mark_notification_read' }
      list = tools.find { |t| t['name'] == 'list_notifications' }
      expect(mark.dig('inputSchema', 'properties')).to have_key('idempotency_key')
      expect(list.dig('inputSchema', 'properties')).not_to have_key('idempotency_key')
    end

    # Terminal client S2. The schema stays flat: the Go client detects a feature
    # by the TOP-LEVEL properties only, so the "exactly one change" rule lives in
    # the tool, not in a oneOf.
    it 'advertises update_ticket as a project-scoped write with a flat schema' do
      tools = post_mcp(rpc('tools/list')).dig('result', 'tools')
      tool = tools.find { |t| t['name'] == 'update_ticket' }
      schema = tool.fetch('inputSchema')

      expect(schema['properties'].keys).to contain_exactly('project_id', 'idempotency_key', 'ticket_id', 'title',
                                                           'status', 'add_assignee_ids', 'remove_assignee_ids')
      expect(schema['required']).to contain_exactly('project_id', 'ticket_id')
      expect(schema.keys & %w[oneOf anyOf allOf]).to be_empty
    end
  end

  # ------------------------------------------------------------------
  # Inbox workflow S1 (doc/mcp_inbox_workflow_plan.md): the token-scoped inbox
  # ------------------------------------------------------------------

  describe 'tools/call list_notifications' do
    let(:inbox_ticket) do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: user)
      end
    end
    let!(:mine) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, :ticket_commented, recipient: user, organisation: organisation,
                                                 notifiable: inbox_ticket, project: project, state: 'queued')
      end
    end
    let!(:foreign) do
      ActsAsTenant.with_tenant(other_organisation) do
        create(:notification, recipient: user, organisation: other_organisation, state: 'queued')
      end
    end

    it 'lists the inbox without a project_id, within the token reach, over the read-only token' do
      body = tool_json('list_notifications', {})
      expect(body['data'].map { |r| r['id'] }).to eq([mine.id])
      expect(body['data'].first['ticket']).to include('id' => inbox_ticket.id, 'project_id' => project.id)
      expect(body['meta']).to include('unread_total' => 1)
    end

    it 'narrows to a project with the optional project_id' do
      expect(tool_json('list_notifications', { project_id: project.id })['data'].size).to eq(1)
    end

    it 'reports a project outside the token scope as not found, without leaking it' do
      result = tool_result('list_notifications', { project_id: foreign_project.id })
      expect(result['isError']).to be true
      expect(result.dig('content', 0, 'text')).to eq('Project not found or not accessible.')
    end

    it 'reports an unusable since as a clean tool error, not a protocol error' do
      result = tool_result('list_notifications', { since: 'gestern' })
      expect(result['isError']).to be true
      expect(result.dig('content', 0, 'text')).to match(/since/)
    end
  end

  # The seam's contracts (D3, D7, D9) were only ever exercised in project mode.
  # A refactoring that ties any of them to `project` would disarm all token-scoped
  # tools without a red test; these pin them on the token path.
  describe 'token-scoped seam (inbox workflow)' do
    def inbox_row
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation, state: 'queued')
      end
    end

    it 'applies the idempotency contract to a token-scoped write: remembers the key, refuses it with other args (D9)' do
      first = inbox_row
      second = inbox_row
      args = { notification_id: first.id, idempotency_key: 'inbox-1' }
      expect { tool_result_as(write_pat, 'mark_notification_read', args) }.to change(McpIdempotencyKey, :count).by(1)

      result = tool_result_as(write_pat, 'mark_notification_read', args.merge(notification_id: second.id))
      expect(result['isError']).to be true
      expect(result.dig('content', 0, 'text')).to match(/different parameters/i)
      expect(second.reload.state).to eq('queued')
    end

    describe 'D7 tripwire in token mode' do
      let(:broken_token_tool) do
        Class.new(Lalabase::Tools::Base) do
          def self.tool_name = 'broken_token_tool'
          def self.description = 'Test-only token-scoped record tool that forgets to authorize.'
          def self.input_schema = { type: 'object', properties: {}, required: [] }
          def self.scope_mode = :token
          def self.requires_actor? = true
          def self.authorization_mode = :record
          def self.execute(**) = Lalabase::Tools::Result.new(content: 'served without authorizing')
        end
      end

      before { stub_const('Mcp::Dispatcher::TOOLS', Mcp::Dispatcher::TOOLS + [broken_token_tool]) }

      it 'raises a JSON-RPC internal error (-32603) when a token-scoped record-mode tool skips authorize!' do
        body = post_mcp(rpc('tools/call', { name: 'broken_token_tool', arguments: {} }))
        expect(body.dig('error', 'code')).to eq(-32_603)
        expect(body).not_to have_key('result')
      end

      # The gem's default exception reporter is a no-op and the controller
      # answers 200 with the error body: without config/initializers/mcp.rb an
      # internal error on this surface leaves no server-side trace.
      it 'reports the internal error to Rails.error, so a -32603 leaves a server-side trace' do
        allow(Rails.error).to receive(:report).and_call_original
        post_mcp(rpc('tools/call', { name: 'broken_token_tool', arguments: {} }))
        expect(Rails.error).to have_received(:report)
          .with(instance_of(Mcp::ToolCall::AuthorizationNotPerformedError), hash_including(source: 'mcp'))
      end
    end
  end

  describe 'tools/call create_time_session (inbox workflow S2)' do
    let!(:time_session_permission) do
      ActsAsTenant.with_tenant(organisation) do
        TimeSessionPermission.create!(user: user, project: project, can_create_own: true)
      end
    end
    let(:booking) { { project_id: project.id, ticket_id: ticket.id, duration: '1:30', description: 'Fehler eingegrenzt' } }

    it 'books time on the ticket through the actor and returns the row the HTTP API returns' do
      payload = nil
      expect { payload = tool_json_as(write_pat, 'create_time_session', booking) }
        .to change { count_without_tenant(TimeSession) }.by(1)

      expect(payload).to include('ticket_id' => ticket.id, 'duration_minutes' => 90,
                                 'description' => 'Fehler eingegrenzt', 'billed' => false)
      expect(payload.dig('creator', 'id')).to eq(user.id)
      expect(payload.keys).to contain_exactly(
        'id', 'ticket_id', 'creator', 'occurred_on', 'duration_minutes', 'description',
        'customer_description', 'billed', 'billed_at', 'created_at'
      )
    end

    it 'is denied for a read-only token (D3 gate), booking nothing' do
      result = nil
      expect { result = tool_result('create_time_session', booking) }
        .not_to(change { count_without_tenant(TimeSession) })
      expect(result['isError']).to be true
      expect(result.dig('content', 0, 'text')).to match(/read-only/i)
    end

    it 'is denied without the project time permission, booking nothing' do
      time_session_permission.destroy
      result = nil
      expect { result = tool_result_as(write_pat, 'create_time_session', booking) }
        .not_to(change { count_without_tenant(TimeSession) })
      expect(result['isError']).to be true
      expect(result.dig('content', 0, 'text')).to eq('Not authorized.')
    end

    it 'replays the first booking for a repeated idempotency_key instead of booking twice (D9)' do
      args = booking.merge(idempotency_key: 'buchung-1')
      first = second = nil
      expect do
        first = tool_json_as(write_pat, 'create_time_session', args)
        second = tool_json_as(write_pat, 'create_time_session', args)
      end.to change { count_without_tenant(TimeSession) }.by(1)
      expect(second).to eq(first)
    end

    # A not-found answer performed no write and must not be pinned to the key:
    # once the ticket exists (here: created under the id the first call named),
    # the same key books instead of replaying "No ticket found" forever.
    it 'does not pin a not-found answer to the idempotency key (D9)' do
      missing = SecureRandom.uuid
      args = booking.merge(ticket_id: missing, idempotency_key: 'buchung-2')
      first = tool_result_as(write_pat, 'create_time_session', args)
      expect(first.dig('content', 0, 'text')).to match(/No ticket found/)
      expect(McpIdempotencyKey.where(personal_access_token_id: write_pat.id, idempotency_key: 'buchung-2')).to be_empty

      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, id: missing, project: project, organisation: organisation, creator: user)
      end
      expect { tool_json_as(write_pat, 'create_time_session', args) }
        .to change { count_without_tenant(TimeSession) }.by(1)
    end

    it 'names the ticket in the provenance line of a project-scoped booking (D9)' do
      allow(Rails.logger).to receive(:info).and_call_original
      tool_json_as(write_pat, 'create_time_session', booking)
      expect(Rails.logger).to have_received(:info)
        .with(/tool=create_time_session outcome=success .*org_id=#{organisation.id} project_id=#{project.id} target=#{ticket.id}/)
        .at_least(:once)
    end

    # I18n.locale is thread state the web layer assigns without restoring: the
    # actor's validation message must come in the OWNER's language whatever the
    # thread carries, and the request must leave the thread as it found it.
    it "answers a booking error in the token owner's language, whatever locale the thread carries" do
      user.update!(language_preference: 'de')
      I18n.locale = :en
      result = tool_result_as(write_pat, 'create_time_session', booking.merge(duration: '0'))
      expect(result['isError']).to be true
      expect(result.dig('content', 0, 'text')).to include('größer als 0')
      expect(I18n.locale).to eq(:en)
    ensure
      I18n.locale = I18n.default_locale
    end
  end

  describe 'tools/call mark_notification_read (inbox workflow S3)' do
    let!(:mine) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation, notifiable: ticket, state: 'queued')
      end
    end
    let!(:foreign) do
      ActsAsTenant.with_tenant(other_organisation) do
        create(:notification, recipient: user, organisation: other_organisation, state: 'queued')
      end
    end

    it 'marks the row as read over a writable token' do
      payload = tool_json_as(write_pat, 'mark_notification_read', { notification_id: mine.id })
      expect(payload).to include('id' => mine.id, 'state' => 'read')
      expect(mine.reload.state).to eq('read')
    end

    it 'is denied for a read-only token (D3 gate), leaving the row unread' do
      result = tool_result('mark_notification_read', { notification_id: mine.id })
      expect(result['isError']).to be true
      expect(result.dig('content', 0, 'text')).to match(/read-only/i)
      expect(mine.reload.state).to eq('queued')
    end

    it 'reports a row outside the token reach as not found, leaving it untouched' do
      result = tool_result_as(write_pat, 'mark_notification_read', { notification_id: foreign.id })
      expect(result['isError']).to be_falsey
      expect(result.dig('content', 0, 'text')).to match(/No notification found/)
      expect(foreign.reload.state).to eq('queued')
    end

    it 'refuses a project_id it was not offered, instead of ignoring it' do
      result = tool_result_as(write_pat, 'mark_notification_read', { notification_id: mine.id, project_id: project.id })
      expect(result['isError']).to be true
      expect(result.dig('content', 0, 'text')).to match(/project_id does not apply/)
      expect(mine.reload.state).to eq('queued')
    end

    it 'logs write provenance naming the row it addressed, since the seam has no project (D9)' do
      allow(Rails.logger).to receive(:info).and_call_original
      tool_json_as(write_pat, 'mark_notification_read', { notification_id: mine.id })
      expect(Rails.logger).to have_received(:info)
        .with(/\[MCP write\] origin=mcp tool=mark_notification_read outcome=success token_id=#{write_pat.id} .*org_id=- project_id=- target=#{mine.id}/)
        .at_least(:once)
    end

    # The provenance line is written on the failure path too, i.e. after the tool
    # refused the argument as malformed: the raw client text must not reach the
    # log (a newline would forge a second audit line), and a probe for a foreign
    # id must not read as a successful write.
    it 'keeps client text out of the provenance line and logs a probe as not_found, not success' do
      # Only the audit lines themselves: Rails' own "Parameters:" request line
      # also carries the forged text, inspect-escaped, inside its hash.
      lines = []
      allow(Rails.logger).to receive(:info) { |line| lines << line.to_s if line.to_s.start_with?('[MCP write]') }
      forged = "abc\n[MCP write] origin=mcp tool=create_ticket outcome=success token_id=0"
      tool_result_as(write_pat, 'mark_notification_read', { notification_id: forged })
      tool_result_as(write_pat, 'mark_notification_read', { notification_id: foreign.id })

      expect(lines.size).to eq(2)
      expect(lines).to include(match(/tool=mark_notification_read outcome=failure .*target=invalid\z/))
      expect(lines).to include(match(/tool=mark_notification_read outcome=not_found .*target=#{foreign.id}\z/))
      expect(lines.grep(/outcome=success/)).to be_empty
      expect(lines.join).not_to include("\n[MCP write]")
    end
  end

  describe 'tools/call' do
    it 'runs an in-scope tool and returns its content' do
      grant_code_read!
      body = post_mcp(rpc('tools/call', { name: 'list_capabilities',
                                          arguments: { project_id: project.id } }))
      result = body['result']
      expect(result['isError']).to be_falsey
      expect(result.dig('content', 0, 'text')).to include('Billing')
    end

    it 'requires project_id' do
      body = post_mcp(rpc('tools/call', { name: 'list_capabilities', arguments: {} }))
      result = body['result']
      expect(result['isError']).to be true
      expect(result.dig('content', 0, 'text')).to match(/project_id/i)
    end

    it 'reports an out-of-scope project as not found, without leaking it or its data' do
      body = post_mcp(rpc('tools/call', { name: 'list_capabilities',
                                          arguments: { project_id: foreign_project.id } }))
      result = body['result']
      expect(result['isError']).to be true
      expect(result.dig('content', 0, 'text')).to match(/not found or not accessible/i)
      expect(result.dig('content', 0, 'text')).not_to include('Billing')
    end
  end

  # The five code tools read a project's code index. Being in the token's scope
  # is not enough: the owner must also be allowed to read the repository
  # (ProjectRepositoryPolicy::Scope, the rule the assistant's org-wide path
  # uses). The tool list comes from the registry, so a sixth code tool is
  # covered without editing this spec.
  describe 'code tools and the owner\'s repository rights' do
    code_tools = Lalabase::Tools::Registry::ASSISTANT_WITH_CODE - Lalabase::Tools::Registry::ASSISTANT

    let!(:repository) do
      ActsAsTenant.with_tenant(organisation) { create(:project_repository, project: project) }
    end

    def arguments_for(tool_class)
      samples = { 'query' => 'Billing', 'qualified_name' => 'Billing', 'capability_id' => capability.id }
      required = Array(tool_class.input_schema[:required]).map(&:to_s)
      required.index_with { |key| samples.fetch(key) }.merge('project_id' => project.id)
    end

    def denied?(result)
      result['isError'] && result.dig('content', 0, 'text').match?(/not found or not accessible/i)
    end

    it 'covers the five code tools' do
      expect(code_tools.size).to eq(5)
    end

    context 'when the owner may read the repository (chats read)' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          project_permission.update!(chats_access: :read_only)
        end
      end

      code_tools.each do |tool_class|
        it "lets #{tool_class.tool_name} through" do
          expect(denied?(tool_result(tool_class.tool_name, arguments_for(tool_class)))).to be(false)
        end
      end
    end

    context 'when the owner has no right on the repository' do
      code_tools.each do |tool_class|
        it "refuses #{tool_class.tool_name}" do
          result = tool_result(tool_class.tool_name, arguments_for(tool_class))

          expect(denied?(result)).to be(true)
          expect(result.dig('content', 0, 'text')).not_to include('Billing')
        end
      end
    end

    context 'when the owner\'s membership was deactivated' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          project_permission.update!(chats_access: :read_only)
        end
        membership.update!(active: false)
      end

      code_tools.each do |tool_class|
        it "refuses #{tool_class.tool_name}" do
          expect(denied?(tool_result(tool_class.tool_name, arguments_for(tool_class)))).to be(true)
        end
      end
    end
  end

  # ------------------------------------------------------------------
  # M2b — ticket read tools
  # ------------------------------------------------------------------

  # Grants the token owner ticket read/write on `project`, so policy_scope returns
  # its tickets and TicketPolicy#show? passes (mirrors the API read-endpoint setup).
  let!(:project_permission) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_permission, user: user, project: project, tickets_access: :read_write)
    end
  end

  let!(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: user,
                      custom_attributes: { 'status' => 'open' })
    end
  end

  describe 'tools/call list_tickets' do
    it 'lists tickets the user may read, scoped to the project' do
      payload = tool_json('list_tickets', { project_id: project.id })
      expect(payload['data'].map { |t| t['id'] }).to include(ticket.id)
      expect(payload.dig('meta', 'total')).to eq(1)
    end

    it 'filters by status' do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: user,
                        custom_attributes: { 'status' => 'done' })
      end
      payload = tool_json('list_tickets', { project_id: project.id, status: 'done' })
      expect(payload['data'].map { |t| t['status'] }).to all(eq('done'))
    end

    it 'filters by assignee = me' do
      other = ActsAsTenant.with_tenant(organisation) do
        ticket.assignees << user
        create(:ticket, project: project, organisation: organisation, creator: user)
      end
      payload = tool_json('list_tickets', { project_id: project.id, assignee: 'me' })
      ids = payload['data'].map { |t| t['id'] }
      expect(ids).to include(ticket.id)
      expect(ids).not_to include(other.id)
    end

    it 'rejects a malformed assignee instead of crashing on the uuid column' do
      result = tool_result('list_tickets', { project_id: project.id, assignee: 'not-a-uuid' })
      expect(result['isError']).to be true
      expect(result.dig('content', 0, 'text')).to match(/invalid assignee/i)
    end

    # Since 27.09.2026 the seam refuses the project before the tool runs (the owner has
    # no access there at all); it used to answer with an empty list
    it 'refuses a project the user has no access to, without leaking it' do
      no_access_project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: no_access_project, organisation: organisation, creator: user, title: 'Secret plan')
      end
      result = tool_result('list_tickets', { project_id: no_access_project.id })
      expect(result['isError']).to be true
      expect(result.dig('content', 0, 'text')).to match(/not found or not accessible/i)
      expect(result.dig('content', 0, 'text')).not_to include('Secret plan')
    end
  end

  describe 'tools/call get_ticket' do
    it 'returns the full ticket as JSON for an authorized user' do
      payload = tool_json('get_ticket', { project_id: project.id, ticket_id: ticket.id })
      expect(payload['id']).to eq(ticket.id)
      expect(payload.dig('project', 'id')).to eq(project.id)
      expect(payload['posts']).to eq([])
      expect(payload['posts_total']).to eq(0)
    end

    it 'answers a ticket without read access like a missing one, without its data' do
      forbidden_project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      # Access to the project through another area: the seam lets it through, the
      # per-record check refuses the ticket
      ActsAsTenant.with_tenant(organisation) do
        create(:project_permission, user: user, project: forbidden_project, notes_access: :read_only)
      end
      forbidden_ticket = ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: forbidden_project, organisation: organisation, creator: user,
                        title: 'Confidential roadmap')
      end
      result = tool_result('get_ticket', { project_id: forbidden_project.id, ticket_id: forbidden_ticket.id })
      expect(result['isError']).to be_falsey
      expect(result.dig('content', 0, 'text')).to eq("No ticket found for #{forbidden_ticket.id}.")
      expect(result.to_json).not_to include('Confidential roadmap')
    end

    it 'returns an empty (non-error) result for a missing ticket id — and does not trip the wire' do
      result = tool_result('get_ticket', { project_id: project.id, ticket_id: SecureRandom.uuid })
      expect(result['isError']).to be_falsey
      expect(result.dig('content', 0, 'text')).to match(/no ticket found/i)
    end

    it 'rejects a non-uuid ticket id without hitting the database' do
      result = tool_result('get_ticket', { project_id: project.id, ticket_id: 'oops' })
      expect(result['isError']).to be true
      expect(result.dig('content', 0, 'text')).to match(/invalid ticket_id/i)
    end

    it 'truncates an over-long description (D9 caps)' do
      max = Lalabase::Tools::GetTicket::MAX_BODY_CHARS
      marker = Lalabase::Tools::GetTicket::TRUNCATION_MARKER
      ActsAsTenant.with_tenant(organisation) { ticket.update!(content: 'x' * (max + 500)) }

      payload = tool_json('get_ticket', { project_id: project.id, ticket_id: ticket.id })
      expect(payload['description_text']).to end_with('[truncated]')
      expect(payload['description_text'].length).to be <= max + marker.length
    end

    # S0: the number is the address users actually know. End to end here, because the
    # MCP leg has two things the service spec cannot see — the SDK validates arguments
    # against the advertised schema, and the record-mode tripwire asserts afterwards
    # that the tool authorized what it served.
    it 'fetches the same ticket by its number as by its uuid' do
      by_number = tool_json('get_ticket', { project_id: project.id, number: ticket.number.to_s })
      by_uuid   = tool_json('get_ticket', { project_id: project.id, ticket_id: ticket.id })

      expect(by_number).to eq(by_uuid)
      expect(by_number['id']).to eq(ticket.id)
    end

    it 'accepts the "#187" spelling' do
      payload = tool_json('get_ticket', { project_id: project.id, number: "##{ticket.number}" })
      expect(payload['id']).to eq(ticket.id)
    end

    it 'answers a number from another project with that project\'s ticket, not this one' do
      # Numbers restart per project, so the same number exists in both. project_id
      # decides which one is meant — the tool never searches across projects.
      sibling = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      twin = ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: sibling, organisation: organisation, creator: user, title: 'Zwilling')
      end
      expect(twin.number).to eq(ticket.number)

      payload = tool_json('get_ticket', { project_id: project.id, number: twin.number.to_s })

      expect(payload['id']).to eq(ticket.id)
      expect(payload['title']).not_to eq('Zwilling')
    end

    it 'reports an unknown number as empty, not as an error' do
      result = tool_result('get_ticket', { project_id: project.id, number: (ticket.number + 999).to_s })

      expect(result['isError']).to be_falsey
      expect(result.dig('content', 0, 'text')).to match(/no ticket found for number/i)
    end

    it 'rejects a malformed number without hitting the database' do
      result = tool_result('get_ticket', { project_id: project.id, number: 'abc' })

      expect(result['isError']).to be true
      expect(result.dig('content', 0, 'text')).to match(/invalid number/i)
    end

    it 'refuses a call that carries neither address' do
      result = tool_result('get_ticket', { project_id: project.id })

      expect(result['isError']).to be true
      expect(result.dig('content', 0, 'text')).to match(/ticket_id or number is required/i)
    end

    it 'caps the number of posts and flags truncation (D9 caps)' do
      stub_const('Tickets::Reading::MAX_POSTS', 1)
      Prosopite.pause
      ActsAsTenant.with_tenant(organisation) do
        2.times { |i| create(:post, ticket: ticket, user: user, organisation: organisation, content: "Reply #{i}") }
      end
      Prosopite.resume

      payload = tool_json('get_ticket', { project_id: project.id, ticket_id: ticket.id })
      expect(payload['posts'].size).to eq(1)
      expect(payload['posts_total']).to eq(2)
      expect(payload['posts_truncated']).to be true
    end
  end

  describe 'tools/call search_knowledge (Slice 4)' do
    let!(:note) do
      ActsAsTenant.with_tenant(organisation) do
        create(:note, project: project, organisation: organisation, title: 'Deploy Runbook')
      end
    end

    before do
      # The PAT user needs notes read access for the tool to surface the note at all.
      # A (user, project) permission already exists (the top-level project_permission
      # let!), so grant notes on it rather than inserting a duplicate.
      ActsAsTenant.with_tenant(organisation) { project_permission.update!(notes_access: 'read_only') }
    end

    it 'finds a note and returns its ready-to-paste link over a READ-ONLY PAT' do
      # Default `pat` is read-only — a read tool must still run.
      payload = tool_json('search_knowledge', { project_id: project.id, q: 'Deploy' })
      hit = payload['data'].find { |h| h['id'] == note.id }
      expect(hit['link']).to eq("lalabase://note/#{note.id}")
      expect(hit['type']).to eq('note')
    end

    it 'never returns a title from a project the user cannot read (no MCP side-door leak)' do
      secret_project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      ActsAsTenant.with_tenant(organisation) do
        create(:note, project: secret_project, organisation: organisation, title: 'Secret Title')
      end
      # Token is scoped to the org, but the user has no notes access on this project.
      result = tool_result('search_knowledge', { project_id: secret_project.id, q: 'Secret' })
      expect(result.dig('content', 0, 'text')).not_to include('Secret Title')
    end

    it 'round-trips: the returned link, rendered by the sync renderer, becomes the in-app ' \
       'link AND a resolved reference (the full author path)' do
      link = tool_json('search_knowledge', { project_id: project.id, q: 'Deploy' })['data']
             .find { |h| h['id'] == note.id }['link']

      # The doc author pastes `link` into markdown; the sync renders it with the SAME
      # renderer the DocumentationSyncJob uses, resolving it to the in-app note page.
      ActsAsTenant.with_tenant(organisation) do
        set = create(:documentation_set, project: project,
                                         project_repository: create(:project_repository, project: project, organisation: organisation))
        result = Documentation::MarkdownRenderer.new(documentation_set: set, page_path: 'guide.md')
                                                .render_with_references("[runbook](#{link})")
        expect(result.html).to include("/notes/#{note.id}")
        expect(result.references).to eq([note])
      end
    end
  end

  describe 'record-mode authorization tripwire (D7)' do
    # A deliberately broken record-mode tool: it returns a record payload but never
    # calls authorize!. The ToolCall must refuse to serve it, surfacing as -32603.
    let(:broken_tool) do
      Class.new(Lalabase::Tools::Base) do
        def self.tool_name = 'broken_record_tool'
        def self.description = 'Test-only record tool that forgets to authorize.'
        def self.input_schema = { type: 'object', properties: {}, required: [] }
        def self.authorization_mode = :record

        # Returns a successful, non-empty result without ever calling authorize! —
        # exactly the leak the D7 tripwire must catch. (** ignores args/context.)
        def self.execute(**)
          Lalabase::Tools::Result.new(content: 'served a record without authorizing')
        end
      end
    end

    it 'raises a JSON-RPC internal error (-32603) when a record-mode tool skips authorize!' do
      stub_const('Mcp::Dispatcher::TOOLS', Mcp::Dispatcher::TOOLS + [broken_tool])
      body = post_mcp(rpc('tools/call', { name: 'broken_record_tool', arguments: { project_id: project.id } }))
      expect(body.dig('error', 'code')).to eq(-32_603)
      expect(body).not_to have_key('result')
    end
  end

  describe 'read-only write gate (D3)' do
    # A test-only mutating tool. Project-mode (no per-record authorize) so the test
    # isolates the read-only gate, which runs before execute either way.
    let(:mutating_tool) do
      Class.new(Lalabase::Tools::Base) do
        def self.tool_name = 'stub_write_tool'
        def self.description = 'Test-only mutating tool.'
        def self.input_schema = { type: 'object', properties: {}, required: [] }
        def self.mutating? = true

        def self.execute(**)
          Lalabase::Tools::Result.new(content: 'wrote something')
        end
      end
    end

    before { stub_const('Mcp::Dispatcher::TOOLS', Mcp::Dispatcher::TOOLS + [mutating_tool]) }

    it 'denies a mutating tool for a read-only token (the default pat is read-only)' do
      expect(pat.read_only?).to be true # column default
      result = tool_result('stub_write_tool', { project_id: project.id })
      expect(result['isError']).to be true
      expect(result.dig('content', 0, 'text')).to match(/read-only/i)
    end

    it 'lets the same mutating tool run for a writable (read_only=false) token' do
      result = tool_result_as(write_pat, 'stub_write_tool', { project_id: project.id })
      expect(result['isError']).to be_falsey
      expect(result.dig('content', 0, 'text')).to include('wrote something')
    end

    it 'never blocks read tools, even for a read-only token' do
      grant_code_read!
      result = tool_result('list_capabilities', { project_id: project.id })
      expect(result['isError']).to be_falsey
      expect(result.dig('content', 0, 'text')).to include('Billing')
    end
  end

  # ------------------------------------------------------------------
  # M3b — write tools
  # ------------------------------------------------------------------

  # The SDK runs every element of a JSON-RPC array, and the per-token throttle
  # counts HTTP requests: one POST of a thousand create_ticket calls counted once.
  # MCP 2025-06-18 dropped batching; the endpoint refuses it before any call runs.
  describe 'a JSON-RPC batch' do
    let(:call) do
      { jsonrpc: '2.0', method: 'tools/call',
        params: { name: 'create_ticket', arguments: { project_id: project.id, title: 'Aus dem Stapel' } } }
    end

    it 'is refused as one invalid request, and no call in it runs' do
      body = [call.merge(id: 1), call.merge(id: 2)].to_json
      answer = nil
      expect do
        answer = post_mcp(body, headers: auth_headers(write_pat.token))
      end.not_to(change { count_without_tenant(Ticket) })

      expect(response).to have_http_status(:ok)
      expect(answer).to be_a(Hash)
      expect(answer['id']).to be_nil
      expect(answer.dig('error', 'code')).to eq(-32_600)
      expect(answer.dig('error', 'data')).to match(/batch/i)
    end

    it 'is refused with one element and with leading whitespace too' do
      expect do
        post_mcp(" \n[#{call.merge(id: 1).to_json}]", headers: auth_headers(write_pat.token))
      end.not_to(change { count_without_tenant(Ticket) })
      expect(JSON.parse(response.body).dig('error', 'code')).to eq(-32_600)
    end

    it 'leaves a single request as it was' do
      expect do
        post_mcp(call.merge(id: 1).to_json, headers: auth_headers(write_pat.token))
      end.to change { count_without_tenant(Ticket) }.by(1)
    end
  end

  describe 'tools/call create_ticket' do
    it 'creates a ticket via the write seam and returns its summary' do
      payload = nil
      expect do
        payload = tool_json_as(write_pat, 'create_ticket',
                               { project_id: project.id, title: 'Login bug', description: 'Steps to repro', status: 'open' })
      end.to change { count_without_tenant(Ticket) }.by(1)

      expect(payload['title']).to eq('Login bug')
      expect(payload['status']).to eq('open')
      expect(payload['number']).to be_present
      created = ActsAsTenant.with_tenant(organisation) { Ticket.find(payload['id']) }
      expect(created.creator_id).to eq(user.id)
    end

    # In dev and test the actor re-raises an unexpected error; in production it
    # returns it with its message, which may name the database. Stubbed to pin
    # the production branch: the tool answers a fixed text.
    it 'answers an unexpected failure with a fixed text, not the exception message' do
      failure = Actors::BaseActor::Result.new(
        success: false, errors: ['PG::UniqueViolation: duplicate key value violates unique constraint "tickets_pkey"'],
        code: :internal_error
      )
      allow(Actors::SaveTicket).to receive(:call).and_return(failure)

      result = tool_result_as(write_pat, 'create_ticket', { project_id: project.id, title: 'Login bug' })

      expect(result['isError']).to be(true)
      expect(result.dig('content', 0, 'text')).to eq('create failed: unexpected error')
    end

    it 'rejects a blank title without creating anything' do
      result = nil
      expect do
        result = tool_result_as(write_pat, 'create_ticket', { project_id: project.id, title: '   ' })
      end.not_to(change { count_without_tenant(Ticket) })
      expect(result['isError']).to be true
      expect(result.dig('content', 0, 'text')).to match(/title is required/i)
    end

    # The title rule of update_ticket (Tools::TicketTitle), so a ticket cannot be
    # created with a title it could not be renamed to. Before the bound on the
    # model, 256 to ~2,700 characters were stored; now they are refused as
    # input, in English, before the actor runs.
    {
      'a title over the bound' => ['a' * (Ticket::TITLE_MAX_LENGTH + 1), 'title is longer than 255 characters'],
      'a title with a line break' => ["Login\nbug", 'title must be one line without control characters']
    }.each do |label, (title, text)|
      it "refuses #{label} as invalid_input without creating anything" do
        result = nil
        expect do
          result = tool_result_as(write_pat, 'create_ticket', { project_id: project.id, title: title })
        end.not_to(change { count_without_tenant(Ticket) })
        expect(result.dig('content', 0, 'text')).to eq(text)
        expect(result['_meta']).to eq('lalabase/code' => 'invalid_input')
      end
    end

    # The schema makes title required over the wire; a direct call without one
    # (the assistant, a test) gets the same words as a blank title.
    it 'answers a direct call without a title as title is required' do
      context = Lalabase::Tools::Context.new(actor: user, organisation: organisation, project: project,
                                             authorization: Lalabase::Tools::AuthorizationRecorder.new)
      result = ActsAsTenant.with_tenant(organisation) { Lalabase::Tools::CreateTicket.execute(args: {}, context: context) }
      expect(result.error).to eq('title is required')
      expect(result.error_code).to eq(:invalid_input)
    end

    it 'takes a title of the bound, trimmed at the edges' do
      payload = tool_json_as(write_pat, 'create_ticket', { project_id: project.id, title: "  #{'a' * Ticket::TITLE_MAX_LENGTH}  " })
      expect(payload['title']).to eq('a' * Ticket::TITLE_MAX_LENGTH)
    end

    it 'is denied for a read-only token (D3 gate), creating nothing' do
      result = nil
      expect do
        result = tool_result('create_ticket', { project_id: project.id, title: 'Nope' })
      end.not_to(change { count_without_tenant(Ticket) })
      expect(result['isError']).to be true
      expect(result.dig('content', 0, 'text')).to match(/read-only/i)
    end

    it 'is denied when the user lacks ticket-write in the project' do
      no_write_project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      # Read access, so the seam lets it through and the write policy refuses
      ActsAsTenant.with_tenant(organisation) do
        create(:project_permission, user: user, project: no_write_project, tickets_access: :read_only)
      end
      result = nil
      expect do
        result = tool_result_as(write_pat, 'create_ticket', { project_id: no_write_project.id, title: 'X' })
      end.not_to(change { count_without_tenant(Ticket) })
      expect(result['isError']).to be true
      expect(result.dig('content', 0, 'text')).to match(/not authorized/i)
    end

    it 'logs write provenance with the PAT id and origin (D9)' do
      allow(Rails.logger).to receive(:info).and_call_original
      tool_json_as(write_pat, 'create_ticket', { project_id: project.id, title: 'Audited' })
      expect(Rails.logger).to have_received(:info)
        .with(/\[MCP write\] origin=mcp tool=create_ticket outcome=success token_id=#{write_pat.id}/).at_least(:once)
    end
  end

  describe 'tools/call post_comment' do
    it 'posts a comment on a ticket and returns it' do
      payload = nil
      expect do
        payload = tool_json_as(write_pat, 'post_comment',
                               { project_id: project.id, ticket_id: ticket.id, body: 'Looking into it.' })
      end.to change { count_without_tenant(Post) }.by(1)

      expect(payload['ticket_id']).to eq(ticket.id)
      expect(payload['body_text']).to include('Looking into it.')
      created = ActsAsTenant.with_tenant(organisation) { Post.find(payload['id']) }
      expect(created.user_id).to eq(user.id)
    end

    it 'requires a body' do
      result = tool_result_as(write_pat, 'post_comment', { project_id: project.id, ticket_id: ticket.id, body: '  ' })
      expect(result['isError']).to be true
      expect(result.dig('content', 0, 'text')).to match(/body is required/i)
    end

    it 'returns an empty result for a missing ticket' do
      result = tool_result_as(write_pat, 'post_comment',
                              { project_id: project.id, ticket_id: SecureRandom.uuid, body: 'x' })
      expect(result['isError']).to be_falsey
      expect(result.dig('content', 0, 'text')).to match(/no ticket found/i)
    end

    it 'is denied for a read-only token (D3 gate), posting nothing' do
      result = nil
      expect do
        result = tool_result('post_comment', { project_id: project.id, ticket_id: ticket.id, body: 'x' })
      end.not_to(change { count_without_tenant(Post) })
      expect(result['isError']).to be true
      expect(result.dig('content', 0, 'text')).to match(/read-only/i)
    end
  end

  # ------------------------------------------------------------------
  # M3c — idempotent writes (D9)
  # ------------------------------------------------------------------

  describe 'idempotent writes (D9)' do
    it 'create_ticket with the same key creates one ticket and replays the result' do
      args = { project_id: project.id, title: 'Only once', idempotency_key: 'key-abc' }

      first = nil
      expect { first = tool_json_as(write_pat, 'create_ticket', args) }
        .to change { count_without_tenant(Ticket) }.by(1)

      second = nil
      expect { second = tool_json_as(write_pat, 'create_ticket', args) }
        .not_to(change { count_without_tenant(Ticket) })

      expect(second['id']).to eq(first['id'])
      expect(second['number']).to eq(first['number'])
    end

    it 'post_comment with the same key posts one comment' do
      args = { project_id: project.id, ticket_id: ticket.id, body: 'dedup me', idempotency_key: 'cmt-1' }

      first = nil
      expect { first = tool_json_as(write_pat, 'post_comment', args) }
        .to change { count_without_tenant(Post) }.by(1)

      second = nil
      expect { second = tool_json_as(write_pat, 'post_comment', args) }
        .not_to(change { count_without_tenant(Post) })

      expect(second['id']).to eq(first['id'])
    end

    it 'rejects reusing a key with different parameters' do
      tool_json_as(write_pat, 'create_ticket', { project_id: project.id, title: 'First', idempotency_key: 'dup' })
      result = nil
      expect do
        result = tool_result_as(write_pat, 'create_ticket', { project_id: project.id, title: 'Different', idempotency_key: 'dup' })
      end.not_to(change { count_without_tenant(Ticket) })
      expect(result['isError']).to be true
      expect(result.dig('content', 0, 'text')).to match(/different parameters/i)
    end

    it 'isolates keys per token (same key, different PAT)' do
      other_pat = build_pat(read_only: false)
      a = tool_json_as(write_pat, 'create_ticket', { project_id: project.id, title: 'A', idempotency_key: 'shared' })
      b = tool_json_as(other_pat, 'create_ticket', { project_id: project.id, title: 'B', idempotency_key: 'shared' })
      expect(b['id']).not_to eq(a['id'])
    end

    it 'advertises idempotency_key only on mutating tools' do
      tools = post_mcp(rpc('tools/list')).dig('result', 'tools')
      create = tools.find { |t| t['name'] == 'create_ticket' }
      list_caps = tools.find { |t| t['name'] == 'list_capabilities' }
      expect(create.dig('inputSchema', 'properties')).to have_key('idempotency_key')
      expect(list_caps.dig('inputSchema', 'properties')).not_to have_key('idempotency_key')
    end

    it 'logs target=- for a write that addresses no record (D9)' do
      allow(Rails.logger).to receive(:info).and_call_original
      tool_json_as(write_pat, 'create_ticket', { project_id: project.id, title: 'Audited' })
      expect(Rails.logger).to have_received(:info)
        .with(/tool=create_ticket outcome=success .*project_id=#{project.id} target=-\z/)
        .at_least(:once)
    end
  end
end
