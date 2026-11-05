# frozen_string_literal: true

require 'rails_helper'

# What: Lalabase::Tools::ListTickets — lists the project's tickets as JSON with an
#       exact meta.total, now also offered inside the project chat's tool loop.
# Type: Service spec.
# Why:  The tool answers quantity questions from the database, so the number it
#       reports is only as trustworthy as the rights gate around it. Three things
#       must hold: (1) rows come exclusively through Pundit.policy_scope!, so a
#       user without ticket read access gets an empty list and never a foreign
#       row; (2) the tool declares requires_actor?, which is what makes the
#       Runner's fail-closed bar apply to it; (3) attacker-fillable text is
#       fence-neutralised before it reaches our own model context.
RSpec.describe Lalabase::Tools::ListTickets do
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

  let(:context) { Lalabase::Tools::Context.new(actor: actor, organisation: organisation, project: project) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def grant_tickets(access)
    create(:project_permission, user: actor, project: project, tickets_access: access)
  end

  def run(args = {})
    JSON.parse(described_class.execute(args: args, context: context).content)
  end

  describe 'contract metadata' do
    it 'is a read tool that requires an authenticated user' do
      expect(described_class.mutating?).to be false
      expect(described_class.requires_actor?).to be true
    end
  end

  # The assistant hands the model's arguments in unchecked; over MCP the SDK
  # checks the type, not the size. Both used to raise past the tool.
  describe 'a page no list has' do
    before { grant_tickets(:read_only) }

    [ListPaging::MAX_PAGE + 1, ['1'], { 'x' => 1 }].each do |value|
      it "answers page #{value.inspect} as invalid input" do
        result = described_class.execute(args: { page: value }, context: context)
        expect(result.success?).to be false
        expect(result.code).to eq(:invalid_input)
        expect(result.error).to match(/invalid page/)
      end
    end

    it 'answers per_page that is a list as invalid input' do
      result = described_class.execute(args: { per_page: [5] }, context: context)
      expect(result.code).to eq(:invalid_input)
    end
  end

  describe 'rights of the asking user' do
    let!(:own_ticket) { create(:ticket, project: project, organisation: organisation, creator: actor) }

    it 'returns the project tickets with an exact total when the user may read them' do
      grant_tickets(:read_write)

      result = run

      expect(result['data'].map { |t| t['id'] }).to eq([own_ticket.id])
      expect(result['meta']['total']).to eq(1)
    end

    # THE load-bearing case: no ticket read access must yield an empty list, not
    # the project's rows. Mutation probe (Spec §8): drop Pundit.policy_scope! from
    # ListTickets#execute and this example turns red.
    it 'returns an empty list for a user without ticket read access' do
      expect(run['data']).to be_empty
      expect(run['meta']['total']).to eq(0)
    end

    it 'never returns a ticket from another project the user has no access to' do
      grant_tickets(:read_write)
      other_project = create(:project, organisation: organisation)
      foreign = create(:ticket, project: other_project, organisation: organisation, creator: actor)

      ids = run['data'].map { |t| t['id'] }
      expect(ids).to include(own_ticket.id)
      expect(ids).not_to include(foreign.id)
    end

    it 'never returns a ticket from another organisation' do
      grant_tickets(:read_write)
      other_org = create(:organisation)
      foreign = ActsAsTenant.with_tenant(other_org) do
        other_creator = create(:user)
        create(:ticket, project: create(:project, organisation: other_org),
                        organisation: other_org, creator: other_creator)
      end

      expect(run['data'].map { |t| t['id'] }).not_to include(foreign.id)
    end
  end

  # The result string IS the MCP wire format (Mcp::ToolCall#result_to_response passes
  # result.content through verbatim), so it must stay byte-exact. A ticket description
  # in a developer tool routinely contains a real code fence; rewriting it here would
  # hand an MCP client bytes it cannot turn back, and a client writing them back via
  # create_ticket would persist the corruption. The fence guard for OUR model loop sits
  # on the channel instead (Runner#tool_result_message, pinned in runner_spec).
  describe 'payload fidelity (the string is also the MCP wire format)' do
    it 'returns a code fence in a title byte-exact' do
      grant_tickets(:read_write)
      create(:ticket, project: project, organisation: organisation, creator: actor,
                      title: 'Bug in ```ruby``` block')

      expect(run['data'].first['title']).to eq('Bug in ```ruby``` block')
    end
  end

  # The citations are the rights gate for everyone EXCEPT the asker: an answer whose
  # content came only from this tool would count as content-free without them, and
  # Chatpost#gated_streaming? / MessageComponent#redacted? would show the ticket rows
  # to every reader of the shared chat regardless of their own rights.
  describe 'citations (the gate for other readers of the shared chat)' do
    it 'cites every returned row with the tickets area' do
      grant_tickets(:read_write)
      one = create(:ticket, project: project, organisation: organisation, creator: actor)
      two = create(:ticket, project: project, organisation: organisation, creator: actor)

      cites = described_class.execute(args: {}, context: context).citations

      expect(cites.map { |c| c[:id] }).to match_array([one.id, two.id])
      expect(cites.map { |c| c[:area] }.uniq).to eq(['tickets'])
      # Symbol keys like every other citation producer; the jsonb column stringifies
      # them on assignment, which is the form Citations.areas_of (the gate) reads.
      expect(Lalabase::Citations.areas_of(cites.map(&:stringify_keys))).to eq([:tickets])
    end

    it 'cites nothing when the policy scope returned nothing' do
      create(:ticket, project: project, organisation: organisation, creator: actor)

      expect(described_class.execute(args: {}, context: context).citations).to be_empty
    end
  end

  # Status is a per-project select attribute in JSONB, never a fixed enum. Without the
  # vocabulary the model guesses "open", gets zero rows and reports an exact,
  # database-backed "0" — the estimate this tool replaced, in a more convincing shape.
  describe 'status vocabulary in meta' do
    it 'lists the project configured status values' do
      grant_tickets(:read_write)
      create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                           options: { 'allowed_values' => [
                                             { 'value' => 'offen', 'labels' => { 'de' => 'Offen' } },
                                             { 'value' => 'erledigt', 'labels' => { 'de' => 'Erledigt' } }
                                           ] })

      expect(run['meta']['available_statuses']).to eq(%w[offen erledigt])
    end

    it 'is an empty list when the project configures no status attribute' do
      grant_tickets(:read_write)

      expect(run['meta']['available_statuses']).to eq([])
    end

    # The counterweight: without it the example above would also pass if the tool
    # simply echoed a hardcoded English vocabulary.
    it 'does not invent an English default the project never configured' do
      grant_tickets(:read_write)
      create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                           options: { 'allowed_values' => [{ 'value' => 'offen' }] })

      expect(run['meta']['available_statuses']).not_to include('open')
    end
  end

  # G3 (Review, Runde 2): a page past the end used to return zero rows next to a non-zero
  # total. No rows means no citations, so the ANSWER carried no area and the number — the
  # whole point of this tool — would have reached every reader of a shared chat ungated.
  describe 'a page past the end (the number must never travel ungated)' do
    before do
      grant_tickets(:read_write)
      3.times { create(:ticket, project: project, organisation: organisation, creator: actor) }
    end

    it 'returns the last page with rows instead of an empty one' do
      result = run(page: 9, per_page: 2)

      expect(result['meta']['total']).to eq(3)
      expect(result['data']).not_to be_empty
      expect(result['meta']['page']).to eq(2)
    end

    it 'still cites, so an answer built on that number stays gated' do
      cites = described_class.execute(args: { page: 9, per_page: 2 }, context: context).citations

      expect(cites).not_to be_empty
      expect(Lalabase::Citations.areas_of(cites.map(&:stringify_keys))).to eq([:tickets])
    end

    it 'leaves a page within range untouched' do
      expect(run(page: 2, per_page: 2)['meta']['page']).to eq(2)
      expect(run(page: 1, per_page: 2)['data'].size).to eq(2)
    end

    it 'keeps the requested page when there is nothing to page through' do
      empty_project = create(:project, organisation: organisation)
      create(:project_permission, user: actor, project: empty_project, tickets_access: :read_write)
      empty_context = Lalabase::Tools::Context.new(actor: actor, organisation: organisation,
                                                   project: empty_project)

      result = JSON.parse(described_class.execute(args: { page: 4 }, context: empty_context).content)

      expect(result['meta']['total']).to eq(0)
      expect(result['meta']['page']).to eq(4)
    end
  end

  # G4: the gate needs ONE row carrying area 'tickets'; a full page of source chips under
  # a one-number answer helps nobody and accumulates across tool rounds.
  describe 'citation cap' do
    it 'cites at most MAX_CITATIONS rows while still returning the full page' do
      grant_tickets(:read_write)
      (described_class::MAX_CITATIONS + 3).times do
        create(:ticket, project: project, organisation: organisation, creator: actor)
      end

      result = described_class.execute(args: {}, context: context)

      expect(JSON.parse(result.content)['data'].size).to eq(described_class::MAX_CITATIONS + 3)
      expect(result.citations.size).to eq(described_class::MAX_CITATIONS)
    end
  end

  describe 'guards that predate the chat unlock' do
    it 'rejects a hallucinated non-UUID assignee instead of hitting the uuid column' do
      grant_tickets(:read_write)

      result = described_class.execute(args: { assignee: 'not-a-uuid' }, context: context)

      expect(result.success?).to be false
      expect(result.error).to match(/invalid assignee/)
    end

    it 'errors without a project context' do
      result = described_class.execute(
        args: {}, context: Lalabase::Tools::Context.new(actor: actor, organisation: organisation)
      )

      expect(result.success?).to be false
      expect(result.error).to eq('project context missing')
    end
  end

  # S3a T3 (Plan §9.1, §12-S3a): the same tool with org-wide reach. The Scope
  # object is the one rights path; a project outside the asker's ticket reach
  # must never surface, and the answer discloses how far it looked (L7).
  describe 'org-wide reach (S3a T3)' do
    # All three eager, so the coverage total is the same in every example.
    let!(:reachable)  { create(:project, organisation: organisation) }
    let!(:reachable2) { create(:project, organisation: organisation) }
    let!(:forbidden)  { create(:project, organisation: organisation) }

    let(:org_context) do
      Lalabase::Tools::Context.new(
        actor: actor, organisation: organisation, project: nil,
        scope: Lalabase::Tools::Scope.new(organisation: organisation, actor: actor)
      )
    end

    let!(:visible_ticket) { create(:ticket, project: reachable, organisation: organisation, creator: actor) }
    let!(:foreign_ticket) { create(:ticket, project: forbidden, organisation: organisation, creator: actor) }

    before { create(:project_permission, user: actor, project: reachable, tickets_access: 'read_only') }

    def run_org(args = {})
      described_class.execute(args: args, context: org_context)
    end

    it 'lists only tickets from projects whose tickets the asker may read (§12-S3a)' do
      ids = JSON.parse(run_org.content)['data'].map { |t| t['id'] }

      expect(ids).to include(visible_ticket.id)
      expect(ids).not_to include(foreign_ticket.id)
    end

    it 'labels every row with its project (the §14 origin rule needs the label)' do
      row = JSON.parse(run_org.content)['data'].find { |t| t['id'] == visible_ticket.id }

      expect(row['project']).to eq('id' => reachable.id, 'name' => reachable.name)
    end

    # A status name means something else in every project; each row says what its own
    # project means by it, read for all projects of the page at once.
    it 'gives every row the status functions of its own project, in one read' do
      create(:project_permission, user: actor, project: reachable2, tickets_access: 'read_only')
      [[reachable, 'is_completed'], [reachable2, 'is_in_progress']].each do |where, function|
        create(:ticket_attribute_definition, project: where, name: 'status', field_type: 'select',
                                             options: { 'allowed_values' => [
                                               { 'value' => 'Fertig', 'system_functions' => [function] }
                                             ] })
      end
      second = create(:ticket, project: reachable2, organisation: organisation, creator: actor)
      [visible_ticket, second].each { |t| t.update_columns(custom_attributes: { 'status' => 'Fertig' }) }

      reads = []
      callback = ->(*, payload) { reads << payload[:sql] if payload[:sql].include?('"ticket_attribute_definitions"."options"') }
      rows = ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        JSON.parse(run_org.content)['data']
      end

      functions = rows.to_h { |row| [row['id'], row['status_functions']] }
      expect(functions).to eq(visible_ticket.id => ['is_completed'], second.id => ['is_in_progress'])
      expect(reads.size).to eq(1)
    end

    it 'reports the coverage of its answer (L7 contract field)' do
      expect(run_org.coverage).to eq(searched: 1, total: 3)
    end

    # The Context contract says exactly one of project/scope is set; a context
    # carrying BOTH must take the single-project path (org_wide? needs project nil).
    it 'takes the single-project path when a project is set, scope or not' do
      create(:project_permission, user: actor, project: reachable2, tickets_access: 'read_only')
      create(:ticket, project: reachable2, organisation: organisation, creator: actor)
      both = Lalabase::Tools::Context.new(
        actor: actor, organisation: organisation, project: reachable,
        scope: Lalabase::Tools::Scope.new(organisation: organisation, actor: actor)
      )

      result = described_class.execute(args: {}, context: both)

      expect(JSON.parse(result.content)['data'].map { |t| t['id'] }).to contain_exactly(visible_ticket.id)
      expect(result.coverage).to be_nil
    end

    # "Tools never lean on the ambient tenant": an account admin's policy scope is
    # scope.all, so the organisation_id bound is the ONLY thing between a leaky
    # scope and a foreign organisation's ticket.
    it 'never leaves the organisation, even if the scope handed it a foreign project id' do
      admin_role = create(:role, organisation: organisation, title: 'account_admin')
      actor.memberships.find_by(organisation: organisation).update!(role: admin_role)
      foreign_org = create(:organisation)
      foreign_ticket = ActsAsTenant.with_tenant(foreign_org) do
        foreign_project = create(:project, organisation: foreign_org)
        create(:ticket, project: foreign_project, organisation: foreign_org, creator: create(:user))
      end
      leaky = instance_double(Lalabase::Tools::Scope,
                              project_ids: [reachable.id, foreign_ticket.project_id],
                              coverage: { searched: 2, total: 2 })
      ctx = Lalabase::Tools::Context.new(actor: actor, organisation: organisation, project: nil, scope: leaky)

      ids = JSON.parse(described_class.execute(args: {}, context: ctx).content)['data'].map { |t| t['id'] }

      expect(ids).to include(visible_ticket.id)
      expect(ids).not_to include(foreign_ticket.id)
    end

    it 'unions the status vocabulary of the reachable projects, never a forbidden one' do
      create(:project_permission, user: actor, project: reachable2, tickets_access: 'read_only')
      create(:ticket_attribute_definition, project: reachable, name: 'status', field_type: 'select',
                                           options: { 'allowed_values' => [{ 'value' => 'offen' }] })
      create(:ticket_attribute_definition, project: reachable2, name: 'status', field_type: 'select',
                                           options: { 'allowed_values' => [{ 'value' => 'in_arbeit' }] })
      create(:ticket_attribute_definition, project: forbidden, name: 'status', field_type: 'select',
                                           options: { 'allowed_values' => [{ 'value' => 'geheim' }] })

      statuses = JSON.parse(run_org.content)['meta']['available_statuses']

      expect(statuses).to contain_exactly('offen', 'in_arbeit')
    end
  end
end
