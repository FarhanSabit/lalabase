# frozen_string_literal: true

require 'rails_helper'

# What: POST /api/v1/organisations/:organisation_id/meetings: a program creates a meeting
#   with a transcript, in a named project or, without one, in the organisation's inbox.
# Why: this is the write the recording app sends after a call. It must land in the right
#   place, keep every door shut that the web form keeps shut, and a retry after a dropped
#   connection must not create a second meeting. A refused meeting writes nothing, and the
#   transcript stays out of the stored answer, or it would outlive the meeting.
RSpec.describe 'API V1 Meetings', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) do
    ActsAsTenant.with_tenant(organisation) do
      create(:role, organisation: organisation).tap do |role|
        create(:permission, role: role, category: 'people', action: 'view_people', allowed: true)
      end
    end
  end
  let(:project) { in_org { create(:project, organisation: organisation) } }
  let(:inbox) { in_org { create(:project, organisation: organisation) } }
  let(:contact) { in_org { create(:person, organisation: organisation, name: 'Erika Beispiel') } }

  before do
    in_org do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      [project, inbox].each { |target| grant(target) }
    end
  end

  def in_org(&) = ActsAsTenant.with_tenant(organisation, &)

  def grant(target, access: :read_write)
    create(:project_permission, user: user, project: target, meetings_access: access)
  end

  def build_pat(read_only: false, **scope)
    build(:personal_access_token, user: user, read_only: read_only, **scope).tap do |pat|
      pat.token_hash = nil
      pat.token_prefix = nil
      pat.generate_token!
      pat.save!
    end
  end

  let(:pat) { build_pat(organisations: [organisation]) }

  def body(**overrides)
    { title: 'Abstimmung', occurred_at: '2026-11-01T10:00:00+01:00', duration_minutes: 30,
      transcript: "Erika Beispiel: Guten Tag.\n" }.merge(overrides)
  end

  def send_meeting(fields = body, token: pat, headers: {}, org: organisation)
    post "/api/v1/organisations/#{org.id}/meetings", params: { meeting: fields }.to_json,
                                                     headers: { 'Authorization' => "Bearer #{token.token}",
                                                                'Content-Type' => 'application/json' }.merge(headers)
  end

  def meeting_count = in_org { Meeting.count }

  def json = response.parsed_body

  describe 'where it lands' do
    it 'writes into the named project and answers without the transcript' do
      send_meeting(body(project_id: project.id))

      expect(response).to have_http_status(:created)
      meeting = in_org { Meeting.find(json.dig('data', 'id')) }
      expect(meeting.project_id).to eq(project.id)
      expect(meeting.creator).to eq(user)
      expect(meeting.transcript).to include('Guten Tag')
      expect(meeting.create_embeddings).to be(false)
      expect(json['data']).to include('project_id' => project.id, 'in_meeting_inbox' => false, 'title' => 'Abstimmung')
      expect(json['data']['path']).to end_with("/meetings/#{meeting.id}")
      expect(response.body).not_to include('Guten Tag')
    end

    it 'writes into the inbox without a project' do
      organisation.update!(meeting_inbox_project: inbox)

      send_meeting

      expect(response).to have_http_status(:created)
      expect(json['data']).to include('project_id' => inbox.id, 'in_meeting_inbox' => true)
    end

    it 'records the activity the web form records' do
      expect { send_meeting(body(project_id: project.id)) }.to(change { in_org { Activity.count } })
    end

    it 'refuses without a project when no inbox is set' do
      send_meeting

      expect(response).to have_http_status(:unprocessable_content)
      expect(json).to include('error' => 'meeting_inbox_missing', 'code' => 'refused', 'reason' => 'meeting_inbox_missing')
      expect(meeting_count).to eq(0)
    end

    it 'treats an archived inbox as none' do
      organisation.update!(meeting_inbox_project: inbox)
      in_org { inbox.archive!(user) }

      send_meeting

      expect(json['reason']).to eq('meeting_inbox_missing')
    end

    it 'says so when the inbox is out of the writer\'s rights' do
      organisation.update!(meeting_inbox_project: inbox)
      in_org { ProjectPermission.find_by!(user: user, project: inbox).update!(meetings_access: :read_only) }

      send_meeting

      expect(response).to have_http_status(:forbidden)
      expect(json).to include('code' => 'forbidden', 'reason' => 'meeting_inbox_forbidden')
      expect(meeting_count).to eq(0)
    end

    it 'says so when the inbox is out of the token\'s reach' do
      organisation.update!(meeting_inbox_project: inbox)
      token = build_pat(organisations: [organisation], project_scopes: { organisation => [project] })

      send_meeting(body, token: token)

      expect(response).to have_http_status(:forbidden)
      expect(json['reason']).to eq('meeting_inbox_forbidden')
    end
  end

  describe 'the doors' do
    it 'refuses a read-only token' do
      send_meeting(body(project_id: project.id), token: build_pat(read_only: true, organisations: [organisation]))

      expect(response).to have_http_status(:forbidden)
      expect(json['code']).to eq('read_only')
      expect(meeting_count).to eq(0)
    end

    it 'answers 404 for an organisation outside the token' do
      send_meeting(body, org: create(:organisation))

      expect(response).to have_http_status(:not_found)
    end

    it 'answers 404 for a project of another organisation' do
      other = create(:organisation)
      foreign = ActsAsTenant.with_tenant(other) { create(:project, organisation: other) }

      send_meeting(body(project_id: foreign.id))

      expect(response).to have_http_status(:not_found)
    end

    it 'answers 404 for a project outside the token' do
      token = build_pat(organisations: [organisation], project_scopes: { organisation => [inbox] })

      send_meeting(body(project_id: project.id), token: token)

      expect(response).to have_http_status(:not_found)
    end

    it 'answers 404 for a malformed project id' do
      send_meeting(body(project_id: 'kein-projekt'))

      expect(response).to have_http_status(:not_found)
    end

    it 'answers 403 without the write right on a named project' do
      in_org { ProjectPermission.find_by!(user: user, project: project).update!(meetings_access: :read_only) }

      send_meeting(body(project_id: project.id))

      expect(response).to have_http_status(:forbidden)
      expect(meeting_count).to eq(0)
    end

    it 'keeps an account admin out of an archived project' do
      in_org do
        Membership.find_by!(user: user).update!(role: create(:role, organisation: organisation, title: 'account_admin'))
        project.archive!(user)
      end

      send_meeting(body(project_id: project.id))

      expect(json).to include('code' => 'refused', 'reason' => 'project_archived')
      expect(meeting_count).to eq(0)
    end
  end

  describe 'the input' do
    it 'refuses a meeting without a title or date' do
      send_meeting({ project_id: project.id, transcript: 'Text' })

      expect(response).to have_http_status(:unprocessable_content)
      expect(json['code']).to eq('invalid_input')
      expect(meeting_count).to eq(0)
    end

    it 'answers bad_request without a meeting object' do
      post "/api/v1/organisations/#{organisation.id}/meetings",
           params: { meeting: 'text' }.to_json,
           headers: { 'Authorization' => "Bearer #{pat.token}", 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:bad_request)
    end

    it 'takes a transcript just under the limit and refuses one above it' do
      fill = 'x' * (Meeting::MAX_CONTENT_BYTES - 1)
      send_meeting(body(project_id: project.id, transcript: fill))
      expect(response).to have_http_status(:created)

      send_meeting(body(project_id: project.id, transcript: "#{fill}xx"))
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'the participants' do
    def participants_of(id) = in_org { MeetingParticipant.where(meeting_id: id).order(:display_name).to_a }

    it 'keeps a name without a ref as an external participant' do
      send_meeting(body(project_id: project.id, participants: [{ display_name: 'Max Muster' }]))

      row = participants_of(json.dig('data', 'id')).first
      expect(row).to have_attributes(display_name: 'Max Muster', user_id: nil, person_id: nil)
    end

    it 'links a contact and a member by the ids of the people list' do
      send_meeting(body(project_id: project.id, participants: [
                          { display_name: 'Erika Beispiel', ref: "person:#{contact.id}" },
                          { display_name: 'Ich Selbst', ref: "member:#{user.id}" }
                        ]))

      expect(response).to have_http_status(:created)
      erika, ich = participants_of(json.dig('data', 'id'))
      expect(erika).to have_attributes(person_id: contact.id, user_id: nil)
      expect(ich).to have_attributes(user_id: user.id, person_id: nil)
    end

    it 'refuses the whole meeting for a ref that does not resolve' do
      other = create(:organisation)
      foreign = ActsAsTenant.with_tenant(other) { create(:person, organisation: other) }

      ["person:#{foreign.id}", 'quatsch'].each do |ref|
        send_meeting(body(project_id: project.id, participants: [{ display_name: 'Wer', ref: ref }]))

        expect(response).to have_http_status(:unprocessable_content)
        expect(json).to include('code' => 'invalid_input', 'reason' => 'unknown_participant')
      end
      expect(meeting_count).to eq(0)
    end

    it 'refuses a ref without the people right' do
      in_org { Permission.where(role: role, action: 'view_people').delete_all }

      send_meeting(body(project_id: project.id, participants: [{ display_name: 'Erika', ref: "person:#{contact.id}" }]))

      expect(json['reason']).to eq('unknown_participant')
      expect(meeting_count).to eq(0)
    end

    it 'refuses a ref with a token limited to some projects, a plain name still goes' do
      token = build_pat(organisations: [organisation], project_scopes: { organisation => [project] })

      send_meeting(body(project_id: project.id, participants: [{ display_name: 'Erika', ref: "person:#{contact.id}" }]), token: token)
      expect(json['reason']).to eq('unknown_participant')

      send_meeting(body(project_id: project.id, participants: [{ display_name: 'Erika' }]), token: token)
      expect(response).to have_http_status(:created)
    end

    it 'refuses participants that are no list of objects' do
      send_meeting(body(project_id: project.id, participants: 'Erika'))

      expect(json['reason']).to eq('unknown_participant')
      expect(meeting_count).to eq(0)
    end

    it 'refuses a name given twice' do
      send_meeting(body(project_id: project.id, participants: [{ display_name: 'Erika' }, { display_name: 'erika' }]))

      expect(response).to have_http_status(:unprocessable_content)
      expect(meeting_count).to eq(0)
    end
  end

  # K4d: what the sender replaced from the glossary before it sent the transcript.
  describe 'the glossary replacements' do
    let!(:term) { in_org { create(:glossary_term, organisation: organisation, term: 'Lalabase') } }

    def applications_of(id) = in_org { TermApplication.where(meeting_id: id).order(:normalized_heard, :heard).to_a }

    def send_with(replacements)
      send_meeting(body(project_id: project.id, glossary_replacements: replacements))
    end

    it 'writes one row per heard spelling with the term, the project and the count' do
      send_with([{ heard: 'lala bass', term: 'Lalabase', count: 3 }, { heard: 'lalabase', term: 'Lalabase', count: 2 }])

      expect(response).to have_http_status(:created)
      rows = applications_of(json.dig('data', 'id'))
      expect(rows.map { |row| [row.heard, row.term, row.replaced_count, row.glossary_term_id, row.project_id, row.source] })
        .to eq([['lala bass', 'Lalabase', 3, term.id, project.id, 'device'], ['lalabase', 'Lalabase', 2, term.id, project.id, 'device']])
      expect(rows.map(&:spelling?)).to eq([false, true])
      expect(json['data'].keys).not_to include('glossary_replacements'), 'the answer stays the small summary'
    end

    it 'sums a spelling sent twice and cleans what it keeps' do
      send_with([{ heard: 'lala bass', term: 'Lalabase', count: 1 }, { heard: " lala\u00A0bass ", term: 'Lalabase', count: '4' }])

      rows = applications_of(json.dig('data', 'id'))
      expect(rows.map { |row| [row.heard, row.replaced_count] }).to eq([['lala bass', 5]])
    end

    it 'keeps a row whose term the glossary no longer has, without a reference' do
      send_with([{ heard: 'zirbel holz', term: 'Zirbelholz', count: 1 }])

      row = applications_of(json.dig('data', 'id')).first
      expect(row).to have_attributes(term: 'Zirbelholz', glossary_term_id: nil)
      expect(in_org { GlossaryTerm.where(normalized_term: 'zirbelholz') }).not_to exist, 'nothing is learnt'
    end

    it 'writes nothing without the list or with an empty one' do
      send_meeting(body(project_id: project.id))
      expect(applications_of(json.dig('data', 'id'))).to be_empty

      send_with([])
      expect(response).to have_http_status(:created)
      expect(applications_of(json.dig('data', 'id'))).to be_empty
    end

    # One example per shape: a loop of requests in one example reads as an N+1 to the detector.
    {
      'no list' => 'lala bass',
      'a list of strings' => ['lala bass'],
      'a row without heard' => [{ term: 'Lalabase', count: 1 }],
      'a row without term' => [{ heard: 'lala bass', count: 1 }],
      'a row without count' => [{ heard: 'lala bass', term: 'Lalabase' }],
      'a count of zero' => [{ heard: 'lala bass', term: 'Lalabase', count: 0 }],
      'a broken count' => [{ heard: 'lala bass', term: 'Lalabase', count: 1.5 }],
      'a count in words' => [{ heard: 'lala bass', term: 'Lalabase', count: 'drei' }],
      'a count with a space' => [{ heard: 'lala bass', term: 'Lalabase', count: ' 3' }],
      'a blank heard form' => [{ heard: '  ', term: 'Lalabase', count: 1 }],
      'a term too long' => [{ heard: 'lala bass', term: 'x' * 256, count: 1 }],
      'a heard form that is no text' => [{ heard: 7, term: 'Lalabase', count: 1 }],
      'a list too long' => Array.new(TermApplication::MAX_ENTRIES + 1) { |n| { heard: "form #{n}", term: 'Lalabase', count: 1 } }
    }.each do |shape, replacements|
      it "refuses the whole meeting for #{shape}" do
        send_with(replacements)

        expect(response).to have_http_status(:unprocessable_content)
        expect(json).to include('code' => 'invalid_input', 'reason' => 'invalid_glossary_replacements')
        expect(meeting_count).to eq(0)
        expect(in_org { TermApplication.count }).to eq(0)
      end
    end

    it 'writes the list once under one Idempotency-Key' do
      key = { 'Idempotency-Key' => 'aufnahme-2' }
      2.times do
        send_meeting(body(project_id: project.id, glossary_replacements: [{ heard: 'lala bass', term: 'Lalabase', count: 3 }]),
                     headers: key)
      end

      expect(meeting_count).to eq(1)
      expect(in_org { TermApplication.count }).to eq(1)
    end
  end

  describe 'a retry' do
    let(:key) { { 'Idempotency-Key' => 'aufnahme-1' } }

    it 'creates one meeting and answers the first answer again' do
      send_meeting(body(project_id: project.id), headers: key)
      first = response.body

      send_meeting(body(project_id: project.id), headers: key)

      expect(response).to have_http_status(:created)
      expect(response.body).to eq(first)
      expect(meeting_count).to eq(1)
    end

    it 'refuses the same key with another content' do
      send_meeting(body(project_id: project.id), headers: key)
      send_meeting(body(project_id: project.id, title: 'Anders'), headers: key)

      expect(json['error']).to eq('idempotency_key_reused')
      expect(meeting_count).to eq(1)
    end

    it 'leaves the key free after a refusal' do
      send_meeting(body, headers: key)
      expect(response).to have_http_status(:unprocessable_content)

      send_meeting(body(project_id: project.id), headers: key)
      expect(response).to have_http_status(:created)
    end

    it 'stores no transcript with the key' do
      send_meeting(body(project_id: project.id), headers: key)

      stored = McpIdempotencyKey.find_by!(idempotency_key: 'aufnahme-1')
      expect(stored.response_content).not_to include('Guten Tag')
      expect(stored.request_fingerprint).not_to include('Guten Tag')
    end
  end

  describe 'the project list' do
    it 'names the inbox' do
      organisation.update!(meeting_inbox_project: inbox)

      get '/api/v1/projects', headers: { 'Authorization' => "Bearer #{pat.token}" }

      flags = json['data'].to_h { |row| [row['id'], row['meeting_inbox']] }
      expect(flags).to include(inbox.id => true, project.id => false)
    end
  end
end
