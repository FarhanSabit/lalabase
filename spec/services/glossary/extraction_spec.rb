# frozen_string_literal: true

require 'rails_helper'

# What: Glossary::Extraction, one run of the glossary extraction (K5b): what it reads with
#   the rights of the account that started it, what it never reads, what it drops before
#   the model, how it adds to open proposals, how it writes new ones and where it stops.
# Type: Service spec. The classifier, the one AI step, is stubbed: it keeps every candidate
#   it gets, in the spelling seen most often, unless an example says otherwise. Its own spec
#   covers the call to the model.
# Why: the run reads across a whole organisation in the background, with no request around
#   it. A read one right too wide puts a private comment or a project the starter may not
#   see into the model, and onto a proposal every reader of the glossary sees.
#   Invented terms and people only.
RSpec.describe Glossary::Extraction, :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def role_with(title: nil)
    create(:role, organisation: organisation, **{ title: title }.compact)
  end

  # Read fresh from the database, as the run reads its starter.
  def member_with(role, active: true, first_name: 'Test', last_name: 'User')
    user = create(:user, first_name: first_name, last_name: last_name)
    create(:membership, user: user, organisation: organisation, role: role, active: active)
    User.find(user.id)
  end

  def grant(user, project, **areas)
    create(:project_permission, user: user, project: project, **areas)
  end

  let(:admin) { member_with(role_with(title: Role::ACCOUNT_ADMIN_TITLE)) }
  # A role that grants nothing: every right comes from a project permission.
  let(:reader) { member_with(role_with) }
  let(:starter) { admin }
  let(:everything) { true }
  let(:run) do
    create(:glossary_extraction_run, :running, organisation: organisation, started_by: starter,
                                               scope: { 'kind' => 'organisation', 'everything' => everything })
  end

  # The candidates of every classifier call, in order.
  let(:calls) { [] }

  before do
    allow(Glossary::Classifier).to receive(:call) do |candidates:, **|
      calls << candidates
      candidates.map { |candidate| kept(candidate) }
    end
  end

  def kept(candidate)
    Glossary::Classifier::Row.new(key: candidate.key, term: candidate.display, category: 'product',
                                  variants: candidate.forms.drop(1), hint: 'Ein erfundener Begriff.')
  end

  def sent_keys
    calls.flatten.map(&:key)
  end

  def extract
    described_class.call(run: run)
    run.reload
  end

  # A later run of the same starter, once the one before it has ended. calls
  # holds the classifier calls of this run only.
  def run_again(everything: true)
    calls.clear
    later = create(:glossary_extraction_run, :running, organisation: organisation, started_by: starter,
                                                       scope: { 'kind' => 'organisation', 'everything' => everything })
    described_class.call(run: later)
    later.reload
  end

  # The terms stand next to no other capitalised word, so each is a candidate of its own.
  def text(*terms)
    "Wir nutzen #{terms.join(', ')} im Team."
  end

  def ticket(content, project: self.project)
    create(:ticket, organisation: organisation, project: project, title: 'Anfrage', content: content)
  end

  def comment(ticket, content, private: false, author: create(:user), addressee: nil)
    create(:post, organisation: organisation, ticket: ticket, user: author, content: content,
                  is_private: private, visible_to_user: addressee)
  end

  def ticket_file(ticket, content)
    create(:ticket_document, organisation: organisation, ticket: ticket, plain_text_version: content)
  end

  def comment_file(post, content)
    create(:post_document, organisation: organisation, post: post, plain_text_version: content)
  end

  def note(content, project: self.project)
    create(:note, organisation: organisation, project: project, title: 'Notiz', content: content)
  end

  # A document whose current version holds content; older is the text of a version before it.
  def document(content, project: self.project, older: nil)
    record = create(:document, organisation: organisation, project: project)
    version_of(record, older) if older
    record.update!(current_version: version_of(record, content))
    record
  end

  def version_of(record, content)
    create(:document_version, organisation: organisation, document: record, title: 'Handbuch', description: nil,
                              plain_text_version: content)
  end

  def proposal_terms
    GlossaryProposal.where(organisation: organisation).pluck(:term)
  end

  describe 'what it reads' do
    it 'reads tickets, public comments, their files, notes and documents and proposes what the model keeps' do
      open_ticket = ticket(text('Quarnix'))
      post = comment(open_ticket, text('Vexoria'))
      ticket_file(open_ticket, text('Plumbix'))
      comment_file(post, text('Glimmox'))
      note(text('Trondel'))
      document(text('Bexlo'))

      extract

      expect(run).to have_attributes(status: 'succeeded', error_code: nil)
      expect(run.finished_at).to be_present
      expect(run.stats['sources']).to eq('tickets' => 1, 'posts' => 1, 'ticket_documents' => 1,
                                         'post_documents' => 1, 'notes' => 1, 'document_versions' => 1)
      expect(proposal_terms).to contain_exactly('Quarnix', 'Vexoria', 'Plumbix', 'Glimmox', 'Trondel', 'Bexlo')
      expect(run.stats).to include('candidates' => 6, 'ai_calls' => 1, 'parse_errors' => 0, 'proposals_created' => 6,
                                   'proposals_updated' => 0, 'truncated' => false, 'since' => nil)
      expect(Glossary::Classifier).to have_received(:call)
        .with(organisation: organisation, user: starter, run: run, candidates: anything)
    end

    it 'writes a proposal with the occurrences of its candidate and the places the scan kept' do
      busy = ticket("#{text('Quarnix')} Quarnix steht hier noch einmal.")
      calm = ticket(text('Quarnix'))

      extract

      proposal = GlossaryProposal.find_by!(organisation: organisation, normalized_term: 'quarnix')
      expect(proposal).to have_attributes(status: 'open', glossary_extraction_run_id: run.id, category: 'product',
                                          hint: 'Ein erfundener Begriff.', occurrences: 3, variants: [])
      places = proposal.glossary_proposal_sources.order(occurrences: :desc)
      expect(places.map { |place| [place.source_type, place.source_id, place.project_id, place.occurrences] })
        .to eq([['Ticket', busy.id, project.id, 2], ['Ticket', calm.id, project.id, 1]])
      expect(places.last.snippet).to eq("Anfrage #{text('Quarnix')}")
    end

    it 'keeps hint provenance for every input context, including a dropped candidate, separately per batch' do
      stub_const('Glossary::Extraction::BATCH_SIZE', 2)
      quarnix = ticket(text('Quarnix'))
      vexoria = ticket(text('Vexoria'))
      zorbel = ticket(text('Zorbelwerk'))
      allow(Glossary::Classifier).to receive(:call) do |candidates:, **|
        candidates.reject { |candidate| candidate.key == 'vexoria' }.map { |candidate| kept(candidate) }
      end

      extract

      expect(GlossaryProposal.find_by!(term: 'Quarnix').hint_sources).to contain_exactly(
        { 'source_type' => 'Ticket', 'source_id' => quarnix.id },
        { 'source_type' => 'Ticket', 'source_id' => vexoria.id }
      )
      expect(GlossaryProposal.find_by!(term: 'Zorbelwerk').hint_sources)
        .to eq([{ 'source_type' => 'Ticket', 'source_id' => zorbel.id }])
      expect(GlossaryProposal.find_by(term: 'Vexoria')).to be_nil
    end

    it 'records exactly the snippet sources sent to the model and deduplicates shared context' do
      busy = ticket("#{text('Quarnix', 'Vexoria')} Quarnix, Vexoria, Quarnix, Vexoria.")
      middle = ticket("#{text('Quarnix', 'Vexoria')} Quarnix, Vexoria.")
      ticket(text('Quarnix', 'Vexoria'))

      extract

      expected = [busy, middle].map { |source| { 'source_type' => 'Ticket', 'source_id' => source.id } }
      expect(GlossaryProposal.find_by!(term: 'Quarnix').hint_sources).to match_array(expected)
      expect(GlossaryProposal.find_by!(term: 'Vexoria').hint_sources).to match_array(expected)
      expect(Glossary::Classifier::SNIPPETS_PER_CANDIDATE).to eq(2)
    end

    it 'reads a document only in its current version' do
      document(text('Bexlo'), older: text('Altfix'))

      extract

      expect(sent_keys).to eq(['bexlo'])
      expect(run.stats['sources']['document_versions']).to eq(1)
    end

    it 'never reads the texts of another organisation, not even for an account admin' do
      other = create(:organisation)
      ActsAsTenant.with_tenant(other) do
        foreign_project = create(:project, organisation: other)
        create(:ticket, organisation: other, project: foreign_project, title: 'Anfrage', content: text('Fremdix'))
        create(:note, organisation: other, project: foreign_project, title: 'Notiz', content: text('Fremdnotix'))
      end
      ticket(text('Quarnix'))

      extract

      expect(sent_keys).to eq(['quarnix'])
    end
  end

  describe 'what it never reads' do
    it 'never reads a private comment or its file, not even for an account admin who may read it on the page' do
      open_ticket = ticket(text('Quarnix'))
      secret = comment(open_ticket, text('Kryptax'), private: true)
      secret_file = comment_file(secret, text('Geheimix'))
      expect(secret.readable_by?(admin)).to be(true)

      extract

      expect(sent_keys).to eq(['quarnix'])
      expect(GlossaryProposalSource.where(source_id: [secret.id, secret_file.id])).to be_empty
      expect(run.stats['sources']).to include('tickets' => 1, 'posts' => 0, 'post_documents' => 0)
    end

    context 'when the starter is the addressee of a private comment' do
      let(:starter) { reader }

      it 'never reads it either' do
        grant(reader, project, tickets_access: 'read_only')
        open_ticket = ticket(text('Quarnix'))
        secret = comment(open_ticket, text('Kryptax'), private: true, addressee: reader)
        expect(secret.readable_by?(reader)).to be(true)

        extract

        expect(sent_keys).to eq(['quarnix'])
        expect(run.stats['sources']['posts']).to eq(0)
      end
    end

    context 'with a ticket outside the ticket reach of the starter' do
      let(:starter) { reader }

      it 'never reads it, its comments or their files, also in a project reached through another area' do
        elsewhere = create(:project, organisation: organisation)
        grant(reader, project, tickets_access: 'read_only')
        grant(reader, elsewhere, notes_access: 'read_only')
        ticket(text('Quarnix'))
        far = ticket(text('Vexoria'), project: elsewhere)
        ticket_file(far, text('Plumbix'))
        comment_file(comment(far, text('Glimmox')), text('Trondel'))

        extract

        expect(sent_keys).to eq(['quarnix'])
      end
    end

    # Review round 2 of #129. The reach gives the projects. The policy scope of
    # each kind may hold back a row in a project the starter reaches, and the
    # run reads what the scope gives, not what the reach alone would. Here the
    # scope of notes holds back one note.
    it "never reads a row its kind's policy scope holds back, in a project the starter reaches" do
      note(text('Trondel'))
      held_back = note(text('Vexoria'))
      allow_any_instance_of(NotePolicy::Scope).to receive(:resolve).and_wrap_original do |resolve|
        resolve.call.where.not(id: held_back.id)
      end

      extract

      expect(sent_keys).to eq(['trondel'])
      expect(run.stats['sources']['notes']).to eq(1)
    end

    context 'with notes and documents in a project where the starter may read tickets only' do
      let(:starter) { reader }

      it 'reads notes and documents only where their own area is readable' do
        knowledge = create(:project, organisation: organisation)
        grant(reader, project, tickets_access: 'read_only')
        grant(reader, knowledge, notes_access: 'read_only', documents_access: 'read_only')
        ticket(text('Quarnix'))
        note(text('Trondel'))
        document(text('Bexlo'))
        note(text('Vexoria'), project: knowledge)
        document(text('Plumbix'), project: knowledge)

        extract

        expect(sent_keys).to contain_exactly('quarnix', 'vexoria', 'plumbix')
        expect(run.stats['sources']).to include('tickets' => 1, 'notes' => 1, 'document_versions' => 1)
      end
    end
  end

  describe 'the starter' do
    it 'fails the run as starter_inactive when the starter is no longer an active member' do
      Membership.where(user_id: admin.id, organisation_id: organisation.id).update_all(active: false)
      ticket(text('Quarnix'))

      extract

      expect(run).to have_attributes(status: 'failed', error_code: 'starter_inactive')
      expect(run.finished_at).to be_present
      expect(Glossary::Classifier).not_to have_received(:call)
      expect(proposal_terms).to be_empty
    end

    it 'fails the run as starter_inactive when the account that started it is gone' do
      run.update_columns(started_by_id: nil)
      ticket(text('Quarnix'))

      extract

      expect(run).to have_attributes(status: 'failed', error_code: 'starter_inactive')
      expect(Glossary::Classifier).not_to have_received(:call)
    end
  end

  describe 'incremental runs' do
    let(:everything) { false }
    let(:bound) { Time.zone.parse('2026-10-01 08:00:00') }

    before do
      create(:glossary_extraction_run, :succeeded, organisation: organisation, created_at: bound)
      # Neither a later failed run nor a run of another organisation moves the bound.
      create(:glossary_extraction_run, :failed, organisation: organisation, created_at: bound + 2.days)
      other = create(:organisation)
      ActsAsTenant.with_tenant(other) do
        create(:glossary_extraction_run, :succeeded, organisation: other, created_at: bound + 3.days)
      end
      ticket(text('Altfix')).update_columns(updated_at: bound - 1.hour)
      ticket(text('Quarnix')).update_columns(updated_at: bound + 1.hour)
    end

    it 'reads only what changed after the start of the last succeeded run of the organisation' do
      extract

      expect(sent_keys).to eq(['quarnix'])
      expect(run.scope).to include('kind' => 'organisation', 'everything' => false, 'since' => bound.iso8601(6))
      expect(run.stats['since']).to eq(bound.iso8601(6))
    end

    context 'with everything' do
      let(:everything) { true }

      it 'reads everything and uses no bound' do
        extract

        expect(sent_keys).to contain_exactly('altfix', 'quarnix')
        expect(run.scope['since']).to be_nil
        expect(run.stats['since']).to be_nil
      end
    end
  end

  it 'reads everything on an incremental run when no run has succeeded yet' do
    run.update_columns(scope: { 'kind' => 'organisation', 'everything' => false })
    ticket(text('Quarnix')).update_columns(updated_at: 1.year.ago)

    extract

    expect(sent_keys).to eq(['quarnix'])
    expect(run.scope['since']).to be_nil
  end

  describe 'limits' do
    it 'reads the newest MAX_SOURCES sources over all kinds and says it cut' do
      stub_const('Glossary::Extraction::MAX_SOURCES', 2)
      ticket(text('Altfix')).update_columns(updated_at: 3.days.ago)
      ticket(text('Quarnix')).update_columns(updated_at: 2.days.ago)
      note(text('Trondel')).update_columns(updated_at: 1.day.ago)

      extract

      expect(sent_keys).to contain_exactly('quarnix', 'trondel')
      expect(run.stats['sources']).to include('tickets' => 1, 'notes' => 1)
      expect(run.stats['truncated']).to be(true)
    end

    it 'says nothing was cut when the sources fit MAX_SOURCES exactly' do
      stub_const('Glossary::Extraction::MAX_SOURCES', 2)
      ticket(text('Quarnix'))
      note(text('Trondel'))

      extract

      expect(sent_keys).to contain_exactly('quarnix', 'trondel')
      expect(run.stats['truncated']).to be(false)
    end

    it 'sends at most MAX_CANDIDATES candidates and says it cut' do
      stub_const('Glossary::Extraction::MAX_CANDIDATES', 1)
      ticket(text('Quarnix', 'Vexoria'))

      extract

      expect(sent_keys).to eq(['quarnix'])
      expect(run.stats).to include('candidates' => 2, 'truncated' => true)
    end

    it 'asks the model at most MAX_AI_CALLS times and says it cut' do
      stub_const('Glossary::Extraction::BATCH_SIZE', 1)
      stub_const('Glossary::Extraction::MAX_AI_CALLS', 2)
      ticket(text('Plumbix', 'Quarnix', 'Vexoria'))

      extract

      expect(Glossary::Classifier).to have_received(:call).twice
      expect(calls.map { |batch| batch.map(&:key) }).to eq([['plumbix'], ['quarnix']])
      expect(proposal_terms).to contain_exactly('Plumbix', 'Quarnix')
      expect(run.stats).to include('ai_calls' => 2, 'proposals_created' => 2, 'truncated' => true)
    end

    it 'writes at most MAX_PROPOSALS_PER_RUN proposals and says it cut' do
      stub_const('Glossary::Extraction::MAX_PROPOSALS_PER_RUN', 1)
      ticket(text('Quarnix', 'Vexoria'))

      extract

      expect(proposal_terms).to eq(['Quarnix'])
      expect(run.stats).to include('proposals_created' => 1, 'truncated' => true)
    end

    # With the numbers of today MAX_AI_CALLS and MAX_PROPOSALS_PER_RUN never
    # bind: the MAX_CANDIDATES a run sends fit into five calls of BATCH_SIZE
    # (300 / 60), fewer than MAX_AI_CALLS (8), and a run cannot propose more
    # than it sends. MAX_AI_CALLS stays as a safety net, the bound on what a run
    # costs should one of the other numbers change. Red here means: decide
    # whether the net may bind, then change the numbers or this example.
    it 'fits what it sends into MAX_AI_CALLS calls and a proposal for each into MAX_PROPOSALS_PER_RUN' do
      expect(described_class::MAX_CANDIDATES).to be <= described_class::BATCH_SIZE * described_class::MAX_AI_CALLS
      expect(described_class::MAX_PROPOSALS_PER_RUN).to be >= described_class::MAX_CANDIDATES
    end

    it 'asks the model no more once MAX_PROPOSALS_PER_RUN proposals are written' do
      stub_const('Glossary::Extraction::BATCH_SIZE', 1)
      stub_const('Glossary::Extraction::MAX_PROPOSALS_PER_RUN', 1)
      ticket(text('Quarnix', 'Vexoria'))

      extract

      expect(Glossary::Classifier).to have_received(:call).once
      expect(run.stats).to include('ai_calls' => 1, 'proposals_created' => 1, 'truncated' => true)
    end
  end

  describe 'long texts and long scans' do
    include ActiveSupport::Testing::TimeHelpers

    after { travel_back }

    # Ticket and note: "Anfrage" or "Notiz", a line break, then the content.
    # The cut at 40 falls into Vexoria and into Glimmoxwerk; Bexlo and Plumbix
    # stand after it.
    it 'reads a text only up to MAX_SOURCE_CHARS, whatever its kind, and cuts it between words' do
      stub_const('Glossary::Extraction::MAX_SOURCE_CHARS', 40)
      ticket("#{text('Quarnix')} Vexoria #{'und ' * 20}Bexlo")
      note("#{text('Trondel')} Glimmoxwerk und Plumbix")

      extract

      # Not "vexo" or "glimmo" either: the piece of a word at the cut is no word.
      expect(sent_keys).to contain_exactly('quarnix', 'trondel')
      expect(run.stats['sources']).to include('tickets' => 1, 'notes' => 1)
    end

    # Review of K5c: the run line says whether a limit cut anything, and a text
    # read only in part is such a cut. The bound is the length of the ticket's
    # own text, so the example holds whatever the text around the content.
    it 'says it cut when a text is longer than MAX_SOURCE_CHARS' do
      length = ticket(text('Quarnix', 'Vexoria')).plain_text_version.length
      stub_const('Glossary::Extraction::MAX_SOURCE_CHARS', length - 1)

      extract

      expect(sent_keys).to contain_exactly('quarnix', 'vexoria')
      expect(run.stats['truncated']).to be(true)
    end

    it 'says nothing was cut when a text fits MAX_SOURCE_CHARS exactly' do
      length = ticket(text('Quarnix', 'Vexoria')).plain_text_version.length
      stub_const('Glossary::Extraction::MAX_SOURCE_CHARS', length)

      extract

      expect(sent_keys).to contain_exactly('quarnix', 'vexoria')
      expect(run.stats['truncated']).to be(false)
    end

    # Calls each_text for every text the scan reads, as it reads it.
    def during_scan(&each_text)
      allow(Glossary::CandidateScan).to receive(:call).and_wrap_original do |scan, sources:, **options|
        scan.call(sources: sources.lazy.map { |source| source.tap(&each_text) }, **options)
      end
    end

    # One text per batch: the one query per kind and batch repeats, and
    # Prosopite would read the batches as an N+1 (the example with real
    # batches below watches the queries).
    def extract_in_batches_of_one
      stub_const('Glossary::Extraction::LOAD_BATCH', 1)
      Prosopite.pause { extract }
    end

    it 'touches the run before each load batch, so a scan that takes long does not turn it stale' do
      %w[Quarnix Vexoria Plumbix].each { |term| ticket(text(term)) }
      seen = []
      # Six minutes per text: the three outlast STALE_AFTER (ten minutes).
      during_scan do
        seen << GlossaryExtractionRun.find(run.id).then { |stored| [stored.updated_at, stored.stale?] }
        travel(6.minutes)
      end

      extract_in_batches_of_one

      expect(seen.size).to eq(3)
      expect(seen.map(&:first)).to eq(seen.map(&:first).uniq.sort)
      expect(seen.map(&:last)).to eq([false, false, false])
      expect(run).to have_attributes(status: 'succeeded')
    end

    it 'reads no further batch once the run was ended elsewhere during its scan' do
      %w[Quarnix Vexoria Plumbix].each { |term| ticket(text(term)) }
      read = 0
      during_scan do
        read += 1
        GlossaryExtractionRun.find(run.id).mark_failed!('stale') if read == 1
      end

      extract_in_batches_of_one

      expect(read).to eq(1)
      expect(run).to have_attributes(status: 'failed', error_code: 'stale')
      expect(Glossary::Classifier).not_to have_received(:call)
    end
  end

  describe 'open proposals' do
    it 'adds occurrences, new spellings and new places to an open proposal and does not ask the model about it' do
      proposal = create(:glossary_proposal, organisation: organisation, term: 'Quarnix', occurrences: 3)
      earlier = ticket('Wir nutzen nichts im Team.')
      create(:glossary_proposal_source, organisation: organisation, glossary_proposal: proposal, project: project,
                                        source: earlier, snippet: 'Quarnix stand hier.', occurrences: 2)
      first = ticket(text('Quarnix'))
      second = ticket(text('Quar-nix'))
      ticket(text('Vexoria'))

      extract

      expect(sent_keys).to eq(['vexoria'])
      expect(proposal.reload).to have_attributes(status: 'open', occurrences: 5, variants: ['Quar-nix'])
      expect(proposal.glossary_proposal_sources.pluck(:source_id)).to contain_exactly(earlier.id, first.id, second.id)
      expect(proposal.glossary_proposal_sources.find_by!(source_id: earlier.id))
        .to have_attributes(snippet: 'Quarnix stand hier.', occurrences: 2)
      expect(run.stats).to include('proposals_updated' => 1, 'proposals_created' => 1)
    end

    it 'keeps at most MAX_SOURCES places on an open proposal, the busiest new ones first' do
      proposal = create(:glossary_proposal, organisation: organisation, term: 'Quarnix')
      Prosopite.pause do
        (GlossaryProposal::MAX_SOURCES - 1).times do
          create(:glossary_proposal_source, organisation: organisation, glossary_proposal: proposal, project: project,
                                            source: ticket('Wir nutzen nichts im Team.'))
        end
      end
      busy = ticket('Wir nutzen Quarnix im Team. Quarnix, Quarnix.')
      calm = ticket(text('Quarnix'))

      extract

      places = proposal.glossary_proposal_sources.pluck(:source_id)
      expect(places.size).to eq(GlossaryProposal::MAX_SOURCES)
      expect(places).to include(busy.id)
      expect(places).not_to include(calm.id)
    end

    it 'finds an open proposal by one of its variants as well' do
      proposal = create(:glossary_proposal, organisation: organisation, term: 'Vexoria', variants: ['Plumbix'])
      ticket(text('Plumbix'))

      extract

      expect(Glossary::Classifier).not_to have_received(:call)
      expect(proposal.reload).to have_attributes(occurrences: 1, variants: ['Plumbix'])
      expect(run.stats['proposals_updated']).to eq(1)
    end

    # The candidates of open proposals take none of the MAX_CANDIDATES places:
    # else the open proposals of a first run, left undecided, would fill every
    # later run, and a new term would never reach the model.
    it 'sends up to MAX_CANDIDATES fresh candidates besides the candidates of open proposals' do
      stub_const('Glossary::Extraction::MAX_CANDIDATES', 1)
      2.times { ticket(text('Quarnix')) }
      ticket(text('Vexoria'))

      extract
      expect(sent_keys).to eq(['quarnix'])
      expect(run.stats).to include('candidates' => 2, 'truncated' => true)

      later = run_again

      expect(sent_keys).to eq(['vexoria'])
      expect(later.stats).to include('candidates' => 2, 'ai_calls' => 1, 'proposals_created' => 1, 'truncated' => false)
      expect(proposal_terms).to contain_exactly('Quarnix', 'Vexoria')
    end

    # The count orders the review list: a place read again, by a run that reads
    # everything or because its row changed, counts once.
    it 'counts the occurrences of a place once, however often a run reads it again' do
      first = ticket(text('Quarnix'))
      ticket(text('Quarnix'))

      extract
      proposal = GlossaryProposal.find_by!(organisation: organisation, normalized_term: 'quarnix')
      expect(proposal.occurrences).to eq(2)

      # Two lines, not a loop: Prosopite reads runs started from one line as an N+1.
      run_again
      run_again
      expect(proposal.reload.occurrences).to eq(2)

      first.update!(content: "#{text('Quarnix')} Quarnix noch einmal.")
      expect(run_again(everything: false).stats['sources']['tickets']).to eq(1)
      expect(proposal.reload.occurrences).to eq(2)

      ticket(text('Quarnix'))
      run_again(everything: false)
      expect(proposal.reload.occurrences).to eq(3)
      expect(proposal.glossary_proposal_sources.count).to eq(3)
    end

    # The run reads the keys of the open proposals before its scan and locks
    # the proposals after it, so a person may decide one in between, while the
    # scan reads (here: right after it). The lock takes only a proposal that is
    # still open.
    {
      'accepted' => ->(proposal, user) { Actors::AcceptGlossaryProposal.call(proposal: proposal, current_user: user) },
      'dismissed' => ->(proposal, user) { Actors::DismissGlossaryProposal.call(proposal: proposal, current_user: user) }
    }.each do |decision, decide|
      it "adds nothing to a proposal #{decision} after the open ones were read" do
        proposal = create(:glossary_proposal, organisation: organisation, term: 'Quarnix', occurrences: 3)
        ticket(text('Quarnix', 'Quar-nix'))
        allow(Glossary::CandidateScan).to receive(:call).and_wrap_original do |scan, **options|
          scan.call(**options).tap { expect(decide.call(GlossaryProposal.find(proposal.id), admin)).to be_success }
        end

        extract

        expect(proposal.reload).to have_attributes(status: decision, occurrences: 3, variants: [])
        expect(proposal.glossary_proposal_sources).to be_empty
        expect(run.stats['proposals_updated']).to eq(0)
      end
    end

    it 'leaves accepted and dismissed proposals as they are and sends none of their forms' do
      accepted = create(:glossary_proposal, :accepted, organisation: organisation, term: 'Quarnix',
                                                       variants: ['Quar-nix'], occurrences: 4)
      dismissed = create(:glossary_proposal, :dismissed, organisation: organisation, term: 'Vexoria',
                                                         variants: ['Glimmox'], occurrences: 2)
      decided = GlossaryProposal.where(id: [accepted.id, dismissed.id]).order(:id)
      stored = decided.map(&:attributes)
      ticket(text('Quarnix', 'Quar-nix', 'Vexoria', 'Glimmox', 'Plumbix'))

      extract

      expect(sent_keys).to eq(['plumbix'])
      expect(decided.reload.map(&:attributes)).to eq(stored)
      expect(GlossaryProposalSource.where(glossary_proposal: [accepted, dismissed])).to be_empty
      expect(run.stats['proposals_updated']).to eq(0)
    end
  end

  describe 'what it knows already' do
    it 'sends no glossary term, heard form or name of the people directory and of the active members' do
      term = create(:glossary_term, :rejected, organisation: organisation, term: 'Quarnix')
      create(:term_correction, organisation: organisation, glossary_term: term, heard: 'Vexoria')
      create(:person, organisation: organisation, name: 'Glimmox Trondel')
      member_with(role_with, first_name: 'Bexlo', last_name: 'Fizzbo')
      member_with(role_with, active: false, first_name: 'Morbax', last_name: 'Ustrel')
      ticket(text('Quarnix', 'Vexoria', 'Glimmox', 'Trondel', 'Bexlo', 'Fizzbo', 'Morbax', 'Plumbix'))
      ticket('Wir treffen Glimmox Trondel und Bexlo Fizzbo heute.')

      extract

      # Morbax: the name of a deactivated member is no known name.
      expect(sent_keys).to contain_exactly('morbax', 'plumbix')
    end
  end

  describe 'failures of the model' do
    before { stub_const('Glossary::Extraction::BATCH_SIZE', 1) }

    def answer(failing:, code:)
      allow(Glossary::Classifier).to receive(:call) do |candidates:, **|
        calls << candidates
        raise Glossary::Classifier::Failure.new(code: code) if failing.include?(calls.size)

        candidates.map { |candidate| kept(candidate) }
      end
    end

    it 'ends the run with the code of a failure and keeps the proposals written before' do
      answer(failing: [2], code: 'quota_exceeded')
      ticket(text('Plumbix', 'Quarnix', 'Vexoria'))

      extract

      expect(run).to have_attributes(status: 'failed', error_code: 'quota_exceeded')
      expect(run.finished_at).to be_present
      expect(Glossary::Classifier).to have_received(:call).twice
      expect(proposal_terms).to eq(['Plumbix'])
      expect(run.stats).to include('ai_calls' => 2, 'proposals_created' => 1)
    end

    it 'skips a batch whose answer could not be read and goes on' do
      answer(failing: [1], code: 'parse_error')
      ticket(text('Quarnix', 'Vexoria'))

      extract

      expect(run).to have_attributes(status: 'succeeded', error_code: nil)
      expect(proposal_terms).to eq(['Vexoria'])
      expect(run.stats).to include('ai_calls' => 2, 'parse_errors' => 1, 'proposals_created' => 1)
    end

    it 'fails as parse_error when no batch could be read' do
      answer(failing: [1, 2], code: 'parse_error')
      ticket(text('Quarnix', 'Vexoria'))

      extract

      expect(run).to have_attributes(status: 'failed', error_code: 'parse_error')
      expect(run.stats).to include('ai_calls' => 2, 'parse_errors' => 2, 'proposals_created' => 0)
    end

    it 'succeeds without asking the model when there is no candidate' do
      ticket('Wir nutzen nichts im Team.')

      extract

      expect(run).to have_attributes(status: 'succeeded')
      expect(Glossary::Classifier).not_to have_received(:call)
      expect(run.stats).to include('candidates' => 0, 'ai_calls' => 0)
    end
  end

  it 'takes a proposal another run wrote at the same moment as existing, not as an error' do
    allow(Glossary::Classifier).to receive(:call) do |candidates:, **|
      create(:glossary_proposal, organisation: organisation, term: 'Quarnix')
      candidates.map { |candidate| kept(candidate) }
    end
    ticket(text('Quarnix'))

    extract

    expect(run).to have_attributes(status: 'succeeded')
    expect(GlossaryProposal.where(organisation: organisation, normalized_term: 'quarnix').count).to eq(1)
    expect(GlossaryProposal.find_by!(normalized_term: 'quarnix').glossary_extraction_run_id).to be_nil
    expect(run.stats['proposals_created']).to eq(0)
  end

  it 'writes nothing more once the run was ended elsewhere (a start that found it stale)' do
    allow(Glossary::Classifier).to receive(:call) do |candidates:, **|
      GlossaryExtractionRun.find(run.id).mark_failed!('stale')
      candidates.map { |candidate| kept(candidate) }
    end
    ticket(text('Quarnix'))

    extract

    expect(run).to have_attributes(status: 'failed', error_code: 'stale')
    expect(proposal_terms).to be_empty
  end

  context 'with a starter who reaches some projects' do
    let(:starter) { reader }

    it 'counts the projects of any of the three reaches against all projects of the organisation' do
      knowledge = create(:project, organisation: organisation)
      create(:project, organisation: organisation)
      grant(reader, project, tickets_access: 'read_only')
      grant(reader, knowledge, notes_access: 'read_only')

      extract

      expect(run.stats).to include('projects_reached' => 2, 'projects_total' => 3)
    end
  end

  it 'reads thirty sources of every kind and adds to open proposals without an N+1 (Prosopite raises here)' do
    open_terms = %w[Zorbelone Zorbeltwo]
    Prosopite.pause do
      open_terms.each { |term| create(:glossary_proposal, organisation: organisation, term: term) }
      %w[a e i o u].each do |suffix|
        words = %w[Quarnix Vexoria Plumbix Glimmox Trondel Bexlo].map { |word| "#{word}#{suffix}" }
        open_ticket = ticket(text(words[0], *open_terms))
        post = comment(open_ticket, text(words[1]))
        ticket_file(open_ticket, text(words[2]))
        comment_file(post, text(words[3]))
        note(text(words[4]))
        document(text(words[5]))
      end
    end

    extract

    expect(run.stats['sources'].values.sum).to eq(30)
    expect(run.stats).to include('proposals_created' => 30, 'proposals_updated' => 2)
  end
end
