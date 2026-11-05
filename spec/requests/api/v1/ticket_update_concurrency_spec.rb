# frozen_string_literal: true

require 'rails_helper'

# PATCH /api/v1/tickets/:id against a ticket that moves while the request runs.
#
# Until 2026-11-05 PATCH authorized the ticket in its project and then handed
# the id to Actors::SaveTicket, which looks the ticket up across the whole
# organisation. A move in between let the write land in a project the caller
# may not write: found in the API review, a probe removed every assignee of a
# ticket in such a project and answered 200. POST /changes locked the row for
# its title write; PATCH did not. The status was also merged into a copy of
# custom_attributes read before any lock, so a concurrent change to another
# attribute was written back with its old value.
RSpec.describe 'PATCH /api/v1/tickets/:id during a concurrent move', :ci_guard, type: :request do
  def build_pat(user, organisation)
    pat = build(:personal_access_token, user: user, organisations: [organisation], read_only: false)
    pat.token_hash = nil
    pat.token_prefix = nil
    pat.generate_token!
    pat
  end

  describe 'within one connection' do
    let(:organisation) { create(:organisation) }
    let(:user) { create(:user) }
    let(:author) { create(:user) }
    let(:role) { create(:role, organisation: organisation) }
    let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
    let(:elsewhere) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
    let(:pat) { build_pat(user, organisation) }
    let!(:ticket) do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: author,
                        custom_attributes: { 'status' => 'open', 'priority' => 'low' }).tap do |t|
          TicketAssignment.create!(ticket: t, user: author)
        end
      end
    end

    before do
      ActsAsTenant.with_tenant(organisation) do
        [user, author].each do |member|
          create(:membership, user: member, organisation: organisation, role: role, active: true)
          create(:project_permission, user: member, project: project, tickets_access: :read_write)
        end
        # The author may write the destination, the caller may not.
        create(:project_permission, user: author, project: elsewhere, tickets_access: :read_write)
      end
    end

    # Runs `change` on the row right after the rights check said yes, which is
    # where a concurrent request can commit before the write starts.
    def after_the_rights_check(&change)
      allow_any_instance_of(TicketPolicy).to receive(:update?).and_wrap_original do |original|
        original.call.tap { ActsAsTenant.without_tenant(&change) }
      end
    end

    def patch_ticket(attributes)
      patch "/api/v1/tickets/#{ticket.id}", params: { ticket: attributes },
                                            headers: { 'Authorization' => "Bearer #{pat.token}" }, as: :json
    end

    def stored
      ActsAsTenant.without_tenant { Ticket.find(ticket.id) }
    end

    it 'answers a ticket that moved away as not found and writes nothing there' do
      after_the_rights_check { Ticket.where(id: ticket.id).update_all(project_id: elsewhere.id) }

      patch_ticket(assignee_ids: [''], status: 'done')

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to include('error' => 'not_found', 'code' => 'not_found')
      expect(stored.project_id).to eq(elsewhere.id)
      expect(ActsAsTenant.without_tenant { TicketAssignment.where(ticket_id: ticket.id).count }).to eq(1)
      expect(stored.custom_attributes['status']).to eq('open')
    end

    it 'merges the status into the attributes as they are under the lock' do
      after_the_rights_check do
        Ticket.where(id: ticket.id).update_all(custom_attributes: { 'status' => 'open', 'priority' => 'high' })
      end

      patch_ticket(status: 'in_progress')

      expect(response).to have_http_status(:ok)
      expect(stored.custom_attributes).to include('status' => 'in_progress', 'priority' => 'high')
    end

    it 'still writes a ticket that stayed where it was' do
      patch_ticket(status: 'in_progress', assignee_ids: [user.id])

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('data', 'status')).to eq('in_progress')
      expect(ActsAsTenant.without_tenant { TicketAssignment.where(ticket_id: ticket.id).pluck(:user_id) }).to eq([user.id])
    end
  end

  # Real commits and a second connection: the row lock has to hold while the
  # actor writes and while the response reads the ticket, or a move commits in
  # between and the answer carries data of a project the caller cannot read.
  describe 'with a second connection' do
    self.use_transactional_tests = false

    before do
      DatabaseCleaner.clean
      DatabaseCleaner.strategy = :truncation
      DatabaseCleaner.start
      Prosopite.pause
    end

    after { Prosopite.resume }

    def try_to_move(ticket, organisation, destination)
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          ActsAsTenant.with_tenant(organisation) do
            Ticket.transaction do
              connection.execute("SET LOCAL lock_timeout = '100ms'")
              Ticket.where(id: ticket.id).update_all(project_id: destination.id, title: 'Private destination title')
            end
          end
        end
      rescue ActiveRecord::LockWaitTimeout => e
        e
      end
    end

    it 'keeps a move waiting while the actor writes and while the response reads' do
      organisation = create(:organisation)
      user = create(:user)
      ActsAsTenant.current_tenant = organisation
      create(:membership, user: user, organisation: organisation, role: create(:role, organisation: organisation), active: true)
      project = create(:project, organisation: organisation)
      elsewhere = create(:project, organisation: organisation)
      create(:project_permission, user: user, project: project, tickets_access: :read_write)
      ticket = create(:ticket, project: project, organisation: organisation, creator: user, title: 'Original')
      pat = build_pat(user, organisation)
      moves = []

      allow(Actors::SaveTicket).to receive(:call).and_wrap_original do |original, **arguments|
        moves << try_to_move(ticket, organisation, elsewhere).tap { |worker| worker.join(10) }
        original.call(**arguments)
      end
      allow_any_instance_of(Tickets::Serializer).to receive(:summary).and_wrap_original do |original, record|
        moves << try_to_move(ticket, organisation, elsewhere).tap { |worker| worker.join(10) }
        original.call(record)
      end

      patch "/api/v1/tickets/#{ticket.id}", params: { ticket: { status: 'in_progress' } }.to_json,
                                            headers: { 'Authorization' => "Bearer #{pat.token}", 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('data', 'title')).to eq('Original')
      expect(moves.size).to eq(2)
      expect(moves.map(&:value)).to all(be_a(ActiveRecord::LockWaitTimeout))
      # The request has finished: the move can now take the row.
      expect(Ticket.where(id: ticket.id).update_all(project_id: elsewhere.id)).to eq(1)
    ensure
      moves&.each { |worker| worker.join(2) || worker.kill }
    end
  end
end
