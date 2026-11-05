# frozen_string_literal: true

require 'rails_helper'

# Actors::SaveMeeting — the meetings write seam (Tier 1).
# Intent per describe:
#  - create: persists with the acting user as creator (the controller never
#    passes creator via params — the actor owns that assignment).
#  - update guards: an id that matches nothing in the tenant (foreign tenant or
#    deleted record) must yield a clean failure result, never a raise-through —
#    this path is unreachable via the controller (set_meeting 404s first), so it
#    can ONLY be covered here.
#  - invalid params: failure result, nothing persisted.
RSpec.describe Actors::SaveMeeting do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:user) { create(:user) }

  let(:valid_params) { { title: 'Kickoff', occurred_at: Time.current } }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  describe 'create' do
    it 'persists the meeting with the acting user as creator' do
      result = described_class.call(project: project, params: valid_params, current_user: user)

      expect(result.success).to be(true)
      meeting = project.meetings.find_by(title: 'Kickoff')
      expect(meeting.creator).to eq(user)
    end

    it 'returns a failure result and persists nothing for invalid params' do
      result = nil
      expect do
        result = described_class.call(project: project, params: { title: '', occurred_at: nil }, current_user: user)
      end.not_to change(Meeting, :count)
      expect(result.success).to be(false)
    end
  end

  describe 'update lookup guards' do
    it 'fails cleanly when the id matches no meeting in the tenant (foreign tenant / deleted)' do
      other_org = create(:organisation)
      foreign_meeting = ActsAsTenant.with_tenant(other_org) do
        other_project = create(:project, organisation: other_org)
        create(:meeting, project: other_project, organisation: other_org, creator: user)
      end

      result = described_class.call(project: project, params: valid_params,
                                    id: foreign_meeting.id, current_user: user)

      expect(result.success).to be(false)
      expect(ActsAsTenant.with_tenant(other_org) { foreign_meeting.reload.title }).not_to eq('Kickoff')
    end

    # The edit was authorized against this project. A move (Actors::MoveMeeting)
    # that committed meanwhile has taken the meeting into another one, where the
    # editor may have no rights: the edit finds no meeting here.
    it 'does not edit a meeting that has moved to another project' do
      meeting = create(:meeting, project: project, organisation: organisation, creator: user, title: 'Alt')
      elsewhere = create(:project, organisation: organisation)
      allow(Meeting).to receive(:where).and_wrap_original do |original, *args, **kwargs|
        relation = original.call(*args, **kwargs)
        Meeting.unscoped.where(id: meeting.id).update_all(project_id: elsewhere.id)
        relation
      end

      result = described_class.call(project: project, params: valid_params, id: meeting.id, current_user: user)

      expect(result.success).to be(false)
      expect(result.resource).to be_nil
      expect(meeting.reload.title).to eq('Alt')
    end
  end

  # A term correction (Actors::CorrectMeetingTerm, K4b) keeps the AI summary
  # for its one save; any other save of the transcript drops it as before.
  describe 'keep_summary' do
    let!(:meeting) do
      create(:meeting, project: project, organisation: organisation, creator: user, transcript: 'Lalabeis hier',
                       generated_summary: 'Zusammenfassung zu Lalabeis')
    end

    it 'drops the summary of a changed transcript by default' do
      described_class.call(project: project, params: { transcript: 'Lalabase hier' }, id: meeting.id, current_user: user)

      expect(meeting.reload.generated_summary).to eq('')
    end

    it 'keeps it when asked, for that save' do
      result = described_class.call(project: project, params: { transcript: 'Lalabase hier' }, id: meeting.id,
                                    current_user: user, keep_summary: true)

      expect(result).to be_success
      expect(meeting.reload.transcript).to eq('Lalabase hier')
      expect(meeting.generated_summary).to eq('Zusammenfassung zu Lalabeis')
    end
  end

  describe 'participant sync' do
    def org_member(_name = nil)
      u = create(:user)
      role = create(:role, title: "R#{SecureRandom.hex(4)}", organisation: organisation)
      create(:membership, user: u, organisation: organisation, role: role, active: true)
      u
    end

    def participants_of(meeting)
      meeting.meeting_participants.pluck(:normalized_name).sort
    end

    it 'creates participants from the payload' do
      params = valid_params.merge(participants: [{ display_name: 'Karl Krause' }, { display_name: 'Anna Ananas' }])
      result = described_class.call(project: project, params: params, current_user: user)

      expect(result.success).to be(true)
      expect(participants_of(result.resource)).to eq(['anna ananas', 'karl krause'])
    end

    it 'adds, removes and keeps on update (no orphans)' do
      meeting = described_class.call(
        project: project, params: valid_params.merge(participants: [{ display_name: 'Karl Krause' }, { display_name: 'Anna Ananas' }]),
        current_user: user
      ).resource

      described_class.call(
        project: project, id: meeting.id,
        params: valid_params.merge(participants: [{ display_name: 'Karl Krause' }, { display_name: 'Bert Bauer' }]),
        current_user: user
      )

      expect(participants_of(meeting.reload)).to eq(['bert bauer', 'karl krause'])
    end

    it 'renames in place when the normalized name is unchanged' do
      meeting = described_class.call(
        project: project, params: valid_params.merge(participants: [{ display_name: 'Karl' }]),
        current_user: user
      ).resource

      described_class.call(
        project: project, id: meeting.id,
        params: valid_params.merge(participants: [{ display_name: 'KARL' }]),
        current_user: user
      )

      expect(meeting.reload.meeting_participants.count).to eq(1)
      expect(meeting.meeting_participants.first.display_name).to eq('KARL')
    end

    it 'leaves participants untouched when no :participants key is sent' do
      meeting = described_class.call(
        project: project, params: valid_params.merge(participants: [{ display_name: 'Karl Krause' }]),
        current_user: user
      ).resource

      described_class.call(project: project, id: meeting.id,
                           params: { title: 'Renamed', occurred_at: Time.current }, current_user: user)

      expect(participants_of(meeting.reload)).to eq(['karl krause'])
    end

    it 'clears all participants for an empty payload' do
      meeting = described_class.call(
        project: project, params: valid_params.merge(participants: [{ display_name: 'Karl Krause' }]),
        current_user: user
      ).resource

      described_class.call(project: project, id: meeting.id,
                           params: valid_params.merge(participants: []), current_user: user)

      expect(meeting.reload.meeting_participants).to be_empty
    end

    # The SlimSelect mirror posts an INDEXED hash (meeting[participants][i][...]) with
    # a static blank index-0 sentinel row. These lock in that exact wire shape against
    # the array/hash-tolerant extractor (Option C) so a frontend rework can't silently
    # break the save contract.
    it 'accepts the indexed hash payload from the SlimSelect mirror and drops the blank sentinel row' do
      params = valid_params.merge(participants: { '0' => { 'display_name' => '' },
                                                  '1' => { 'display_name' => 'Karl Krause', 'user_id' => '' } })
      result = described_class.call(project: project, params: params, current_user: user)

      expect(result.success).to be(true)
      expect(participants_of(result.resource)).to eq(['karl krause'])
    end

    it 'clears all when only the blank sentinel row is sent (everyone removed in the UI)' do
      meeting = described_class.call(
        project: project, params: valid_params.merge(participants: [{ display_name: 'Karl Krause' }]),
        current_user: user
      ).resource

      described_class.call(project: project, id: meeting.id,
                           params: valid_params.merge(participants: { '0' => { 'display_name' => '' } }),
                           current_user: user)

      expect(meeting.reload.meeting_participants).to be_empty
    end

    it 'links an internal org member via user_id' do
      member = org_member
      params = valid_params.merge(participants: [{ display_name: 'Member Name', user_id: member.id }])
      meeting = described_class.call(project: project, params: params, current_user: user).resource

      expect(meeting.meeting_participants.first.user_id).to eq(member.id)
    end

    it 'drops a foreign (non-org) user_id to an external name (tamper guard)' do
      outsider = create(:user) # never made an org member
      params = valid_params.merge(participants: [{ display_name: 'Outsider', user_id: outsider.id }])
      meeting = described_class.call(project: project, params: params, current_user: user).resource

      participant = meeting.meeting_participants.first
      expect(participant.user_id).to be_nil
      expect(participant.display_name).to eq('Outsider')
    end

    it 'fails with a readable error on a duplicate name and persists nothing' do
      params = valid_params.merge(participants: [{ display_name: 'Jörg' }, { display_name: 'Joerg' }])

      result = nil
      expect { result = described_class.call(project: project, params: params, current_user: user) }
        .not_to change(MeetingParticipant, :count)
      expect(result.success).to be(false)
      expect(result.errors.join).to match(/doppelt|zweimal|twice|more than once/i)
    end

    it 'fails when the same org member appears twice under different names' do
      member = org_member
      params = valid_params.merge(participants: [
                                    { display_name: 'Karl Krause', user_id: member.id },
                                    { display_name: 'Karl', user_id: member.id }
                                  ])

      result = described_class.call(project: project, params: params, current_user: user)
      expect(result.success).to be(false)
    end

    # meeting_participants.person_id links a row to the people directory. The form
    # never sends it: the edit keeps a row by its normalized name, or by its member
    # under another name, so the link survives every save that keeps the
    # participant, and a new name without the same member is a new row without a
    # link (accepted; the link dialog sets it again). Rebuilding the rows on save,
    # or taking person_id from the payload, would drop every link on every save.
    describe 'person link (person_id)' do
      let(:person) { create(:person, organisation: organisation, name: 'Karl Krause') }

      it 'sets a link a caller resolved, by the normalized name' do
        result = described_class.call(
          project: project, current_user: user,
          params: valid_params.merge(participants: [{ display_name: 'Karl Krause' }, { display_name: 'Anna Ananas' }]),
          participant_links: { MeetingParticipant.normalize_name('Karl Krause') => person.id }
        )

        expect(result.resource.meeting_participants.find_by(display_name: 'Karl Krause').person_id).to eq(person.id)
        expect(result.resource.meeting_participants.find_by(display_name: 'Anna Ananas').person_id).to be_nil
      end

      it 'never takes a person_id from the payload' do
        result = described_class.call(
          project: project, current_user: user,
          params: valid_params.merge(participants: [{ display_name: 'Karl Krause', person_id: person.id }])
        )

        expect(result.resource.meeting_participants.first.person_id).to be_nil
      end

      # The meeting is created through the actor; the link is set directly, as the
      # link dialog (a separate writer) will.
      def meeting_with(*names)
        described_class.call(
          project: project, params: valid_params.merge(participants: names.map { |n| { display_name: n } }),
          current_user: user
        ).resource
      end

      def linked_row(meeting, name)
        row = meeting.meeting_participants.find_by!(normalized_name: MeetingParticipant.normalize_name(name))
        row.update_column(:person_id, person.id)
        row
      end

      def save(meeting, params)
        result = described_class.call(project: project, id: meeting.id, params: params, current_user: user)
        expect(result.success).to be(true)
        result
      end

      it 'keeps person_id and the row when the name stays and the rest of the meeting changes' do
        meeting = meeting_with('Karl Krause', 'Anna Ananas')
        row = linked_row(meeting, 'Karl Krause')

        save(meeting, valid_params.merge(title: 'Retro',
                                         participants: [{ display_name: 'Karl Krause' }, { display_name: 'Bert Bauer' }]))

        expect(meeting.reload.title).to eq('Retro')
        expect(participants_of(meeting)).to eq(['bert bauer', 'karl krause'])
        expect(MeetingParticipant.where(id: row.id).pluck(:person_id)).to eq([person.id])
      end

      it 'keeps person_id and takes the new spelling when the normalized name is the same' do
        meeting = meeting_with('Karl Krause')
        row = linked_row(meeting, 'Karl Krause')

        save(meeting, valid_params.merge(participants: [{ display_name: '  KARL   krause ' }]))

        rows = meeting.reload.meeting_participants.pluck(:id, :display_name, :person_id)
        expect(rows).to eq([[row.id, 'KARL krause', person.id]])
      end

      # One key per participant (people directory, S2b): a contact row the form
      # makes a member's is that member now. It keeps the row, not the contact.
      it 'drops the contact link when the form makes the row a member' do
        member = org_member
        meeting = meeting_with('Karl Krause')
        row = linked_row(meeting, 'Karl Krause')

        save(meeting, valid_params.merge(participants: [{ display_name: 'Karl Krause', user_id: member.id }]))

        expect(MeetingParticipant.where(id: row.id).pluck(:user_id, :person_id)).to eq([[member.id, nil]])
      end

      it 'keeps person_id when a save sends the row without a member, as before' do
        meeting = meeting_with('Karl Krause')
        row = linked_row(meeting, 'Karl Krause')

        save(meeting, valid_params.merge(participants: [{ display_name: 'Karl Krause', user_id: '' }]))

        expect(MeetingParticipant.where(id: row.id).pluck(:user_id, :person_id)).to eq([[nil, person.id]])
      end

      it 'keeps person_id when no :participants key is sent' do
        meeting = meeting_with('Karl Krause')
        row = linked_row(meeting, 'Karl Krause')

        save(meeting, { title: 'Renamed', occurred_at: Time.current })

        expect(MeetingParticipant.where(id: row.id).pluck(:person_id)).to eq([person.id])
      end

      it 'never takes person_id from the payload' do
        other = create(:person, organisation: organisation, name: 'Erika Muster')
        meeting = meeting_with('Karl Krause', 'Anna Ananas')
        row = linked_row(meeting, 'Karl Krause')

        save(meeting, valid_params.merge(participants: [{ display_name: 'Karl Krause', person_id: other.id },
                                                        { display_name: 'Anna Ananas', person_id: other.id }]))

        expect(meeting.reload.meeting_participants.pluck(:id, :person_id))
          .to contain_exactly([row.id, person.id], [anything, nil])
      end

      # The accepted rule (no rename in the form): a chip removed and a new one
      # added is another participant. The old row goes, its link with it.
      it 'drops the row and its link when the name is replaced by a new one' do
        meeting = meeting_with('Karl Krause')
        row = linked_row(meeting, 'Karl Krause')

        save(meeting, valid_params.merge(participants: [{ display_name: 'Karl Kraus' }]))

        rows = meeting.reload.meeting_participants.pluck(:id, :normalized_name, :person_id)
        expect(rows.size).to eq(1)
        expect(rows.first).to match([satisfy { |id| id != row.id }, 'karl kraus', nil])
        expect(Person.exists?(person.id)).to be(true)
      end

      # The form labels a member chip with the member's CURRENT profile name, not
      # the stored one. After a change of name in the profile, an untouched save
      # sends the same member under a new name: still the same participant, the
      # same row. (A member row carries no person_id: one key per participant,
      # so the row id is the mark that it stayed.)
      it 'keeps the row when a member arrives under a new name' do
        member = org_member
        meeting = described_class.call(
          project: project, params: valid_params.merge(participants: [{ display_name: 'Karl Krause', user_id: member.id }]),
          current_user: user
        ).resource
        row = meeting.meeting_participants.find_by!(user_id: member.id)

        save(meeting, valid_params.merge(participants: [{ display_name: 'Karl Krause-Meier', user_id: member.id }]))

        rows = meeting.reload.meeting_participants.pluck(:id, :display_name, :user_id)
        expect(rows).to eq([[row.id, 'Karl Krause-Meier', member.id]])
      end

      # Two members, one renamed and one removed in the same save: the renamed
      # member takes its own row, never the other member's. Each member is the
      # renamed one once, so the order the rows load in cannot hide it.
      [0, 1].each do |renamed|
        it "gives a member under a new name its own row, not another member's (member #{renamed + 1})" do
          names = ['Karl Krause', 'Erika Muster']
          members = [org_member, org_member]
          meeting = described_class.call(
            project: project,
            params: valid_params.merge(participants: names.zip(members).map { |n, m| { display_name: n, user_id: m.id } }),
            current_user: user
          ).resource
          kept = meeting.meeting_participants.find_by!(user_id: members[renamed].id)

          save(meeting, valid_params.merge(participants: [{ display_name: "#{names[renamed]}-Neu",
                                                            user_id: members[renamed].id }]))

          rows = meeting.reload.meeting_participants.pluck(:id, :user_id)
          expect(rows).to eq([[kept.id, members[renamed].id]])
        end
      end

      # A row whose name is sent keeps its name; matching by member comes second.
      # The member takes the row of its new name, and its old row goes.
      it 'matches by name before it matches by member' do
        member = org_member
        meeting = described_class.call(
          project: project,
          params: valid_params.merge(participants: [{ display_name: 'Karl Krause', user_id: member.id },
                                                    { display_name: 'Karl Krause-Meier' }]),
          current_user: user
        ).resource
        named = meeting.meeting_participants.find_by!(normalized_name: 'karl krause-meier')

        save(meeting, valid_params.merge(participants: [{ display_name: 'Karl Krause-Meier', user_id: member.id }]))

        rows = meeting.reload.meeting_participants.pluck(:id, :user_id)
        expect(rows).to eq([[named.id, member.id]])
      end

      # The member's old name comes back as an external participant: that name
      # claims the row, so the member cannot take it too and gets a new one.
      it 'never gives a name and a member the same row' do
        member = org_member
        meeting = described_class.call(
          project: project, params: valid_params.merge(participants: [{ display_name: 'Karl Krause', user_id: member.id }]),
          current_user: user
        ).resource
        row = meeting.meeting_participants.find_by!(user_id: member.id)

        save(meeting, valid_params.merge(participants: [{ display_name: 'Karl Krause' },
                                                        { display_name: 'Karl Krause-Meier', user_id: member.id }]))

        rows = meeting.reload.meeting_participants.order(:normalized_name).pluck(:id, :normalized_name, :user_id)
        expect(rows).to match([[row.id, 'karl krause', nil],
                               [satisfy { |id| id != row.id }, 'karl krause-meier', member.id]])
      end
    end
  end

  # Search & chat embedding wiring (Gespräche Slice 6): enqueue gating mirrors
  # SaveNote; the toggle-OFF fragment purge is Meeting-specific (PII data class).
  describe 'search & chat embedding wiring (Slice 6)' do
    let(:content_params) { { title: 'Kickoff', occurred_at: Time.current, notes: 'Wichtige Notizen zum Gespräch.' } }

    def fragment_for(meeting)
      create(:fragment, fragmentable: meeting, organisation: organisation,
                        plain_text_content: 'chunk')
    end

    describe 'enqueue gating' do
      before { allow(EmbeddingProcessingJob).to receive(:perform_later) }

      it 'enqueues the embedding job when the opt-in is on' do
        actor = described_class.new(project: project, params: content_params.merge(create_embeddings: true), current_user: user)
        actor.call
        expect(EmbeddingProcessingJob).to have_received(:perform_later).with(
          record_class: Meeting, record_id: actor.record.id, fragment_association: :fragments
        )
      end

      it 'does NOT enqueue when the opt-in is off' do
        described_class.call(project: project, params: content_params.merge(create_embeddings: false), current_user: user)
        expect(EmbeddingProcessingJob).not_to have_received(:perform_later)
      end

      it 'does NOT enqueue on a validation failure even with the opt-in on' do
        described_class.call(project: project, params: { title: '', occurred_at: nil, create_embeddings: true }, current_user: user)
        expect(EmbeddingProcessingJob).not_to have_received(:perform_later)
      end

      # Cost gate (review PR #247): every run is metered (#231) — an edit that does
      # not change the indexed text must not re-embed the whole transcript.
      it 'does NOT re-enqueue on a content-unchanged update while the opt-in stays on' do
        meeting = described_class.call(project: project, params: content_params.merge(create_embeddings: true), current_user: user).resource

        described_class.call(project: project, id: meeting.id,
                             params: content_params.merge(title: 'Umbenannt', create_embeddings: true), current_user: user)

        expect(EmbeddingProcessingJob).to have_received(:perform_later).once
      end

      it 're-enqueues when the opt-in is re-enabled without a content change' do
        meeting = described_class.call(project: project, params: content_params.merge(create_embeddings: true), current_user: user).resource
        described_class.call(project: project, id: meeting.id,
                             params: content_params.merge(create_embeddings: false), current_user: user)

        described_class.call(project: project, id: meeting.id,
                             params: content_params.merge(create_embeddings: true), current_user: user)

        expect(EmbeddingProcessingJob).to have_received(:perform_later).twice
      end
    end

    describe 'fragment purge on opt-out (PII fail-safe)' do
      before { allow(EmbeddingProcessingJob).to receive(:perform_later) }

      it 'deletes fragments and resets the status columns when the opt-in is turned off' do
        meeting = described_class.call(project: project, params: content_params.merge(create_embeddings: true), current_user: user).resource
        fragment_for(meeting)
        meeting.update!(embeddings_creation_flag: true, embedding_creation_error: 'stale')

        described_class.call(project: project, id: meeting.id,
                             params: content_params.merge(create_embeddings: false), current_user: user)

        expect(meeting.reload.fragments).to be_empty
        expect(meeting.read_attribute(:embeddings_creation_flag)).to be_nil
        expect(meeting.read_attribute(:embedding_creation_error)).to be_nil
      end

      # Matrix row 3 (embedding v2 PR 2): the opt-out purge must take the fragments'
      # sidecar rows with them, synchronously in the actor transaction (PII).
      it 'also purges the fragments\' sidecar content_embeddings rows (no orphan PII)' do
        meeting = described_class.call(project: project, params: content_params.merge(create_embeddings: true), current_user: user).resource
        fragment = fragment_for(meeting)
        create(:content_embedding, organisation: organisation, embeddable: fragment)

        described_class.call(project: project, id: meeting.id,
                             params: content_params.merge(create_embeddings: false), current_user: user)

        expect(meeting.reload.fragments).to be_empty
        expect(ContentEmbedding.where(embeddable: fragment)).to be_empty
      end

      it 'deletes fragments when content is cleared even if the opt-in stays on' do
        meeting = described_class.call(project: project, params: content_params.merge(create_embeddings: true), current_user: user).resource
        fragment_for(meeting)

        described_class.call(project: project, id: meeting.id,
                             params: { title: 'Kickoff', occurred_at: Time.current, notes: '', transcript: '', create_embeddings: true },
                             current_user: user)

        expect(meeting.reload.fragments).to be_empty
      end

      it 'keeps fragments when the opt-in stays on with content present' do
        meeting = described_class.call(project: project, params: content_params.merge(create_embeddings: true), current_user: user).resource
        fragment_for(meeting)

        described_class.call(project: project, id: meeting.id,
                             params: content_params.merge(create_embeddings: true, notes: 'Aktualisierte Notizen.'), current_user: user)

        expect(meeting.reload.fragments).not_to be_empty
      end
    end
  end
end
