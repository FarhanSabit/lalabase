# frozen_string_literal: true

require 'rails_helper'

# What the glossary did to a meeting (K4d): tenant bound, references only within
# the organisation, the writer of Meetings::Intake, and the delete rules of plan
# m4d §3. Invented words only.
RSpec.describe TermApplication, :ci_guard, type: :model do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:term) { create(:glossary_term, organisation: organisation, term: 'Lalabase') }
  let(:project) { create(:project, organisation: organisation) }
  let(:meeting) { create(:meeting, organisation: organisation, project: project, creator: create(:user)) }

  it 'is bound to the tenant' do
    mine = create(:term_application, organisation: organisation, meeting: meeting, glossary_term: term)
    theirs = ActsAsTenant.with_tenant(other_organisation) { create(:term_application, organisation: other_organisation) }

    expect(described_class.all).to contain_exactly(mine)
    expect(described_class.unscoped.where(id: theirs.id)).to exist
  end

  it 'cleans the spellings and stores the compared form of the heard one' do
    row = create(:term_application, organisation: organisation, meeting: meeting, glossary_term: term,
                                    heard: '  Lala  Bass ', term: ' Lala​base ')

    expect([row.heard, row.normalized_heard, row.term]).to eq(['Lala Bass', 'lala bass', 'Lalabase'])
  end

  it 'tells a righted spelling from a heard form' do
    spelling = build(:term_application, organisation: organisation, meeting: meeting, glossary_term: term, heard: 'LALABASE')
    heard = build(:term_application, organisation: organisation, meeting: meeting, glossary_term: term, heard: 'lala bass')

    expect([spelling.spelling?, heard.spelling?]).to eq([true, false])
  end

  it 'needs a spelling, a heard form and a count of at least one' do
    row = build(:term_application, organisation: organisation, meeting: meeting, glossary_term: term, heard: ' ', term: '',
                                   replaced_count: 0)

    expect(row).not_to be_valid
    expect(row.errors.attribute_names).to include(:heard, :term, :replaced_count)
  end

  it 'refuses a meeting, a project or a term of another organisation, read past the tenant' do
    foreign = ActsAsTenant.with_tenant(other_organisation) do
      { meeting: create(:meeting, organisation: other_organisation), project: create(:project, organisation: other_organisation),
        glossary_term: create(:glossary_term, organisation: other_organisation) }
    end

    foreign.each do |name, record|
      row = build(:term_application, organisation: organisation, meeting: meeting, glossary_term: term, name => record)
      expect(row).not_to be_valid, name.to_s
      expect(row.errors.attribute_names).to include(name)
    end
  end

  it 'goes with its meeting and outlives its term with the spelling' do
    row = create(:term_application, organisation: organisation, meeting: meeting, glossary_term: term)

    term.destroy!
    expect(row.reload).to have_attributes(glossary_term_id: nil, term: 'Lalabase')

    meeting.destroy!
    expect(described_class.where(id: row.id)).not_to exist
  end

  describe '.record!' do
    def record(*entries)
      described_class.record!(meeting: meeting, entries: entries)
      described_class.where(meeting: meeting).order(:normalized_heard, :heard).to_a
    end

    it 'writes one row per spelling with the term found by its normalized spelling' do
      term
      rows = record({ heard: 'lala bass', term: 'Lalabase', count: 3 }, { heard: 'lalabase', term: 'LALABASE', count: 1 },
                    { heard: 'zirbel holz', term: 'Zirbelholz', count: 2 })

      expect(rows.map { |row| [row.heard, row.term, row.replaced_count, row.glossary_term_id, row.project_id] }).to eq([
                                                                                                                         ['lala bass', 'Lalabase', 3, term.id, project.id],
                                                                                                                         ['lalabase', 'LALABASE', 1, term.id, project.id],
                                                                                                                         ['zirbel holz', 'Zirbelholz', 2, nil, project.id]
                                                                                                                       ])
      expect(rows.map(&:organisation_id).uniq).to eq([organisation.id])
    end

    it 'sums a spelling given twice, as the same characters' do
      rows = record({ heard: 'lala bass', term: 'Lalabase', count: 1 }, { heard: 'lala bass', term: 'Lalabase', count: 4 },
                    { heard: 'Lala Bass', term: 'Lalabase', count: 1 })

      expect(rows.map { |row| [row.heard, row.replaced_count] }).to eq([['Lala Bass', 1], ['lala bass', 5]])
    end

    it 'writes nothing for no entries' do
      expect(record).to be_empty
    end
  end
end
