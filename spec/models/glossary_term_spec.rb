# frozen_string_literal: true

require 'rails_helper'

# The glossary of an organisation (K4a). Invented words only.
RSpec.describe GlossaryTerm, :ci_guard, type: :model do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  it 'is bound to the tenant' do
    mine = create(:glossary_term, organisation: organisation)
    theirs = ActsAsTenant.with_tenant(other_organisation) { create(:glossary_term, organisation: other_organisation) }

    expect(described_class.all).to contain_exactly(mine)
    expect(described_class.unscoped.where(id: theirs.id)).to exist
  end

  it 'requires a term' do
    term = build(:glossary_term, organisation: organisation, term: " \u00A0 ")

    expect(term).not_to be_valid
    expect(term.errors[:term]).to be_present
  end

  it 'refuses a term longer than the limit' do
    term = build(:glossary_term, organisation: organisation, term: 'a' * (described_class::MAX_LENGTH + 1))

    expect(term).not_to be_valid
    expect(build(:glossary_term, organisation: organisation, term: 'a' * described_class::MAX_LENGTH)).to be_valid
  end

  describe 'normalisation (GlossaryText)' do
    it 'keeps the spelling, collapses any whitespace and stores the lower case form' do
      term = create(:glossary_term, organisation: organisation, term: "  Lala\u00A0  Base\t")

      expect(term.term).to eq('Lala Base')
      expect(term.normalized_term).to eq('lala base')
    end

    it 'composes to NFC, so a decomposed umlaut is the same term' do
      create(:glossary_term, organisation: organisation, term: "Mu\u0308hlstein")
      twin = build(:glossary_term, organisation: organisation, term: "M\u00FChlstein")

      expect(twin).not_to be_valid
      expect(twin.errors.details[:term]).to include(error: :taken)
    end

    it 'does not write umlauts or ß out, unlike PersonName' do
      create(:glossary_term, organisation: organisation, term: 'Maße')

      expect(build(:glossary_term, organisation: organisation, term: 'Masse')).to be_valid
      expect(build(:glossary_term, organisation: organisation, term: 'Mueller')).to be_valid
      expect(described_class.last.normalized_term).to eq('maße')
    end

    it 'compares an umlaut by its case only: "MÜLLER" is "Müller", "Mueller" is another term' do
      create(:glossary_term, organisation: organisation, term: 'Müller')
      upper = build(:glossary_term, organisation: organisation, term: 'MÜLLER')

      expect(upper).not_to be_valid
      expect(upper.errors.details[:term]).to include(error: :taken)
      expect(build(:glossary_term, organisation: organisation, term: 'Mueller')).to be_valid
    end

    # Review round 4 of #113: a character that shows nothing made a term of
    # nothing, or a second term that looks like the first.
    describe 'characters that show nothing' do
      it 'refuses a term of nothing else' do
        term = build(:glossary_term, organisation: organisation, term: "\u{200B}\u{00AD} \u{2060}\u{FEFF}\u{3164}")

        expect(term).not_to be_valid
        expect(term.errors.details[:term]).to include(error: :blank)
      end

      {
        'a zero-width space' => "Lala\u{200B}base",
        'a soft hyphen' => "Lala\u{00AD}base",
        'bidi controls' => "\u{202E}Lala\u{200F}base\u{202C}",
        'a Hangul filler (shows as a blank)' => "Lala\u{3164}base",
        'a control character' => "Lala\u{0007}base"
      }.each do |what, spelling|
        it "drops #{what}, so the term collides with the plain spelling" do
          create(:glossary_term, organisation: organisation, term: 'Lalabase')
          twin = build(:glossary_term, organisation: organisation, term: spelling)

          expect(twin).not_to be_valid
          expect(twin.errors.details[:term]).to include(error: :taken)
          expect([twin.term, twin.normalized_term]).to eq(%w[Lalabase lalabase])
        end
      end

      it 'stores a term with a null character without it (the database refuses one)' do
        term = create(:glossary_term, organisation: organisation, term: "Lala\u{0000}base")

        expect(term.reload.term).to eq('Lalabase')
      end

      it 'keeps a tab or a line break as a space' do
        expect(create(:glossary_term, organisation: organisation, term: "Lala\tBase\r\nWerk").term).to eq('Lala Base Werk')
      end

      it 'composes an umlaut across a dropped character' do
        create(:glossary_term, organisation: organisation, term: "M\u{00FC}hlstein")
        twin = build(:glossary_term, organisation: organisation, term: "Mu\u{200B}\u{0308}hlstein")

        expect(twin).not_to be_valid
        expect(twin.normalized_term).to eq("m\u{00FC}hlstein")
      end
    end
  end

  describe 'one spelling per organisation' do
    it 'refuses a term that differs only in case and whitespace, with the message on term' do
      create(:glossary_term, organisation: organisation, term: 'Lalabase')
      twin = build(:glossary_term, organisation: organisation, term: '  lalaBASE ')

      expect(twin).not_to be_valid
      expect(twin.errors.details[:term]).to include(error: :taken)
      expect(twin.errors.full_messages.join).to include(described_class.human_attribute_name(:term))
    end

    it 'allows the same term in another organisation' do
      ActsAsTenant.with_tenant(other_organisation) { create(:glossary_term, organisation: other_organisation, term: 'Lalabase') }

      expect(build(:glossary_term, organisation: organisation, term: 'Lalabase')).to be_valid
    end

    it 'keeps its own spelling valid on a later save' do
      term = create(:glossary_term, organisation: organisation, term: 'Lalabase')

      expect(term.update(category: 'product')).to be(true)
    end

    it 'is held by the unique index when the validation is skipped' do
      create(:glossary_term, organisation: organisation, term: 'Lalabase')
      twin = build(:glossary_term, organisation: organisation, term: 'LALABASE')
      twin.valid? # runs the normalisation, which save(validate: false) skips

      expect { twin.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe 'category and status' do
    it 'stores a blank category as none' do
      expect(create(:glossary_term, organisation: organisation, category: '').category).to be_nil
    end

    it 'accepts the six categories and refuses any other' do
      described_class::CATEGORIES.each do |category|
        expect(build(:glossary_term, organisation: organisation, category: category)).to be_valid
      end
      expect(build(:glossary_term, organisation: organisation, category: 'planet')).not_to be_valid
    end

    it 'is confirmed by default and refuses an unknown status' do
      expect(described_class.new.status).to eq('confirmed')
      expect(build(:glossary_term, organisation: organisation, status: 'maybe')).not_to be_valid
    end
  end

  it 'orders open proposals first, then confirmed, then rejected, each by spelling' do
    rejected = create(:glossary_term, :rejected, organisation: organisation, term: 'Aalwort')
    confirmed_b = create(:glossary_term, organisation: organisation, term: 'Bergwort')
    confirmed_a = create(:glossary_term, organisation: organisation, term: 'apfelwort')
    proposed = create(:glossary_term, :proposed, organisation: organisation, term: 'Zielwort')

    expect(described_class.ordered.to_a).to eq([proposed, confirmed_a, confirmed_b, rejected])
  end
end
