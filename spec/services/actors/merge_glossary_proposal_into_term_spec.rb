# frozen_string_literal: true

require 'rails_helper'

# Merging a proposal of the glossary extraction into a term the glossary has
# (K5b): the proposal is accepted for that term, and its spelling and the
# variants a person chose become heard forms of the term. The term keeps its
# spelling, category and status. One claim on the row decides, the right is
# asked again under the term's lock, and a term of another organisation is
# refused. Invented words and names only.
RSpec.describe Actors::MergeGlossaryProposalIntoTerm, :ci_guard, type: :service do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:manager) { member_with(role_with('manage_glossary')) }
  let(:viewer) { member_with(role_with('view_glossary')) }
  let(:project) { create(:project, organisation: organisation) }
  # Confirmed: the only kind of term the page offers to merge into.
  let(:term) { create(:glossary_term, organisation: organisation, term: 'Zorbel', category: 'company') }
  let(:proposal) do
    create(:glossary_proposal, organisation: organisation, term: 'Zorbel-Hub', category: 'product',
                               variants: ['Zorbelhub', 'Zorbl Hub'], occurrences: 7)
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

  def merge(user: manager, on: proposal, into: term, variants: [])
    described_class.call(proposal: on, term: into, current_user: user, variants: variants)
  end

  # What a refused merge must leave as it was.
  def written
    [TermCorrection.count, GlossaryTerm.where(id: term.id).pick(:term, :category, :status, :lock_version),
     GlossaryProposal.where(id: proposal.id).pick(:status, :glossary_term_id, :decided_by_id, :decided_at)]
  end

  it 'accepts the proposal for the term, with who decided and when' do
    result = merge

    expect(result).to be_success
    expect(result.resource).to eq(term)
    proposal.reload
    expect([proposal.status, proposal.glossary_term_id, proposal.decided_by_id]).to eq(['accepted', term.id, manager.id])
    expect(proposal.decided_at).to be_within(1.minute).of(Time.current)
  end

  it 'makes the spelling of the proposal and the chosen variants heard forms of the term, as an accept does' do
    busy = create(:project, organisation: organisation)
    Prosopite.pause do
      create(:glossary_proposal_source, organisation: organisation, glossary_proposal: proposal, project: project, occurrences: 2)
      create(:glossary_proposal_source, organisation: organisation, glossary_proposal: proposal, project: busy, occurrences: 5)
    end

    merge(variants: ['zorbl hub', 'Fremdwort'])

    expect(term.term_corrections.pluck(:heard)).to contain_exactly('Zorbel-Hub', 'Zorbl Hub')
    expect(term.term_corrections.distinct.pluck(:status, :origin, :project_id, :corrected_by_id, :replaced_count))
      .to eq([['confirmed', 'extraction', busy.id, manager.id, 1]])
    expect(term.term_corrections.distinct.pluck(:meeting_id, :person_id, :user_id, :line_index)).to eq([[nil, nil, nil, nil]])
  end

  it 'keeps spelling, category and status of the term' do
    merge(variants: ['Zorbelhub'])

    term.reload
    expect([term.term, term.category, term.status]).to eq(%w[Zorbel company confirmed])
  end

  it 'skips a form that is the term itself and one the term has already' do
    hub = create(:glossary_term, organisation: organisation, term: 'ZorbelHub')
    create(:term_correction, organisation: organisation, glossary_term: hub, heard: 'zorbel-hub')

    expect(merge(into: hub, variants: ['Zorbelhub', 'Zorbl Hub'])).to be_success
    expect(hub.term_corrections.pluck(:heard, :origin)).to contain_exactly(%w[zorbel-hub meeting], ['Zorbl Hub', 'extraction'])
  end

  # The one lock order of the glossary: the term first, then the proposal;
  # the right is asked under the term's lock, before anything is written.
  it 'locks the term, then asks for the right, then claims the proposal' do
    merged = proposal
    into = term
    user = manager
    expect(Glossary::TermLock).to receive(:call).with(term: into).and_call_original
    statements = []
    callback = ->(*, payload) { statements << payload[:sql] }

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { merge(user: user, on: merged, into: into) }

    lock = statements.index { |sql| sql.include?('FROM "glossary_terms"') && sql.include?('FOR UPDATE') }
    right = statements.index { |sql| sql.include?('FROM "memberships"') }
    claim = statements.index { |sql| sql.start_with?('UPDATE "glossary_proposals"') }
    expect([lock, right, claim]).to all(be_present)
    expect(lock).to be < right
    expect(right).to be < claim
    expect(statements.first(claim).grep(/FROM "glossary_proposals".*FOR UPDATE/)).to be_empty
  end

  describe 'refusals, with nothing written' do
    it 'refuses a term of another organisation' do
      foreign = ActsAsTenant.with_tenant(other_organisation) { create(:glossary_term, organisation: other_organisation) }
      before = written

      result = merge(into: foreign, variants: ['Zorbelhub'])

      expect(result.code).to eq(:other_glossary)
      expect(written).to eq(before)
      expect(TermCorrection.unscoped.where(glossary_term_id: foreign.id)).not_to exist
    end

    it 'refuses a term deleted in the meantime' do
      gone = term
      GlossaryTerm.where(id: gone.id).delete_all

      result = merge(into: gone, variants: ['Zorbelhub'])

      expect(result.code).to eq(:not_found)
      expect(proposal.reload).to be_open
      expect(TermCorrection.count).to eq(0)
    end

    # Review round 2 of #129. The page offers only confirmed terms, and the
    # lock reads the row again: a term rejected after the page loaded it
    # would take heard forms that work nowhere, and the proposal would count
    # as accepted, its spelling never proposed again.
    it 'refuses a term rejected after it was loaded, by the status of its row' do
      loaded = GlossaryTerm.find(term.id)
      GlossaryTerm.where(id: term.id).update_all(status: 'rejected')
      expect(loaded).to be_confirmed

      result = merge(into: loaded, variants: ['Zorbelhub'])

      expect(result.code).to eq(:term_not_confirmed)
      expect(result.errors.join).to eq(I18n.t('controllers.glossary.proposals.term_not_confirmed'))
      expect(proposal.reload).to have_attributes(status: 'open', glossary_term_id: nil, decided_by_id: nil)
      expect(TermCorrection.count).to eq(0)
    end

    it 'refuses a term that is still a proposal' do
      proposed = create(:glossary_term, :proposed, organisation: organisation, term: 'Quarnix')

      expect(merge(into: proposed, variants: ['Zorbelhub']).code).to eq(:term_not_confirmed)
      expect(proposal.reload).to be_open
      expect(proposed.reload).to be_proposed
      expect(TermCorrection.count).to eq(0)
    end

    # A refusal of the term's state answers only someone who may decide.
    it 'asks for the right before it reads the status of the term' do
      GlossaryTerm.where(id: term.id).update_all(status: 'rejected')

      expect(merge(user: viewer, variants: ['Zorbelhub']).code).to eq(:forbidden)
    end

    it 'refuses a proposal accepted or dismissed before' do
      accepted = create(:glossary_proposal, :accepted, organisation: organisation, term: 'Wub')
      dismissed = create(:glossary_proposal, :dismissed, organisation: organisation, term: 'Quarnix')

      expect(merge(on: accepted).code).to eq(:already_processed)
      expect(merge(on: dismissed).code).to eq(:already_processed)
      expect(TermCorrection.count).to eq(0)
      expect(GlossaryProposal.where(id: [accepted.id, dismissed.id]).order(:term).pluck(:term, :status, :glossary_term_id))
        .to eq([['Quarnix', 'dismissed', nil], ['Wub', 'accepted', nil]])
    end

    # The claim's own condition decides, not the copy the caller loaded.
    it 'refuses a proposal decided after it was loaded, by the status of its row' do
      loaded = GlossaryProposal.find(proposal.id)
      GlossaryProposal.where(id: proposal.id).update_all(status: 'dismissed')
      expect(loaded).to be_open

      result = merge(on: loaded, variants: ['Zorbelhub'])

      expect(result.code).to eq(:already_processed)
      expect(TermCorrection.count).to eq(0)
      expect(GlossaryProposal.where(id: proposal.id).pick(:status, :glossary_term_id)).to eq(['dismissed', nil])
    end

    it 'refuses a user with only view_glossary' do
      before = written

      expect(merge(user: viewer, variants: ['Zorbelhub']).code).to eq(:forbidden)
      expect(written).to eq(before)
    end

    it 'refuses a deactivated member, whatever the role grants' do
      user = manager
      user.memberships.update_all(active: false)
      before = written

      expect(merge(user: user, variants: ['Zorbelhub']).code).to eq(:forbidden)
      expect(written).to eq(before)
    end
  end
end
