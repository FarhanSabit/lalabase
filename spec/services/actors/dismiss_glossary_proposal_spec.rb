# frozen_string_literal: true

require 'rails_helper'

# Dismissing a proposal of the glossary extraction, and restoring a dismissed
# one (K5b). One UPDATE whose condition is the status of the row decides: only
# an open proposal is dismissed, only a dismissed one restored, whatever the
# copy the caller loaded says. The right is asked again under the row's lock.
# Invented words and names only.
RSpec.describe Actors::DismissGlossaryProposal, :ci_guard, type: :service do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:manager) { member_with(role_with('manage_glossary')) }
  let(:viewer) { member_with(role_with('view_glossary')) }
  let(:proposal) { create(:glossary_proposal, organisation: organisation, term: 'Zorbel-Hub') }
  let(:dismissed) do
    create(:glossary_proposal, :dismissed, organisation: organisation, term: 'Wub', decided_by: manager)
  end

  def role_with(*glossary_actions)
    role = create(:role, organisation: organisation)
    glossary_actions.each { |action| create(:permission, role: role, category: 'glossary', action: action, allowed: true) }
    role
  end

  def member_with(role)
    user = create(:user, first_name: 'Anna', last_name: "Beispiel#{SecureRandom.hex(2)}")
    create(:membership, user: user, organisation: organisation, role: role)
    user
  end

  def dismiss(user: manager, on: proposal, restore: false)
    described_class.call(proposal: on, current_user: user, restore: restore)
  end

  def row_of(record)
    GlossaryProposal.where(id: record.id).pick(:status, :decided_by_id, :decided_at, :updated_at)
  end

  describe 'dismissing' do
    it 'dismisses an open proposal, with who decided and when' do
      result = dismiss

      expect(result).to be_success
      expect(result.resource).to eq(proposal)
      expect(result.resource).to be_dismissed
      status, decided_by_id, decided_at = row_of(proposal)
      expect([status, decided_by_id]).to eq(['dismissed', manager.id])
      expect(decided_at).to be_within(1.minute).of(Time.current)
    end

    # The UPDATE's own condition decides, not the copy the caller loaded: the
    # row changes behind the actor's back.
    %w[accepted dismissed].each do |status|
      it "refuses a proposal that became #{status} after it was loaded, by the status of its row" do
        loaded = GlossaryProposal.find(proposal.id)
        GlossaryProposal.where(id: proposal.id).update_all(status: status)
        before = row_of(proposal)
        expect(loaded).to be_open

        expect(dismiss(on: loaded).code).to eq(:already_processed)
        expect(row_of(proposal)).to eq(before)
      end
    end

    it 'refuses a user with only view_glossary' do
      before = row_of(proposal)

      expect(dismiss(user: viewer).code).to eq(:forbidden)
      expect(row_of(proposal)).to eq(before)
    end

    it 'refuses a deactivated member, whatever the role grants' do
      user = manager
      user.memberships.update_all(active: false)
      before = row_of(proposal)

      expect(dismiss(user: user).code).to eq(:forbidden)
      expect(row_of(proposal)).to eq(before)
    end
  end

  describe 'restoring' do
    it 'opens a dismissed proposal again, without who decided' do
      result = dismiss(on: dismissed, restore: true)

      expect(result).to be_success
      expect(result.resource).to be_open
      expect(row_of(dismissed).first(3)).to eq(['open', nil, nil])
    end

    %w[open accepted].each do |status|
      it "refuses a proposal that became #{status} after it was loaded, by the status of its row" do
        loaded = GlossaryProposal.find(dismissed.id)
        GlossaryProposal.where(id: dismissed.id).update_all(status: status)
        before = row_of(dismissed)
        expect(loaded).to be_dismissed

        expect(dismiss(on: loaded, restore: true).code).to eq(:already_processed)
        expect(row_of(dismissed)).to eq(before)
      end
    end

    it 'refuses a user with only view_glossary' do
      before = row_of(dismissed)

      expect(dismiss(user: viewer, on: dismissed, restore: true).code).to eq(:forbidden)
      expect(row_of(dismissed)).to eq(before)
    end

    it 'refuses a deactivated member, whatever the role grants' do
      user = manager
      record = dismissed
      user.memberships.update_all(active: false)
      before = row_of(record)

      expect(dismiss(user: user, on: record, restore: true).code).to eq(:forbidden)
      expect(row_of(record)).to eq(before)
    end
  end

  it 'refuses to dismiss a proposal deleted in the meantime' do
    gone = proposal
    GlossaryProposal.where(id: gone.id).delete_all

    expect(dismiss(on: gone).code).to eq(:already_processed)
  end

  it 'refuses to restore a proposal deleted in the meantime' do
    gone = dismissed
    GlossaryProposal.where(id: gone.id).delete_all

    expect(dismiss(on: gone, restore: true).code).to eq(:already_processed)
  end

  it 'locks the row before it asks for the right and changes it' do
    record = proposal
    user = manager
    statements = []
    callback = ->(*, payload) { statements << payload[:sql] }

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { dismiss(user: user, on: record) }

    lock = statements.index { |sql| sql.match?(/FROM "glossary_proposals".*FOR UPDATE/) }
    right = statements.index { |sql| sql.include?('FROM "memberships"') }
    change = statements.index { |sql| sql.start_with?('UPDATE "glossary_proposals"') }
    expect([lock, right, change]).to all(be_present)
    expect(lock).to be < right
    expect(right).to be < change
  end
end
