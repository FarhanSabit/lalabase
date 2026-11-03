# frozen_string_literal: true

module Lalabase
  module Tools
    # Registry of LLM-callable tools, organised into named SETS — one registry,
    # two surfaces (D6), the assistant in two variants:
    #   :assistant    — the org-wide read tools of the personal thread (S3a T3).
    #   :assistant_with_code — the same, plus the five code tools, for an
    #                   organisation that has a connected repository at all.
    #   :mcp          — read + curated writes for the external MCP surface.
    #
    # The Runner consults `all_schemas(set:)` to advertise tools to the provider
    # and `by_name(name, set:)` to resolve a tool name back to its class. Both
    # default to :assistant.
    #
    # ⚠️ That default USED to be :project_chat, and projekt_chat_abbau moving it is
    # the sharp edge of this file: a caller that omits the argument silently changes
    # which tools it advertises. Every caller in the app names its set (the Runner
    # takes tool_set:, ChatResponseJob passes it), so the default only serves specs
    # and the console -- and it is pinned in registry_spec so it cannot drift back.
    #
    # HARD RULE (§6 / D6): only :mcp may contain mutating tools. Chat sets reach
    # the LLM tool loop, where ticket/post content is attacker-fillable — a write
    # tool there would be a prompt-injection write primitive. Enforced by
    # registry_spec's positive allowlist + no-mutating-tool guard.
    module Registry
      # Eager const references are intentional and Zeitwerk-safe: the autoloader
      # resolves load order at boot, so these classes are available whether
      # eager-loaded (production) or autoloaded (development).

      # Assistant (org-wide personal thread, S3a T3): the read tools with a REAL
      # org-wide branch — they resolve their rows through Context#scope (per-area
      # project reach / per-project ViewingScope) instead of a single project.
      # Deliberately NOT search_knowledge: the org thread has its own asker-gated
      # content retrieval (Retriever org path), so a second search surface would
      # only add injection surface and tokens.
      #
      # summarize_time_sessions (S2) is a REPORT tool: numbers, no rows. It decides
      # own-vs-all itself (TimeSessions::ViewingScope) because the :time_sessions
      # area gate cannot. Since MCP 0.12.0 it is in :mcp too, appended last there
      # (that wire order is pinned separately).
      #
      # recent_activity (§13-11) is here and ONLY here. Its rows span areas and
      # only the ticket ones can carry a citation, so a shared thread's render
      # gate could not redact the rest; the org thread is owner-only, which is
      # what makes it safe. Offering it on a SHARED surface would need per-area
      # citations first (see the tool's own comment).
      #
      # get_note and get_document (doc/assistent_wissen_kontext_plan.md, step 2)
      # and get_meeting (Bezugs-Sammlung S3) are what makes a knowledge or meeting
      # reference more than a label: the system prompt names a referenced object
      # by title and id only (Bezugs-Sammlung E5), and these three are the only
      # road from that id to the text.
      #
      # find_people and get_person (People S3) read the organisation's people directory. Like
      # the help tools they take no project and report no coverage, but they ask a right of
      # their own (the people right, inside the tool, before anything is read) and cite with
      # the people area, so an answer drawn on them stays with the asker. :mcp has twins of
      # them under the same names (McpFindPeople, McpGetPerson, People S3b), which name the
      # organisation and cite nothing.
      #
      # search_help, help_contents and get_help_page (doc/product_knowledge_plan.md, S2) read
      # Lalabase's OWN help, the one thing here that is not the organisation's. It is the same
      # for every organisation and has no rights of its own, so they take no project, report no
      # coverage and cite without an area. Not in :mcp: the plan leaves that surface out, and
      # its wire order is pinned.
      ASSISTANT = [
        ListTickets,
        GetTicket,
        GetNote,
        GetDocument,
        GetMeeting,
        SummarizeTimeSessions,
        RecentActivity,
        FindPeople,
        GetPerson,
        SearchHelp,
        HelpContents,
        GetHelpPage
      ].freeze

      # The assistant WITH reach into the project code
      # (doc/assistent_code_werkzeuge_plan.md). A SECOND NAMED SET, not a flag on
      # Registry.for: the Runner resolves the advertised schemas AND the tool name
      # of an answer through the same @tool_set symbol, so a flag would have to
      # travel with every caller, while a named set keeps the registry a lookup
      # table. It also makes the safety structural rather than checked: a run that
      # did not ADVERTISE the code tools cannot resolve a call to one either,
      # because by_name asks the same symbol.
      #
      # Offered per ORGANISATION, not per surface (ChatResponseJob#runner_tool_set):
      # the five schemas are ~40 percent on top of the assistant's tool list, on
      # EVERY answer including "how many tickets are open", and 26 of 27
      # organisations on production have no repository at all. A tool that cannot
      # find anything is an invitation to call it anyway.
      #
      # The five reach ONE project each (vision and capabilities are 1:1 per
      # project), resolved through Base.resolve_code_project against
      # Scope#code_project_ids -- the repository rights, which are a two-area union
      # ProjectPermission has no area for.
      ASSISTANT_WITH_CODE = (ASSISTANT + [
        SearchCodeSymbols,
        GetProjectVision,
        ListCapabilities,
        GetCapabilityDetails,
        GetSymbolDetails
      ]).freeze

      # MCP surface: read + curated writes, authorized per-record against the PAT
      # owner. The ONLY set permitted to contain mutating tools. Order is pinned to
      # keep the wire tool list stable for pinned clients (R3).
      MCP = [
        SearchCodeSymbols,
        ListCapabilities,
        GetProjectVision,
        GetCapabilityDetails,
        GetSymbolDetails,
        ListTickets,
        GetTicket,
        SearchKnowledge,
        CreateTicket,
        PostComment,
        # Inbox workflow (doc/mcp_inbox_workflow_plan.md), appended so the pinned
        # wire order of the tools before them stays intact: S1 the first
        # token-scoped tool (scope_mode :token, no project gate), S2 the time
        # booking, S3 the token-scoped write.
        ListNotifications,
        CreateTimeSession,
        MarkNotificationRead,
        # Terminal client S2: status, assignees and title of one ticket, through
        # the board's write paths. Appended for the same reason.
        UpdateTicket,
        # Terminal client S6: the booked time of a ticket, for the meta bar of the
        # client's ticket view. A read in project mode: the seam gates the project,
        # the tool narrows through TimeSessions::ViewingScope itself; its org-wide
        # `project` filter is ignored on this path. Appended so the pinned wire
        # order stays intact.
        SummarizeTimeSessions,
        # People S3b: the people directory for agents, the assistant's two tools with an
        # organisation_id. Token-scoped reads: only a token that reaches every project of
        # the organisation reads its directory (E1), never the notes (E2). Appended for the
        # same reason.
        McpFindPeople,
        McpGetPerson,
        # How an agent finds the organisation and project ids the tools above take,
        # token-scoped reads. Appended for the same reason.
        ListOrganisations,
        ListProjects,
        # A meeting with its transcript, token-scoped because the project may be
        # missing (it then lands in the inbox). Appended for the same reason.
        CreateMeeting,
        McpGetMeeting
      ].freeze

      # Sets whose tools reach the LLM tool loop. The guard-spec enforces the
      # no-mutating-tool rule against exactly these — which is why
      # :assistant_with_code is a member and not an afterthought.
      CHAT_SETS = %i[assistant assistant_with_code].freeze
      # Every set there is: the chat sets plus the MCP surface. The ONE list a
      # guard iterates when a rule holds for every tool of every set; a hand-kept
      # copy in a spec went stale the day :ticket_chat was dissolved (S4-T1) and
      # raised on the merge.
      SETS = (CHAT_SETS + [:mcp]).freeze

      # Frozen array of tool classes for a named set. Resolves the constants at
      # call time (not via a frozen snapshot), so a test can stub_const a set and
      # the resolution follows. Unknown set → ArgumentError (a typo must fail
      # loudly, not silently advertise an empty toolset).
      # The three tools that read the handbook. An instance without a catalogue
      # does not have it at all (self-hosted instances do not, by decision), and
      # offering a tool that can only fail teaches the model to keep trying and
      # to report a loading problem that will never resolve.
      HELP_TOOLS = [SearchHelp, HelpContents, GetHelpPage].freeze

      def self.for(set)
        tools = case set
                when :assistant then ASSISTANT
                when :assistant_with_code then ASSISTANT_WITH_CODE
                when :mcp then MCP
                else raise ArgumentError, "unknown tool set: #{set.inspect}"
                end

        return tools if Docs::Catalogue.available?

        tools - HELP_TOOLS
      end

      # Resolves a tool name returned by the LLM back to its class within a set.
      # Tolerant of casing and dash/underscore drift: some providers echo a tool
      # name as 'search-code-symbols' or in different casing than we registered it.
      def self.by_name(name, set: :assistant)
        normalised = normalize_name(name)
        return nil if normalised.empty?

        self.for(set).find { |klass| normalize_name(klass.tool_name) == normalised }
      end

      def self.all_schemas(set: :assistant)
        self.for(set).map(&:to_schema)
      end

      def self.normalize_name(name)
        name.to_s.strip.downcase.tr('-', '_')
      end
      private_class_method :normalize_name
    end
  end
end
