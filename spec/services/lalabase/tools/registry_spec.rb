# frozen_string_literal: true

require 'rails_helper'

# Guard-spec for the named tool sets (D6). The registry is the ONE definition of
# which tools each surface may call, so this spec is a positive allowlist: adding
# or moving a tool must show up here as a deliberate edit, never as silent drift.
#
# The load-bearing invariant is the no-mutating-tool guard on the chat sets (§6):
# ticket/post content is attacker-fillable, so a write tool in the LLM loop would
# be a prompt-injection write primitive. Only :mcp (per-record PAT auth, outside
# the chat loop) may carry mutating tools.
RSpec.describe Lalabase::Tools::Registry do
  let(:t) { Lalabase::Tools }

  describe '.for (named sets)' do
    # projekt_chat_abbau removed :project_chat (and ::ALL, its backward-compatible
    # alias). Pinned as a raise rather than deleted: the set name lived in the DEFAULT
    # argument of by_name and all_schemas, so a caller that omits the argument used to
    # land here. An unknown set must fail loudly, never advertise an empty toolset.
    it ':project_chat is gone, and asking for it raises rather than answering empty' do
      expect { described_class.for(:project_chat) }.to raise_error(ArgumentError, /unknown tool set/)
      expect(described_class).not_to be_const_defined(:ALL)
    end

    it ':assistant is exactly the org-wide read tools (S3a T3, §13-11)' do
      # Deliberately NOT search_knowledge: the thread gets its own asker-gated
      # content retrieval (Retriever), so a second search surface would only add
      # injection surface and tokens.
      # get_note / get_document (doc/assistent_wissen_kontext_plan.md): the road
      # from a knowledge REFERENCE to its text. Not in :mcp -- the MCP side has
      # search_knowledge for authoring links and no reference collection.
      # search_help / help_contents / get_help_page (doc/product_knowledge_plan.md, S2):
      # Lalabase's own help, the same for every organisation. Not in :mcp (pinned below).
      # find_people / get_person (People S3): the people directory, under the asker's
      # people right. :mcp has twins of them, not these classes (pinned below).
      expect(described_class.for(:assistant)).to contain_exactly(
        t::ListTickets, t::GetTicket, t::GetNote, t::GetDocument, t::GetMeeting, t::SummarizeTimeSessions, t::RecentActivity,
        t::FindPeople, t::GetPerson, t::SearchHelp, t::HelpContents, t::GetHelpPage
      )
      expect(described_class.for(:assistant)).to be_frozen
    end

    it ':assistant_with_code is exactly :assistant plus the five code tools' do
      expect(described_class.for(:assistant_with_code)).to contain_exactly(
        t::ListTickets, t::GetTicket, t::GetNote, t::GetDocument, t::GetMeeting, t::SummarizeTimeSessions, t::RecentActivity,
        t::FindPeople, t::GetPerson, t::SearchHelp, t::HelpContents, t::GetHelpPage,
        t::SearchCodeSymbols, t::GetProjectVision, t::ListCapabilities,
        t::GetCapabilityDetails, t::GetSymbolDetails
      )
    end

    # The gate is what the second set is FOR: the five schemas are about 40 percent
    # on top of the assistant's tool list, on every answer, and 26 of 27
    # organisations on production have no repository at all. A set that quietly
    # grew the code tools into :assistant would make the gate a comment.
    it 'keeps the code tools OUT of :assistant, which is the plain org thread' do
      [t::SearchCodeSymbols, t::GetProjectVision, t::ListCapabilities,
       t::GetCapabilityDetails, t::GetSymbolDetails].each do |tool|
        expect(described_class.for(:assistant)).not_to include(tool), tool.tool_name
      end
    end

    # Structural, not checked: the Runner resolves the advertised schemas AND an
    # answer's tool name through the SAME @tool_set symbol, so a run that did not
    # advertise a code tool cannot resolve a call to one either.
    it 'cannot resolve a code tool by name in the set that does not advertise it' do
      expect(described_class.by_name('get_project_vision', set: :assistant)).to be_nil
      expect(described_class.by_name('get_project_vision', set: :assistant_with_code))
        .to eq(t::GetProjectVision)
    end

    # ⚠️ recent_activity belongs to the org thread and nowhere else. Its rows span
    # areas and only the ticket ones can carry a citation, so a SHARED thread's
    # render gate could not redact the rest. The org thread is owner-only, which
    # is what makes it safe; a set that carries it into a shared surface needs
    # per-area citations first.
    it 'keeps recent_activity out of every SHARED surface' do
      %i[mcp].each do |set|
        expect(described_class.for(set)).not_to include(t::RecentActivity), "#{set} must not offer recent_activity"
      end
    end

    # People S3b: on :mcp the people tools are twins of the assistant's, under the same names,
    # because their schema names the organisation (organisation_id) and they run on a token.
    # The assistant's classes stay out of :mcp, and a name resolves to the twin there.
    it 'offers the people tools on :mcp as twins, never the assistant\'s classes' do
      [t::FindPeople, t::GetPerson].each do |tool|
        expect(described_class.for(:mcp)).not_to include(tool), tool.tool_name
      end
      expect(described_class.by_name('find_people', set: :mcp)).to eq(t::McpFindPeople)
      expect(described_class.by_name('get_person', set: :mcp)).to eq(t::McpGetPerson)
      expect(described_class.by_name('find_people', set: :assistant)).to eq(t::FindPeople)
    end

    # R9: get_meeting on :mcp is a twin as well, token-scoped and paged; the assistant keeps its
    # capped read, and the name resolves to the twin on :mcp alone.
    it 'offers get_meeting on :mcp as a twin, never the assistant\'s class' do
      expect(described_class.for(:mcp)).not_to include(t::GetMeeting)
      expect(described_class.by_name('get_meeting', set: :mcp)).to eq(t::McpGetMeeting)
      expect(described_class.by_name('get_meeting', set: :assistant)).to eq(t::GetMeeting)
      expect(described_class.for(:assistant)).not_to include(t::McpGetMeeting)
    end

    # Terminal client S6 (the booked time of a ticket), then People S3b, then the two lists an
    # agent finds its ids with, then create_meeting, then get_meeting (R9), then get_glossary
    # (K4c): each appended LAST, so the pinned wire order of every tool before them stays intact.
    it 'offers the time report, the people twins, the two id lists, create_meeting, get_meeting and get_glossary last on :mcp (wire order pinned)' do
      expect(described_class.for(:mcp).last(8)).to eq(
        [t::SummarizeTimeSessions, t::McpFindPeople, t::McpGetPerson, t::ListOrganisations, t::ListProjects,
         t::CreateMeeting, t::McpGetMeeting, t::GetGlossary]
      )
    end

    # K4c: get_glossary lives on :mcp alone. It runs on a token (scope_mode :token), which no
    # chat has, and the assistant does not need the glossary; a twin would come with a reason.
    it 'offers get_glossary on :mcp alone' do
      described_class::CHAT_SETS.each do |set|
        expect(described_class.for(set)).not_to include(t::GetGlossary), "#{set} must not offer get_glossary"
        expect(described_class.by_name('get_glossary', set: set)).to be_nil
      end
      expect(described_class.by_name('get_glossary', set: :mcp)).to eq(t::GetGlossary)
    end

    it 'no chat set carries search_knowledge (deliberate omission)' do
      # The assistant already has an asker-gated content retrieval; a second search
      # path would only add injection surface. Pinned so "while we're at it" cannot
      # slip it in without this line turning red.
      described_class::CHAT_SETS.each do |set|
        expect(described_class.for(set)).not_to include(t::SearchKnowledge), "#{set} must not offer search_knowledge"
      end
    end

    it ':mcp is exactly the read + curated-write surface' do
      expect(described_class.for(:mcp)).to contain_exactly(
        t::SearchCodeSymbols, t::ListCapabilities, t::GetProjectVision,
        t::GetCapabilityDetails, t::GetSymbolDetails, t::ListTickets,
        t::GetTicket, t::SearchKnowledge, t::CreateTicket, t::PostComment, t::ListNotifications,
        t::CreateTimeSession, t::MarkNotificationRead, t::UpdateTicket, t::SummarizeTimeSessions,
        t::McpFindPeople, t::McpGetPerson, t::ListOrganisations, t::ListProjects, t::CreateMeeting,
        t::McpGetMeeting, t::GetGlossary
      )
    end

    it 'raises ArgumentError on an unknown set (a typo must fail loudly)' do
      expect { described_class.for(:nope) }.to raise_error(ArgumentError, /unknown tool set/)
    end

    # SETS is the list every "for every tool of every set" guard iterates. Pinned
    # against .for in both directions: a set .for answers must be in SETS (or a
    # guard silently skips it), and every name in SETS must resolve (or the
    # guards raise, which is how a stale hand-kept list broke a merge).
    it 'SETS is exactly the chat sets plus :mcp, and .for answers each of them' do
      expect(described_class::SETS).to contain_exactly(*described_class::CHAT_SETS, :mcp)
      described_class::SETS.each { |set| expect(described_class.for(set)).to be_an(Array) }
    end

    it 'exposes only frozen set arrays' do
      described_class::SETS.each do |set|
        expect(described_class.for(set)).to be_frozen
      end
    end
  end

  # THE load-bearing guard: no write tool may reach the LLM tool loop.
  describe 'chat sets never contain a mutating tool (§6 / D6)' do
    # Pin CHAT_SETS itself so the no-mutating guard below (which iterates it) can't
    # silently lose coverage if a refactor drops a set from the constant.
    it 'CHAT_SETS is exactly the two assistant surfaces' do
      # S4-T1 dissolved :ticket_chat, projekt_chat_abbau :project_chat. What is left is
      # the assistant with and without the five code tools -- the second existing per
      # ORGANISATION (does it have a connected repository at all), not per surface.
      # Both belong HERE because the no-mutating-tool guard below iterates exactly
      # this constant.
      expect(described_class::CHAT_SETS).to contain_exactly(:assistant, :assistant_with_code)
    end

    described_class::CHAT_SETS.each do |set_name|
      it "#{set_name.inspect} has no mutating? tool" do
        mutating = described_class.for(set_name).select(&:mutating?)
        expect(mutating).to be_empty,
                            "#{set_name} must not expose write tools to the LLM loop, found: #{mutating.inspect}"
      end

      it "#{set_name.inspect} tools all declare a sane authorization_mode" do
        described_class.for(set_name).each do |tool|
          expect(tool.authorization_mode).to be_in(%i[project record])
        end
      end
    end

    it ':mcp is the only set permitted to carry mutating tools (contrast)' do
      expect(described_class.for(:mcp).select(&:mutating?))
        .to contain_exactly(t::CreateTicket, t::PostComment, t::CreateTimeSession, t::MarkNotificationRead,
                            t::UpdateTicket, t::CreateMeeting)
    end
  end

  # R3: the MCP wire surface must not drift when the registry is refactored. Pins
  # the exact tool names a pinned client sees AND that the dispatcher is sourced
  # from the registry (single definition, D6).
  # Inbox workflow S1: a token-scoped tool has no project gate, so the registry
  # pins where it may live and what it must declare (Base.scope_mode).
  describe 'token-scoped tools (scope_mode :token)' do
    it 'every tool of every set declares a known scope_mode' do
      described_class::SETS.each do |set|
        described_class.for(set).each do |tool|
          expect(tool.scope_mode).to be_in(%i[project token]), tool.tool_name
        end
      end
    end

    described_class::CHAT_SETS.each do |set_name|
      it "#{set_name.inspect} carries no token-scoped tool (a chat has no token)" do
        expect(described_class.for(set_name).select { |tool| tool.scope_mode == :token }).to be_empty
      end
    end

    it 'only a token-scoped tool may read the optional project_id filter, and only those that do say so' do
      described_class::SETS.each do |set|
        described_class.for(set).each do |tool|
          expect(tool.scope_mode).to eq(:token), "#{tool.tool_name} advertises a filter it cannot take" if tool.project_filter?
        end
      end
      expect(t::ListNotifications.project_filter?).to be true
      expect(t::MarkNotificationRead.project_filter?).to be false
    end

    it ':mcp token-scoped tools require the actor and mark their own authorization (record mode)' do
      token_tools = described_class.for(:mcp).select { |tool| tool.scope_mode == :token }
      expect(token_tools).to include(t::ListNotifications, t::McpFindPeople, t::McpGetPerson, t::McpGetMeeting,
                                     t::GetGlossary)
      token_tools.each do |tool|
        expect(tool.requires_actor?).to be(true), tool.tool_name
        expect(tool.authorization_mode).to eq(:record), tool.tool_name
      end
    end
  end

  describe 'MCP surface regression (R3)' do
    let(:expected_mcp_tool_names) do
      %w[
        search_code_symbols list_capabilities get_project_vision
        get_capability_details get_symbol_details list_tickets
        get_ticket search_knowledge create_ticket post_comment
        list_notifications create_time_session mark_notification_read
        update_ticket summarize_time_sessions find_people get_person
        list_organisations list_projects create_meeting get_meeting get_glossary
      ]
    end

    it 'advertises exactly the pinned MCP tool names in order' do
      expect(described_class.for(:mcp).map(&:tool_name)).to eq(expected_mcp_tool_names)
    end

    it 'is the single source for Mcp::Dispatcher::TOOLS' do
      expect(Mcp::Dispatcher::TOOLS).to eq(described_class.for(:mcp))
    end
  end

  describe 'every set is frozen so accidental mutation fails fast' do
    it 'holds for each named set' do
      described_class::SETS.each do |set|
        expect(described_class.for(set)).to be_frozen, "#{set} must be frozen"
      end
    end
  end

  describe '.by_name' do
    let(:fake_tool) do
      Class.new(Lalabase::Tools::Base) do
        def self.tool_name
          'fake_tool'
        end
      end
    end

    # Drive the name-resolution logic against a controlled set via .for, so these
    # cases pin normalization, not the live tool list.
    before { allow(described_class).to receive(:for).with(:assistant).and_return([fake_tool]) }

    it 'returns the class whose tool_name matches' do
      expect(described_class.by_name('fake_tool')).to eq(fake_tool)
    end

    it 'returns nil when no class matches' do
      expect(described_class.by_name('does_not_exist')).to be_nil
    end

    it 'normalises Symbol input to String' do
      expect(described_class.by_name(:fake_tool)).to eq(fake_tool)
    end

    it 'matches case-insensitively (providers may echo a different casing)' do
      expect(described_class.by_name('FAKE_TOOL')).to eq(fake_tool)
      expect(described_class.by_name('Fake_Tool')).to eq(fake_tool)
    end

    it 'treats dashes as underscores (providers may emit kebab-case names)' do
      expect(described_class.by_name('fake-tool')).to eq(fake_tool)
    end

    it 'normalises case and dashes together' do
      expect(described_class.by_name('FAKE-TOOL')).to eq(fake_tool)
    end

    it 'strips surrounding whitespace before matching' do
      # Pins the .strip in normalize_name. The blank-input tests do NOT pin it:
      # a blank misses every tool_name with or without strip. Only a padded-but-
      # valid name proves strip runs on the match path.
      expect(described_class.by_name('  fake_tool  ')).to eq(fake_tool)
    end

    it 'returns nil for blank input rather than matching by accident' do
      expect(described_class.by_name(nil)).to be_nil
      expect(described_class.by_name('')).to be_nil
      expect(described_class.by_name('   ')).to be_nil
    end
  end

  describe '.by_name is set-scoped' do
    it 'resolves the ticket read tools in both chat sets' do
      expect(described_class.by_name('get_ticket', set: :assistant)).to eq(t::GetTicket)
      expect(described_class.by_name('get_ticket', set: :assistant_with_code)).to eq(t::GetTicket)
      # ⚠️ The DEFAULT moved from :project_chat to :assistant with projekt_chat_abbau.
      # Pinned here and in .all_schemas below, because a default that drifts changes
      # which tools an argument-less caller advertises without any call site changing.
      expect(described_class.by_name('list_tickets')).to eq(t::ListTickets)
    end

    it 'resolves search_knowledge only within :mcp, not in a chat set' do
      expect(described_class.by_name('search_knowledge', set: :mcp)).to eq(t::SearchKnowledge)
      expect(described_class.by_name('search_knowledge', set: :assistant)).to be_nil
      expect(described_class.by_name('search_knowledge')).to be_nil
    end
  end

  describe '.all_schemas' do
    it 'returns one schema per tool in the default (:assistant) set' do
      expect(described_class.all_schemas.size).to eq(described_class.for(:assistant).size)
      expect(described_class.all_schemas).to all(include(:name, :description, :input_schema))
    end

    it 'returns schemas for the requested set' do
      expect(described_class.all_schemas(set: :assistant).size)
        .to eq(described_class.for(:assistant).size)
    end
  end
  # Guard for the fail-closed bar (Story: chat tools under the asker's rights). The
  # bar in Runner#run_tool_safely only fires for tools that DECLARE requires_actor?,
  # so the declaration is the load-bearing part: a new tool that authorizes against
  # a user but forgets the line would silently run with actor nil again. This spec
  # derives the expectation from the tool's own source instead of a hand-kept list,
  # so it cannot go stale when a tool is added.
  describe 'requires_actor? declaration guard' do
    # Every tool class across every set, deduplicated — derived from SETS so a
    # new set cannot slip past this guard.
    let(:all_tools) { described_class::SETS.flat_map { |set| described_class.for(set) }.uniq }

    # Two ways a tool authorizes against a user, and BOTH have to count here.
    # `context.actor` is the direct read. `resolve_code_project` is the indirect
    # one: the five code tools never name the actor, they hand the Context to
    # Base.resolve_code_project, which asks Scope#code_project_ids, which asks
    # ProjectRepositoryPolicy::Scope with the actor. Matching only the literal
    # would leave the guard vacuum-green for exactly the tools whose reach became
    # a rights question, which is the state this feature shipped in before.
    let(:actor_readers) { ['context.actor', 'resolve_code_project'].freeze }

    def reads_actor?(klass)
      source_path = Object.const_source_location(klass.name)&.first
      return false if source_path.nil?

      source = File.read(source_path)
      actor_readers.any? { |marker| source.include?(marker) }
    end

    it 'every tool that reads context.actor or is record-mode declares requires_actor?' do
      offenders = all_tools.reject do |klass|
        needs = reads_actor?(klass) || klass.authorization_mode == :record
        !needs || klass.requires_actor?
      end

      expect(offenders).to be_empty,
                           "these tools authorize against a user but do not declare requires_actor?: #{offenders.inspect}"
    end

    it 'the four actor-dependent tools declare it' do
      expect(t::ListTickets.requires_actor?).to be true
      expect(t::GetTicket.requires_actor?).to be true
      expect(t::SearchKnowledge.requires_actor?).to be true
      expect(t::SummarizeTimeSessions.requires_actor?).to be true
    end

    # The five code tools used to be the counterweight of the guard above ("the
    # code/context tools do NOT require an actor"). They stopped being actor-free
    # the moment their reach became a rights question: on an org thread the project
    # they answer for is resolved through ProjectRepositoryPolicy::Scope, so a call
    # with no actor would reach Pundit with nil instead of a clean tool error.
    it 'the five code tools require an actor, because their reach is a rights question' do
      [t::SearchCodeSymbols, t::GetSymbolDetails, t::GetProjectVision,
       t::ListCapabilities, t::GetCapabilityDetails].each do |tool|
        expect(tool.requires_actor?).to be(true), tool.tool_name
      end
    end

    it 'the detector finds BOTH kinds of actor reader (so an empty offender list means something)' do
      # Mutation probe in spec form: if reads_actor? silently stopped matching,
      # the guard above would be vacuum-green. One probe per marker, because
      # matching only the literal `context.actor` is the failure mode that would
      # let the code tools slip past.
      expect(reads_actor?(t::ListTickets)).to be true
      expect(reads_actor?(t::SearchCodeSymbols)).to be true
    end

    it 'the detector does NOT match a source that authorizes against nobody' do
      # The other half of the probe: without a class the detector says false about,
      # "every tool matched" and "the detector always matches" look identical.
      # TicketCandidates builds a payload out of rows it is handed; it asks nobody.
      expect(reads_actor?(t::TicketCandidates)).to be false
    end
  end
  # The counterpart to the requires_actor? guard, for the two rules the review of round 2
  # found sitting in comments rather than in a check.
  describe 'source-derived guards on the chat sets' do
    let(:chat_tools) { described_class::CHAT_SETS.flat_map { |set| described_class.for(set) }.uniq }

    def source_of(klass)
      path = Object.const_source_location(klass.name)&.first
      path ? File.read(path) : ''
    end

    # G1: fence_guarded: true tells Runner#tool_result_message to leave the content alone.
    # That is only safe for a tool that guarded the foreign parts itself before building
    # its own Markdown. Declaring it without doing so would be an injection hole with a
    # reassuring name.
    it 'every tool declaring fence_guarded: true sanitizes its own foreign text' do
      offenders = chat_tools.select { |k| source_of(k).include?('fence_guarded: true') }
                            .reject { |k| source_of(k).include?('FenceGuard.sanitize') }

      expect(offenders).to be_empty,
                           "these tools opt out of the channel guard without guarding themselves: #{offenders.inspect}"
    end

    it 'the two tools that build their own fences are the ones declaring it' do
      declaring = chat_tools.select { |k| source_of(k).include?('fence_guarded: true') }

      expect(declaring).to contain_exactly(t::SearchCodeSymbols, t::GetSymbolDetails)
    end

    # G2: the rights gate of an ANSWER runs on its citations' area, not on the asker. A
    # chat tool that hands back content rows without citing them is a way around the gate
    # for every OTHER reader of a shared chat. The rule used to live in a comment on
    # Base.json_result; search_knowledge already broke it.
    it 'every chat tool returning content rows passes citations' do
      offenders = chat_tools.select { |k| source_of(k).match?(/^\s*data:/) }
                            .reject { |k| source_of(k).include?('citations:') }

      expect(offenders).to be_empty,
                           "these tools return rows without citing them, so the answer is ungated: #{offenders.inspect}"
    end

    it 'the detector finds a row-returning tool (so an empty offender list means something)' do
      expect(source_of(t::ListTickets)).to match(/^\s*data:/)
      expect(source_of(t::GetProjectVision)).not_to match(/^\s*data:/)
    end

    # G3 (§13-9): a chat tool that cites area 'time_sessions' hands out booked time,
    # and that area gate cannot tell "own" from "all". Such a tool must narrow through
    # TimeSessions::ViewingScope itself. The behavioural half (a can_view_own user
    # gets no project-wide sum) lives in summarize_time_sessions_spec; this pins that
    # the narrowing is not dropped from the source.
    it 'every chat tool citing the time_sessions area narrows through TimeSessions::ViewingScope' do
      offenders = chat_tools.select { |k| source_of(k).include?('Citations.time_report') }
                            .reject { |k| source_of(k).include?('TimeSessions::ViewingScope') }

      expect(offenders).to be_empty,
                           "these tools report booked time without deciding own-vs-all themselves: #{offenders.inspect}"
    end

    it 'the time detector finds the time report tool (so an empty offender list means something)' do
      expect(source_of(t::SummarizeTimeSessions)).to include('Citations.time_report')
      expect(source_of(t::ListTickets)).not_to include('Citations.time_report')
    end
  end
end
