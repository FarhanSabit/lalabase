# frozen_string_literal: true

require 'rails_helper'

# A proposal of the glossary extraction (K5b): one per compared form and
# organisation, its spelling variants cleaned, references only within the
# organisation, and the delete rules of the three tables. Invented words only.
RSpec.describe GlossaryProposal, :ci_guard, type: :model do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:connection) { ActiveRecord::Base.connection }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def proposal_with(**attributes)
    create(:glossary_proposal, organisation: organisation, **attributes)
  end

  def built_with(**attributes)
    build(:glossary_proposal, organisation: organisation, **attributes)
  end

  # A statement the database refuses aborts the open transaction; a savepoint
  # keeps the example usable after it.
  def in_savepoint(&)
    described_class.transaction(requires_new: true, &)
  end

  it 'is bound to the tenant' do
    mine = proposal_with
    theirs = ActsAsTenant.with_tenant(other_organisation) { create(:glossary_proposal, organisation: other_organisation) }

    expect(described_class.all).to contain_exactly(mine)
    expect(described_class.unscoped.where(id: theirs.id)).to exist
  end

  it 'is asked through the glossary policy' do
    expect(Pundit::PolicyFinder.new(described_class.new).policy).to eq(GlossaryPolicy)
  end

  it 'keeps up to MAX_SOURCES sources' do
    expect(described_class::MAX_SOURCES).to eq(5)
  end

  describe 'the term' do
    it 'keeps the spelling cleaned and stores its compared form' do
      proposal = proposal_with(term: "  Zorbel\u{00A0} Hub\u{200B} ")

      expect([proposal.term, proposal.normalized_term]).to eq(['Zorbel Hub', 'zorbel hub'])
    end

    it 'requires a term' do
      proposal = built_with(term: " \u{200B} ")

      expect(proposal).not_to be_valid
      expect(proposal.errors.details[:term]).to include(error: :blank)
    end

    it 'refuses a term longer than a glossary term may be' do
      expect(built_with(term: 'a' * (GlossaryTerm::MAX_LENGTH + 1))).not_to be_valid
      expect(built_with(term: 'a' * GlossaryTerm::MAX_LENGTH)).to be_valid
    end
  end

  describe 'one proposal per compared form and organisation' do
    it 'refuses a term that differs only in case and whitespace, with the message on term' do
      proposal_with(term: 'Zorbel Hub')
      twin = built_with(term: ' zorbel  HUB ')

      expect(twin).not_to be_valid
      expect(twin.errors.details[:term]).to include(error: :taken)
    end

    it 'allows the same term in another organisation' do
      ActsAsTenant.with_tenant(other_organisation) { create(:glossary_proposal, organisation: other_organisation, term: 'Zorbel Hub') }

      expect(built_with(term: 'Zorbel Hub')).to be_valid
    end

    it 'keeps its own spelling valid on a later save' do
      proposal = proposal_with(term: 'Zorbel Hub')

      expect(proposal.update(occurrences: 3, term: 'zorbel hub')).to be(true)
    end

    it 'is held by the unique index when the validation is skipped' do
      proposal_with(term: 'Zorbel Hub')
      twin = built_with(term: 'ZORBEL HUB')
      twin.valid? # runs the cleaning, which save(validate: false) skips

      expect { twin.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    # An accepted proposal stays beside the term it became, in the same form.
    it 'lets a proposal stand beside a glossary term of the same form' do
      term = create(:glossary_term, organisation: organisation, term: 'Zorbel Hub')

      expect(built_with(term: 'Zorbel Hub', status: 'accepted', glossary_term: term)).to be_valid
    end
  end

  describe 'the category' do
    it 'stores a blank category as none and takes the categories of the glossary only' do
      expect(proposal_with(category: '').category).to be_nil
      GlossaryTerm::CATEGORIES.each { |category| expect(built_with(category: category)).to be_valid }
      expect(built_with(category: 'planet')).not_to be_valid
    end

    it 'is held by the database: a category of the glossary or none, nothing else' do
      proposal = proposal_with

      Prosopite.pause do
        [*GlossaryTerm::CATEGORIES, nil].each do |category|
          proposal.update_column(:category, category)
          expect(proposal.reload.category).to eq(category)
        end
      end
      expect { proposal.update_column(:category, 'planet') }
        .to raise_error(ActiveRecord::StatementInvalid, /glossary_proposals_category_known/)
    end
  end

  describe 'the status' do
    it 'is open unless set, and knows open, accepted and dismissed' do
      expect(described_class.new.status).to eq('open')
      expect(described_class::STATUSES).to eq(%w[open accepted dismissed])
      expect(built_with(status: 'merged')).not_to be_valid
    end

    it 'stores every known status in the database' do
      proposal = proposal_with

      Prosopite.pause do
        described_class::STATUSES.each do |status|
          proposal.update_column(:status, status)
          expect(proposal.reload.status).to eq(status)
        end
      end
    end

    it 'is held by the database too' do
      proposal = proposal_with

      expect { proposal.update_column(:status, 'bogus') }
        .to raise_error(ActiveRecord::StatementInvalid, /glossary_proposals_status_known/)
    end
  end

  describe 'the variants' do
    it 'is an empty list unless set' do
      expect(described_class.new.variants).to eq([])
    end

    it 'cleans each spelling and drops blanks, repeats and the term itself' do
      proposal = proposal_with(term: 'Zorbel-Hub',
                               variants: ['  Zorbel  Hub ', 'zorbel hub', '', "\u{200B}", nil, 'ZORBEL-HUB', 'Zorbelhub',
                                          "Zorbel\u{00A0}Hub"])

      expect(proposal.variants).to eq(['Zorbel Hub', 'Zorbelhub'])
    end

    it 'takes MAX_VARIANTS spellings and refuses one more' do
      expect(described_class::MAX_VARIANTS).to eq(10)
      expect(built_with(variants: Array.new(10) { |index| "Wub #{index}" })).to be_valid

      too_many = built_with(variants: Array.new(11) { |index| "Wub #{index}" })
      expect(too_many).not_to be_valid
      expect(too_many.errors.details[:variants]).to include(error: :too_many, count: 10)
    end

    it 'refuses a spelling that is no text or too long, and a value that is no list' do
      not_text = built_with(variants: ['Wub', 7])
      expect(not_text).not_to be_valid
      expect(not_text.errors.details[:variants]).to include(error: :not_text, position: 2)

      too_long = built_with(variants: ['a' * (GlossaryTerm::MAX_LENGTH + 1)])
      expect(too_long).not_to be_valid
      expect(too_long.errors.details[:variants]).to include(error: :variant_too_long, position: 1, count: GlossaryTerm::MAX_LENGTH)
      expect(built_with(variants: ['a' * GlossaryTerm::MAX_LENGTH])).to be_valid

      [{ 'Wub' => 'Quarnix' }, 'Wub'].each do |value|
        not_a_list = built_with(variants: value)
        expect(not_a_list).not_to be_valid, value.inspect
        expect(not_a_list.errors.details[:variants]).to include(error: :not_a_list)
      end
    end

    it 'is held by the database: a list of at most ten texts' do
      proposal = proposal_with
      proposal.update_column(:variants, Array.new(10) { |index| "Wub #{index}" })
      expect(proposal.reload.variants.size).to eq(10)

      shapes = [Array.new(11) { |index| "Wub #{index}" }, ['Wub', 7], ['Wub', nil], ['Wub', ['Quarnix']], ['Wub', { 'Quarnix' => 1 }],
                { 'Wub' => 'Quarnix' }, 'Wub', 7]
      Prosopite.pause do
        shapes.each do |shape|
          expect { in_savepoint { proposal.update_column(:variants, shape) } }
            .to raise_error(ActiveRecord::StatementInvalid, /glossary_proposals_variants_shape/), shape.inspect
        end
      end
      expect(proposal.reload.variants.size).to eq(10)
    end
  end

  describe 'the hint' do
    it 'is empty unless set, cleaned, and at most MAX_HINT characters' do
      expect(described_class.new.hint).to eq('')
      expect(proposal_with(hint: "  Ein  Werkzeug\n von Quarnix ").hint).to eq('Ein Werkzeug von Quarnix')
      expect(proposal_with(hint: nil).hint).to eq('')

      expect(described_class::MAX_HINT).to eq(160)
      expect(built_with(hint: 'a' * described_class::MAX_HINT)).to be_valid
      expect(built_with(hint: 'a' * (described_class::MAX_HINT + 1))).not_to be_valid
    end
  end

  describe 'the occurrences' do
    it 'is zero unless set, a whole number and never negative' do
      expect(described_class.new.occurrences).to eq(0)
      expect(built_with(occurrences: 0)).to be_valid
      expect(built_with(occurrences: -1)).not_to be_valid
      expect(built_with(occurrences: 1.5)).not_to be_valid
    end

    it 'is held by the database too' do
      proposal = proposal_with

      expect { proposal.update_column(:occurrences, -1) }
        .to raise_error(ActiveRecord::StatementInvalid, /glossary_proposals_occurrences_not_negative/)
    end
  end

  it 'lists the most frequent first, then by compared form' do
    second = proposal_with(term: 'Bwub', occurrences: 5)
    first = proposal_with(term: 'awub', occurrences: 5)
    top = proposal_with(term: 'Cwub', occurrences: 9)
    last = proposal_with(term: 'dwub', occurrences: 0)

    expect(described_class.in_review_order.to_a).to eq([top, first, second, last])
  end

  describe 'references to rows of another organisation' do
    let(:foreign) do
      ActsAsTenant.with_tenant(other_organisation) do
        {
          glossary_extraction_run: create(:glossary_extraction_run, organisation: other_organisation),
          glossary_term: create(:glossary_term, organisation: other_organisation)
        }
      end
    end

    it 'names the run and the term' do
      expect(described_class::TENANT_REFERENCES).to eq(%i[glossary_extraction_run glossary_term])
    end

    it 'accepts a run and a term of its own organisation' do
      run = create(:glossary_extraction_run, organisation: organisation)
      term = create(:glossary_term, organisation: organisation)

      expect(built_with(glossary_extraction_run: run, glossary_term: term)).to be_valid
    end

    GlossaryProposal::TENANT_REFERENCES.each do |name|
      it "refuses a #{name} of another organisation" do
        proposal = built_with
        proposal.public_send(:"#{name}_id=", foreign.fetch(name).id)

        expect(proposal).not_to be_valid
        expect(proposal.errors[name]).to be_present
      end

      it "refuses a #{name} of another organisation without a tenant set" do
        foreign_id = foreign.fetch(name).id
        proposal = ActsAsTenant.without_tenant do
          built = built_with
          built.public_send(:"#{name}_id=", foreign_id)
          built.validate
          built
        end

        expect(proposal.errors[name]).to be_present
      end
    end
  end

  describe 'deleting' do
    let(:run) { create(:glossary_extraction_run, organisation: organisation) }
    let(:term) { create(:glossary_term, organisation: organisation, term: 'Quarnix') }
    let!(:proposal) { proposal_with(term: 'Quarnix Wub', glossary_extraction_run: run, glossary_term: term) }
    let!(:source) { create(:glossary_proposal_source, organisation: organisation, glossary_proposal: proposal) }

    it 'says the delete rules in the foreign keys' do
      keys = connection.foreign_keys('glossary_proposals').to_h { |key| [key.column, [key.to_table, key.on_delete]] }

      expect(keys).to eq(
        'organisation_id' => ['organisations', :cascade],
        'glossary_extraction_run_id' => ['glossary_extraction_runs', :nullify],
        'glossary_term_id' => ['glossary_terms', :nullify],
        'decided_by_id' => ['users', :nullify]
      )
    end

    it 'the run leaves its proposals without the run' do
      run.destroy!
      proposal.reload

      expect(proposal.glossary_extraction_run_id).to be_nil
      expect(proposal.glossary_term_id).to eq(term.id)
      expect(GlossaryProposalSource.unscoped.where(id: source.id)).to exist
    end

    it 'the proposal takes its sources along' do
      proposal.destroy!

      expect(GlossaryProposalSource.unscoped.where(id: source.id)).not_to exist
    end

    it 'the proposal takes its sources along in the database too' do
      described_class.where(id: proposal.id).delete_all

      expect(GlossaryProposalSource.unscoped.where(id: source.id)).not_to exist
    end

    it 'the glossary term leaves the proposal without it' do
      term.destroy!
      proposal.reload

      expect(proposal.glossary_term_id).to be_nil
      expect(proposal.glossary_extraction_run_id).to eq(run.id)
    end

    it 'the person who decided leaves the proposal without them' do
      decider = create(:user)
      proposal.update!(decided_by: decider, decided_at: Time.current, status: 'dismissed')

      User.where(id: decider.id).delete_all

      expect(proposal.reload.decided_by_id).to be_nil
    end

    it 'the organisation takes runs, proposals and sources along' do
      organisation.destroy!

      expect(GlossaryExtractionRun.unscoped.where(id: run.id)).not_to exist
      expect(described_class.unscoped.where(id: proposal.id)).not_to exist
      expect(GlossaryProposalSource.unscoped.where(id: source.id)).not_to exist
    end
  end
end
