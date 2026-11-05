# frozen_string_literal: true

require 'rails_helper'

# What: Lalabase::Tools::SummarizeTimeSessions — sums the project's booked time by
#       billing bucket (billed / in_billing / without_billing) for the project chat.
# Type: Service spec.
# Why:  This is the first report tool (Plan doc/persoenlicher_assistent_plan.md,
#       S2). Two things decide whether it is safe, and both are the load-bearing
#       cases below: (1) the area gate for :time_sessions cannot tell "own" from
#       "all" (§2.4), so the tool must narrow to the asker's own sessions ITSELF
#       when the asker may only view their own (§6.4, §13-9); (2) an answer built
#       only on tool data with no area-bearing citation counts as content-free
#       and reaches every reader ungated (§2.3, PR #534), so every number must be
#       cited with area 'time_sessions'.
RSpec.describe Lalabase::Tools::SummarizeTimeSessions do
  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:role)         { create(:role, organisation: organisation, is_default: true) }

  let(:actor) do
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    user
  end
  let(:colleague) do
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    user
  end

  let(:context) { Lalabase::Tools::Context.new(actor: actor, organisation: organisation, project: project) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def grant_time(view_all:)
    create(:time_session_permission, user: actor, project: project, can_view_own: true, can_view_all: view_all)
  end

  # A time row brings the actor's ProjectPermission with it (the factory), so
  # ticket access widens that row instead of adding a second one.
  def grant_tickets(on, level)
    ProjectPermission.find_or_initialize_by(user: actor, project: on).update!(tickets_access: level)
  end

  def make_admin
    admin_role = create(:role, organisation: organisation, title: 'account_admin')
    actor.memberships.find_by(organisation: organisation).update!(role: admin_role)
  end

  def session(creator:, minutes:, group: nil, occurred_on: Time.zone.parse('2026-08-10 10:00'), ticket: nil)
    create(:time_session, project: project, organisation: organisation, creator: creator, duration: minutes,
                          time_session_group: group, occurred_on: occurred_on, ticket: ticket,
                          billed: group&.billed? || false)
  end

  def execute(args = {})
    described_class.execute(args: args, context: context)
  end

  def run(args = {})
    JSON.parse(execute(args).content)
  end

  describe 'contract metadata' do
    it 'is a read tool that requires an authenticated user' do
      expect(described_class.mutating?).to be false
      expect(described_class.requires_actor?).to be true
      expect(described_class.authorization_mode).to eq(:project)
    end

    it 'advertises the filters the model may pass, none required' do
      schema = described_class.input_schema
      # :project joined in S3a T5 -- the org-wide narrowing that answers "how
      # many hours on Nordlicht?" without changing the thread's standing scope.
      expect(schema[:properties].keys).to contain_exactly(:start_date, :end_date, :creator, :ticket, :project)
      expect(schema[:required]).to eq([])
    end
  end

  describe 'own versus all (the split the area gate cannot make, §2.4 / §6.4)' do
    before do
      session(creator: actor, minutes: 60)
      session(creator: colleague, minutes: 120)
    end

    # THE load-bearing case of S2. Mutation probe: replace the ViewingScope
    # narrowing with `context.project.time_sessions` and this example turns red
    # (total 180 instead of 60).
    it 'gives a can_view_own user only their own minutes and says so' do
      grant_time(view_all: false)

      result = run
      expect(result['scope']).to eq('own')
      expect(result['total']['minutes']).to eq(60)
      expect(result['total']['sessions']).to eq(1)
    end

    it 'gives a can_view_all user the whole project' do
      grant_time(view_all: true)

      result = run
      expect(result['scope']).to eq('all')
      expect(result['total']['minutes']).to eq(180)
      expect(result['total']['sessions']).to eq(2)
    end

    it 'gives an account admin the whole project without a permission row' do
      make_admin

      result = run
      expect(result['scope']).to eq('all')
      expect(result['total']['minutes']).to eq(180)
    end

    it 'refuses a user without a persisted permission row: no numbers, no citation' do
      result = execute

      expect(result.success?).to be false
      expect(result.error).to match(/no access/i)
      expect(result.content).to be_nil
      expect(Array(result.citations)).to be_empty
    end

    it 'refuses a user whose membership was deactivated, despite a stale permission row' do
      grant_time(view_all: true)
      actor.memberships.find_by(organisation: organisation).update!(active: false)

      result = execute
      expect(result.success?).to be false
      expect(result.content).to be_nil
    end

    it 'a creator filter can never widen an own-only view' do
      grant_time(view_all: false)

      result = run(creator: colleague.id)
      expect(result['scope']).to eq('own')
      expect(result['total']['minutes']).to eq(0)
    end
  end

  describe 'the citation that gates the answer (§2.3, regression to PR #534)' do
    before do
      grant_time(view_all: true)
      session(creator: actor, minutes: 60)
    end

    # Mutation probe: pass `citations: []` from the tool and this turns red.
    it 'cites the report with area time_sessions so the answer is content-bearing' do
      result = execute

      expect(result.citations.size).to eq(1)
      citation = result.citations.first
      expect(citation).to include(type: 'time_report', area: 'time_sessions', project_id: project.id)
      # The SAME derivation Chatpost#content_bearing? and the render-gate use.
      expect(Lalabase::Citations.areas_of([citation.stringify_keys])).to eq([:time_sessions])
    end

    it 'the citation passes the REAL area gate for the asker who may see the numbers' do
      citation = execute.citations.first
      expect(ProjectPolicy.new(actor, project).area_access?(citation[:area].to_sym, :read)).to be true
    end

    it 'freezes the applied filters onto the citation so the chip opens the same view' do
      citation = execute(start_date: '2026-08-01', end_date: '2026-08-31').citations.first
      expect(citation[:filters]).to include(start_date: '2026-08-01', end_date: '2026-08-31')
    end

    # Zweitreview F2: without these pins, dropping ticket_id/creator_id from the
    # citation would silently unhook the chip link from the reported number.
    it 'freezes creator and ticket ids onto the citation, but not the ticket title' do
      grant_tickets(project, :read_write)
      ticket = create(:ticket, project: project, organisation: organisation, creator: actor)
      session(creator: actor, minutes: 5, ticket: ticket)

      citation = execute(creator: 'me', ticket: "##{ticket.number}").citations.first
      expect(citation[:filters]).to include(creator_id: actor.id, ticket_id: ticket.id)
      expect(citation[:filters]).not_to have_key(:ticket)
    end

    it 'cites even when the sum is zero (a zero is a number too)' do
      TimeSession.delete_all
      result = execute
      expect(result.success?).to be true
      expect(result.citations.size).to eq(1)
    end
  end

  describe 'billing buckets' do
    let(:open_group)   { create(:time_session_group, organisation: organisation) }
    let(:billed_group) { create(:time_session_group, :billed, organisation: organisation) }

    before do
      grant_time(view_all: true)
      session(creator: actor, minutes: 10, group: billed_group)
      session(creator: actor, minutes: 20, group: open_group)
      session(creator: colleague, minutes: 40)
      session(creator: colleague, minutes: 80)
    end

    it 'partitions the minutes into billed / in_billing / without_billing and totals them' do
      buckets = run['buckets']

      expect(buckets['billed']).to include('minutes' => 10, 'sessions' => 1)
      expect(buckets['in_billing']).to include('minutes' => 20, 'sessions' => 1)
      expect(buckets['without_billing']).to include('minutes' => 120, 'sessions' => 2)
    end

    it 'reports the total and the not-yet-invoiced share the user actually asks for' do
      result = run
      expect(result['total']).to include('minutes' => 150, 'hours' => 2.5, 'sessions' => 4)
      expect(result['not_invoiced']).to include('minutes' => 140, 'hours' => 2.33, 'sessions' => 3)
    end

    it 'uses the bucket names of the UI status filter, so the vocabulary cannot drift' do
      expect(run['buckets'].keys).to eq(TimeSession::BILLING_STATUS_FILTERS)
    end
  end

  describe 'filters' do
    before { grant_time(view_all: true) }

    it 'includes the end date itself (a date bound is inclusive)' do
      session(creator: actor, minutes: 15, occurred_on: Time.zone.parse('2026-08-31 18:30'))
      session(creator: actor, minutes: 25, occurred_on: Time.zone.parse('2026-09-01 08:00'))

      result = run(start_date: '2026-08-01', end_date: '2026-08-31')
      expect(result['total']['minutes']).to eq(15)
      expect(result['filters']).to include('start_date' => '2026-08-01', 'end_date' => '2026-08-31')
    end

    # One example per spelling (not a loop inside one): three executes in one
    # example would trip the N+1 detector on the repeated permission lookup.
    # 999999-01-01 and 2026-8-1 pass Date.strptime and would only die later in
    # Postgres (the documented Date.iso8601 trap) — they pin the FORM half of
    # valid_date?, the first three the calendar half.
    %w[31.08.2026 2026-13-40 letzter-monat 999999-01-01 2026-8-1].each do |bad|
      it "refuses the malformed date #{bad.inspect} instead of silently summing everything" do
        session(creator: actor, minutes: 15)

        result = execute(start_date: bad)
        expect(result.success?).to be false
        expect(result.error).to match(/date/i)
      end
    end

    it 'resolves creator "me" to the asker and accepts a user UUID' do
      session(creator: actor, minutes: 30)
      session(creator: colleague, minutes: 50)

      expect(run(creator: 'me')['total']['minutes']).to eq(30)
      expect(run(creator: colleague.id)['total']['minutes']).to eq(50)
      expect(run(creator: 'me')['filters']['creator_id']).to eq(actor.id)
    end

    it 'refuses a creator that is neither "me" nor a UUID' do
      result = execute(creator: 'Guido')
      expect(result.success?).to be false
      expect(result.error).to match(/creator/i)
    end

    context 'by ticket' do
      let(:ticket) { create(:ticket, project: project, organisation: organisation, creator: actor) }

      before do
        grant_tickets(project, :read_write)
        session(creator: actor, minutes: 30, ticket: ticket)
        session(creator: actor, minutes: 70)
      end

      it 'narrows to one ticket by UUID or by its number, and names the ticket in the filters' do
        expect(run(ticket: ticket.id)['total']['minutes']).to eq(30)
        by_number = run(ticket: "##{ticket.number}")
        expect(by_number['total']['minutes']).to eq(30)
        expect(by_number['filters']['ticket']).to include('id' => ticket.id, 'number' => ticket.number)
      end

      it 'answers "no ticket" for an unknown number, without a sum' do
        result = execute(ticket: '999999')
        expect(result.kind).to eq(:empty)
        expect(result.content).to match(/no ticket/i)
      end

      it 'refuses garbage as a ticket address before any lookup' do
        result = execute(ticket: 'abc')
        expect(result.success?).to be false
        expect(result.error).to match(/ticket/i)
      end

      # The ticket read gate stays in force: a ticket the asker may not read is
      # "no ticket", never a sum revealing that it exists.
      it 'treats a ticket the user may not read as not found' do
        ProjectPermission.where(user: actor, project: project).update_all(tickets_access: ProjectPermission.tickets_accesses[:no_access])
        result = execute(ticket: ticket.id)
        expect(result.kind).to eq(:empty)
      end
    end
  end

  # Viertreview F5/F6: the one seam no unit example covers is the Runner's
  # citation merge. Two reports in one turn must keep BOTH chips, each with its
  # own filters — with the old project-id dedup key the second one vanished and
  # the chip under a two-number answer opened the first report's filters.
  describe 'through the Runner: two reports in one turn' do
    let(:chat)     { build(:chat, organisation: organisation).tap(&:save!) }
    let(:provider) { instance_double(Lalabase::Llm::OpenAiProvider) }

    def tool_call(id, args)
      { id: id, name: 'summarize_time_sessions', args: args }
    end

    it 'keeps one citation per report so each number stays checkable' do
      grant_time(view_all: true)
      session(creator: actor, minutes: 30, occurred_on: Time.zone.parse('2026-07-10 10:00'))
      session(creator: actor, minutes: 50, occurred_on: Time.zone.parse('2026-08-10 10:00'))

      allow(provider).to receive(:chat).and_return(
        { content: nil, tool_calls: [
          tool_call('c1', { start_date: '2026-07-01', end_date: '2026-07-31' }),
          tool_call('c2', { start_date: '2026-08-01', end_date: '2026-08-31' })
        ] },
        { content: 'Juli 0,5 h, August 0,83 h.', tool_calls: [] }
      )

      runner = Lalabase::Tools::Runner.new(
        chat: chat, provider: provider, asker: actor,
        messages: [{ role: 'user', content: 'Stunden im Juli und im August?' }]
      )

      # bucket_totals runs twice inside ONE example, which Prosopite flags as an
      # N+1. That is a test-environment artefact (in the app the tool runs inside
      # a Solid Queue job where Prosopite does not raise), so it is paused HERE,
      # with reason, not file-wide.
      Prosopite.pause
      begin
        runner.call { |_delta| }
      ensure
        Prosopite.resume
      end

      reports = runner.citations.select { |c| c[:type] == 'time_report' }
      expect(reports.size).to eq(2)
      expect(reports.map { |c| c[:filters][:start_date] }).to contain_exactly('2026-07-01', '2026-08-01')
    end
  end

  describe 'tenant and project boundaries' do
    before { grant_time(view_all: true) }

    it 'never counts a session of another project, even one the user created' do
      other_project = create(:project, organisation: organisation)
      create(:time_session_permission, user: actor, project: other_project, can_view_all: true)
      create(:time_session, project: other_project, organisation: organisation, creator: actor, duration: 99)
      session(creator: actor, minutes: 1)

      expect(run['total']['minutes']).to eq(1)
    end

    it 'never counts a session of another organisation' do
      other_org = create(:organisation)
      ActsAsTenant.with_tenant(other_org) do
        create(:time_session, project: create(:project, organisation: other_org), organisation: other_org,
                              creator: create(:user), duration: 99)
      end
      session(creator: actor, minutes: 1)

      expect(run['total']['minutes']).to eq(1)
    end

    it 'errors without a project context' do
      bare = Lalabase::Tools::Context.new(actor: actor, organisation: organisation, project: nil)
      expect(described_class.execute(args: {}, context: bare).error).to match(/project/)
    end
  end

  # S3a T3 (Plan §9.1, §13-9): org-wide sums stay honest ONLY if every project is
  # narrowed through its own ViewingScope tier — "all" in one project must never
  # widen "own" in another, and a project with no persisted permission row
  # contributes nothing at all (§12-S3a).
  describe 'org-wide reach (S3a T3)' do
    let(:project_all)  { create(:project, organisation: organisation) }
    let(:project_own)  { create(:project, organisation: organisation) }
    let(:project_none) { create(:project, organisation: organisation) }

    let(:org_context) do
      Lalabase::Tools::Context.new(
        actor: actor, organisation: organisation, project: nil,
        scope: Lalabase::Tools::Scope.new(organisation: organisation, actor: actor)
      )
    end

    def org_session(target_project, creator:, minutes:, ticket: nil)
      create(:time_session, project: target_project, organisation: organisation, creator: creator,
                            duration: minutes, ticket: ticket,
                            occurred_on: Time.zone.parse('2026-08-10 10:00'))
    end

    # Not paused for Prosopite: the org path reads every tier from one
    # ViewingScope.for_organisation and sums in one query, so a query per
    # project is an N+1 again and turns this whole block red.
    def org_run(args = {})
      described_class.execute(args: args, context: org_context)
    end

    def queries_of(&)
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name] == 'SCHEMA' || payload[:cached] }
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
      count
    end

    # Found in the API review of 2026-11-05: the org path asked ViewingScope
    # once per project (membership, admin role, permission row) and summed each
    # project in a query of its own, so the cost grew with the organisation.
    it 'asks the same number of queries for three projects as for six' do
      org_run # warms what is loaded once per process, not per call
      three = queries_of { org_run }

      # Setup, not the code under test: a loop of factories is not the N+1 here.
      Prosopite.pause do
        3.times do |n|
          extra = create(:project, organisation: organisation)
          create(:time_session_permission, user: actor, project: extra, can_view_own: true, can_view_all: n.even?)
          org_session(extra, creator: actor, minutes: 5)
        end
      end
      six = queries_of { org_run }

      expect(JSON.parse(org_run.content)['total']['minutes']).to eq(60 + 30 + 45 + 15)
      expect(six).to eq(three)
    end

    before do
      create(:time_session_permission, user: actor, project: project_all, can_view_own: true, can_view_all: true)
      create(:time_session_permission, user: actor, project: project_own, can_view_own: true, can_view_all: false)
      org_session(project_all, creator: actor, minutes: 60)
      org_session(project_all, creator: colleague, minutes: 30)
      org_session(project_own, creator: actor, minutes: 45)
      org_session(project_own, creator: colleague, minutes: 90)
      org_session(project_none, creator: actor, minutes: 999)
    end

    it 'sums each project through its own tier: all of A, only own of B, nothing of C' do
      expect(JSON.parse(org_run.content)['total']['minutes']).to eq(60 + 30 + 45)
    end

    it 'reports the mixed tier so the model can say what the numbers cover' do
      expect(JSON.parse(org_run.content)['scope']).to eq('mixed')
    end

    it 'cites every included project and none beyond (origin per project, §14)' do
      cites = org_run.citations

      expect(cites.map { |c| c[:project_id] }).to contain_exactly(project_all.id, project_own.id)
      expect(Lalabase::Citations.areas_of(cites.map(&:stringify_keys))).to eq([:time_sessions])
    end

    it 'reports the coverage of its answer (L7 contract field)' do
      expect(org_run.coverage).to eq(searched: 2, total: 3)
    end

    # The org counterpart of "refuses a user without a persisted permission row":
    # without this exit the tool would answer a zero sum under scope "mixed" with
    # no citation, i.e. content-free and ungated for every reader.
    it 'refuses a user without a persisted time permission in ANY project (fail-closed)' do
      TimeSessionPermission.where(user: actor).delete_all

      result = org_run

      expect(result.success?).to be false
      expect(result.error).to match(/no access/)
      expect(result.coverage).to eq(searched: 0, total: 3)
    end

    # S3a T5: the shared `project` filter of Tools::Base, wired through THIS
    # tool's org path. Tested here and not only through list_tickets because the
    # wiring differs per tool: here the filter has to land before the per-project
    # ViewingScope pass, or the sum is taken over the wrong set of projects and
    # only the reported coverage narrows.
    describe 'the project filter (T5)' do
      it 'sums only the named project' do
        expect(JSON.parse(org_run(project: project_all.name).content)['total']['minutes']).to eq(60 + 30)
      end

      # Named, not counted (T5 review): the question named the project, so the
      # sentence under the answer says so instead of reporting "1 von 3", which
      # is what a rights limit looks like.
      it 'wears the reach it actually had, and names the project' do
        expect(org_run(project: project_all.name).coverage)
          .to eq(searched: 1, total: 3, chosen: project_all.name)
      end

      # The per-project tier still decides INSIDE the chosen project: narrowing to
      # a project where the actor may only see their own sessions must not turn
      # into "all" just because it is now the only one.
      it 'keeps the tier of the chosen project' do
        payload = JSON.parse(org_run(project: project_own.name).content)

        expect(payload['total']['minutes']).to eq(45)
        expect(payload['scope']).to eq('own')
      end

      # A project the actor has no TIME permission in is not reachable, and the
      # filter must not become a way in. It is not among the scope's projects for
      # this area, so the resolver cannot even name it.
      it 'cannot name a project outside the time reach' do
        payload = JSON.parse(org_run(project: project_none.name).content)

        expect(payload['unknown_project']).to be(true)
        expect(payload).not_to have_key('total')
      end
    end

    describe 'the ticket filter across projects (§9.2)' do
      before do
        grant_tickets(project_all, 'read_only')
        grant_tickets(project_own, 'read_only')
      end

      # A readable ticket in a project WITHOUT time reach used to filter the other
      # projects' sessions and report an exact zero under scope "all" (T3 second
      # review) — a wrong number with database authority.
      it 'treats a ticket outside the TIME reach as not found instead of summing to zero' do
        grant_tickets(project_none, 'read_only')
        outside = create(:ticket, project: project_none, organisation: organisation, creator: actor)
        org_session(project_none, creator: actor, minutes: 120, ticket: outside)

        result = org_run(ticket: outside.id)

        expect(result.kind).to eq(:empty)
        expect(result.content).not_to include('total')
      end

      it 'lists only candidates within the time reach' do
        grant_tickets(project_none, 'read_only')
        one  = create(:ticket, project: project_all, organisation: organisation, creator: actor)
        twin = create(:ticket, project: project_own, organisation: organisation, creator: actor)
        create(:ticket, project: project_none, organisation: organisation, creator: actor, title: 'Ausserhalb')

        result = org_run(ticket: one.number.to_s)
        body = JSON.parse(result.content)

        expect(body['candidates'].map { |c| c['id'] }).to contain_exactly(one.id, twin.id)
        expect(result.content).not_to include('Ausserhalb')
        expect(result.coverage).to eq(searched: 2, total: 3)
      end

      it 'narrows the sum to an unambiguous ticket number' do
        create(:ticket, project: project_all, organisation: organisation, creator: actor)
        second = create(:ticket, project: project_all, organisation: organisation, creator: actor)
        org_session(project_all, creator: actor, minutes: 15, ticket: second)

        body = JSON.parse(org_run(ticket: second.number.to_s).content)

        expect(body['total']['minutes']).to eq(15)
      end

      it 'answers an ambiguous ticket number with candidates instead of a sum' do
        one = create(:ticket, project: project_all, organisation: organisation, creator: actor)
        twin = create(:ticket, project: project_own, organisation: organisation, creator: actor)

        body = JSON.parse(org_run(ticket: one.number.to_s).content)

        expect(body['ambiguous']).to be true
        expect(body['candidates'].map { |c| c['id'] }).to contain_exactly(one.id, twin.id)
      end
    end
  end
end
