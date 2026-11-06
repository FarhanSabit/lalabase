# frozen_string_literal: true

require 'rails_helper'

# What: GET /api/v1/organisations/:organisation_id/terms (K4c), the glossary of an organisation
#   for a program that hands the terms to speech recognition and replaces learnt wrong forms,
#   read through Glossary::Lookup like the MCP tool get_glossary.
# Why: a token reads only what works (confirmed terms, confirmed heard forms), only with the
#   glossary right of its owner (403 glossary_forbidden), never an organisation beyond its reach
#   (one 404 for outside, foreign, missing and malformed), the heard forms only of its projects
#   (E4), speakers only with the people right (E6), and never a meeting, a place in a transcript
#   or who corrected. Invented words and names only.
RSpec.describe 'API V1 glossary terms', :ci_guard, type: :request do
  let(:organisation) { create(:organisation, name: 'Nordlicht GmbH') }
  let(:other_organisation) { create(:organisation, name: 'Zweitfirma AG') }
  let(:foreign_organisation) { create(:organisation, name: 'Fremdfirma AG') }

  def role_in(org, *rights, title: nil)
    ActsAsTenant.with_tenant(org) do
      role = create(:role, organisation: org, **{ title: title }.compact)
      rights.each do |right|
        category, action = right.split(':')
        create(:permission, role: role, category: category, action: action, allowed: true)
      end
      role
    end
  end

  def member_of(org, user, role:, active: true)
    ActsAsTenant.with_tenant(org) { create(:membership, user: user, organisation: org, role: role, active: active) }
  end

  let(:anna) { create(:user, first_name: 'Anna', last_name: 'Albers', email: 'anna@example.com', language_preference: 'en') }
  let(:gustav) { create(:user, first_name: 'Gustav', last_name: 'Glossar', email: 'gustav@example.com') }
  let(:nobody) { create(:user, first_name: 'Nora', last_name: 'Ohnerecht', email: 'nora@example.com', language_preference: 'en') }
  let(:admin) { create(:user, first_name: 'Ada', last_name: 'Admin', email: 'ada@example.com') }
  let(:ben) { create(:user, first_name: 'Ben', last_name: 'Berger', email: 'ben@example.com') }

  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Ahorn') } }
  let(:other_project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Birke') } }
  let(:doris) { ActsAsTenant.with_tenant(organisation) { create(:person, organisation: organisation, name: 'Doris Dienstleister') } }
  let(:erika) { ActsAsTenant.with_tenant(organisation) { create(:person, organisation: organisation, name: 'Erika Muster') } }
  let(:meeting) do
    ActsAsTenant.with_tenant(organisation) do
      create(:meeting, organisation: organisation, project: project, title: 'Geheimrunde Ahorn', creator: anna)
    end
  end

  let(:lalabase) { ActsAsTenant.with_tenant(organisation) { create(:glossary_term, organisation: organisation, term: 'Lalabase', category: 'product') } }
  let(:nordlicht) { ActsAsTenant.with_tenant(organisation) { create(:glossary_term, organisation: organisation, term: 'Nordlicht', category: 'company') } }

  def heard(term, form, replaced: 1, at: 1.day.ago, **attributes)
    ActsAsTenant.with_tenant(term.organisation) do
      create(:term_correction, organisation: term.organisation, glossary_term: term, heard: form, replaced_count: replaced,
                               created_at: at, **attributes)
    end
  end

  before do
    Prosopite.pause do
      member_of(organisation, anna, role: role_in(organisation, 'glossary:view_glossary', 'people:view_people'))
      member_of(organisation, gustav, role: role_in(organisation, 'glossary:view_glossary'))
      member_of(organisation, nobody, role: role_in(organisation))
      member_of(organisation, admin, role: role_in(organisation, title: Role::ACCOUNT_ADMIN_TITLE))
      member_of(organisation, ben, role: role_in(organisation))
      member_of(other_organisation, anna, role: role_in(other_organisation, 'glossary:view_glossary', 'people:view_people'))
      ActsAsTenant.with_tenant(organisation) do
        [anna, gustav, ben].each { |user| create(:project_permission, user: user, project: project, tickets_access: :read_only) }
      end

      heard(lalabase, 'lala bass', replaced: 3, at: 2.days.ago, project: project, user: ben, meeting: meeting,
                                   line_index: 4, char_offset: 7, transcript_digest: 'b' * 64, corrected_by: anna)
      heard(lalabase, 'Lala Bass', replaced: 1, at: 1.day.ago, project: project, person: doris)
      heard(lalabase, 'lala bass', replaced: 2, at: 3.days.ago, project: project)
      heard(lalabase, 'la la base', replaced: 2, project: other_project, person: erika)
      heard(lalabase, 'lala basis', replaced: 1, user: ben)
      heard(lalabase, 'lalabeis', replaced: 9, project: project, user: ben, status: 'proposed')
      nordlicht
      ActsAsTenant.with_tenant(organisation) do
        heard(create(:glossary_term, :proposed, organisation: organisation, term: 'Zirbelholz'), 'zirbel holz', project: project)
        heard(create(:glossary_term, :rejected, organisation: organisation, term: 'Ahornweg'), 'ahorn weg', project: project)
      end
      ActsAsTenant.with_tenant(other_organisation) do
        heard(create(:glossary_term, organisation: other_organisation, term: 'Zweitwort'), 'zweit wort')
      end
    end
  end

  def token(owner: anna, organisations: [organisation], project_scopes: {}, read_only: true)
    build(:personal_access_token, user: owner, organisations: organisations, project_scopes: project_scopes,
                                  read_only: read_only).tap do |pat|
      pat.token_hash = nil
      pat.token_prefix = nil
      pat.generate_token!
    end
  end

  let(:pat) { token }

  def terms(with: pat, organisation_id: organisation.id, **query)
    get "/api/v1/organisations/#{organisation_id}/terms", params: query,
                                                          headers: { 'Authorization' => "Bearer #{with.token}" }
    response
  end

  def body = response.parsed_body

  def forms = body['data'].find { |row| row['id'] == lalabase.id }['heard']

  def not_found_body = { 'error' => 'not_found', 'code' => 'not_found' }

  def forbidden_body(message)
    { 'error' => 'forbidden', 'code' => 'forbidden', 'reason' => 'glossary_forbidden', 'message' => message }
  end

  describe 'the list' do
    it 'answers a read-only token with the confirmed terms in the contract form' do
      expect(pat.read_only?).to be true

      expect(terms).to have_http_status(:ok)
      expect(body).to eq(
        'data' => [
          { 'id' => lalabase.id, 'term' => 'Lalabase', 'category' => 'product', 'heard' => [
            { 'form' => 'Lala Bass', 'count' => 6,
              'speakers' => [{ 'ref' => "member:#{ben.id}", 'count' => 3 }, { 'ref' => "person:#{doris.id}", 'count' => 1 }] },
            { 'form' => 'la la base', 'count' => 2, 'speakers' => [{ 'ref' => "person:#{erika.id}", 'count' => 2 }] },
            { 'form' => 'lala basis', 'count' => 1, 'speakers' => [{ 'ref' => "member:#{ben.id}", 'count' => 1 }] }
          ] },
          { 'id' => nordlicht.id, 'term' => 'Nordlicht', 'category' => 'company', 'heard' => [] }
        ],
        'people' => [
          { 'ref' => "member:#{ben.id}", 'name' => 'Ben Berger' },
          { 'ref' => "person:#{doris.id}", 'name' => 'Doris Dienstleister' },
          { 'ref' => "person:#{erika.id}", 'name' => 'Erika Muster' }
        ],
        'meta' => { 'page' => 1, 'per_page' => 50, 'total' => 2 }
      )
    end

    it 'carries no meeting, no place in the transcript and nobody who corrected' do
      terms

      expect(response.body).not_to include(meeting.id, 'Geheimrunde', 'b' * 64, anna.id, '"line_index"', '"char_offset"')
    end

    it 'leaves out proposed and rejected terms and every proposed heard form (E3)' do
      terms

      expect(response.body).not_to include('Zirbelholz', 'Ahornweg', 'zirbel holz', 'ahorn weg', 'lalabeis', 'Zweitwort')
    end

    it 'answers an account admin without a glossary row' do
      expect(terms(with: token(owner: admin))).to have_http_status(:ok)
      expect(body['data'].pluck('term')).to eq(%w[Lalabase Nordlicht])
    end

    it 'answers a token that may write as well: reading is no write' do
      expect(terms(with: token(read_only: false))).to have_http_status(:ok)
    end
  end

  describe 'the glossary right (E2)' do
    it 'refuses a member without it with 403 and the reason glossary_forbidden' do
      expect(terms(with: token(owner: nobody))).to have_http_status(:forbidden)
      expect(body).to eq(forbidden_body('You may not read the glossary of this organisation.'))
    end

    it 'words the refusal in the token owner\'s language' do
      nobody.update!(language_preference: 'de')

      terms(with: token(owner: nobody))
      expect(body['message']).to eq('Sie dürfen das Glossar dieser Organisation nicht lesen.')
    end

    it 'refuses before it reads a page value' do
      expect(terms(with: token(owner: nobody), per_page: 101)).to have_http_status(:forbidden)
    end

    it 'answers a deactivated member like an organisation outside the token: the token reaches active memberships only' do
      deactivated = token
      ActsAsTenant.with_tenant(organisation) { Membership.find_by!(user: anna, organisation: organisation).update!(active: false) }

      expect(terms(with: deactivated)).to have_http_status(:not_found)
      expect(body).to eq(not_found_body)
    end

    # The right asks for an active membership itself (GlossaryPolicy), not only the reach: a
    # reach that still names the organisation, as one read before a deactivation would.
    it 'refuses a deactivated member whom the token still reaches with 403' do
      deactivated = token
      reach = PersonalAccessToken::Reach.new(project_ids_by_organisation: { organisation.id => nil })
      allow_any_instance_of(PersonalAccessToken).to receive(:reach).and_return(reach)
      ActsAsTenant.with_tenant(organisation) { Membership.find_by!(user: anna, organisation: organisation).update!(active: false) }

      expect(terms(with: deactivated)).to have_http_status(:forbidden)
      expect(body).to eq(forbidden_body('You may not read the glossary of this organisation.'))
    end
  end

  describe 'the reach of the token (E4)' do
    it 'answers an organisation outside the token, a foreign, a missing and a malformed one with the same 404' do
      outside = terms(organisation_id: other_organisation.id).then { |answer| [answer.status, answer.parsed_body] }
      foreign = terms(organisation_id: foreign_organisation.id).then { |answer| [answer.status, answer.parsed_body] }
      missing = terms(organisation_id: SecureRandom.uuid).then { |answer| [answer.status, answer.parsed_body] }
      malformed = terms(organisation_id: 'oops').then { |answer| [answer.status, answer.parsed_body] }

      expect([outside, foreign, missing, malformed]).to all(eq([404, not_found_body]))
    end

    it 'reads the organisation of the token and no other one' do
      both = token(organisations: [organisation, other_organisation])

      terms(with: both, organisation_id: other_organisation.id)
      expect(body['data'].pluck('term')).to eq(%w[Zweitwort])
      terms(with: both)
      expect(body['data'].pluck('term')).to eq(%w[Lalabase Nordlicht])
    end

    it 'gives a token limited to some projects every term, but only the heard forms of its projects' do
      terms(with: token(project_scopes: { organisation => [project] }))

      expect(body['data'].pluck('term')).to eq(%w[Lalabase Nordlicht])
      expect(forms.pluck('form')).to eq(['Lala Bass'])
      expect(body['people'].pluck('ref')).to eq(["member:#{ben.id}", "person:#{doris.id}"])
      expect(body['meta']['total']).to eq(2)
    end

    it 'gives a heard form without a project only to a token that reaches every project' do
      terms(with: token(project_scopes: { organisation => [project, other_project] }))
      expect(forms.pluck('form')).to eq(['Lala Bass', 'la la base'])
      terms
      expect(forms.pluck('form')).to include('lala basis')
    end
  end

  describe 'project_id (E5)' do
    it 'puts the heard forms of that project first and still answers every term' do
      terms(project_id: other_project.id)

      expect(forms.pluck('form')).to eq(['la la base', 'Lala Bass', 'lala basis'])
      expect(body['data'].pluck('term')).to eq(%w[Lalabase Nordlicht])
    end

    it 'answers a project of another organisation, outside the token, missing or malformed with the same 404' do
      foreign = ActsAsTenant.with_tenant(foreign_organisation) { create(:project, organisation: foreign_organisation) }
      limited = token(project_scopes: { organisation => [project] })

      answers = [
        terms(project_id: foreign.id).then { |answer| [answer.status, answer.parsed_body] },
        terms(with: limited, project_id: other_project.id).then { |answer| [answer.status, answer.parsed_body] },
        terms(project_id: SecureRandom.uuid).then { |answer| [answer.status, answer.parsed_body] },
        terms(project_id: 'oops').then { |answer| [answer.status, answer.parsed_body] }
      ]
      expect(answers).to all(eq([404, not_found_body]))
    end
  end

  describe 'speakers (E6)' do
    it 'names nobody without the people right: people and every speakers list are empty' do
      terms(with: token(owner: gustav))

      expect(forms.pluck('form', 'count')).to eq([['Lala Bass', 6], ['la la base', 2], ['lala basis', 1]])
      expect(forms.pluck('speakers')).to all(eq([]))
      expect(body['people']).to eq([])
      expect(response.body).not_to include(ben.id, doris.id, 'Doris')
    end
  end

  describe 'pages' do
    it 'pages the terms in a stable order, with the total of all of them' do
      terms(per_page: 1, page: 2)

      expect(body['data'].pluck('term')).to eq(%w[Nordlicht])
      expect(body['people']).to eq([])
      expect(body['meta']).to eq('page' => 2, 'per_page' => 1, 'total' => 2)
    end

    it 'takes 100 per page at most and refuses a value outside with 400, never cuts it' do
      expect(terms(per_page: 100)).to have_http_status(:ok)
      expect(terms(per_page: 101)).to have_http_status(:bad_request)
      expect(body).to eq('error' => 'bad_request', 'code' => 'invalid_input',
                         'message' => 'invalid per_page "101" (expected a whole number from 1 to 100)')
    end

    it 'refuses a page that is no whole number from 1, a list included' do
      zero = terms(page: '0').status
      text = terms(page: 'abc').status
      get "/api/v1/organisations/#{organisation.id}/terms?page[]=1", headers: { 'Authorization' => "Bearer #{pat.token}" }

      expect([zero, text, response.status]).to all(eq(400))
      expect(body['code']).to eq('invalid_input')
    end
  end
end
