# frozen_string_literal: true

require 'rails_helper'

# The machine field of every MCP tool answer (terminal client plan, S0 c):
# `_meta` carries `lalabase/kind` (ok, empty) on a result and `lalabase/code`
# (plus `lalabase/reason` on a refusal) on an error, so a client classifies an
# answer without parsing its text.
#
# Security properties pinned here:
#   * a missing project and a project the token cannot reach give the SAME
#     answer, field included: the field must not become an existence oracle;
#   * a read-only token is refused a write with its own code, and nothing is written;
#   * no tool of the MCP set answers without the field, the SDK's own input
#     errors included.
RSpec.describe 'MCP answers carry a machine field', :ci_guard, type: :request do
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

  let!(:project_permission) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_permission, user: user, project: project, tickets_access: :read_write)
    end
  end

  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: user, title: 'Login bricht ab')
    end
  end

  def build_pat(owner, organisation, read_only:)
    token = build(:personal_access_token, user: owner, organisations: [organisation], read_only: read_only)
    token.token_hash = nil
    token.token_prefix = nil
    token.generate_token!
    token
  end

  let(:read_pat) { build_pat(user, organisation, read_only: true) }
  let(:write_pat) { build_pat(user, organisation, read_only: false) }

  def call_tool(pat_record, name, arguments)
    body = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: name, arguments: arguments } }.to_json
    post '/api/mcp', params: body,
                     headers: { 'Authorization' => "Bearer #{pat_record.token}", 'CONTENT_TYPE' => 'application/json' }
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body).fetch('result')
  end

  def post_count
    ActsAsTenant.without_tenant { Post.count }
  end

  describe 'results' do
    it 'marks a result as ok' do
      result = call_tool(read_pat, 'get_ticket', { project_id: project.id, ticket_id: ticket.id })
      expect(result['isError']).to be_falsey
      expect(result['_meta']).to eq('lalabase/kind' => 'ok')
    end

    it 'marks a record that was not found as empty, not as an error' do
      result = call_tool(read_pat, 'get_ticket', { project_id: project.id, ticket_id: SecureRandom.uuid })
      expect(result['isError']).to be_falsey
      expect(result['_meta']).to eq('lalabase/kind' => 'empty')
    end

    it 'keeps the kind on an idempotent replay' do
      args = { project_id: project.id, ticket_id: ticket.id, body: 'Erledigt', idempotency_key: 'codes-1' }
      first = call_tool(write_pat, 'post_comment', args)
      replay = call_tool(write_pat, 'post_comment', args)

      expect([first['_meta'], replay['_meta']]).to all(eq('lalabase/kind' => 'ok'))
      expect(replay['content']).to eq(first['content'])
    end
  end

  describe 'errors' do
    it 'classifies a malformed argument as invalid_input, without a reason' do
      result = call_tool(read_pat, 'get_ticket', { project_id: project.id, ticket_id: 'oops' })
      expect(result['isError']).to be true
      expect(result['_meta']).to eq('lalabase/code' => 'invalid_input')
    end

    # These two answers come from the MCP SDK itself, before our tool runs.
    it 'classifies a missing required argument as invalid_input' do
      result = call_tool(read_pat, 'get_ticket', {})
      expect(result['isError']).to be true
      expect(result['_meta']).to eq('lalabase/code' => 'invalid_input')
    end

    it 'classifies an argument of the wrong type as invalid_input' do
      result = call_tool(read_pat, 'get_ticket', { project_id: project.id, ticket_id: 42 })
      expect(result['isError']).to be true
      expect(result['_meta']).to eq('lalabase/code' => 'invalid_input')
    end

    it 'refuses a write over a read-only token with read_only, and writes nothing' do
      ticket
      expect do
        result = call_tool(read_pat, 'post_comment', { project_id: project.id, ticket_id: ticket.id, body: 'Hallo' })
        expect(result['isError']).to be true
        expect(result['_meta']).to eq('lalabase/code' => 'read_only')
      end.not_to(change { post_count })
    end

    it 'lets the same write through over a writable token' do
      ticket
      expect do
        result = call_tool(write_pat, 'post_comment', { project_id: project.id, ticket_id: ticket.id, body: 'Hallo' })
        expect(result['_meta']).to eq('lalabase/kind' => 'ok')
      end.to change { post_count }.by(1)
    end

    # A ticket that may be read but not written: the caller knows it exists, so
    # the refusal of the write may say what it is. A ticket that may not be read
    # at all answers like a missing one (mcp_ticket_existence_spec).
    it 'classifies a per-record denial as forbidden, writing nothing' do
      read_only_tickets = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      ActsAsTenant.with_tenant(organisation) do
        create(:project_permission, user: user, project: read_only_tickets, tickets_access: :read_only)
      end
      readable = ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: read_only_tickets, organisation: organisation, creator: user, title: 'Lesbar')
      end

      expect do
        result = call_tool(write_pat, 'post_comment',
                           { project_id: read_only_tickets.id, ticket_id: readable.id, body: 'Hallo' })
        expect(result['isError']).to be true
        expect(result['_meta']).to eq('lalabase/code' => 'forbidden')
      end.not_to(change { post_count })
    end

    it 'names the reason of a domain refusal' do
      notification = ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation, notifiable: ticket, state: 'archived')
      end
      result = call_tool(write_pat, 'mark_notification_read', { notification_id: notification.id })
      expect(result['isError']).to be true
      expect(result['_meta']).to eq('lalabase/code' => 'refused', 'lalabase/reason' => 'archived')
      expect(notification.reload.state).to eq('archived')
    end

    # People S3b: an owner without the people right.
    it 'names the reason when the owner may not see the people directory' do
      listed = call_tool(read_pat, 'find_people', { organisation_id: organisation.id })
      read = call_tool(read_pat, 'get_person', { organisation_id: organisation.id, id: "person:#{SecureRandom.uuid}" })

      [listed, read].each do |result|
        expect(result['_meta']).to eq('lalabase/code' => 'refused', 'lalabase/reason' => 'people_directory')
      end
    end
  end

  # The field must not tell "missing" from "not yours". The whole answer is
  # compared, so neither the text nor the field may differ.
  describe 'not found and not reachable' do
    let(:foreign_project) do
      ActsAsTenant.with_tenant(other_organisation) { create(:project, organisation: other_organisation) }
    end

    it 'answers a foreign project exactly like a missing one' do
      missing = call_tool(read_pat, 'list_tickets', { project_id: SecureRandom.uuid })
      foreign = call_tool(read_pat, 'list_tickets', { project_id: foreign_project.id })

      expect(foreign).to eq(missing)
      expect(foreign['_meta']).to eq('lalabase/code' => 'not_found')
    end

    it 'answers a token of another organisation exactly like a missing project' do
      outsider = create(:user)
      ActsAsTenant.with_tenant(other_organisation) do
        create(:membership, user: outsider, organisation: other_organisation,
                            role: create(:role, organisation: other_organisation), active: true)
      end
      outsider_pat = build_pat(outsider, other_organisation, read_only: true)

      missing = call_tool(outsider_pat, 'get_ticket', { project_id: SecureRandom.uuid, ticket_id: ticket.id })
      foreign = call_tool(outsider_pat, 'get_ticket', { project_id: project.id, ticket_id: ticket.id })

      expect(foreign).to eq(missing)
      expect(foreign.to_json).not_to include('Login bricht ab')
    end

    # The inbox filter refuses a project through InboxQuery, not through the
    # seam's gate; it has to land on the same class as the gate.
    it 'answers an inbox filter on a foreign project exactly like a missing one' do
      missing = call_tool(read_pat, 'list_notifications', { project_id: SecureRandom.uuid })
      foreign = call_tool(read_pat, 'list_notifications', { project_id: foreign_project.id })

      expect(foreign).to eq(missing)
      expect(foreign['_meta']).to eq('lalabase/code' => 'not_found')
    end

    # People S3b: the organisation of a people tool, outside the token or missing.
    it 'answers a people tool on a foreign organisation exactly like on a missing one' do
      missing = call_tool(read_pat, 'find_people', { organisation_id: SecureRandom.uuid })
      foreign = call_tool(read_pat, 'find_people', { organisation_id: other_organisation.id })

      expect(foreign).to eq(missing)
      expect(foreign['_meta']).to eq('lalabase/code' => 'not_found')
    end

    # A code tool refuses a reachable project without repository rights in the
    # tool (Base.single_project_code_target), with the gate's answer.
    it 'answers a code tool without repository rights exactly like a foreign project' do
      no_rights = call_tool(read_pat, 'list_capabilities', { project_id: project.id })
      foreign = call_tool(read_pat, 'list_capabilities', { project_id: foreign_project.id })

      expect(no_rights).to eq(foreign)
      expect(no_rights['_meta']).to eq('lalabase/code' => 'not_found')
    end
  end

  # `empty` is "the call found nothing", not only "the record is missing": the
  # code tools answer a search without hits with it too, and the list tools an
  # empty list with `ok` and `data: []`. Which one a tool gives is pinned here
  # and in the contract file, because a client's cache rule depends on it.
  describe 'what the code tools answer when they find nothing' do
    before do
      ActsAsTenant.with_tenant(organisation) do
        create(:project_repository, project: project)
        project_permission.update!(chats_access: :read_only)
      end
    end

    empty_answers = [
      ['list_capabilities', -> { { project_id: project.id } }, /No capabilities have been indexed/],
      ['get_project_vision', -> { { project_id: project.id } }, /No vision has been indexed/],
      ['get_capability_details', -> { { project_id: project.id, capability_id: SecureRandom.uuid } }, /No capability found/],
      ['get_symbol_details', -> { { project_id: project.id, qualified_name: 'Billing' } }, /No symbol found/]
    ]

    empty_answers.each do |tool, arguments, text|
      it "#{tool}: #{text.source} is empty" do
        result = call_tool(read_pat, tool, instance_exec(&arguments))
        expect(result['isError']).to be_falsey
        expect(result.dig('content', 0, 'text')).to match(text)
        expect(result['_meta']).to eq('lalabase/kind' => 'empty')
      end
    end

    # The factory repository counts as indexed; the two search paths below are
    # reached by taking the index away, or by a search that matches nothing.
    it 'search_code_symbols: a project without an indexed repository is empty' do
      allow(Lalabase::RepoScope).to receive(:ids_for).and_return([])
      result = call_tool(read_pat, 'search_code_symbols', { project_id: project.id, query: 'Billing' })

      expect(result.dig('content', 0, 'text')).to match(/no indexed code repositories/)
      expect(result['_meta']).to eq('lalabase/kind' => 'empty')
    end

    it 'search_code_symbols: a search without hits is empty' do
      allow(Lalabase::Tools::SearchCodeSymbols).to receive(:embed_query).and_return([0.0])
      allow(CodeSymbol).to receive(:semantic_search).and_return([])
      result = call_tool(read_pat, 'search_code_symbols', { project_id: project.id, query: 'Billing' })

      expect(result.dig('content', 0, 'text')).to match(/No symbols matched/)
      expect(result['_meta']).to eq('lalabase/kind' => 'empty')
    end

    it 'answers an empty ticket list with ok, not empty' do
      result = call_tool(read_pat, 'list_tickets', { project_id: project.id })
      expect(JSON.parse(result.dig('content', 0, 'text'))['data']).to eq([])
      expect(result['_meta']).to eq('lalabase/kind' => 'ok')
    end
  end

  # One row per error a tool raises itself, past the SDK's schema check (the
  # text proves the tool answered). A row whose code is lost turns red here;
  # the loop below only reaches the SDK's own input errors.
  describe 'each error a tool raises itself' do
    let!(:time_permission) do
      ActsAsTenant.with_tenant(organisation) do
        TimeSessionPermission.create!(user: user, project: project, can_create_own: true)
      end
    end

    # The code tools check the repository rights before their own arguments, the
    # people tools the people right.
    before do
      ActsAsTenant.with_tenant(organisation) do
        create(:project_repository, project: project)
        project_permission.update!(chats_access: :read_only)
        create(:permission, role: role, category: 'people', action: 'view_people', allowed: true)
      end
    end

    error_sites = [
      ['list_tickets', -> { { project_id: project.id, assignee: 'not-a-uuid' } }, /invalid assignee/],
      ['get_ticket', -> { { project_id: project.id, ticket_id: 'oops' } }, /invalid ticket_id format/],
      ['get_ticket', -> { { project_id: project.id, number: 'abc' } }, /invalid number/],
      ['get_ticket', -> { { project_id: project.id } }, /ticket_id or number is required/],
      ['search_knowledge', -> { { project_id: project.id, q: ' ' } }, /q is required/],
      ['search_knowledge', -> { { project_id: project.id, q: 'x', type: 'video' } }, /invalid type/],
      ['create_ticket', -> { { project_id: project.id, title: ' ' } }, /title is required/],
      ['create_ticket', -> { { project_id: project.id, title: 'a' * 256 } }, /title is longer than 255 characters/],
      ['post_comment', -> { { project_id: project.id, ticket_id: 'oops', body: 'x' } }, /invalid ticket_id format/],
      ['post_comment', -> { { project_id: project.id, ticket_id: ticket.id, body: ' ' } }, /body is required/],
      ['post_comment', -> { { project_id: project.id, ticket_id: ticket.id, body: 'x', format: 'markdown' } },
       /format must be html or plain/, :direct],
      ['post_comment', -> { { project_id: project.id, ticket_id: ticket.id, body: 'x', format: 1 } },
       /format must be a string/, :direct],
      ['post_comment', -> { { project_id: project.id, ticket_id: ticket.id, body: 255.chr.force_encoding(Encoding::UTF_8), format: 'plain' } },
       /body must be valid UTF-8/, :direct],
      ['post_comment', -> { { project_id: project.id, ticket_id: ticket.id, body: "a#{0.chr}b", format: 'plain' } },
       /body must not contain NUL bytes/],
      ['create_time_session', -> { { project_id: project.id, ticket_id: 'oops', duration: '1:00' } }, /invalid ticket_id format/],
      ['create_time_session', -> { { project_id: project.id, ticket_id: ticket.id } }, /duration or duration_minutes is required/],
      ['create_time_session', -> { { project_id: project.id, ticket_id: ticket.id, duration: '1:00', duration_minutes: 60 } },
       /not both/],
      ['create_time_session', -> { { project_id: project.id, ticket_id: ticket.id, duration: '1:00', occurred_on: 'nope' } },
       /invalid occurred_on/],
      ['list_notifications', -> { { project_id: 'oops' } }, /invalid project_id/],
      ['mark_notification_read', -> { { notification_id: 'oops' } }, /invalid notification_id format/],
      ['mark_notification_read', -> { { notification_id: SecureRandom.uuid, project_id: project.id } }, /project_id does not apply/],
      ['get_capability_details', -> { { project_id: project.id, capability_id: 'oops' } }, /invalid capability_id format/],
      ['get_symbol_details', -> { { project_id: project.id, qualified_name: ' ' } }, /qualified_name is required/],
      ['search_code_symbols', -> { { project_id: project.id, query: ' ' } }, /query is required/],
      ['update_ticket', -> { { project_id: project.id, ticket_id: 'oops', status: 'open' } }, /invalid ticket_id format/],
      ['update_ticket', -> { { project_id: project.id, ticket_id: ticket.id } }, /exactly one change per call/],
      ['update_ticket', -> { { project_id: project.id, ticket_id: ticket.id, title: 'x', status: 'open' } }, /exactly one change per call/],
      ['update_ticket', -> { { project_id: project.id, ticket_id: ticket.id, title: ' ' } }, /title is required/],
      ['update_ticket', -> { { project_id: project.id, ticket_id: ticket.id, title: 'a' * 256 } }, /title is longer than 255 characters/],
      ['update_ticket', -> { { project_id: project.id, ticket_id: ticket.id, title: "a\nb" } }, /title must be one line/],
      ['update_ticket', -> { { project_id: project.id, ticket_id: ticket.id, title: 'x', priority: 'low' } }, /unknown arguments: priority/],
      ['update_ticket', -> { { project_id: project.id, ticket_id: ticket.id, status: ' ' } }, /status is required/],
      ['update_ticket', -> { { project_id: project.id, ticket_id: ticket.id, add_assignee_ids: ['oops'] } }, /invalid user id in add_assignee_ids/],
      ['update_ticket', -> { { project_id: project.id, ticket_id: ticket.id, add_assignee_ids: [] } }, /must name at least one user/],
      ['update_ticket', -> { { project_id: project.id, ticket_id: ticket.id, add_assignee_ids: ['me'], remove_assignee_ids: ['me'] } },
       /name the same user/],
      ['update_ticket', -> { { project_id: project.id, ticket_id: ticket.id, add_assignee_ids: Array.new(51) { SecureRandom.uuid } } },
       /at most 50 user ids per list/],
      ['find_people', -> { { organisation_id: ' ' } }, /organisation_id is required/],
      ['find_people', -> { { organisation_id: 'oops' } }, /invalid organisation_id/],
      ['find_people', -> { { organisation_id: organisation.id, kind: 'member' } }, /kind must be one of/, :direct],
      ['get_person', -> { { organisation_id: 'oops', id: 'person:x' } }, /invalid organisation_id/],
      ['get_person', -> { { organisation_id: organisation.id, id: ' ' } }, /id is required/],
      ['get_person', -> { { organisation_id: organisation.id, id: 'abc' } }, /invalid id/],
      ['get_glossary', -> { { organisation_id: ' ' } }, /organisation_id is required/],
      ['get_glossary', -> { { organisation_id: organisation.id, query: 'lala' } }, /unknown arguments: query/],
      ['get_glossary', -> { { organisation_id: organisation.id, per_page: 101 } }, /per_page/]
    ]

    error_sites.each do |tool, arguments, text, mode|
      it "#{tool}: #{text.source} is invalid_input" do
        # Schema-invalid values and invalid UTF-8 cannot reach execute through
        # JSON + the SDK. Exercise the real seam directly for those rows, with
        # the class the dispatcher would pick for the tool name.
        args = instance_exec(&arguments)
        before = post_count
        result = if mode == :direct
                   tool_class = Lalabase::Tools::Registry.by_name(tool, set: :mcp) || raise("unknown MCP tool #{tool}")
                   answer = Mcp::ToolCall.new(token: write_pat, tool_class: tool_class, args: args).response
                   JSON.parse(answer.to_h.to_json)
                 else
                   call_tool(write_pat, tool, args)
                 end
        expect(result.dig('content', 0, 'text')).to match(text)
        expect(result['_meta']).to eq('lalabase/code' => 'invalid_input')
        expect(post_count).to eq(before)
      end
    end

    it 'classifies a reused idempotency key with other arguments as invalid_input' do
      args = { project_id: project.id, ticket_id: ticket.id, idempotency_key: 'codes-reuse' }
      call_tool(write_pat, 'post_comment', args.merge(body: 'Erster'))
      result = call_tool(write_pat, 'post_comment', args.merge(body: 'Zweiter'))

      expect(result.dig('content', 0, 'text')).to match(/already used with different parameters/)
      expect(result['_meta']).to eq('lalabase/code' => 'invalid_input')
    end

    # A model validation is not proof that the input was wrong, so all three
    # writes answer a refused save the same way: refused, no reason.
    it 'classifies a booking the actor refuses as refused' do
      result = call_tool(write_pat, 'create_time_session',
                         { project_id: project.id, ticket_id: ticket.id, duration: '0' })
      expect(result.dig('content', 0, 'text')).to match(/booking failed/)
      expect(result['_meta']).to eq('lalabase/code' => 'refused')
    end

    it 'classifies a comment the model refuses as refused' do
      allow_any_instance_of(Post).to receive(:save!) do |record|
        record.errors.add(:content, :blank)
        raise ActiveRecord::RecordInvalid, record
      end
      result = call_tool(write_pat, 'post_comment', { project_id: project.id, ticket_id: ticket.id, body: 'Hallo' })
      expect(result.dig('content', 0, 'text')).to match(/comment failed/)
      expect(result['_meta']).to eq('lalabase/code' => 'refused')
    end

    # update_ticket's refusals are decided by the project's state, so each names
    # its reason (terminal client S2). This project has no status field yet.
    describe 'update_ticket refusals' do
      def add_statuses
        ActsAsTenant.with_tenant(organisation) do
          create(:ticket_attribute_definition,
                 project: project, name: 'status', field_type: 'select', position: 1, labels: { 'de' => 'Status' },
                 options: { 'allowed_values' => [{ 'value' => 'open', 'labels' => { 'de' => 'offen' } }] })
        end
      end

      def refusal(arguments)
        result = call_tool(write_pat, 'update_ticket', { project_id: project.id, ticket_id: ticket.id }.merge(arguments))
        expect(result['isError']).to be true
        [result['_meta'], result.dig('content', 0, 'text')]
      end

      it 'no_status_field' do
        expect(refusal(status: 'open'))
          .to eq([{ 'lalabase/code' => 'refused', 'lalabase/reason' => 'no_status_field' }, 'this project has no status field'])
      end

      it 'value_not_allowed for a status' do
        add_statuses
        meta, text = refusal(status: 'erledigt')
        expect(meta).to eq('lalabase/code' => 'refused', 'lalabase/reason' => 'value_not_allowed')
        expect(text).to eq('status is not a status of this project; use a key from meta.available_statuses')
      end

      it 'value_not_allowed for a person' do
        meta, text = refusal(add_assignee_ids: [SecureRandom.uuid])
        expect(meta).to eq('lalabase/code' => 'refused', 'lalabase/reason' => 'value_not_allowed')
        expect(text).to eq('a user in this change cannot be assigned in this project')
      end

      # Only a race reaches it: the person added lost access after the option
      # list was read. Stubbed at the write check.
      it 'user_not_assignable for a person who lost access in the meantime' do
        allow_any_instance_of(Ticket).to receive(:assignable_user_ids).and_return([])
        meta, = refusal(add_assignee_ids: ['me'])
        expect(meta).to eq('lalabase/code' => 'refused', 'lalabase/reason' => 'user_not_assignable')
      end

      # A real refusal (a ticket that lost its number), read in English although
      # the request runs in German.
      it 'validation_failed for a title the model refuses' do
        ActsAsTenant.with_tenant(organisation) { ticket.update_column(:number, nil) }
        expect(refusal(title: 'Neu'))
          .to eq([{ 'lalabase/code' => 'refused', 'lalabase/reason' => 'validation_failed' },
                  "title could not be saved: Number can't be blank"])
      end

      it 'a fixed text and no reason for anything else' do
        allow(Actors::SaveTicket).to receive(:call).and_return(
          Actors::BaseActor::Result.new(success: false, errors: ['PG::Error: detail'], code: :internal_error)
        )
        expect(refusal(title: 'Neu')).to eq([{ 'lalabase/code' => 'refused' }, 'update failed'])
      end
    end

    it 'names the reason when AI is switched off for the organisation' do
      allow(Lalabase::Tools::SearchCodeSymbols).to receive_messages(repo_ids_for: ['repo'])
      allow(Lalabase::Tools::SearchCodeSymbols).to receive(:embed_query).and_raise(Lalabase::Llm::AiDisabledError)
      result = call_tool(write_pat, 'search_code_symbols', { project_id: project.id, query: 'Billing' })

      expect(result.dig('content', 0, 'text')).to match(/AI features are disabled/)
      expect(result['_meta']).to eq('lalabase/code' => 'refused', 'lalabase/reason' => 'ai_disabled')
    end
  end

  # Every tool of the MCP set, from the registry, so a new tool is covered
  # without editing this spec. Called without arguments, most answer an input
  # error; a tool whose arguments are all optional answers a result. Either way
  # the answer carries exactly one of the two fields, with a known value.
  describe 'every tool of the MCP set' do
    Lalabase::Tools::Registry.for(:mcp).each do |tool_class|
      it "#{tool_class.tool_name} answers with the machine field" do
        result = call_tool(write_pat, tool_class.tool_name, {})
        meta = result.fetch('_meta')

        if result['isError']
          expect(meta.keys - ['lalabase/reason']).to eq(['lalabase/code'])
          expect(Lalabase::Tools::Result::ERROR_CODES.map(&:to_s)).to include(meta['lalabase/code'])
        else
          expect(meta.keys).to eq(['lalabase/kind'])
          expect(%w[ok empty]).to include(meta['lalabase/kind'])
        end
      end
    end
  end
end
