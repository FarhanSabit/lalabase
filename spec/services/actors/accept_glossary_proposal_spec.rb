# frozen_string_literal: true

require 'rails_helper'

# Accepting a proposal of the glossary extraction (K5b): it becomes a
# confirmed term of the glossary (a new one, or the term of the same compared
# form the glossary has), and the variants a person chose become heard forms
# of that term. One claim on the row decides: a proposal accepted or dismissed
# in the meantime is refused, and nothing is written. The right is asked again
# under the term's lock. Invented words and names only.
RSpec.describe Actors::AcceptGlossaryProposal, :ci_guard, type: :service do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:manager) { member_with(role_with('manage_glossary')) }
  let(:viewer) { member_with(role_with('view_glossary')) }
  let(:project) { create(:project, organisation: organisation) }
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

  def accept(user: manager, on: proposal, **choices)
    described_class.call(proposal: on, current_user: user, **choices)
  end

  def term_of_form(spelling)
    GlossaryTerm.find_by(normalized_term: GlossaryText.normalize(spelling))
  end

  def source_for(project, occurrences:, of: proposal)
    create(:glossary_proposal_source, organisation: organisation, glossary_proposal: of, project: project,
                                      source: create(:ticket, organisation: organisation, project: self.project),
                                      occurrences: occurrences)
  end

  # What a refused accept must leave as it was.
  def written
    [GlossaryTerm.count, TermCorrection.count,
     GlossaryProposal.where(id: proposal.id).pick(:status, :glossary_term_id, :decided_by_id, :decided_at)]
  end

  describe 'a new term' do
    it 'is created confirmed, in the cleaned spelling of the form, by the person who accepts' do
      result = accept(term: "  Zorbel\u{00A0}Hub ")

      term = term_of_form('Zorbel Hub')
      expect(result).to be_success
      expect(result.resource).to eq(term)
      expect([term.term, term.status, term.created_by_id, term.organisation_id])
        .to eq(['Zorbel Hub', 'confirmed', manager.id, organisation.id])
    end

    it 'takes the spelling of the proposal when the form leaves it blank' do
      expect(accept(term: " \u{200B}")).to be_success
      expect(GlossaryTerm.pluck(:term)).to eq(['Zorbel-Hub'])
    end

    it 'gets the category of the form, else the one of the proposal' do
      wub = create(:glossary_proposal, organisation: organisation, term: 'Wub', category: 'place')

      accept(category: 'company')
      accept(on: wub, category: '')

      expect(term_of_form('Zorbel-Hub').category).to eq('company')
      expect(term_of_form('Wub').category).to eq('place')
    end
  end

  describe 'the proposal' do
    it 'is accepted for the term, with who decided and when' do
      result = accept

      proposal.reload
      expect([proposal.status, proposal.glossary_term_id, proposal.decided_by_id])
        .to eq(['accepted', result.resource.id, manager.id])
      expect(proposal.decided_at).to be_within(1.minute).of(Time.current)
    end
  end

  describe 'a term the glossary has' do
    it 'is found in another spelling of the same form, and keeps its spelling' do
      existing = create(:glossary_term, organisation: organisation, term: 'ZORBEL-HUB')

      result = accept

      expect(result.resource).to eq(existing)
      expect(GlossaryTerm.pluck(:term)).to eq(['ZORBEL-HUB'])
    end

    it 'accepts equivalent Unicode, whitespace and case after the locked reload' do
      existing = create(:glossary_term, :proposed, organisation: organisation, term: 'Zörbel Hub')

      result = accept(term: "  ZO\u{0308}R\u{200B}BEL\u{00A0} HUB  ", variants: ['Zorbelhub'])

      expect(result).to be_success
      expect(result.resource).to eq(existing)
      expect(existing.reload).to have_attributes(term: 'Zörbel Hub', status: 'confirmed')
      expect(GlossaryTerm.count).to eq(1)
      expect(proposal.reload.glossary_term_id).to eq(existing.id)
      expect(TermCorrection.pluck(:glossary_term_id, :heard)).to eq([[existing.id, 'Zorbelhub']])
    end

    %i[de en].each do |locale|
      it "refuses a term renamed between lookup and lock, with a #{locale} message" do
        existing = create(:glossary_term, :proposed, organisation: organisation, term: 'Zorbel-Hub')
        # Keep the lookup snapshot while another request changes the stored spelling.
        allow_any_instance_of(described_class).to receive(:existing_term).and_return(existing)
        GlossaryTerm.find(existing.id).update!(term: 'Quarnix')
        stored = existing.class.find(existing.id).attributes
        before = written

        result = I18n.with_locale(locale) { accept(category: 'person', variants: ['Zorbelhub', 'Zorbl Hub']) }

        expect(result).not_to be_success
        expect(result.code).to eq(:term_changed)
        expect(I18n.exists?('controllers.glossary.proposals.term_changed', locale, fallback: false)).to be(true)
        expect(result.errors).to eq([I18n.t('controllers.glossary.proposals.term_changed', locale: locale)])
        expect(existing.reload.attributes).to eq(stored)
        expect(written).to eq(before)
        expect(proposal.reload).to have_attributes(status: 'open', glossary_term_id: nil, decided_by_id: nil, decided_at: nil)
      end
    end

    it 'is confirmed when it was proposed or rejected: a person accepts it now' do
      proposed = create(:glossary_term, :proposed, organisation: organisation, term: 'Zorbel-Hub')
      rejected = create(:glossary_term, :rejected, organisation: organisation, term: 'Wub')
      wub = create(:glossary_proposal, organisation: organisation, term: 'Wub')

      accept
      accept(on: wub)

      expect(proposed.reload).to be_confirmed
      expect(rejected.reload).to be_confirmed
    end

    it 'gets a category only when it has none: the form’s, else the proposal’s' do
      with_one = create(:glossary_term, organisation: organisation, term: 'Zorbel-Hub', category: 'company')
      without_one = create(:glossary_term, organisation: organisation, term: 'Wub')
      bare = create(:glossary_term, organisation: organisation, term: 'Quarnix')
      wub = create(:glossary_proposal, organisation: organisation, term: 'Wub', category: 'place')
      quarnix = create(:glossary_proposal, organisation: organisation, term: 'Quarnix', category: 'domain')

      accept(category: 'person')
      accept(on: wub, category: 'person')
      accept(on: quarnix)

      expect(with_one.reload.category).to eq('company')
      expect(without_one.reload.category).to eq('person')
      expect(bare.reload.category).to eq('domain')
    end

    it 'is never a term of another organisation, which stays as it was' do
      foreign = ActsAsTenant.with_tenant(other_organisation) do
        create(:glossary_term, :proposed, organisation: other_organisation, term: 'Zorbel-Hub')
      end

      result = accept(category: 'person')

      expect(result.resource.organisation_id).to eq(organisation.id)
      expect(GlossaryTerm.unscoped.find(foreign.id).attributes.slice('status', 'category'))
        .to eq('status' => 'proposed', 'category' => nil)
    end

    # Two accepts create the same term at once: the second insert meets the
    # validation that saw the first term, or the unique index, and takes that
    # term instead of failing.
    it 'takes a term created at the same moment instead of failing' do
      other = create(:glossary_term, :proposed, organisation: organisation, term: 'Zorbel-Hub')
      allow_any_instance_of(described_class).to receive(:existing_term).and_return(nil)

      result = accept

      expect(result).to be_success
      expect(result.resource).to eq(other)
      expect(other.reload).to be_confirmed
    end

    it 'takes a term the unique index reports, past a validation that did not see it' do
      other = create(:glossary_term, organisation: organisation, term: 'Zorbel-Hub')
      allow_any_instance_of(described_class).to receive(:existing_term).and_return(nil)
      allow_any_instance_of(GlossaryTerm).to receive(:term_not_taken)

      result = accept(variants: ['Zorbelhub'])

      expect(result).to be_success
      expect(result.resource).to eq(other)
      expect(GlossaryTerm.count).to eq(1)
      expect(TermCorrection.pluck(:glossary_term_id)).to eq([other.id])
    end

    it 'is refused as gone when it was deleted before its lock' do
      existing = create(:glossary_term, organisation: organisation, term: 'Zorbel-Hub')
      allow_any_instance_of(described_class).to receive(:existing_term).and_return(existing)
      GlossaryTerm.where(id: existing.id).delete_all

      result = accept

      expect(result.code).to eq(:not_found)
      expect(proposal.reload).to be_open
    end
  end

  # The one lock order of the glossary: the term first, then the proposal;
  # the right is asked under the term's lock, before anything is written.
  it 'locks the term, then asks for the right, then claims the proposal' do
    existing = create(:glossary_term, :proposed, organisation: organisation, term: 'Zorbel-Hub')
    accepted = proposal
    user = manager
    expect(Glossary::TermLock).to receive(:call).with(term: existing).and_call_original
    statements = []
    callback = ->(*, payload) { statements << payload[:sql] }

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { accept(user: user, on: accepted) }

    lock = statements.index { |sql| sql.include?('FROM "glossary_terms"') && sql.include?('FOR UPDATE') }
    right = statements.index { |sql| sql.include?('FROM "memberships"') }
    write = statements.index { |sql| sql.start_with?('UPDATE') }
    claim = statements.index { |sql| sql.start_with?('UPDATE "glossary_proposals"') }
    expect([lock, right, write, claim]).to all(be_present)
    expect(lock).to be < right
    expect(right).to be < write
    expect(write).to be <= claim
    expect(statements.first(claim).grep(/FROM "glossary_proposals".*FOR UPDATE/)).to be_empty
  end

  describe 'the chosen variants' do
    def heard_forms
      TermCorrection.all
    end

    it 'become confirmed heard forms from the extraction, by the person who accepts, with the project of the busiest source that has one' do
      busy = create(:project, organisation: organisation)
      Prosopite.pause do
        source_for(project, occurrences: 2)
        source_for(busy, occurrences: 4)
        source_for(nil, occurrences: 9)
      end

      result = accept(variants: ['Zorbelhub', 'Zorbl Hub'])

      expect(heard_forms.pluck(:heard)).to contain_exactly('Zorbelhub', 'Zorbl Hub')
      expect(heard_forms.distinct.pluck(:glossary_term_id, :status, :origin, :project_id, :corrected_by_id, :replaced_count))
        .to eq([[result.resource.id, 'confirmed', 'extraction', busy.id, manager.id, 1]])
    end

    it 'name no meeting, no speaker and no place' do
      accept(variants: ['Zorbelhub', 'Zorbl Hub'])

      expect(heard_forms.distinct.pluck(:meeting_id, :person_id, :user_id, :line_index, :char_offset, :transcript_digest))
        .to eq([[nil, nil, nil, nil, nil, nil]])
    end

    it 'name no project when no source has one' do
      Prosopite.pause { source_for(nil, occurrences: 3) }

      accept(variants: ['Zorbelhub'])

      expect(heard_forms.pluck(:project_id)).to eq([nil])
    end

    it 'are only variants of the proposal, compared by form and written as the proposal spells them' do
      accept(variants: ['ZORBELHUB', 'Fremdwort', 42, nil, ['Zorbl Hub'], 'zorbelhub'])

      expect(heard_forms.pluck(:heard)).to eq(['Zorbelhub'])
    end

    it 'skip a variant that is the term itself in its compared form' do
      result = accept(term: 'ZorbelHub', variants: ['Zorbelhub', 'Zorbl Hub'])

      expect(result.resource.term).to eq('ZorbelHub')
      expect(heard_forms.pluck(:heard)).to eq(['Zorbl Hub'])
    end

    it 'offer the spelling of the proposal once the form changed the spelling' do
      accept(term: 'Zorbel Hub', variants: ['zorbel-hub'])

      expect(heard_forms.pluck(:heard)).to eq(['Zorbel-Hub'])
    end

    it 'skip the spelling of the proposal when the term keeps it' do
      expect(accept(variants: ['Zorbel-Hub'])).to be_success
      expect(heard_forms.count).to eq(0)
    end

    it 'skip a form the term has already as a heard form' do
      existing = create(:glossary_term, organisation: organisation, term: 'Zorbel-Hub')
      create(:term_correction, organisation: organisation, glossary_term: existing, heard: 'zorbl hub')

      accept(variants: ['Zorbl Hub', 'Zorbelhub'])

      expect(existing.term_corrections.pluck(:heard, :origin))
        .to contain_exactly(['zorbl hub', 'meeting'], %w[Zorbelhub extraction])
    end
  end

  describe 'refusals, with nothing written' do
    it 'refuses a proposal accepted or dismissed before' do
      accepted = create(:glossary_proposal, :accepted, organisation: organisation, term: 'Wub')
      dismissed = create(:glossary_proposal, :dismissed, organisation: organisation, term: 'Quarnix')

      expect(accept(on: accepted).code).to eq(:already_processed)
      expect(accept(on: dismissed).code).to eq(:already_processed)
      expect([GlossaryTerm.count, TermCorrection.count]).to eq([0, 0])
      expect(GlossaryProposal.where(id: [accepted.id, dismissed.id]).order(:term).pluck(:term, :status, :glossary_term_id))
        .to eq([['Quarnix', 'dismissed', nil], ['Wub', 'accepted', nil]])
    end

    # The claim's own condition decides, not the copy the caller loaded: the
    # row changes behind the actor's back, and the term created a moment ago
    # goes with the transaction.
    it 'refuses a proposal decided after it was loaded, by the status of its row' do
      loaded = GlossaryProposal.find(proposal.id)
      GlossaryProposal.where(id: proposal.id).update_all(status: 'dismissed')
      expect(loaded).to be_open

      result = accept(on: loaded, variants: ['Zorbelhub'])

      expect(result).not_to be_success
      expect(result.code).to eq(:already_processed)
      expect([GlossaryTerm.count, TermCorrection.count]).to eq([0, 0])
      expect(GlossaryProposal.where(id: proposal.id).pick(:status, :glossary_term_id)).to eq(['dismissed', nil])
    end

    it 'leaves a term the glossary has as it was when the claim fails' do
      existing = create(:glossary_term, :proposed, organisation: organisation, term: 'Zorbel-Hub')
      loaded = GlossaryProposal.find(proposal.id)
      GlossaryProposal.where(id: proposal.id).update_all(status: 'accepted')

      expect(accept(on: loaded, category: 'person', variants: ['Zorbelhub']).code).to eq(:already_processed)
      expect([existing.reload.status, existing.category, TermCorrection.count]).to eq(['proposed', nil, 0])
    end

    it 'refuses a user with only view_glossary' do
      before = written

      result = accept(user: viewer, variants: ['Zorbelhub'])

      expect(result.code).to eq(:forbidden)
      expect(written).to eq(before)
    end

    it 'refuses a deactivated member, whatever the role grants' do
      user = manager
      user.memberships.update_all(active: false)
      before = written

      expect(accept(user: user, variants: ['Zorbelhub']).code).to eq(:forbidden)
      expect(written).to eq(before)
    end

    it 'leaves a term the glossary has as it was when it refuses the person' do
      existing = create(:glossary_term, :proposed, organisation: organisation, term: 'Zorbel-Hub')

      expect(accept(user: viewer, category: 'person', variants: ['Zorbelhub']).code).to eq(:forbidden)
      expect([existing.reload.status, existing.category, TermCorrection.count]).to eq(['proposed', nil, 0])
    end

    it 'counts an account admin as holding manage_glossary' do
      admin = member_with(create(:role, organisation: organisation, title: Role::ACCOUNT_ADMIN_TITLE))

      expect(accept(user: admin)).to be_success
    end
  end
end
