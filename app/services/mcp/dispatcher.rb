# frozen_string_literal: true

module Mcp
  # Stateless MCP (Model Context Protocol) dispatcher — the protocol seam between
  # an external MCP client (Claude Code) and the existing Lalabase::Tools registry.
  #
  # Distinct from the gem constant `MCP` (the official SDK). `Mcp` (this module) is
  # our thin Rails-side glue. The SDK provides JSON-RPC framing + capability
  # negotiation; we provide auth, tenant scoping and the tool surface.
  #
  #   POST /api/mcp  (one JSON-RPC request per HTTP request — NO session, NO SSE)
  #        │
  #        ▼
  #   Dispatcher#handle_json(raw)
  #        │  builds a fresh MCP::Server per request (stateless; safe under
  #        │  multi-worker Puma — nothing is held in memory between requests)
  #        ▼
  #   MCP::Server#handle_json  ── initialize / tools/list / tools/call ──┐
  #        │                                                             │
  #        │  tools/call ──▶ define_tool block ──▶ Mcp::ToolCall         │
  #        │                   (project scope auth + tenant + execute)   │
  #        └─────────────────────────────────────────────────────────────┘
  #
  # Spike-verified (mcp 0.22.0): handle_json(req, session: nil) runs stateless;
  # snake_case input_schema is emitted as camelCase `inputSchema` on the wire.
  class Dispatcher
    SERVER_NAME = 'lalabase'
    # Version of the MCP SURFACE (the tool set + their schemas), independent of the
    # app version (D9). It evolves ADDITIVE-ONLY: adding a tool or an optional arg
    # bumps the minor; we never rename/remove a tool or break an existing arg, so a
    # pinned client keeps working. History: 0.1 = M1 read context, 0.2 = M2 ticket
    # reads, 0.3 = M3 curated writes (create_ticket/post_comment + idempotency),
    # 0.4 = search_knowledge (documentation link authoring, Slice 4), 0.5 =
    # list_notifications (inbox workflow S1, the first token-scoped tool), 0.6 =
    # create_time_session + mark_notification_read (inbox workflow S2/S3), 0.7 =
    # the machine field in `_meta` of every tool answer (terminal client S0 c,
    # see ToolCall#result_to_response); 0.7.1 = a ticket without read access
    # answers like a missing one instead of "Not authorized." (Base.
    # readable_tickets); 0.8 = list_notifications takes organisation_id (terminal
    # client S1 a); 0.9 = get_ticket pages comments and attachments, hands out
    # full text and one comment by post_id (S1 b/c); 0.10 = update_ticket: the
    # status, the assignees or the title of one ticket (terminal client S2), and
    # create_ticket takes the same title (one line, at most 255 characters,
    # anything else is invalid_input instead of being stored).
    # 0.11 = post_comment takes format: "plain" (terminal client S2b).
    # 0.12 = summarize_time_sessions (terminal client S6: the booked time of a
    # ticket). 0.13 = find_people and get_person (People S3b: the people directory,
    # for a token that reaches every project of the organisation named).
    # 0.13.1 = a key the store cannot hold (more than 255 bytes, no valid UTF-8,
    # a NUL) is refused as invalid_input before the write, as REST does since R0.
    # It narrows an existing argument on purpose, released as a fix: a key of 256
    # bytes up to about 2.6 KB used to be stored and replayed (one stored before
    # is refused now, not replayed), a longer one wrote again on every retry.
    # 0.14 = a comment in get_ticket lists its files (`attachments`: id, filename,
    # content_type, byte_size; REST R7), beside attachments_count.
    # 0.15 = list_organisations and list_projects: the ids the other tools take,
    # from the same reader as GET /api/v1/organisations and /projects.
    # 0.16 = create_meeting, by the rule of POST /api/v1/organisations/:id/meetings,
    # and meeting_inbox on the rows of list_projects.
    # 0.17 = get_meeting: one meeting whole behind the token, its summary, notes and
    # transcript in pages, by the gate of GET /api/v1/meetings/:id (Meetings::Readable).
    # 0.18 = get_glossary: the confirmed terms of an organisation with their confirmed
    # heard forms, by the reader of GET /api/v1/organisations/:id/terms (Glossary::Lookup).
    SERVER_VERSION = '0.18.0'

    # MCP surface — sourced from the single tool registry (D6): the :mcp set is the
    # ONE definition of this surface, so a registry refactor can't drift it (R3);
    # the registry and the SERVER_VERSION history above say what is in it. Writes
    # are curated, routed through the existing write seams, and gated by the
    # read_only PAT flag (D3). Kept as a
    # constant (not inlined) so specs can `stub_const('Mcp::Dispatcher::TOOLS', …)` and
    # build_server picks it up. NOTE: this binds to the frozen Registry::MCP array at
    # load — stubbing Registry::MCP after boot would NOT propagate here; stub THIS const.
    TOOLS = Lalabase::Tools::Registry.for(:mcp)

    def initialize(token:)
      @token = token
    end

    # A JSON text whose first token is `[` (JSON allows space, tab, CR and LF before it).
    # Refused since 2026-11-05 without a version bump: the tools and their schemas,
    # which SERVER_VERSION names, did not change, and no client we know sends one.
    BATCH = /\A[ \t\r\n]*\[/

    BATCH_REFUSAL = JSON.generate(
      jsonrpc: '2.0', id: nil,
      error: { code: -32_600, message: 'Invalid Request', data: 'Batch requests are not supported' }
    ).freeze

    # @param raw_request [String] a single JSON-RPC request body
    # @return [String, nil] JSON-RPC response string, or nil for a notification
    def handle_json(raw_request)
      # One request per POST, as the endpoint has always said: the SDK would run
      # every element of an array, and Rack::Attack counts the POST, not the calls.
      return BATCH_REFUSAL if raw_request.to_s.match?(BATCH)

      with_sdk_error_codes(build_server.handle_json(raw_request))
    end

    private

    # The SDK answers two input errors itself, before a tool runs: a missing
    # required argument and an argument that fails the input schema. Both come
    # back as an isError result WITHOUT the machine field ToolCall sets on every
    # answer it builds, so the field is added here: an isError result without
    # `_meta` can only be one of those two. The text test is a cheap filter that
    # spares the parse for every other answer (an escaped copy inside a tool's
    # text does not match it).
    def with_sdk_error_codes(json)
      return json if json.nil? || !json.include?('"isError":true')

      payload = JSON.parse(json)
      Array.wrap(payload).each do |message|
        result = message.is_a?(Hash) ? message['result'] : nil
        next unless result.is_a?(Hash) && result['isError'] == true && !result.key?('_meta')

        result['_meta'] = { ToolCall::CODE_META_KEY => 'invalid_input' }
      end
      JSON.generate(payload)
    end

    def build_server
      server = MCP::Server.new(name: SERVER_NAME, version: SERVER_VERSION)
      TOOLS.each { |tool_class| register_tool(server, tool_class) }
      server
    end

    def register_tool(server, tool_class)
      token = @token # capture for the closure (block `self` is the SDK Tool subclass)
      server.define_tool(
        name: tool_class.tool_name,
        description: tool_class.description,
        input_schema: mcp_input_schema(tool_class)
      ) do |server_context:, **args|
        Mcp::ToolCall.new(token: token, tool_class: tool_class, args: args).response
      end
    end

    # Injects `project_id` (UUID) into the tool's own schema: an MCP client has no
    # URL path to carry the project, so it names it explicitly (D9 identifier
    # strategy: projects are addressed by UUID). For a project-scoped tool it is
    # REQUIRED, the ToolCall gates on it; for a token-scoped tool (scope_mode
    # :token) the reach comes from the token and `project_id` is an optional
    # filter, advertised only to a tool that reads it (project_filter?). Mutating
    # tools also get an optional `idempotency_key` so a client retry can't
    # double-write (D9); its description names the bound ToolCall holds it to.
    def mcp_input_schema(tool_class)
      schema = tool_class.input_schema.deep_dup
      schema[:properties] ||= {}
      if tool_class.scope_mode == :token
        if tool_class.project_filter?
          schema[:properties][:project_id] = {
            type: 'string',
            description: 'Optional. UUID of a Lalabase project to narrow this call to.'
          }
        end
      else
        schema[:properties][:project_id] = {
          type: 'string',
          description: 'UUID of the Lalabase project to scope this call to (list_projects names them).'
        }
        schema[:required] = (Array(schema[:required]) + ['project_id']).uniq
      end
      if tool_class.mutating?
        schema[:properties][:idempotency_key] = {
          type: 'string',
          description: 'Optional. Repeating a write with the same key returns the ' \
                       'original result instead of creating a duplicate. At most ' \
                       "#{IdempotencyStore::MAX_KEY_LENGTH} bytes of valid UTF-8 without NUL."
        }
      end
      schema
    end
  end
end
