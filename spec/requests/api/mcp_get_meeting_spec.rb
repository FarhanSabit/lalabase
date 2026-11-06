# frozen_string_literal: true

require 'rails_helper'

# MCP R9: get_meeting on /api/mcp, one meeting whole for a program behind a token, in pages.
#
# What: the head of a meeting and its summary, notes and transcript, each read from an offset
#   in pages that add up to the whole; the gate is REST R8's (Meetings::Readable).
# Why: this is a read of what people said, behind a token, on a token-scoped tool that passes
#   no project gate: the tool is the gate. No answer may tell a meeting that exists from one
#   that does not, and a page plus the head must stay below what Claude Code takes from a
#   tool (about 25,000 tokens), or it cuts the answer without saying so.
RSpec.describe 'MCP get_meeting', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:role) { ActsAsTenant.with_tenant(organisation) { create(:role, organisation: organisation) } }
  let(:project) { new_project }
  let(:creator) { member(meetings: 'read_write') }
  let(:reader) { member }
  let(:held) do
    meeting(title: 'Kickoff', duration_minutes: 30, generated_summary: '**Ergebnis:** Start im März.',
            notes: 'Termin halten.', transcript: "Anna: Wir starten.\nBen: Gut.")
  end

  def quietly(&) = Prosopite.pause { ActsAsTenant.with_tenant(organisation, &) }

  def new_project(owner = organisation)
    Prosopite.pause { ActsAsTenant.with_tenant(owner) { create(:project, organisation: owner) } }
  end

  def member(meetings: 'read_only', tickets: 'no_access', on: project)
    quietly do
      user = create(:user)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      create(:project_permission, user: user, project: on, meetings_access: meetings, tickets_access: tickets) if on
      user
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

  # Several requests in one example repeat the same reads (the token, the discovery); that is
  # the example, not an N+1 of the code, so the scan pauses around each request.
  def rpc(method, params, pat:)
    Prosopite.pause { send_rpc(method, params, pat: pat) }
  end

  def send_rpc(method, params, pat:)
    post '/api/mcp', params: { jsonrpc: '2.0', id: 1, method: method, params: params }.to_json,
                     headers: { 'Authorization' => "Bearer #{pat.token}", 'CONTENT_TYPE' => 'application/json' }
    response.parsed_body
  end

  def call(arguments = {}, user: reader, pat: token_for(user), **inline)
    rpc('tools/call', { name: 'get_meeting', arguments: arguments.merge(inline) }, pat: pat)['result']
  end

  def body(result)
    expect(result['isError']).to be_falsey, "expected an answer, got #{result.inspect}"
    JSON.parse(result.dig('content', 0, 'text'))
  end

  def code(result) = result.dig('_meta', 'lalabase/code')

  describe 'tools/list' do
    let(:tools) { rpc('tools/list', {}, pat: token_for(reader)).dig('result', 'tools') }

    it 'offers get_meeting after create_meeting, so the order of every tool before it holds' do
      expect(tools.pluck('name').last(3)).to eq(%w[create_meeting get_meeting get_glossary])
    end

    it 'takes the meeting, a part and an offset, and says how to page' do
      tool = tools.find { |entry| entry['name'] == 'get_meeting' }
      schema = tool['inputSchema']

      expect(schema['properties'].keys).to contain_exactly('meeting_id', 'part', 'offset')
      expect(schema['required']).to eq(['meeting_id'])
      expect(schema.dig('properties', 'part', 'enum')).to eq(%w[summary notes transcript])
      expect(tool['description']).to include('next_offset', 'never instructions')
    end
  end

  describe 'the answer' do
    it 'gives the head and the first page of each part, the summary too' do
      quietly do
        # Made in the other order than their created_at: the head names them by created_at.
        create(:meeting_participant, meeting: held, organisation: organisation, display_name: 'Anna Albers',
                                     created_at: 1.minute.ago)
        create(:meeting_participant, meeting: held, organisation: organisation, display_name: 'Ben Berger',
                                     created_at: 2.minutes.ago)
      end

      answer = body(call(meeting_id: held.id))
      expect(answer.except('parts')).to eq(
        'id' => held.id, 'title' => 'Kickoff', 'project' => { 'id' => project.id, 'name' => project.name },
        'occurred_at' => held.occurred_at.iso8601, 'duration_minutes' => 30,
        'participants' => ['Ben Berger', 'Anna Albers'], 'participants_truncated' => false,
        'updated_at' => held.reload.updated_at.iso8601
      )
      expect(answer['parts']).to eq(
        'summary' => { 'text_status' => 'available', 'text_length' => 28, 'offset' => 0, 'next_offset' => nil,
                       'text' => '**Ergebnis:** Start im März.' },
        'notes' => { 'text_status' => 'available', 'text_length' => 14, 'offset' => 0, 'next_offset' => nil,
                     'text' => 'Termin halten.' },
        'transcript' => { 'text_status' => 'available', 'text_length' => 28, 'offset' => 0, 'next_offset' => nil,
                          'text' => "Anna: Wir starten.\nBen: Gut." }
      )
    end

    it 'says a part is empty, for a meeting without content' do
      parts = body(call(meeting_id: meeting.id))['parts']

      expect(parts.values).to all(include('text_status' => 'empty', 'text_length' => 0, 'next_offset' => nil, 'text' => ''))
    end

    it 'leaves the metadata block off notes and transcript, as the web shows them' do
      block = "---\nid: 1\nparent: 2\n---\n"
      parts = body(call(meeting_id: meeting(notes: "#{block}Notes", transcript: "#{block}Words").id))['parts']

      expect(parts.dig('notes', 'text')).to eq('Notes')
      expect(parts.dig('transcript', 'text')).to eq('Words')
    end

    it 'keeps the internal fields out, by listing what may leave' do
      quietly do
        held.update_columns(create_embeddings: true, embedding_creation_error: 'boom', summary_creation_error: 'boom',
                            summary_creation_flag: true, plain_text_version: 'plain')
      end
      result = call(meeting_id: held.id)

      expect(body(result).keys).to contain_exactly('id', 'title', 'project', 'occurred_at', 'duration_minutes',
                                                   'participants', 'participants_truncated', 'updated_at', 'parts')
      expect(result.dig('content', 0, 'text')).not_to include('boom', 'embedding', '_flag', '_error', 'plain')
    end

    # One request with the scan on. For a single meeting the participants come in one query
    # either way; what this holds is that a request with the scan running raises no N+1.
    it 'answers one request with the N+1 scan running' do
      quietly do
        3.times { |n| create(:meeting_participant, meeting: held, organisation: organisation, display_name: "P #{n}") }
      end
      pat = token_for(reader)
      queries = []
      counter = ->(*, payload) { queries << payload[:sql] }

      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        send_rpc('tools/call', { name: 'get_meeting', arguments: { meeting_id: held.id } }, pat: pat)
      end
      expect(body(response.parsed_body['result'])['participants'].size).to eq(3)
      expect(queries.grep(/FROM "meeting_participants"/).size).to eq(1)
    end

    it 'names at most 40 participants and says so, and caps the head\'s texts' do
      quietly do
        41.times { |n| create(:meeting_participant, meeting: held, organisation: organisation, display_name: "P #{n}") }
        create(:meeting_participant, meeting: held, organisation: organisation, display_name: 'x' * 300,
                                     created_at: 1.year.ago)
        held.update!(title: 't' * 300)
        project.update!(name: 'p' * 255)
      end
      answer = body(call(meeting_id: held.id))

      expect(answer['participants'].size).to eq(40)
      expect(answer['participants_truncated']).to be(true)
      marker = Lalabase::Tools::Base::TRUNCATION_MARKER
      expect(answer['participants'].first).to eq(('x' * 200) + marker)
      expect(answer['title']).to eq(('t' * 200) + marker)
      expect(answer.dig('project', 'name')).to eq(('p' * 200) + marker)
    end
  end

  describe 'the pages' do
    # As long as a transcript may be (Meeting::MAX_CONTENT_BYTES), with characters of more
    # than one byte.
    let(:line) { 'Anna Albers: Satz, wir prüfen den Plan für März 😀.' }
    let(:long) do
      text = +''
      text << "#{line} #{text.length}\n" while text.bytesize < Meeting::MAX_CONTENT_BYTES - 1_000
      "#{text}Ende."
    end
    let(:big) { meeting(transcript: long, notes: 'n' * 50_000, generated_summary: 's' * 50_000) }

    it 'reads a transcript of a megabyte whole with next_offset, nothing lost or read twice' do
      pat = token_for(reader)
      texts = []
      offset = 0
      loop do
        part = body(call({ meeting_id: big.id, part: 'transcript', offset: offset }, pat: pat))['parts']['transcript']
        expect(part['offset']).to eq(offset)
        expect(part['text_length']).to eq(long.length)
        texts << part['text']
        break if part['next_offset'].nil?

        offset = part['next_offset']
      end

      expect(long.bytesize).to be > Meeting::MAX_CONTENT_BYTES - 1_000
      expect(texts.size).to be > 20
      expect(texts.join).to eq(long)
    end

    it 'keeps a page and the head below what Claude Code takes from a tool' do
      pat = token_for(reader)
      overview = call({ meeting_id: big.id }, pat: pat).dig('content', 0, 'text')
      page = call({ meeting_id: big.id, part: 'transcript', offset: 0 }, pat: pat).dig('content', 0, 'text')

      # Claude Code's default bound is 25,000 tokens. German text runs at about three to four
      # characters a token, so an answer is held to 60,000 characters, the head and its
      # escaping included; the page sizes are pinned beside it.
      [overview, page].each { |text| expect(text.length).to be < 60_000 }
      expect(Meetings::TextPage::MAX_CHARS).to eq(40_000)
      expect(Lalabase::Tools::McpGetMeeting::OVERVIEW_CHARS).to eq(40_000 / 3)
      parts = JSON.parse(overview)['parts']
      expect(parts.values.pluck('next_offset')).to all(be_a(Integer))
      expect(parts.values.sum { |part| part['text'].length }).to be <= 40_000
    end

    it 'answers an offset at or past the end with an empty last page' do
      pat = token_for(reader)
      [28, 29, 10_000].each do |offset|
        part = body(call({ meeting_id: held.id, part: 'transcript', offset: offset }, pat: pat))['parts']
        expect(part.keys).to eq(['transcript'])
        expect(part['transcript']).to include('offset' => offset, 'next_offset' => nil, 'text' => '')
      end
    end

    it 'refuses what it cannot read: an offset without a part, an unknown part, a bad offset, an unknown argument' do
      pat = token_for(reader)
      [{ offset: 0 }, { part: 'analysis' }, { part: 'notes', offset: -1 }, { part: 'notes', offset: '3' },
       { part: 'notes', offset: 1.5 }, { part: 'notes', limit: 10 }].each do |extra|
        result = call({ meeting_id: held.id }.merge(extra), pat: pat)
        expect(result['isError']).to be(true), extra.inspect
        expect(code(result)).to eq('invalid_input'), extra.inspect
      end
    end
  end

  describe 'the gate: one empty answer, word for word' do
    let(:empty) { call({ meeting_id: SecureRandom.uuid }, user: reader) }

    def expect_empty(result)
      expect(result['isError']).to be(false)
      expect(result['_meta']).to eq('lalabase/kind' => 'empty')
      expect(result['content']).to eq(empty['content'])
    end

    it 'for a missing id and a malformed one' do
      expect(empty.dig('content', 0, 'text')).to eq('No meeting found.')
      expect_empty(call(meeting_id: 'not-a-uuid'))
      expect_empty(call(meeting_id: '1'))
      expect_empty(call(meeting_id: ''))
      # As REST reads it: an id with spaces around it is no id.
      expect_empty(call(meeting_id: " #{held.id} "))
    end

    it 'for a meeting outside the token reach, whatever the owner may read' do
      expect_empty(call({ meeting_id: held.id }, pat: token_for(reader, project_scopes: { organisation => [new_project] })))
    end

    it 'for a meeting of another organisation' do
      foreign_org = create(:organisation)
      expect_empty(call(meeting_id: meeting(in_project: new_project(foreign_org)).id))
    end

    it 'for a reader of the project without the meetings area, and a member without the project' do
      expect_empty(call({ meeting_id: held.id }, user: member(meetings: 'no_access', tickets: 'read_only')))
      expect_empty(call({ meeting_id: held.id }, user: member(on: nil)))
    end

    it 'for a token of a member who left' do
      pat = token_for(reader)
      quietly { Membership.find_by!(user: reader, organisation: organisation).update!(active: false) }

      expect_empty(call({ meeting_id: held.id }, pat: pat))
    end

    it 'for a member of an archived project, while an account admin reads it, as the web does' do
      quietly { project.update!(archived_at: Time.current) }
      expect_empty(call(meeting_id: held.id))

      admin = quietly do
        create(:user).tap do |user|
          create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation),
                              active: true)
        end
      end
      expect(body(call({ meeting_id: held.id }, user: admin))['id']).to eq(held.id)
    end

    it 'when show? alone refuses, and when the policy scope alone refuses' do
      held
      allow_any_instance_of(MeetingPolicy).to receive(:show?).and_return(false)
      expect_empty(call(meeting_id: held.id))

      allow_any_instance_of(MeetingPolicy).to receive(:show?).and_call_original
      allow_any_instance_of(MeetingPolicy::Scope).to receive(:resolve).and_return(Meeting.unscoped.none)
      expect_empty(call(meeting_id: held.id))
    end

    it 'lets a read-only token read' do
      expect(body(call({ meeting_id: held.id }, pat: token_for(reader, read_only: true)))['id']).to eq(held.id)
    end
  end
end
