# frozen_string_literal: true

require 'rails_helper'

# What a relation write may touch. The caller decides the answer; this object only finds: the
# other ticket through Tickets::ReadableForToken, the relation through TicketRelation.visible_to.
# With a token both stop at its reach, so an account admin who reads every project and holds a
# token for A alone cannot name a ticket or a relation in B. Each nil stands next to a positive
# case, so none of them is green in a vacuum.
RSpec.describe Tickets::RelationAccess, :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:foreign_organisation) { create(:organisation) }
  let(:project_a) { new_project(organisation) }
  let(:project_b) { new_project(organisation) }
  let(:hidden_project) { new_project(organisation) }

  let(:reader) { member_reading(project_a, project_b) }
  let(:admin) { account_admin }

  let(:ticket_a) { new_ticket(project_a, 'In reach') }
  let(:ticket_a2) { new_ticket(project_a, 'Also in reach') }
  let(:ticket_b) { new_ticket(project_b, 'Readable, out of reach') }
  let(:hidden_ticket) { new_ticket(hidden_project, 'Unreadable') }

  after { ActsAsTenant.current_tenant = nil }

  # Setup only: each create loads its organisation for the belongs_to check, which Prosopite
  # would report from the second record on. What the object itself asks stays scanned.
  def new_project(org)
    Prosopite.pause { ActsAsTenant.with_tenant(org) { create(:project, organisation: org) } }
  end

  def new_ticket(project, title)
    Prosopite.pause { ActsAsTenant.with_tenant(project.organisation) { create(:ticket, project: project, title: title) } }
  end

  def link(source, target, type = :blocks)
    Prosopite.pause do
      ActsAsTenant.with_tenant(source.organisation) do
        TicketRelation.create!(source_ticket: source, target_ticket: target, relation_type: type)
      end
    end
  end

  def member_reading(*projects)
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      projects.each { |project| create(:project_permission, user: user, project: project, tickets_access: 'read_only') }
    end
    user
  end

  def account_admin
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:admin_role, organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    user
  end

  def token_reaching_a(user)
    Prosopite.pause do
      create(:personal_access_token, user: user, organisations: [organisation],
                                     project_scopes: { organisation => [project_a] })
    end
  end

  def access(user, token:)
    described_class.new(user: user, organisation: organisation, token: token)
  end

  it 'requires the token keyword: leaving it out would drop the limit silently' do
    expect { described_class.new(user: build(:user), organisation: organisation) }
      .to raise_error(ArgumentError, /token/)
  end

  def other_ticket(user, id, token: nil)
    ActsAsTenant.with_tenant(organisation) { access(user, token: token).other_ticket(id) }
  end

  def relation(user, ticket, id, token: nil)
    ActsAsTenant.with_tenant(organisation) { access(user, token: token).relation(ticket, id) }
  end

  describe '#other_ticket' do
    it 'finds a readable ticket' do
      expect(other_ticket(reader, ticket_b.id)).to eq(ticket_b)
    end

    {
      'a missing id' => -> { SecureRandom.uuid },
      'a ticket of a foreign organisation' => -> { new_ticket(new_project(foreign_organisation), 'Foreign').id },
      'a ticket the user may not read' => -> { hidden_ticket.id }
    }.each do |name, id|
      it "gives nil for #{name}" do
        expect(other_ticket(reader, instance_exec(&id))).to be_nil
      end
    end

    it 'gives nil for a ticket the user may read and the token does not reach' do
      token = token_reaching_a(reader)

      expect(other_ticket(reader, ticket_a.id, token: token)).to eq(ticket_a)
      expect(other_ticket(reader, ticket_b.id, token: token)).to be_nil
    end

    it 'stops an account admin at the reach of a token for project A' do
      expect(other_ticket(admin, ticket_b.id, token: token_reaching_a(admin))).to be_nil
    end

    it 'finds nothing through a token outside the organisation, never everything' do
      token = Prosopite.pause { create(:personal_access_token, user: admin, organisations: [foreign_organisation]) }

      expect(other_ticket(admin, ticket_a.id)).to eq(ticket_a)
      expect(other_ticket(admin, ticket_a.id, token: token)).to be_nil
    end

    ['not-a-uuid', '', nil].each do |id|
      it "gives nil for #{id.inspect}, and no database error" do
        ticket_a

        expect(other_ticket(admin, id)).to be_nil
      end
    end

    it 'finds project B for the account admin without a token' do
      expect(other_ticket(admin, ticket_b.id)).to eq(ticket_b)
    end
  end

  describe '#relation' do
    it 'finds a visible relation from both of its ends' do
      edge = link(ticket_a, ticket_b)

      expect(relation(reader, ticket_a, edge.id)).to eq(edge)
      expect(relation(reader, ticket_b, edge.id)).to eq(edge)
    end

    it 'gives nil for a relation that does not touch the ticket' do
      edge = link(ticket_a, ticket_b)

      expect(relation(reader, ticket_a2, edge.id)).to be_nil
    end

    it 'gives nil when the other end is hidden, from either end' do
      outgoing = link(ticket_a, hidden_ticket)
      incoming = link(hidden_ticket, ticket_a, :relates_to)

      expect(relation(reader, ticket_a, outgoing.id)).to be_nil
      expect(relation(reader, ticket_a, incoming.id)).to be_nil
      # The rows exist: the account admin sees both, so the hiding is the rule.
      expect(relation(admin, ticket_a, outgoing.id)).to eq(outgoing)
      expect(relation(admin, ticket_a, incoming.id)).to eq(incoming)
    end

    it 'stops an account admin at the reach of a token for project A' do
      edge = link(ticket_a, ticket_b)
      inside = link(ticket_a, ticket_a2)
      token = token_reaching_a(admin)

      expect(relation(admin, ticket_a, inside.id, token: token)).to eq(inside)
      expect(relation(admin, ticket_a, edge.id, token: token)).to be_nil
    end

    it 'stops at the reach whichever end lies outside it' do
      incoming = link(ticket_b, ticket_a)
      token = token_reaching_a(admin)

      expect(relation(admin, ticket_a, incoming.id)).to eq(incoming)
      expect(relation(admin, ticket_a, incoming.id, token: token)).to be_nil
    end

    it 'finds nothing through a token outside the organisation, never everything' do
      edge = link(ticket_a, ticket_a2)
      token = Prosopite.pause { create(:personal_access_token, user: admin, organisations: [foreign_organisation]) }

      expect(relation(admin, ticket_a, edge.id, token: token)).to be_nil
    end

    ['not-a-uuid', '', nil].each do |id|
      it "gives nil for #{id.inspect}, and no database error" do
        link(ticket_a, ticket_a2)

        expect(relation(admin, ticket_a, id)).to be_nil
      end
    end

    it 'finds the relation A-B for the account admin without a token' do
      edge = link(ticket_a, ticket_b)

      expect(relation(admin, ticket_a, edge.id)).to eq(edge)
    end

    it 'gives nil for the relation of a foreign organisation, even from one of its tickets' do
      foreign_project = new_project(foreign_organisation)
      foreign_ticket = new_ticket(foreign_project, 'Foreign A')
      foreign = link(foreign_ticket, new_ticket(foreign_project, 'Foreign B'))

      expect(relation(admin, ticket_a, foreign.id)).to be_nil
      expect(relation(admin, foreign_ticket, foreign.id)).to be_nil
    end
  end
end
