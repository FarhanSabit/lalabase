# frozen_string_literal: true

require 'rails_helper'

# A heard form of a glossary term (K4a): tenant bound, at most one speaker,
# references only within the organisation, and the delete rules of plan §3.3.
# Invented words and names only.
RSpec.describe TermCorrection, :ci_guard, type: :model do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:term) { create(:glossary_term, organisation: organisation, term: 'Lalabase') }
  let(:project) { create(:project, organisation: organisation) }

  def member_of(org)
    user = create(:user)
    create(:membership, user: user, organisation: org)
    user
  end

  it 'is bound to the tenant' do
    mine = create(:term_correction, organisation: organisation, glossary_term: term)
    theirs = ActsAsTenant.with_tenant(other_organisation) { create(:term_correction, organisation: other_organisation) }

    expect(described_class.all).to contain_exactly(mine)
    expect(described_class.unscoped.where(id: theirs.id)).to exist
  end

  it 'keeps the heard form as marked and stores its compared form' do
    correction = create(:term_correction, organisation: organisation, glossary_term: term, heard: "  Lala\u00A0 Bass ")

    expect(correction.heard).to eq('Lala Bass')
    expect(correction.normalized_heard).to eq('lala bass')
  end

  it 'requires a heard form' do
    correction = build(:term_correction, organisation: organisation, glossary_term: term, heard: '  ')

    expect(correction).not_to be_valid
    expect(correction.errors[:heard]).to be_present
  end

  # Review round 4 of #113: the heard form goes through the same normalizer as
  # the term (GlossaryText), characters that show nothing included.
  it 'drops characters that show nothing from a heard form, and refuses one of nothing else' do
    correction = create(:term_correction, organisation: organisation, glossary_term: term, heard: "Lala\u{200B}\u{00AD}Bass")
    blank = build(:term_correction, organisation: organisation, glossary_term: term, heard: "\u{200B}\u{202E}")

    expect([correction.heard, correction.normalized_heard]).to eq(%w[LalaBass lalabass])
    expect(blank).not_to be_valid
    expect(blank.errors.details[:heard]).to include(error: :blank)
  end

  it 'checks the place and the count' do
    expect(build(:term_correction, organisation: organisation, glossary_term: term, replaced_count: 0)).not_to be_valid
    expect(build(:term_correction, organisation: organisation, glossary_term: term, line_index: -1)).not_to be_valid
    expect(build(:term_correction, organisation: organisation, glossary_term: term, transcript_digest: 'abc')).not_to be_valid
    expect(build(:term_correction, organisation: organisation, glossary_term: term, line_index: 0, char_offset: 4,
                                   transcript_digest: 'a' * 64)).to be_valid
  end

  # Every heard form has a status of its own (K4b, E3): a correction without
  # manage_glossary is a proposal, also at a confirmed term. Rows written
  # before K4b are confirmed (the column's default).
  describe 'the status' do
    it 'is confirmed unless set, the state of every row before K4b' do
      expect(create(:term_correction, organisation: organisation, glossary_term: term)).to be_confirmed
    end

    it 'knows proposed and confirmed, nothing else' do
      expect(build(:term_correction, organisation: organisation, glossary_term: term, status: 'proposed')).to be_valid
      expect(build(:term_correction, organisation: organisation, glossary_term: term, status: 'rejected')).not_to be_valid
      expect(build(:term_correction, organisation: organisation, glossary_term: term, status: nil)).not_to be_valid
    end

    it 'is held by the database too' do
      correction = create(:term_correction, organisation: organisation, glossary_term: term)

      expect { described_class.where(id: correction.id).update_all(status: 'rejected') }
        .to raise_error(ActiveRecord::StatementInvalid, /term_corrections_status_known/)
    end
  end

  # Where a heard form came from (K5b): a correction in a meeting, a proposal
  # of the glossary extraction, or an import. Rows written before K5b came
  # from meetings (the column's default).
  describe 'the origin' do
    it 'is meeting unless set, the origin of every row before K5b' do
      expect(described_class.new.origin).to eq('meeting')
      expect(create(:term_correction, organisation: organisation, glossary_term: term).origin).to eq('meeting')
    end

    it 'is meeting for a row the database fills without it' do
      inserted = described_class.insert_all!(
        [{ organisation_id: organisation.id, glossary_term_id: term.id, heard: 'zor bel', normalized_heard: 'zor bel' }],
        returning: %w[origin]
      )

      expect(inserted.rows).to eq([['meeting']])
    end

    it 'knows meeting, extraction and import, nothing else' do
      Prosopite.pause do
        described_class::ORIGINS.each do |origin|
          expect(build(:term_correction, organisation: organisation, glossary_term: term, origin: origin)).to be_valid
        end
      end
      expect(described_class::ORIGINS).to eq(%w[meeting extraction import])

      unknown = build(:term_correction, organisation: organisation, glossary_term: term, origin: 'guess')
      expect(unknown).not_to be_valid
      expect(unknown.errors.details[:origin]).to include(a_hash_including(error: :inclusion))
      expect(build(:term_correction, organisation: organisation, glossary_term: term, origin: nil)).not_to be_valid
    end

    it 'stores every known origin in the database' do
      correction = create(:term_correction, organisation: organisation, glossary_term: term)

      Prosopite.pause do
        described_class::ORIGINS.each do |origin|
          described_class.where(id: correction.id).update_all(origin: origin)
          expect(correction.reload.origin).to eq(origin)
        end
      end
    end

    it 'is held by the database too' do
      correction = create(:term_correction, organisation: organisation, glossary_term: term)

      expect { described_class.where(id: correction.id).update_all(origin: 'guess') }
        .to raise_error(ActiveRecord::StatementInvalid, /term_corrections_origin_known/)
    end
  end

  # What K4c and the device (M4) read: a confirmed form at a confirmed term.
  # A proposal at a confirmed term and a confirmed form at a proposed or a
  # rejected term do not work anywhere yet.
  describe '.effective' do
    let(:proposed_term) { create(:glossary_term, :proposed, organisation: organisation, term: 'Zirbelholz') }
    let(:rejected_term) { create(:glossary_term, :rejected, organisation: organisation, term: 'Ahornsirup') }

    it 'is the confirmed forms of confirmed terms, and nothing else' do
      effective = create(:term_correction, organisation: organisation, glossary_term: term, heard: 'lala bass')
      create(:term_correction, organisation: organisation, glossary_term: term, heard: 'lala base', status: 'proposed')
      create(:term_correction, organisation: organisation, glossary_term: proposed_term, heard: 'zirbel holz')
      create(:term_correction, organisation: organisation, glossary_term: rejected_term, heard: 'ahorn sirup')

      expect(described_class.effective).to contain_exactly(effective)
    end

    # The origin does not decide what works: only the two statuses do.
    it 'reads the origin nowhere: a confirmed form from the extraction works at a confirmed term only' do
      extracted = create(:term_correction, organisation: organisation, glossary_term: term, heard: 'zorbel hub',
                                           origin: 'extraction')
      create(:term_correction, organisation: organisation, glossary_term: proposed_term, heard: 'zorbel wub',
                               origin: 'extraction')
      imported = create(:term_correction, organisation: organisation, glossary_term: term, heard: 'quar nix', origin: 'import')

      expect(described_class.effective).to contain_exactly(extracted, imported)
    end

    it 'stays inside the tenant' do
      theirs = ActsAsTenant.with_tenant(other_organisation) { create(:term_correction, organisation: other_organisation) }

      expect(described_class.effective).not_to include(theirs)
      expect(ActsAsTenant.with_tenant(other_organisation) { described_class.effective.to_a }).to contain_exactly(theirs)
    end
  end

  describe 'the speaker' do
    let(:person) { create(:person, organisation: organisation) }
    let(:member) { member_of(organisation) }

    it 'is a person or a member' do
      expect(build(:term_correction, organisation: organisation, glossary_term: term, person: person)).to be_valid
      expect(build(:term_correction, organisation: organisation, glossary_term: term, user: member)).to be_valid
    end

    it 'is never both, in the model' do
      correction = build(:term_correction, organisation: organisation, glossary_term: term, person: person, user: member)

      expect(correction).not_to be_valid
      expect(correction.errors[:base]).to be_present
    end

    it 'is never both, in the database' do
      correction = create(:term_correction, organisation: organisation, glossary_term: term, person: person)

      expect { described_class.where(id: correction.id).update_all(user_id: member.id) }
        .to raise_error(ActiveRecord::StatementInvalid, /term_corrections_one_speaker/)
    end

    it 'is a member of this organisation' do
      stranger = member_of(other_organisation)
      correction = build(:term_correction, organisation: organisation, glossary_term: term, user: stranger)

      expect(correction).not_to be_valid
      expect(correction.errors[:user]).to be_present
    end
  end

  describe 'references to rows of another organisation' do
    let(:foreign) do
      ActsAsTenant.with_tenant(other_organisation) do
        foreign_project = create(:project, organisation: other_organisation)
        {
          glossary_term: create(:glossary_term, organisation: other_organisation),
          project: foreign_project,
          person: create(:person, organisation: other_organisation),
          meeting: create(:meeting, organisation: other_organisation, project: foreign_project)
        }
      end
    end

    TermCorrection::TENANT_REFERENCES.each do |name|
      it "refuses a #{name} of another organisation" do
        correction = build(:term_correction, organisation: organisation, glossary_term: term)
        correction.public_send(:"#{name}_id=", foreign.fetch(name).id)

        expect(correction).not_to be_valid
        expect(correction.errors[name]).to be_present
      end

      it "refuses a #{name} of another organisation without a tenant set" do
        attributes = { organisation: organisation, glossary_term: term }
        foreign_id = foreign.fetch(name).id
        correction = ActsAsTenant.without_tenant do
          built = build(:term_correction, **attributes)
          built.public_send(:"#{name}_id=", foreign_id)
          built.validate
          built
        end

        expect(correction.errors[name]).to be_present
      end
    end
  end

  # Plan §3.3 (decided 04.11.2026).
  describe 'deleting' do
    let(:creator) { member_of(organisation) }
    let(:meeting) { create(:meeting, organisation: organisation, project: project, creator: creator) }
    let(:person) { create(:person, organisation: organisation) }
    let!(:correction) do
      create(:term_correction, organisation: organisation, glossary_term: term, project: project, meeting: meeting,
                               person: person, line_index: 3, char_offset: 12, transcript_digest: 'b' * 64)
    end

    it 'the term takes its heard forms along' do
      term.destroy!

      expect(described_class.unscoped.where(id: correction.id)).not_to exist
    end

    it 'the term takes them along in the database too' do
      GlossaryTerm.where(id: term.id).delete_all

      expect(described_class.unscoped.where(id: correction.id)).not_to exist
    end

    it 'the organisation takes terms and heard forms along' do
      organisation.destroy!

      expect(GlossaryTerm.unscoped.where(id: term.id)).not_to exist
      expect(described_class.unscoped.where(id: correction.id)).not_to exist
    end

    # E4: a correction is knowledge of the organisation, confirmed by a person,
    # not content of the conversation. It stays with its place; only the link
    # to the meeting goes.
    it 'the meeting leaves the heard form with its place and clears only meeting_id' do
      meeting.destroy!
      correction.reload

      expect(correction.meeting_id).to be_nil
      expect([correction.line_index, correction.char_offset, correction.transcript_digest]).to eq([3, 12, 'b' * 64])
      expect([correction.project_id, correction.person_id, correction.glossary_term_id]).to eq([project.id, person.id, term.id])
    end

    it 'the project leaves the heard form without its origin' do
      project.destroy!
      correction.reload

      expect(correction.project_id).to be_nil
      expect(correction.glossary_term_id).to eq(term.id)
    end

    it 'the person leaves the heard form without its speaker' do
      person.destroy!
      correction.reload

      expect(correction.person_id).to be_nil
      expect(correction.meeting_id).to eq(meeting.id)
    end
  end
end
