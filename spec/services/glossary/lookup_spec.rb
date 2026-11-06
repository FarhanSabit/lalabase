# frozen_string_literal: true

require 'rails_helper'

# What: Glossary::Lookup, the one read of an organisation's glossary behind
#   GET /api/v1/organisations/:organisation_id/terms and the MCP tool get_glossary (K4c).
# Type: Service spec against real rows.
# Why:  Both doors read through this object, so its rules are theirs: the glossary right first
#   (E2), only what works (E3: confirmed terms, confirmed heard forms), the token's projects for
#   the heard forms but every term (E4), project_id only reorders (E5), speakers only with the
#   people right and as the people directory names them (E6), pages, and no meeting data, place
#   or corrector in the answer. Invented words and names only.
RSpec.describe Glossary::Lookup, :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # Rights as "category:action".
  def role_with(*rights, title: nil)
    role = create(:role, organisation: organisation, **{ title: title }.compact)
    rights.each do |right|
      category, action = right.split(':')
      create(:permission, role: role, category: category, action: action, allowed: true)
    end
    role
  end

  def member(first, role: role_with, active: true)
    user = create(:user, first_name: first, last_name: 'Beispiel', email: "#{first.downcase}@example.com")
    create(:membership, user: user, organisation: organisation, role: role, active: active)
    User.find(user.id)
  end

  let(:project) { create(:project, organisation: organisation, name: 'Projekt Ahorn') }
  let(:other_project) { create(:project, organisation: organisation, name: 'Projekt Birke') }
  let(:hidden_project) { create(:project, organisation: organisation, name: 'Projekt Eibe') }

  # Reads the glossary and the people directory; shares the first project with Ben.
  let(:reader) { member('Vera', role: role_with('glossary:view_glossary', 'people:view_people')) }
  # Reads the glossary, not the people directory.
  let(:glossary_only) { member('Gustav', role: role_with('glossary:view_glossary')) }
  let(:ben) { member('Ben') }
  # A member of a project the reader cannot see: not in the reader's directory.
  let(:sven) { member('Sven') }
  let(:doris) { create(:person, organisation: organisation, name: 'Doris Dienstleister') }
  let(:erika) { create(:person, organisation: organisation, name: 'Erika Muster') }
  let(:ben_row) { create(:person, organisation: organisation, user: ben, name: 'B. Alt') }
  let(:meeting) { create(:meeting, organisation: organisation, project: project, title: 'Geheimrunde Ahorn', creator: reader) }

  let!(:lalabase) { create(:glossary_term, organisation: organisation, term: 'Lalabase', category: 'product') }
  let!(:nordlicht) { create(:glossary_term, organisation: organisation, term: 'Nordlicht', category: 'company') }
  let!(:proposal) { create(:glossary_term, :proposed, organisation: organisation, term: 'Zirbelholz') }
  let!(:rejected) { create(:glossary_term, :rejected, organisation: organisation, term: 'Ahornweg') }

  def heard(term, form, replaced: 1, at: 1.day.ago, **attributes)
    create(:term_correction, organisation: organisation, glossary_term: term, heard: form, replaced_count: replaced,
                             created_at: at, **attributes)
  end

  before do
    create(:project_permission, user: reader, project: project, tickets_access: :read_only)
    create(:project_permission, user: glossary_only, project: project, tickets_access: :read_only)
    create(:project_permission, user: ben, project: project, tickets_access: :read_only)
    create(:project_permission, user: sven, project: hidden_project, tickets_access: :read_only)

    # "lala bass": three corrections, one form. The newest spelling stands; the one without a
    # speaker counts, and stands for nobody.
    heard(lalabase, 'lala bass', replaced: 3, at: 2.days.ago, project: project, user: ben, meeting: meeting,
                                 line_index: 4, char_offset: 7, transcript_digest: 'a' * 64, corrected_by: reader)
    heard(lalabase, 'Lala Bass', replaced: 1, at: 1.day.ago, project: project, person: doris)
    heard(lalabase, 'lala bass', replaced: 2, at: 3.days.ago, project: project)
    # Spoken by a member the reader cannot see.
    heard(lalabase, 'lala bus', replaced: 5, project: project, user: sven)
    heard(lalabase, 'la la base', replaced: 2, project: other_project, person: erika)
    # The project is gone: no origin.
    heard(lalabase, 'lala basis', replaced: 1, person: ben_row)
    # Proposals work nowhere: one at a confirmed term, and every form of a term that is not confirmed.
    heard(lalabase, 'lalabeis', replaced: 9, project: project, user: ben, status: 'proposed')
    heard(proposal, 'zirbel holz', project: project)
    heard(rejected, 'ahorn weg', project: project)

    ActsAsTenant.with_tenant(other_organisation) do
      foreign = create(:glossary_term, organisation: other_organisation, term: 'Fremdwort')
      create(:term_correction, organisation: other_organisation, glossary_term: foreign, heard: 'fremd wort')
    end
  end

  def lookup(viewer = reader, project_ids: nil)
    described_class.new(viewer: viewer, organisation: organisation, project_ids: project_ids)
  end

  def forms(answer, term = lalabase)
    answer[:data].find { |row| row[:id] == term.id }[:heard]
  end

  describe '.for_token' do
    def token(user = reader, organisations: [organisation], project_scopes: {})
      create(:personal_access_token, user: user, organisations: organisations, project_scopes: project_scopes)
    end

    def for_token(reach, organisation_id = organisation.id)
      described_class.for_token(reach: reach, viewer: reader, organisation_id: organisation_id)
    end

    it 'opens an organisation the token reaches in every project, with no project limit' do
      found = for_token(token.reach)

      expect(found.organisation).to eq(organisation)
      expect(found.read[:data].pluck(:term)).to eq(%w[Lalabase Nordlicht])
      expect(forms(found.read).pluck(:form)).to include('lala basis')
    end

    it 'opens an organisation the token reaches in some projects, with those projects as the limit (E4)' do
      found = for_token(token(project_scopes: { organisation => [project] }).reach)

      expect(found.read[:data].pluck(:term)).to eq(%w[Lalabase Nordlicht])
      expect(forms(found.read).pluck(:form)).to eq(['Lala Bass', 'lala bus'])
    end

    it 'answers nil for an organisation outside the token, a missing one and a malformed id alike (E4)' do
      ActsAsTenant.with_tenant(other_organisation) do
        role = create(:role, organisation: other_organisation)
        create(:permission, role: role, category: 'glossary', action: 'view_glossary', allowed: true)
        create(:membership, user: reader, organisation: other_organisation, role: role)
      end
      reach = token.reach

      expect(for_token(reach, other_organisation.id)).to be_nil
      expect(for_token(reach, SecureRandom.uuid)).to be_nil
      expect(for_token(reach, 'oops')).to be_nil
      expect(for_token(reach, '')).to be_nil
      expect(for_token(reach, nil)).to be_nil
    end

    it 'answers nil once the membership is deactivated: the token reaches only active memberships' do
      pat = token
      Membership.find_by!(user: reader, organisation: organisation).update!(active: false)

      expect(for_token(PersonalAccessToken.find(pat.id).reach)).to be_nil
    end

    it 'reads an id in the spelling the uuid column takes, upper case or without dashes' do
      reach = token.reach

      expect(for_token(reach, organisation.id.upcase).organisation).to eq(organisation)
      expect(for_token(reach, organisation.id.delete('-')).organisation).to eq(organisation)
    end
  end

  describe '#allowed?' do
    it 'is the glossary right: view_glossary yes, nothing no' do
      expect(lookup.allowed?).to be true
      expect(lookup(ben).allowed?).to be false
    end

    it 'holds for manage_glossary, which implies view_glossary, and for an account admin without a row' do
      expect(lookup(member('Mona', role: role_with('glossary:manage_glossary'))).allowed?).to be true
      expect(lookup(member('Ada', role: role_with(title: Role::ACCOUNT_ADMIN_TITLE))).allowed?).to be true
    end

    it 'is false for a deactivated member who still holds the right' do
      Membership.find_by!(user: reader, organisation: organisation).update!(active: false)

      expect(lookup(User.find(reader.id)).allowed?).to be false
    end
  end

  describe '#read' do
    it 'refuses a reader without the glossary right before it reads a term' do
      statements = capture_sql { expect { lookup(ben).read }.to raise_error(described_class::Refused) }

      expect(statements.grep(/glossary_terms|term_corrections/)).to be_empty
    end

    it 'refuses a deactivated member who still holds the right' do
      Membership.find_by!(user: reader, organisation: organisation).update!(active: false)

      expect { lookup(User.find(reader.id)).read }.to raise_error(described_class::Refused)
    end

    it 'lists the confirmed terms only, by spelling, a confirmed term without a working form with empty heard (E3)' do
      answer = lookup.read

      expect(answer[:data].pluck(:term)).to eq(%w[Lalabase Nordlicht])
      expect(answer[:data].last).to eq(id: nordlicht.id, term: 'Nordlicht', category: 'company', heard: [])
      expect(answer[:meta]).to eq(page: 1, per_page: 50, total: 2)
    end

    it 'gives a heard form only when it is confirmed, grouped by its compared form (E3)' do
      expect(forms(lookup.read)).to eq(
        [
          { form: 'Lala Bass', count: 6, speakers: [{ ref: "member:#{ben.id}", count: 3 }, { ref: "person:#{doris.id}", count: 1 }] },
          { form: 'lala bus', count: 5, speakers: [] },
          { form: 'la la base', count: 2, speakers: [{ ref: "person:#{erika.id}", count: 2 }] },
          { form: 'lala basis', count: 1, speakers: [{ ref: "member:#{ben.id}", count: 1 }] }
        ]
      )
    end

    it 'names every speaker of the answer once, as the people directory names them' do
      expect(lookup.read[:people]).to eq(
        [
          { ref: "member:#{ben.id}", name: 'Ben Beispiel' },
          { ref: "person:#{doris.id}", name: 'Doris Dienstleister' },
          { ref: "person:#{erika.id}", name: 'Erika Muster' }
        ]
      )
    end

    it 'counts a speaker the reader may not see in the directory in the form alone, nowhere named' do
      answer = lookup.read

      expect(forms(answer).find { |form| form[:form] == 'lala bus' }).to eq(form: 'lala bus', count: 5, speakers: [])
      expect(answer.to_json).not_to include(sven.id, 'Sven')
    end

    it 'gives neither speakers nor people without the people right, and reads no directory then (E6)' do
      expect(People::Directory).not_to receive(:new)
      answer = lookup(glossary_only).read

      expect(forms(answer).pluck(:form, :count)).to eq([['Lala Bass', 6], ['lala bus', 5], ['la la base', 2], ['lala basis', 1]])
      expect(forms(answer).pluck(:speakers)).to all(eq([]))
      expect(answer[:people]).to eq([])
    end

    it 'gives a token limited to some projects every term, but only the heard forms of its projects (E4)' do
      answer = lookup(project_ids: [project.id]).read

      expect(answer[:data].pluck(:term)).to eq(%w[Lalabase Nordlicht])
      expect(forms(answer).pluck(:form)).to eq(['Lala Bass', 'lala bus'])
      expect(answer[:people].pluck(:ref)).to eq(["member:#{ben.id}", "person:#{doris.id}"])
      expect(answer[:meta][:total]).to eq(2)
    end

    it 'gives a heard form without a project only to a token that reaches every project (E4)' do
      expect(forms(lookup(project_ids: [project.id, other_project.id]).read).pluck(:form)).not_to include('lala basis')
      expect(forms(lookup(project_ids: nil).read).pluck(:form)).to include('lala basis')
    end

    it 'gives a token whose projects all went away the terms without any heard form' do
      answer = lookup(project_ids: []).read

      expect(answer[:data].pluck(:term, :heard)).to eq([['Lalabase', []], ['Nordlicht', []]])
      expect(answer[:people]).to eq([])
    end

    it 'puts the heard forms of project_id first and still lists every term (E5)' do
      answer = lookup.read(project_id: other_project.id)

      expect(forms(answer).pluck(:form)).to eq(['la la base', 'Lala Bass', 'lala bus', 'lala basis'])
      expect(answer[:data].pluck(:term)).to eq(%w[Lalabase Nordlicht])
    end

    it 'reads a blank project_id as none' do
      plain = forms(lookup.read)
      spaces = forms(lookup.read(project_id: ' '))
      empty = forms(lookup.read(project_id: ''))

      expect([spaces, empty]).to all(eq(plain))
    end

    it 'refuses a project_id outside the organisation, outside the token, missing or malformed as not found (E5)' do
      foreign = ActsAsTenant.with_tenant(other_organisation) { create(:project, organisation: other_organisation) }

      expect { lookup.read(project_id: foreign.id) }.to raise_error(described_class::NotFound)
      expect { lookup(project_ids: [project.id]).read(project_id: other_project.id) }.to raise_error(described_class::NotFound)
      expect { lookup.read(project_id: SecureRandom.uuid) }.to raise_error(described_class::NotFound)
      expect { lookup.read(project_id: 'oops') }.to raise_error(described_class::NotFound)
      expect { lookup.read(project_id: ['oops']) }.to raise_error(described_class::NotFound)
    end

    it 'takes a project the reader may not open: the glossary shows its heard forms anyway (plan §4)' do
      expect(forms(lookup.read(project_id: hidden_project.id)).first[:form]).to eq('Lala Bass')
    end

    it 'carries no meeting, no place and no corrector, only the fields of the contract' do
      answer = lookup.read

      expect(answer.keys).to eq(%i[data people meta])
      expect(answer[:data].map(&:keys)).to all(eq(%i[id term category heard]))
      expect(forms(answer).map(&:keys)).to all(eq(%i[form count speakers]))
      expect(forms(answer).flat_map { |form| form[:speakers] }.map(&:keys)).to all(eq(%i[ref count]))
      expect(answer[:people].map(&:keys)).to all(eq(%i[ref name]))
      expect(answer[:meta].keys).to eq(%i[page per_page total])
      expect(answer.to_json).not_to include(meeting.id, 'Geheimrunde', 'a' * 64, reader.id)
    end

    it 'never shows a term or heard form of another organisation' do
      json = lookup.read.to_json

      expect(json).not_to include('Fremdwort', 'fremd wort')
    end

    it 'reads under the organisation it was made for, whatever tenant is set around it' do
      ActsAsTenant.current_tenant = other_organisation

      expect(lookup.read[:data].pluck(:term)).to eq(%w[Lalabase Nordlicht])
    end

    # A fresh reader each time: a user keeps some of its rights answers for the
    # life of the object, and a warm second call would count fewer.
    it 'reads a page in a fixed number of queries, however many terms, forms and speakers it holds' do
      small = capture_sql { lookup(User.find(reader.id)).read(per_page: 1) }.size
      Prosopite.pause do
        %w[Quarzsand Quelle Quitte].each_with_index do |word, index|
          term = create(:glossary_term, organisation: organisation, term: word)
          heard(term, "#{word.downcase} a", project: project, user: ben, replaced: index + 1)
          heard(term, "#{word.downcase} b", project: other_project, person: doris)
          heard(term, "#{word.downcase} c", project: project, person: erika)
        end
      end

      expect(capture_sql { lookup(User.find(reader.id)).read(per_page: 10) }.size).to eq(small)
    end
  end

  # Review round 1 of #124: every rule of the order, with rows made against the expected order, so a
  # missing or a turned sort cannot pass on the order the database happens to hand them out in. The
  # two ids of Alma and Zeta sort the other way round when read backwards.
  describe 'the order of the answer' do
    let(:quell) { create(:glossary_term, organisation: organisation, term: 'Quellwort') }
    let(:zeta) { create(:person, id: '00000000-0000-4000-8000-0000000000b1', organisation: organisation, name: 'Zeta Zander') }
    let(:alma) { create(:person, id: '00000000-0000-4000-8000-0000000000a9', organisation: organisation, name: 'Alma Abel') }

    it 'breaks a tie of forms by the compared form, and a tie of speakers by ref' do
      heard(quell, 'kalbe', replaced: 2, project: project, person: zeta)
      heard(quell, 'kalbe', replaced: 2, project: project, person: alma)
      heard(quell, 'kalb x', replaced: 4, project: project)

      tied = forms(lookup.read, quell)
      expect(tied.pluck(:form)).to eq(['kalb x', 'kalbe'])
      expect(tied.last[:speakers]).to eq([{ ref: "person:#{alma.id}", count: 2 }, { ref: "person:#{zeta.id}", count: 2 }])
    end

    it 'lists the people by name, not in the order they were heard' do
      heard(quell, 'quell z', project: project, person: zeta)
      heard(quell, 'quell a', project: project, person: alma)

      expect(lookup.read[:people].pluck(:name))
        .to eq(['Alma Abel', 'Ben Beispiel', 'Doris Dienstleister', 'Erika Muster', 'Zeta Zander'])
    end

    it 'puts first a form heard in project_id that was heard in another project too' do
      heard(quell, 'quell viel', replaced: 5, project: other_project)
      heard(quell, 'quell mix', replaced: 1, project: other_project)
      heard(quell, 'quell mix', replaced: 1, project: project)

      expect(forms(lookup.read, quell).pluck(:form)).to eq(['quell viel', 'quell mix'])
      expect(forms(lookup.read(project_id: project.id), quell).pluck(:form)).to eq(['quell mix', 'quell viel'])
    end
  end

  describe 'pages' do
    before do
      %w[Birkenweg Eschenhof].each { |word| create(:glossary_term, organisation: organisation, term: word) }
    end

    it 'pages the confirmed terms in a stable order, with the total of all of them' do
      first = lookup.read(per_page: 2)
      second = lookup.read(page: 2, per_page: 2)

      expect(first[:data].pluck(:term)).to eq(%w[Birkenweg Eschenhof])
      expect(second[:data].pluck(:term)).to eq(%w[Lalabase Nordlicht])
      expect(second[:meta]).to eq(page: 2, per_page: 2, total: 4)
    end

    it 'takes page and per_page as text (REST) or as whole numbers (MCP)' do
      expect(lookup.read(page: '2', per_page: '3')[:data].pluck(:term)).to eq(%w[Nordlicht])
      expect(lookup.read(page: 2, per_page: 3)[:data].pluck(:term)).to eq(%w[Nordlicht])
    end

    it 'reads absent and empty values as the defaults: page 1 of 50' do
      expect(lookup.read(page: '', per_page: nil)[:meta]).to eq(page: 1, per_page: 50, total: 4)
    end

    it 'answers a page beyond the last with no terms and no people, and reads no heard form' do
      answer = nil
      statements = capture_sql { answer = lookup.read(page: 3, per_page: 2) }

      expect(answer).to eq(data: [], people: [], meta: { page: 3, per_page: 2, total: 4 })
      expect(statements.grep(/term_corrections/)).to be_empty
    end

    it 'takes 100 per page at most and refuses a value outside, never cuts it' do
      expect(lookup.read(per_page: 100)[:meta][:per_page]).to eq(100)
      I18n.with_locale(:en) do
        expect { lookup.read(per_page: 101) }
          .to raise_error(described_class::InvalidArgument, 'invalid per_page "101" (expected a whole number from 1 to 100)')
      end
      expect { lookup.read(per_page: '0') }.to raise_error(described_class::InvalidArgument, /per_page "0"/)
      expect { lookup.read(page: 'abc') }.to raise_error(described_class::InvalidArgument, /page "abc"/)
      expect { lookup.read(page: '-1') }.to raise_error(described_class::InvalidArgument)
      expect { lookup.read(page: '1.5') }.to raise_error(described_class::InvalidArgument)
      expect { lookup.read(page: 1.0) }.to raise_error(described_class::InvalidArgument)
      expect { lookup.read(page: described_class::MAX_PAGE + 1) }.to raise_error(described_class::InvalidArgument)
    end

    it 'quotes only the start of a refused text and nothing of a list' do
      expect { lookup.read(page: '9' * 40) }.to raise_error(described_class::InvalidArgument, /page "9{17}\.\.\."/)
      I18n.with_locale(:en) do
        expect { lookup.read(page: ['2']) }
          .to raise_error(described_class::InvalidArgument, 'invalid page (expected a whole number from 1 to 100000)')
      end
    end

    it 'words a refusal in the reader\'s language' do
      I18n.with_locale(:de) do
        expect { lookup.read(per_page: 101) }.to raise_error(described_class::InvalidArgument, /ganze Zahl von 1 bis 100/)
      end
    end

    it 'refuses the right before it reads a page value' do
      expect { lookup(ben).read(per_page: 101) }.to raise_error(described_class::Refused)
    end
  end
end
