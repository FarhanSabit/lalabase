# frozen_string_literal: true

require 'rails_helper'

# Correcting a misheard word in a meeting (K4b, plan §5): the transcript is
# replaced through Actors::SaveMeeting with the right to edit the meeting
# (E2); what reaches the glossary depends on the glossary right: confirmed
# with manage_glossary, a proposal without, also at a confirmed term (E3).
# On "everywhere" the AI summary gets the same replacement and stays (E4), on
# "only here" it stays as it is (E5). Invented words and names only.
RSpec.describe Actors::CorrectMeetingTerm, :ci_guard do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:project) { create(:project, organisation: organisation, name: 'Projekt Ahorn') }
  let(:transcript) do
    "Anna: Wir testen Lalabeis heute.\nBen: Lalabeis kann viel, sagt Anna.\nUnd Lalabeis-Konten auch."
  end
  let(:creator) { member_with(role_with) }
  let(:meeting) do
    create(:meeting, organisation: organisation, project: project, creator: creator, title: 'Abstimmung',
                     transcript: transcript, generated_summary: 'Lalabeis wurde vorgestellt.')
  end
  let(:contact) { create(:person, organisation: organisation, name: 'Anna Ananas') }
  let(:ben_user) { member_with(role_with, first_name: 'Ben') }
  let!(:anna) { create(:meeting_participant, meeting: meeting, display_name: 'Anna Ananas', person: contact) }
  let!(:ben) { create(:meeting_participant, meeting: meeting, display_name: 'Ben Birne', user: ben_user) }
  let!(:carla) { create(:meeting_participant, meeting: meeting, display_name: 'Carla Kiwi') }

  let(:manager) { writer(role_with('manage_glossary')) }
  let(:writer_without_glossary) { writer(role_with('view_glossary')) }

  # The place of the second occurrence ("Ben: Lalabeis"), as TranscriptMark gives it.
  let(:place_of_ben) { { line_index: 1, char_offset: 5, length: 8 } }

  def role_with(*glossary_actions)
    role = create(:role, organisation: organisation)
    glossary_actions.each { |action| create(:permission, role: role, category: 'glossary', action: action, allowed: true) }
    role
  end

  def member_with(role, first_name: 'Max', active: true)
    user = create(:user, first_name: first_name, last_name: "Muster#{SecureRandom.hex(2)}")
    create(:membership, user: user, organisation: organisation, role: role, active: active)
    user
  end

  def writer(role, access: :read_write, in_project: project)
    member_with(role).tap do |user|
      create(:project_permission, user: user, project: in_project, meetings_access: access)
    end
  end

  def digest_of(text)
    Digest::SHA256.hexdigest(text.to_s)
  end

  def correct(user: manager, scope: 'everywhere', heard: 'Lalabeis', correct: 'Lalabase', place: place_of_ben,
              digest: digest_of(transcript), speaker_id: ben.id, to_glossary: true, on: meeting, in_project: project)
    described_class.call(meeting: on, project: in_project, heard: heard, correct: correct, scope: scope, place: place,
                         digest: digest, speaker_id: speaker_id, to_glossary: to_glossary, current_user: user)
  end

  def nothing_written
    [meeting.reload.transcript, meeting.generated_summary, GlossaryTerm.count, TermCorrection.count]
  end

  describe 'the transcript' do
    it 'is replaced everywhere, never in the speaker label, through the meeting write' do
      result = correct(heard: 'Anna', correct: 'Hanna', place: { line_index: 1, char_offset: 30, length: 4 })

      expect(result).to be_success
      expect(meeting.reload.transcript)
        .to eq("Anna: Wir testen Lalabeis heute.\nBen: Lalabeis kann viel, sagt Hanna.\nUnd Lalabeis-Konten auch.")
    end

    it 'is replaced at every place on "everywhere", and says how often' do
      actor = described_class.new(meeting: meeting, project: project, heard: 'Lalabeis', correct: 'Lalabase',
                                  scope: 'everywhere', place: place_of_ben, digest: digest_of(transcript),
                                  speaker_id: ben.id, to_glossary: false, current_user: manager)

      expect(actor.call).to be_success
      expect(meeting.reload.transcript)
        .to eq("Anna: Wir testen Lalabase heute.\nBen: Lalabase kann viel, sagt Anna.\nUnd Lalabase-Konten auch.")
      expect(actor.replaced_count).to eq(3)
    end

    it 'is replaced at the marked place only on "only here"' do
      expect(correct(scope: 'here')).to be_success
      expect(meeting.reload.transcript)
        .to eq("Anna: Wir testen Lalabeis heute.\nBen: Lalabase kann viel, sagt Anna.\nUnd Lalabeis-Konten auch.")
    end

    it 'runs the derived columns and the search like an edit does (Actors::SaveMeeting)' do
      allow(EmbeddingProcessingJob).to receive(:perform_later)
      meeting.update_columns(create_embeddings: true)

      correct

      expect(meeting.reload.plain_text_version).to include('Ben: Lalabase kann viel')
      expect(EmbeddingProcessingJob).to have_received(:perform_later)
        .with(record_class: Meeting, record_id: meeting.id, fragment_association: :fragments)
    end

    it 'leaves no fragments of a meeting that is not released for search' do
      create(:fragment, fragmentable: meeting, organisation: organisation, plain_text_content: 'Lalabeis alt')

      correct

      expect(meeting.reload.fragments).to be_empty
    end
  end

  describe 'the AI summary' do
    it 'gets the same replacement and stays on "everywhere"' do
      correct

      expect(meeting.reload.generated_summary).to eq('Lalabase wurde vorgestellt.')
    end

    it 'stays as it is on "everywhere" when the word is not in it' do
      meeting.update_columns(generated_summary: 'Ein kurzes Gespräch.')

      correct

      expect(meeting.reload.generated_summary).to eq('Ein kurzes Gespräch.')
    end

    it 'stays as it is on "only here"' do
      correct(scope: 'here')

      expect(meeting.reload.generated_summary).to eq('Lalabeis wurde vorgestellt.')
    end
  end

  describe 'the glossary' do
    def learned
      TermCorrection.order(:created_at).last
    end

    it 'confirms term and form with manage_glossary' do
      correct

      term = GlossaryTerm.find_by(normalized_term: 'lalabase')
      expect([term.term, term.status, term.created_by_id]).to eq(['Lalabase', 'confirmed', manager.id])
      expect(learned).to have_attributes(heard: 'Lalabeis', status: 'confirmed', glossary_term_id: term.id)
    end

    it 'proposes a new term and its form without manage_glossary' do
      correct(user: writer_without_glossary)

      expect(GlossaryTerm.find_by(normalized_term: 'lalabase')).to be_proposed
      expect(learned).to be_proposed
    end

    it 'proposes the form at a confirmed term without manage_glossary, and leaves the term confirmed' do
      term = create(:glossary_term, organisation: organisation, term: 'Lalabase')

      correct(user: writer_without_glossary)

      expect(term.reload).to be_confirmed
      expect(learned).to have_attributes(glossary_term_id: term.id, status: 'proposed')
    end

    it 'leaves a rejected term rejected without manage_glossary, the form a proposal' do
      term = create(:glossary_term, :rejected, organisation: organisation, term: 'Lalabase')

      correct(user: writer_without_glossary)

      expect(term.reload).to be_rejected
      expect(learned).to be_proposed
    end

    it 'confirms a rejected or proposed term with manage_glossary' do
      rejected = create(:glossary_term, :rejected, organisation: organisation, term: 'Lalabase')
      proposed = create(:glossary_term, :proposed, organisation: organisation, term: 'Zirbel')

      correct
      correct(heard: 'Lalabase', correct: 'Zirbel', digest: digest_of(meeting.reload.transcript))

      expect(rejected.reload).to be_confirmed
      expect(proposed.reload).to be_confirmed
    end

    it 'counts an account admin as holding manage_glossary' do
      admin = member_with(create(:role, organisation: organisation, title: Role::ACCOUNT_ADMIN_TITLE))

      correct(user: admin)

      expect(learned).to be_confirmed
    end

    it 'refuses a deactivated member, whatever the role grants' do
      user = manager
      user.memberships.update_all(active: false)
      before = nothing_written

      expect(correct(user: user).code).to eq(:forbidden)
      expect(nothing_written).to eq(before)
    end

    it 'finds the term in another spelling of the same form' do
      term = create(:glossary_term, organisation: organisation, term: 'LalaBase')

      correct

      expect(GlossaryTerm.count).to eq(1)
      expect(learned.glossary_term_id).to eq(term.id)
    end

    it 'writes the place, the count, the origin and who corrected' do
      correct

      expect(learned).to have_attributes(
        project_id: project.id, meeting_id: meeting.id, line_index: 1, char_offset: 5,
        transcript_digest: digest_of(transcript), replaced_count: 3, corrected_by_id: manager.id
      )
    end

    it 'writes the place of the mark and a count of one on "only here"' do
      correct(scope: 'here')

      expect(learned).to have_attributes(line_index: 1, char_offset: 5, replaced_count: 1)
    end

    it 'writes the transcript only when not asked to learn' do
      expect(correct(to_glossary: false)).to be_success
      expect([GlossaryTerm.count, TermCorrection.count]).to eq([0, 0])
      expect(meeting.reload.transcript).to include('Lalabase')
    end

    # Plan §3.2: a heard form that is the term (case aside) is no misheard form.
    it 'writes no heard form that is the term itself, case aside' do
      meeting.update_columns(transcript: 'Ben: lalabase ist gut.')

      result = correct(heard: 'lalabase', correct: 'Lalabase', place: { line_index: 0, char_offset: 5, length: 8 },
                       digest: digest_of('Ben: lalabase ist gut.'))

      expect(result).to be_success
      expect(meeting.reload.transcript).to eq('Ben: Lalabase ist gut.')
      expect(GlossaryTerm.pluck(:term)).to eq(['Lalabase'])
      expect(TermCorrection.count).to eq(0)
    end

    # Two corrections create the same term at once: the second insert meets
    # the unique index (or the validation that saw the first), and finds the
    # first term instead of failing.
    it 'finds a term created at the same moment instead of failing' do
      other = create(:glossary_term, organisation: organisation, term: 'Lalabase')
      allow_any_instance_of(described_class).to receive(:existing_term).and_return(nil)

      expect(correct).to be_success
      expect(learned.glossary_term_id).to eq(other.id)
    end

    it 'finds a term the unique index reports, past a validation that did not see it' do
      other = create(:glossary_term, organisation: organisation, term: 'Lalabase')
      allow_any_instance_of(described_class).to receive(:existing_term).and_return(nil)
      allow_any_instance_of(GlossaryTerm).to receive(:term_not_taken)

      expect(correct).to be_success
      expect(learned.glossary_term_id).to eq(other.id)
    end

    it 'locks the meeting before the term' do
      expect(meeting).to receive(:lock_in_project!).ordered.and_call_original
      expect(Glossary::TermLock).to receive(:call).ordered.and_call_original

      correct
    end
  end

  describe 'the speaker' do
    def learned
      TermCorrection.order(:created_at).last
    end

    it 'is the member a participant is linked to' do
      correct(speaker_id: ben.id)

      expect(learned).to have_attributes(user_id: ben_user.id, person_id: nil)
    end

    it 'is the person of the directory a participant is linked to' do
      correct(speaker_id: anna.id)

      expect(learned).to have_attributes(user_id: nil, person_id: contact.id)
    end

    it 'stays empty for a participant without a link, and for none' do
      correct(scope: 'here', speaker_id: carla.id)
      first = learned
      correct(scope: 'here', place: { line_index: 0, char_offset: 17, length: 8 }, speaker_id: nil,
              digest: digest_of(meeting.reload.transcript))

      second = learned

      expect([first.user_id, first.person_id, second.user_id, second.person_id]).to eq([nil, nil, nil, nil])
    end

    it 'stays empty for a member who left the organisation' do
      ben_user.memberships.destroy_all

      correct(speaker_id: ben.id)

      expect(learned.user_id).to be_nil
    end

    it 'is refused when it is a participant of another meeting' do
      other_meeting = create(:meeting, organisation: organisation, project: project, creator: creator)
      stranger = create(:meeting_participant, meeting: other_meeting, display_name: 'Fremde Feige')
      before = nothing_written

      result = correct(speaker_id: stranger.id)

      expect(result).not_to be_success
      expect(result.code).to eq(:speaker_not_found)
      expect(nothing_written).to eq(before)
    end
  end

  describe 'refusals, with nothing written' do
    it 'refuses a transcript that changed since the dialog counted' do
      before = nothing_written

      result = correct(digest: digest_of("#{transcript} anders"))

      expect(result.code).to eq(:stale_transcript)
      expect(nothing_written).to eq(before)
    end

    it 'refuses a user without the right to edit the meeting' do
      reader = writer(role_with('manage_glossary'), access: :read_only)
      before = nothing_written

      expect(correct(user: reader).code).to eq(:forbidden)
      expect(nothing_written).to eq(before)
    end

    it 'refuses in an archived project, as every meeting write' do
      user = manager
      project.update_columns(archived_at: Time.current)
      before = nothing_written

      expect(correct(user: user).code).to eq(:forbidden)
      expect(nothing_written).to eq(before)
    end

    # lock_in_project! answers false: a move committed between the rights check
    # and the lock, and this project was the one the request was checked for.
    it 'refuses a meeting that moved out of the project meanwhile' do
      user = manager
      allow(meeting).to receive(:lock_in_project!).and_return(false)
      before = nothing_written

      expect(correct(user: user).code).to eq(:not_found)
      expect(nothing_written).to eq(before)
    end

    it 'refuses a place where the form does not stand' do
      expect(correct(place: { line_index: 1, char_offset: 20, length: 4 }).code).to eq(:place_gone)
      expect(correct(place: { line_index: 9, char_offset: 0, length: 8 }).code).to eq(:place_gone)
    end

    it 'refuses a mark inside the speaker label' do
      expect(correct(heard: 'Ben', correct: 'Benno', place: { line_index: 1, char_offset: 0, length: 3 }).code)
        .to eq(:place_gone)
    end

    it 'refuses a blank, an unchanged or an overlong correct form, and a heard form over a line break' do
      expect(correct(correct: '  ').code).to eq(:correct_blank)
      expect(correct(correct: 'Lalabeis').code).to eq(:same_form)
      expect(correct(correct: 'x' * (GlossaryTerm::MAX_LENGTH + 1)).code).to eq(:correct_too_long)
      expect(correct(heard: "Lala\nbeis").code).to eq(:heard_invalid)
      expect(correct(heard: ' ').code).to eq(:heard_invalid)
    end

    it 'refuses an unknown scope' do
      expect(correct(scope: 'somewhere').code).to eq(:invalid_scope)
    end

    it 'leaves the glossary as it was when the meeting write fails' do
      allow(Actors::SaveMeeting).to receive(:call).and_return(
        Actors::BaseActor::Result.new(success: false, errors: ['zu groß'], code: :validation_failed)
      )

      expect(correct.code).to eq(:validation_failed)
      expect([GlossaryTerm.count, TermCorrection.count]).to eq([0, 0])
    end
  end
end
