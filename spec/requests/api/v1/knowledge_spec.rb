# frozen_string_literal: true

require 'rails_helper'

# REST R2: GET /api/v1/projects/:project_id/knowledge, the knowledge of a project (notes and
# documents) by title, through Knowledge::Lookup, the read the MCP tool search_knowledge uses.
# With `q` REST answers what MCP answers; without it REST lists every readable row, newest first
# (MCP keeps `q` required).
#
# Rights: rows only through the per-type policy scope, so a reader who may read notes only never
# sees a document title, not even in `total`; a reader with access to the project but no
# knowledge right gets an empty list. A missing project, a malformed id, a project beyond the
# token's reach, one the reader cannot open and one of another organisation answer the same 404.
RSpec.describe 'REST knowledge', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:role) { create(:role, organisation: organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:not_found_body) { { error: 'not_found', code: 'not_found' }.to_json }

  def member(notes: 'read_only', documents: 'read_only', tickets: 'no_access', on: project)
    Prosopite.pause do
      ActsAsTenant.with_tenant(organisation) do
        user = create(:user)
        create(:membership, user: user, organisation: organisation, role: role, active: true)
        if on
          create(:project_permission, user: user, project: on, notes_access: notes, documents_access: documents,
                                      tickets_access: tickets)
        end
        user
      end
    end
  end

  let(:reader) { member }

  def note(title, at:, id: nil)
    Prosopite.pause do
      ActsAsTenant.with_tenant(organisation) do
        record = create(:note, { project: project, organisation: organisation, title: title, id: id }.compact)
        record.update_columns(updated_at: at)
        record
      end
    end
  end

  def document(title, at:, id: nil)
    Prosopite.pause do
      ActsAsTenant.with_tenant(organisation) do
        doc = create(:document, { project: project, organisation: organisation, id: id }.compact)
        version = create(:document_version, document: doc, organisation: organisation, title: title)
        doc.update!(current_version: version)
        doc.update_columns(updated_at: at)
        doc
      end
    end
  end

  let!(:runbook) { note('Deploy runbook', at: 3.days.ago) }
  let!(:checklist) { document('Deploy checklist', at: 2.days.ago) }
  let!(:minutes) { note('Board minutes', at: 1.day.ago) }

  after { ActsAsTenant.current_tenant = nil }

  def token_for(user, **options)
    Prosopite.pause do
      create(:personal_access_token, user: user, organisations: [organisation], **options).token
    end
  end

  def get_json(user, params = {}, token: nil, project_id: project.id, **query)
    params = params.merge(query)
    headers = { 'Authorization' => "Bearer #{token || token_for(user)}" }
    get "/api/v1/projects/#{project_id}/knowledge", params: params, headers: headers
    response.parsed_body
  end

  def mcp_answer(user, **args)
    ActsAsTenant.with_tenant(organisation) do
      context = Lalabase::Tools::Context.new(actor: user, organisation: organisation, project: project)
      JSON.parse(Lalabase::Tools::SearchKnowledge.execute(args: args, context: context).content)
    end
  end

  def expect_not_found
    expect(response).to have_http_status(:not_found)
    expect(response.body).to eq(not_found_body)
  end

  def expect_invalid_input(message)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include('error' => 'invalid_input', 'code' => 'invalid_input')
    expect(response.parsed_body['message']).to match(message)
  end

  describe 'with q' do
    it 'answers what MCP search_knowledge answers for the same reader and search' do
      body = get_json(reader, q: 'deploy')

      expect(response).to have_http_status(:ok)
      expect(body).to eq(mcp_answer(reader, q: 'deploy'))
      expect(body['data'].pluck('id')).to eq([checklist.id, runbook.id])
      expect(body['data'].first).to eq(
        'type' => 'document', 'id' => checklist.id, 'title' => 'Deploy checklist',
        'updated_at' => checklist.reload.updated_at.iso8601, 'link' => "lalabase://document/#{checklist.id}"
      )
      expect(body['meta']).to eq('page' => 1, 'per_page' => 10, 'total' => 2)
    end

    it 'answers what MCP answers with a type, a page and a page size' do
      body = get_json(reader, q: 'e', type: 'note', page: '2', per_page: '1')

      expect(body).to eq(mcp_answer(reader, q: 'e', type: 'note', page: 2, per_page: 1))
      expect(body['data'].pluck('id')).to eq([runbook.id])
      expect(body['meta']).to eq('page' => 2, 'per_page' => 1, 'total' => 2)
    end

    it 'takes %, _ and \\ literally, as MCP does' do
      note('50% done', at: 4.days.ago)

      body = get_json(reader, q: '%')
      expect(body['data'].pluck('title')).to eq(['50% done'])
      expect(get_json(reader, q: '_')['data']).to eq([])
      expect(get_json(reader, q: '\\')['data']).to eq([])
    end
  end

  describe 'without q' do
    it 'lists every readable note and document, newest first' do
      body = get_json(reader)

      expect(response).to have_http_status(:ok)
      expect(body['data'].pluck('id')).to eq([minutes.id, checklist.id, runbook.id])
      expect(body['meta']).to eq('page' => 1, 'per_page' => 10, 'total' => 3)
    end

    it 'takes a blank q as no q' do
      expect(get_json(reader, q: '  ')['meta']['total']).to eq(3)
    end

    # The tied rows are the newest, so they fill the first pages. Fixed ids interleave the types
    # (d1 n2 d3 n4 n5) and the notes are inserted against that order: without the id tiebreak
    # in SQL or in the merge, page 1 is no longer d1, n2.
    it 'pages across both types without repeating or losing a row of equal updated_at' do
      at = 1.hour.ago.change(usec: 0)
      ids = (1..5).index_with { |n| format('00000000-0000-4000-8000-%012d', n) }
      note('n5', at: at, id: ids[5])
      note('n4', at: at, id: ids[4])
      note('n2', at: at, id: ids[2])
      document('d3', at: at, id: ids[3])
      document('d1', at: at, id: ids[1])
      token = token_for(reader)

      first = get_json(reader, { page: 1, per_page: 2 }, token: token)['data'].pluck('title')
      second = get_json(reader, { page: 2, per_page: 2 }, token: token)['data'].pluck('title')
      third = get_json(reader, { page: 3, per_page: 2 }, token: token)['data'].pluck('title')

      expect([first, second, third]).to eq([%w[d1 n2], %w[d3 n4], ['n5', minutes.title]])
    end
  end

  describe 'rights' do
    it 'never shows a document title to a reader of notes only, not even in total' do
      notes_only = member(documents: 'no_access')
      token = token_for(notes_only)

      listed = get_json(notes_only, {}, token: token)
      searched = get_json(notes_only, { q: 'checklist' }, token: token)
      documents = get_json(notes_only, { type: 'document' }, token: token)

      expect(listed['data'].pluck('id')).to eq([minutes.id, runbook.id])
      expect(listed['meta']['total']).to eq(2)
      expect(searched).to eq('data' => [], 'meta' => { 'page' => 1, 'per_page' => 10, 'total' => 0 })
      expect(documents['data']).to eq([])
      expect(response.body).not_to include('Deploy checklist')
    end

    it 'never shows a note title to a reader of documents only' do
      documents_only = member(notes: 'no_access')

      body = get_json(documents_only)
      expect(body['data'].pluck('id')).to eq([checklist.id])
      expect(body['meta']['total']).to eq(1)
    end

    it 'answers an empty list to a reader with project access but no knowledge right' do
      tickets_only = member(notes: 'no_access', documents: 'no_access', tickets: 'read_only')

      body = get_json(tickets_only)
      expect(response).to have_http_status(:ok)
      expect(body).to eq('data' => [], 'meta' => { 'page' => 1, 'per_page' => 10, 'total' => 0 })
    end

    it 'answers to a read-only token' do
      body = get_json(reader, {}, token: token_for(reader, read_only: true))
      expect(response).to have_http_status(:ok)
      expect(body['meta']['total']).to eq(3)
    end
  end

  describe 'a project the reader may not read answers like a missing one' do
    let(:admin) do
      Prosopite.pause do
        ActsAsTenant.with_tenant(organisation) do
          user = create(:user)
          create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation),
                              active: true)
          user
        end
      end
    end

    it 'for a missing project' do
      get_json(reader, project_id: SecureRandom.uuid)
      expect_not_found
    end

    it 'for a malformed project id' do
      get_json(reader, project_id: 'not-a-uuid')
      expect_not_found
    end

    it 'for a project beyond the token reach, even for an account admin' do
      elsewhere = Prosopite.pause { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
      get_json(admin, {}, token: token_for(admin, project_scopes: { organisation => [elsewhere] }))
      expect_not_found
    end

    it 'for a member without access to the project' do
      outsider = member(on: nil)
      get_json(outsider)
      expect_not_found
    end

    it 'for an archived project the member cannot open any more' do
      Prosopite.pause { ActsAsTenant.with_tenant(organisation) { project.update!(archived_at: Time.current) } }
      get_json(reader)
      expect_not_found
    end

    it 'for a member whose membership was deactivated' do
      token = token_for(reader)
      Prosopite.pause { Membership.unscoped.find_by!(user: reader, organisation: organisation).update!(active: false) }
      get_json(reader, {}, token: token)
      expect_not_found
    end

    it 'for a project of another organisation' do
      foreign = Prosopite.pause do
        org = create(:organisation)
        ActsAsTenant.with_tenant(org) { create(:project, organisation: org) }
      end
      get_json(admin, project_id: foreign.id)
      expect_not_found
    end
  end

  describe 'invalid input' do
    it 'refuses an unknown type' do
      get_json(reader, type: 'ticket')
      expect_invalid_input(/invalid type/)
    end

    it 'refuses a per_page above the maximum instead of clamping it' do
      get_json(reader, per_page: (Knowledge::Lookup::MAX_PER_PAGE + 1).to_s)
      expect_invalid_input(/per_page/)
    end

    it 'refuses a page or per_page that is no positive whole number' do
      token = token_for(reader)
      get_json(reader, { page: '0' }, token: token)
      expect_invalid_input(/page/)
      get_json(reader, { per_page: 'abc' }, token: token)
      expect_invalid_input(/per_page/)
    end

    # One wording for every list that refuses a page value (ListPaging.strict_number), the
    # glossary's, in the token owner's language.
    it 'names the refused value in the language of the token owner' do
      token = token_for(reader)
      get_json(reader, { per_page: '101' }, token: token)
      expect_invalid_input(/per_page/)
      expect(response.parsed_body['message'])
        .to eq('ungültiger Wert für per_page "101" (erwartet ist eine ganze Zahl von 1 bis 100)')

      reader.update!(language_preference: 'en')
      get_json(reader, { page: '0' }, token: token)
      expect(response.parsed_body['message']).to eq('invalid page "0" (expected a whole number from 1 to 100000)')
    end

    it 'refuses a NUL in q, which would otherwise reach the database' do
      get "/api/v1/projects/#{project.id}/knowledge?q=a%00b", headers: { 'Authorization' => "Bearer #{token_for(reader)}" }
      expect_invalid_input(/q/)
    end

    it 'refuses a q given as a list' do
      get "/api/v1/projects/#{project.id}/knowledge?q[]=a", headers: { 'Authorization' => "Bearer #{token_for(reader)}" }
      expect_invalid_input(/q/)
    end

    it 'checks the input before the project, so a missing project with bad input is still a 422' do
      get_json(reader, { type: 'ticket' }, project_id: SecureRandom.uuid)
      expect_invalid_input(/invalid type/)
    end
  end
end
