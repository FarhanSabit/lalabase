# frozen_string_literal: true

require 'rails_helper'

# REST R8: GET /api/v1/projects/:project_id/meetings and GET /api/v1/meetings/:id, a meeting
# for a program such as the terminal client.
#
# What: the rows of a project, newest first, searched by Meeting.search_by_content, and one
#   meeting whole, with its transcript.
# Why: this is a new read of what people said, behind a token. No answer may tell a meeting
#   that exists from one that does not, the search may never reach a meeting the reader
#   cannot read (it matches inside transcripts), and nothing internal leaves the server.
RSpec.describe 'REST meetings', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:role) { ActsAsTenant.with_tenant(organisation) { create(:role, organisation: organisation) } }
  let(:project) { new_project }
  let(:creator) { member(meetings: 'read_write', first_name: 'Clara', last_name: 'Creator') }
  let(:reader) { member }
  let(:not_found_body) { { error: 'not_found', code: 'not_found' }.to_json }

  def quietly(&) = Prosopite.pause { ActsAsTenant.with_tenant(organisation, &) }

  def new_project(owner = organisation)
    Prosopite.pause { ActsAsTenant.with_tenant(owner) { create(:project, organisation: owner) } }
  end

  def member(meetings: 'read_only', tickets: 'no_access', on: project, **names)
    quietly do
      user = create(:user, **names)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      create(:project_permission, user: user, project: on, meetings_access: meetings, tickets_access: tickets) if on
      user
    end
  end

  def account_admin
    quietly do
      create(:user).tap do |user|
        create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation),
                            active: true)
      end
    end
  end

  def token_for(user, read_only: true, **reach)
    quietly do
      build(:personal_access_token, user: user, read_only: read_only, organisations: [organisation], **reach).tap do |pat|
        pat.token_hash = nil
        pat.token_prefix = nil
        pat.generate_token!
        pat.save!
      end
    end
  end

  def meeting(in_project: project, **attributes)
    Prosopite.pause do
      ActsAsTenant.with_tenant(in_project.organisation) do
        create(:meeting, { project: in_project, organisation: in_project.organisation, creator: creator,
                           title: 'Sprint review', occurred_at: 1.day.ago }.merge(attributes))
      end
    end
  end

  def read(path, user: reader, pat: token_for(user))
    get path, headers: { 'Authorization' => "Bearer #{pat.token}" }
    response
  end

  def list(query = '', **options)
    read("/api/v1/projects/#{project.id}/meetings#{query}", **options)
  end

  def show(id, **options)
    read("/api/v1/meetings/#{id}", **options)
  end

  def ids = response.parsed_body['data'].pluck('id')

  describe 'GET /api/v1/projects/:project_id/meetings' do
    it 'lists the rows newest first, with the allowed fields and the page in meta' do
      older = meeting(title: 'Older', occurred_at: 3.days.ago, duration_minutes: 45)
      newer = meeting(title: 'Newer', occurred_at: 1.day.ago)

      expect(list).to have_http_status(:ok)
      expect(ids).to eq([newer.id, older.id])
      expect(response.parsed_body['meta']).to eq('page' => 1, 'per_page' => 10, 'total' => 2)
      expect(response.parsed_body['data'].first).to eq(
        'id' => newer.id, 'project_id' => project.id, 'title' => 'Newer',
        'occurred_at' => newer.occurred_at.iso8601, 'duration_minutes' => nil,
        'creator' => { 'id' => creator.id, 'name' => 'Clara Creator' }
      )
      expect(response.parsed_body['data'].last['duration_minutes']).to eq(45)
    end

    it 'keeps the order over pages when date and entry time are equal, down to the id' do
      at = 2.days.ago.change(usec: 0)
      made = %w[1 3 2 5 4].map do |digit|
        meeting(id: "00000000-0000-4000-8000-00000000000#{digit}", occurred_at: at, created_at: at)
      end
      # Spelled out, not a loop: Prosopite reads one call site asked three times as an N+1.
      list('?page=1&per_page=2')
      first_page = ids
      list('?page=2&per_page=2')
      second_page = ids
      list('?page=3&per_page=2')

      expect(first_page + second_page + ids).to eq(made.map(&:id).sort.reverse)
    end

    it 'puts a later entry first among meetings of one date, as the web list does' do
      at = 2.days.ago.change(usec: 0)
      first_entered = meeting(id: '00000000-0000-4000-8000-000000000009', occurred_at: at, created_at: at - 1.hour)
      last_entered = meeting(id: '00000000-0000-4000-8000-000000000001', occurred_at: at, created_at: at)

      list
      expect(ids).to eq([last_entered.id, first_entered.id])
    end

    describe 'q' do
      it 'finds title, notes, transcript and summary, and counts only the hits' do
        hits = [meeting(title: 'Budget review'), meeting(notes: 'the budget was cut'),
                meeting(transcript: 'Anna: about the budget'), meeting(generated_summary: 'Budget agreed')]
        meeting(title: 'Something else')

        list('?q=budget')
        expect(ids).to match_array(hits.map(&:id))
        expect(response.parsed_body.dig('meta', 'total')).to eq(4)
      end

      it 'takes a blank q for no search' do
        found = meeting

        list('?q=%20')
        expect(ids).to eq([found.id])
      end

      it 'never finds a meeting of a project the reader cannot read, by its transcript or in the count' do
        elsewhere = new_project
        meeting(in_project: elsewhere, transcript: 'the secret word')
        meeting(transcript: 'the secret word')
        tickets_only = member(meetings: 'no_access', tickets: 'read_only')

        list('?q=secret', user: tickets_only)
        expect(ids).to be_empty
        expect(response.parsed_body.dig('meta', 'total')).to eq(0)
      end

      it 'matches a percent sign as text' do
        meeting(title: 'Plain')

        list('?q=%25')
        expect(ids).to be_empty
      end
    end

    describe 'paging, checked before the project' do
      ['per_page=0', 'per_page=101', 'per_page=-1', 'per_page=abc', 'per_page=1.5', 'page=0', 'page=abc',
       'page=100001', 'page[]=1', 'per_page[]=1'].each do |query|
        it "refuses #{query} with 422, whether the project exists or not" do
          expect(list("?#{query}")).to have_http_status(:unprocessable_content)
          answer = response.body
          expect(response.parsed_body['code']).to eq('invalid_input')

          expect(read("/api/v1/projects/#{SecureRandom.uuid}/meetings?#{query}")).to have_http_status(:unprocessable_content)
          expect(response.body).to eq(answer)
        end
      end

      ['q=a%00b', 'q[]=a'].each do |query|
        it "refuses #{query} with 422" do
          expect(list("?#{query}")).to have_http_status(:unprocessable_content)
          expect(response.parsed_body['code']).to eq('invalid_input')
        end
      end

      it 'takes 100 rows, an empty value as the default, and answers a page beyond the end empty' do
        expect(list('?per_page=100&page=')).to have_http_status(:ok)
        expect(response.parsed_body['meta']).to include('per_page' => 100, 'page' => 1)

        meeting
        expect(list('?page=2')).to have_http_status(:ok)
        expect(ids).to be_empty
        expect(response.parsed_body['meta']).to include('page' => 2, 'total' => 1)
      end
    end

    describe 'the gate' do
      let!(:held) { meeting(transcript: 'the secret word') }

      it 'gives one 404 for a missing, malformed, foreign, unreached and unreadable project' do
        foreign = new_project(create(:organisation))
        unreached = new_project
        grant = quietly { create(:project_permission, user: reader, project: unreached, meetings_access: 'read_only') }
        stranger = member(on: nil)

        answers = [
          read("/api/v1/projects/#{SecureRandom.uuid}/meetings"),
          read('/api/v1/projects/not-a-uuid/meetings'),
          read("/api/v1/projects/#{foreign.id}/meetings"),
          read("/api/v1/projects/#{unreached.id}/meetings",
               pat: token_for(reader, project_scopes: { organisation => [project] })),
          list(user: stranger)
        ].map { |answer| [answer.status, answer.body] }

        expect(grant).to be_persisted
        expect(answers).to all(eq([404, not_found_body]))
      end

      it 'gives the same 404 for a token of a member who left' do
        pat = token_for(reader)
        quietly { Membership.find_by!(user: reader, organisation: organisation).update!(active: false) }

        expect(list(pat: pat)).to have_http_status(:not_found)
        expect(response.body).to eq(not_found_body)
      end

      it 'answers an empty list to a reader of the project without the meetings area' do
        tickets_only = member(meetings: 'no_access', tickets: 'read_only')

        expect(list(user: tickets_only)).to have_http_status(:ok)
        expect(response.parsed_body).to eq('data' => [], 'meta' => { 'page' => 1, 'per_page' => 10, 'total' => 0 })
      end

      it 'lets a read-only token read and a token with the project in reach' do
        expect(list(pat: token_for(reader, read_only: true))).to have_http_status(:ok)
        expect(ids).to eq([held.id])

        list(pat: token_for(reader, project_scopes: { organisation => [project] }))
        expect(ids).to eq([held.id])
      end

      it 'answers 401 without a token' do
        get "/api/v1/projects/#{project.id}/meetings"
        expect(response).to have_http_status(:unauthorized)
      end

      it 'treats an archived project as the web does: closed to a member, open to an account admin' do
        quietly { project.update!(archived_at: Time.current) }

        expect(list).to have_http_status(:not_found)
        expect(response.body).to eq(not_found_body)

        expect(list(user: account_admin)).to have_http_status(:ok)
        expect(ids).to eq([held.id])
      end
    end

    it 'reads no transcript for the rows and asks for creators once' do
      3.times { meeting(transcript: 'long words', creator: member(meetings: 'read_write')) }
      pat = token_for(reader)
      queries = []
      counter = ->(*, payload) { queries << payload[:sql] unless payload[:name] == 'SCHEMA' }

      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { list(pat: pat) }

      expect(ids.size).to eq(3)
      rows = queries.grep(/FROM "meetings"/).grep_v(/COUNT/i)
      expect(rows.size).to eq(1)
      expect(rows.first).not_to match(/transcript|"meetings"\.\*|plain_text_version/)
      expect(queries.grep(/FROM "users" WHERE "users"\."id" IN/).size).to be <= 2
    end

    it 'scales: more rows do not mean more queries' do
      pat = token_for(reader)
      count = lambda do
        queries = 0
        counter = ->(*, payload) { queries += 1 unless payload[:name] == 'SCHEMA' }
        ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { list(pat: pat) }
        queries
      end

      meeting(creator: member(meetings: 'read_write'))
      Prosopite.pause do
        count.call # the first request of a token also stamps its last_used_at
        one_row = count.call
        4.times { meeting(creator: member(meetings: 'read_write')) }

        expect(count.call).to eq(one_row)
      end
    end
  end

  describe 'GET /api/v1/meetings/:id' do
    let(:held) do
      meeting(title: 'Kickoff', occurred_at: 2.days.ago, duration_minutes: 30, generated_summary: '**Head:** done',
              notes: 'Some notes', transcript: 'Anna: hello')
    end

    it 'answers the row, the participants by name, the texts whole, updated_at and the path' do
      quietly do
        create(:meeting_participant, meeting: held, organisation: organisation, display_name: 'Anna Albers',
                                     created_at: 2.minutes.ago)
        create(:meeting_participant, meeting: held, organisation: organisation, display_name: 'Ben Berger',
                                     user: creator, created_at: 1.minute.ago)
      end

      expect(show(held.id)).to have_http_status(:ok)
      expect(response.parsed_body['data']).to eq(
        'id' => held.id, 'project_id' => project.id, 'title' => 'Kickoff',
        'occurred_at' => held.occurred_at.iso8601, 'duration_minutes' => 30,
        'creator' => { 'id' => creator.id, 'name' => 'Clara Creator' },
        'participants' => [{ 'display_name' => 'Anna Albers' }, { 'display_name' => 'Ben Berger' }],
        'generated_summary' => '**Head:** done', 'notes' => 'Some notes', 'transcript' => 'Anna: hello',
        'updated_at' => held.reload.updated_at.iso8601,
        'path' => "/org/#{organisation.id}/projects/#{project.id}/meetings/#{held.id}"
      )
    end

    it 'keeps the internal fields out, by listing what may leave' do
      quietly do
        held.update_columns(create_embeddings: true, embedding_creation_error: 'boom', embeddings_creation_flag: true,
                            summary_creation_error: 'boom', summary_creation_flag: true,
                            suggestions_creation_error: 'boom', suggestions_creation_flag: true,
                            plain_text_version: 'plain')
      end

      show(held.id)
      expect(response.parsed_body['data'].keys).to contain_exactly(
        'id', 'project_id', 'title', 'occurred_at', 'duration_minutes', 'creator', 'participants',
        'generated_summary', 'notes', 'transcript', 'updated_at', 'path'
      )
      expect(response.body).not_to include('boom', 'embedding', '_flag', '_error', 'organisation_id', 'creator_id')
    end

    it 'does not cut a long transcript' do
      long = 'word ' * 150_000

      show(meeting(transcript: long).id)
      expect(response.parsed_body.dig('data', 'transcript')).to eq(long)
    end

    it 'leaves the metadata block off notes and transcript, as the web shows them' do
      block = "---\nid: 1\nparent: 2\n---\n"

      show(meeting(notes: "#{block}Notes", transcript: "#{block}Words").id)
      expect(response.parsed_body['data']).to include('notes' => 'Notes', 'transcript' => 'Words')
    end

    it 'answers null notes and transcript and an empty summary for a meeting without content' do
      show(meeting.id)
      expect(response.parsed_body['data']).to include('notes' => nil, 'transcript' => nil, 'generated_summary' => '')
    end

    it 'reads the participants in one query' do
      quietly do
        3.times { |n| create(:meeting_participant, meeting: held, organisation: organisation, display_name: "P #{n}") }
      end
      queries = []
      counter = ->(*, payload) { queries << payload[:sql] }
      pat = token_for(reader)

      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { show(held.id, pat: pat) }
      expect(queries.grep(/FROM "meeting_participants"/).size).to eq(1)
    end

    describe 'the gate: one 404 in status and body' do
      def expect_not_found(answer)
        expect(answer).to have_http_status(:not_found)
        expect(response.body).to eq(not_found_body)
      end

      it 'for a missing id' do
        expect_not_found(show(SecureRandom.uuid))
      end

      it 'for a malformed id' do
        expect_not_found(show('not-a-uuid'))
        expect_not_found(show('1'))
        expect_not_found(show('a%00b'))
      end

      it 'for a meeting outside the token reach, whatever the owner may read' do
        expect_not_found(show(held.id, pat: token_for(reader, project_scopes: { organisation => [new_project] })))
      end

      it 'for a meeting of another organisation' do
        foreign_org = create(:organisation)
        foreign = meeting(in_project: new_project(foreign_org))

        expect_not_found(show(foreign.id))
      end

      it 'for a reader of the project without the meetings area' do
        expect_not_found(show(held.id, user: member(meetings: 'no_access', tickets: 'read_only')))
      end

      it 'for a member without the project' do
        expect_not_found(show(held.id, user: member(on: nil)))
      end

      it 'for a token of a member who left' do
        pat = token_for(reader)
        quietly { Membership.find_by!(user: reader, organisation: organisation).update!(active: false) }

        expect_not_found(show(held.id, pat: pat))
      end

      it 'for a member of an archived project' do
        quietly { project.update!(archived_at: Time.current) }

        expect_not_found(show(held.id))
      end

      # The scope and show? agree on every grant there is, so no data separates them. Each is
      # held here on its own, or a slip in the other would stand unseen.
      it 'when show? alone refuses: never a 403, which would tell the meeting exists' do
        allow_any_instance_of(MeetingPolicy).to receive(:show?).and_return(false)

        expect_not_found(show(held.id))
      end

      it 'when the policy scope alone refuses' do
        held
        allow_any_instance_of(MeetingPolicy::Scope).to receive(:resolve).and_return(Meeting.none)

        expect_not_found(show(held.id))
      end
    end

    it 'answers 401 without a token' do
      get "/api/v1/meetings/#{held.id}"
      expect(response).to have_http_status(:unauthorized)
    end

    it 'lets a read-only token read, an account admin read an archived project' do
      expect(show(held.id, pat: token_for(reader, read_only: true))).to have_http_status(:ok)

      quietly { project.update!(archived_at: Time.current) }
      expect(show(held.id, user: account_admin)).to have_http_status(:ok)
    end

    it 'follows a meeting that moved: the reach of its project now, not of the old one' do
      target = new_project
      quietly { held.update!(project: target) }

      expect(show(held.id, pat: token_for(reader, project_scopes: { organisation => [project] })))
        .to have_http_status(:not_found)
    end
  end
end
