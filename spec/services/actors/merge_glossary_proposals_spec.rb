# frozen_string_literal: true

require 'rails_helper'

# Merging one proposal of the glossary extraction into another (K5b): two
# spellings of one thing stood as two proposals. The target gains the
# source's spelling and variants as variants, its occurrences and its
# sources; the source is deleted, not dismissed, so a later run finds its
# spelling as a variant of the target. Both must still be open, both of one
# organisation, and the right is asked again under the lock of both rows.
# Invented words and names only.
RSpec.describe Actors::MergeGlossaryProposals, :ci_guard, type: :service do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:manager) { member_with(role_with('manage_glossary')) }
  let(:viewer) { member_with(role_with('view_glossary')) }
  let(:project) { create(:project, organisation: organisation) }
  let(:target) { create(:glossary_proposal, organisation: organisation, term: 'Zorbel-Hub', variants: ['Zorbelhub'], occurrences: 4) }
  let(:source) do
    create(:glossary_proposal, organisation: organisation, term: 'Zorbl Hub', variants: ['Zorbel Hubb', 'ZORBELHUB'],
                               occurrences: 3, category: 'product', hint: 'Ein Werkzeug von Wub')
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

  def merge(from: source, into: target, user: manager)
    described_class.call(source: from, target: into, current_user: user)
  end

  def source_of(proposal, occurrences:, ticket: create(:ticket, organisation: organisation, project: project))
    create(:glossary_proposal_source, organisation: organisation, glossary_proposal: proposal, project: project,
                                      source: ticket, occurrences: occurrences)
  end

  def sources_of(proposal)
    GlossaryProposalSource.where(glossary_proposal_id: proposal.id)
  end

  # What a refused merge must leave as it was.
  def written
    rows = GlossaryProposal.where(id: [source.id, target.id]).order(:id)
    [rows.pluck(:id, :status, :term, :variants, :occurrences, :category, :hint),
     GlossaryProposalSource.order(:id).pluck(:id, :glossary_proposal_id, :occurrences)]
  end

  describe 'the target' do
    it 'gains the spelling and the variants of the source, once per compared form, and its occurrences' do
      result = merge

      expect(result).to be_success
      expect(result.resource).to eq(target)
      target.reload
      expect([target.variants, target.occurrences]).to eq([['Zorbelhub', 'Zorbl Hub', 'Zorbel Hubb'], 7])
    end

    it 'never gets its own term as a variant' do
      wub = create(:glossary_proposal, organisation: organisation, term: 'Wub', variants: %w[zorbel-hub Wubb])

      merge(from: wub)

      expect(target.reload.variants).to eq(%w[Zorbelhub Wub Wubb])
    end

    it 'keeps at most MAX_VARIANTS variants, its own first' do
      full = create(:glossary_proposal, organisation: organisation, term: 'Quarnix',
                                        variants: (1..(GlossaryProposal::MAX_VARIANTS - 1)).map { |n| "Quarnix #{n}" })

      expect(merge(into: full)).to be_success

      expect(full.reload.variants.size).to eq(GlossaryProposal::MAX_VARIANTS)
      expect(full.variants.last(2)).to eq(['Quarnix 9', 'Zorbl Hub'])
    end

    # The source is deleted: a spelling of it with no place left would be known
    # to nobody, and the next run would propose it again. Its other variants
    # only fill what is left.
    it "keeps the source's spelling when the target is full, in the place of the target's last own variant" do
      own = (1..GlossaryProposal::MAX_VARIANTS).map { |n| "Quarnix #{n}" }
      full = create(:glossary_proposal, organisation: organisation, term: 'Quarnix', variants: own)

      expect(merge(into: full)).to be_success

      expect(full.reload.variants).to eq([*own.first(GlossaryProposal::MAX_VARIANTS - 1), 'Zorbl Hub'])
    end

    # Forms the target has, and its own term, are dropped before the cap, so
    # they take no place a new form could have.
    it 'fills the places left only with forms it does not have' do
      full = create(:glossary_proposal, organisation: organisation, term: 'Quarnix',
                                        variants: (1..(GlossaryProposal::MAX_VARIANTS - 2)).map { |n| "Quarnix #{n}" })
      twin = create(:glossary_proposal, organisation: organisation, term: 'quarnix 1', variants: %w[QUARNIX Wub Wubb Wubbs])

      expect(merge(from: twin, into: full)).to be_success

      expect(full.reload.variants.last(3)).to eq(['Quarnix 8', 'Wub', 'Wubb'])
      expect(full.variants.size).to eq(GlossaryProposal::MAX_VARIANTS)
    end

    # A hint belongs to the places it was written from, and the trim to
    # MAX_SOURCES can drop the source's places: the target keeps its own hint,
    # blank or not.
    it 'takes the category of the source only where it has none, and never its hint' do
      own = create(:glossary_proposal, organisation: organisation, term: 'Quarnix', category: 'company', hint: 'Eigener Hinweis')
      expect(target.hint).to eq('')

      merge
      merge(from: create(:glossary_proposal, organisation: organisation, term: 'Wub', category: 'place', hint: 'Fremd'), into: own)

      expect(target.reload.attributes.slice('category', 'hint')).to eq('category' => 'product', 'hint' => '')
      expect(own.reload.attributes.slice('category', 'hint')).to eq('category' => 'company', 'hint' => 'Eigener Hinweis')
    end

    it 'stays open' do
      merge

      expect(target.reload).to be_open
    end
  end

  describe 'the sources' do
    it 'move from the source to the target' do
      moved = Prosopite.pause { [source_of(source, occurrences: 2), source_of(source, occurrences: 1)] }

      merge

      expect(GlossaryProposalSource.where(id: moved.map(&:id)).pluck(:glossary_proposal_id)).to eq([target.id, target.id])
    end

    it 'keep a source both proposals have once, with the occurrences of both' do
      ticket = create(:ticket, organisation: organisation, project: project)
      mine = source_of(target, occurrences: 2, ticket: ticket)
      source_of(source, occurrences: 3, ticket: ticket)

      merge

      expect(sources_of(target).pluck(:id, :source_id, :occurrences)).to eq([[mine.id, ticket.id, 5]])
    end

    it 'keep the MAX_SOURCES with the most occurrences' do
      Prosopite.pause do
        [1, 2, 8].each { |count| source_of(target, occurrences: count) }
        [3, 4, 9].each { |count| source_of(source, occurrences: count) }
      end

      merge

      expect(sources_of(target).order(occurrences: :desc).pluck(:occurrences)).to eq([9, 8, 4, 3, 2])
      expect(GlossaryProposal::MAX_SOURCES).to eq(5)
    end
  end

  it 'deletes the source proposal, with nothing left of it' do
    Prosopite.pause { source_of(source, occurrences: 2) }

    merge

    expect(GlossaryProposal.where(id: source.id)).not_to exist
    expect(sources_of(source)).not_to exist
  end

  # One statement for both rows, in the order of their ids (the rule of
  # Actors::MergeGlossaryTerms): two merges of one pair at once wait for each
  # other instead of deadlocking.
  it 'locks both proposals in one statement ordered by id, before it changes anything' do
    from = source
    into = target
    statements = []
    callback = ->(*, payload) { statements << payload[:sql] }

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { merge(from: from, into: into) }

    locks = statements.each_index.select { |index| statements[index].match?(/FROM "glossary_proposals".*FOR UPDATE/) }
    change = statements.index { |sql| sql.match?(/\A(UPDATE|DELETE FROM) "glossary_proposal/) }
    expect(locks.size).to eq(1)
    expect(statements[locks.first]).to include('ORDER BY "glossary_proposals"."id"')
    expect(locks.first).to be < change
  end

  describe 'refusals, with nothing written' do
    it 'refuses a proposal into itself' do
      before = written

      result = merge(from: target, into: target)

      expect(result.code).to eq(:same_proposal)
      expect(written).to eq(before)
    end

    it 'refuses a proposal of another organisation' do
      foreign = ActsAsTenant.with_tenant(other_organisation) { create(:glossary_proposal, organisation: other_organisation) }
      before = written

      expect(merge(into: foreign).code).to eq(:other_glossary)
      expect(written).to eq(before)
      expect(GlossaryProposal.unscoped.find(foreign.id).variants).to eq([])
    end

    it 'refuses when one of the two is no longer open' do
      accepted = create(:glossary_proposal, :accepted, organisation: organisation, term: 'Wub')
      dismissed = create(:glossary_proposal, :dismissed, organisation: organisation, term: 'Quarnix')
      before = written

      expect(merge(from: accepted).code).to eq(:already_processed)
      expect(merge(into: dismissed).code).to eq(:already_processed)
      expect(written).to eq(before)
      expect(GlossaryProposal.where(id: [accepted.id, dismissed.id]).count).to eq(2)
    end

    # The lock reads both rows again: a copy loaded as open says nothing.
    it 'refuses a proposal decided after it was loaded, by the status of its row' do
      loaded = GlossaryProposal.find(source.id)
      GlossaryProposal.where(id: source.id).update_all(status: 'dismissed')
      before = written

      expect(merge(from: loaded).code).to eq(:already_processed)
      expect(written).to eq(before)
    end

    it 'refuses a proposal deleted in the meantime' do
      gone = source
      GlossaryProposal.where(id: gone.id).delete_all
      before = written

      expect(merge(from: gone).code).to eq(:already_processed)
      expect(written).to eq(before)
    end

    it 'refuses a user with only view_glossary' do
      before = written

      expect(merge(user: viewer).code).to eq(:forbidden)
      expect(written).to eq(before)
    end

    it 'refuses a deactivated member, whatever the role grants' do
      user = manager
      user.memberships.update_all(active: false)
      before = written

      expect(merge(user: user).code).to eq(:forbidden)
      expect(written).to eq(before)
    end
  end
end
