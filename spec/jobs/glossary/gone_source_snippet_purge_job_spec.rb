# frozen_string_literal: true

require 'rails_helper'

# What: Glossary::GoneSourceSnippetPurgeJob, the daily sweep that blanks what a
#   proposal of the glossary extraction still holds of a source that is gone (K5b):
#   the snippet of a place, and the hint of a proposal whose model call read it.
# Type: Job spec against real rows, across organisations, without a tenant.
# Why: a place has no foreign key on purpose (the page says "source gone"), so a
#   deleted ticket or comment leaves up to 240 characters of itself behind, for good,
#   and nothing shows them ever again. Three ways this fails silently: a snippet kept
#   because the id exists in ANOTHER kind's table, a hint kept because one of its
#   sources still exists, and a snippet blanked although its source is still there.
RSpec.describe Glossary::GoneSourceSnippetPurgeJob, :ci_guard, type: :job do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def proposal(**attributes)
    create(:glossary_proposal, organisation: organisation, **attributes)
  end

  def place(of, source, snippet: 'Der Zorbel Hub steht hier.')
    create(:glossary_proposal_source, organisation: organisation, glossary_proposal: of, project: project,
                                      source: source, snippet: snippet, occurrences: 2)
  end

  def reference(source)
    { 'source_type' => source.class.name, 'source_id' => source.id }
  end

  def perform
    ActsAsTenant.current_tenant = nil
    described_class.perform_now
    ActsAsTenant.current_tenant = organisation
  end

  it 'uses the default queue' do
    expect(described_class.new.queue_name).to eq('default')
  end

  describe 'the snippet of a place' do
    it 'is blanked once its source is gone, and the row keeps its project and its count' do
      ticket = create(:ticket, organisation: organisation, project: project)
      gone = place(proposal, ticket)
      ticket.destroy!

      perform

      expect(gone.reload).to have_attributes(snippet: '', project_id: project.id, occurrences: 2, source_id: ticket.id)
    end

    it 'stays while its source exists, whatever kind it is' do
      ticket = create(:ticket, organisation: organisation, project: project)
      note = create(:note, organisation: organisation, project: project)
      post = create(:post, organisation: organisation, ticket: ticket, user: create(:user))
      kept = [place(proposal, ticket), place(proposal, note), place(proposal, post)]

      perform

      expect(GlossaryProposalSource.where(id: kept.map(&:id)).pluck(:snippet)).to all(eq('Der Zorbel Hub steht hier.'))
    end

    it 'is blanked when only a row of another kind carries the id' do
      ticket = create(:ticket, organisation: organisation, project: project)
      note = create(:note, organisation: organisation, project: project)
      row = place(proposal, note)
      row.update_columns(source_type: 'Ticket', source_id: ticket.id)
      row.update_columns(source_type: 'Note')
      ticket_row = place(proposal, ticket)

      perform

      expect(row.reload.snippet).to eq('')
      expect(ticket_row.reload.snippet).to eq('Der Zorbel Hub steht hier.')
    end

    it 'is blanked for a comment, a file, a note and a document version that are gone' do
      ticket = create(:ticket, organisation: organisation, project: project)
      post = create(:post, organisation: organisation, ticket: ticket, user: create(:user))
      file = create(:ticket_document, organisation: organisation, ticket: ticket, plain_text_version: 'Zorbel')
      note = create(:note, organisation: organisation, project: project)
      document = create(:document, organisation: organisation, project: project)
      version = create(:document_version, organisation: organisation, document: document, title: 'Handbuch',
                                          plain_text_version: 'Zorbel')
      rows = [post, file, note, version].map { |source| place(proposal, source) }
      # Deleting four kinds runs their own cleanup callbacks; the sweep itself is one UPDATE per kind.
      Prosopite.pause { [post, file, note, version].each(&:destroy!) }

      perform

      expect(GlossaryProposalSource.where(id: rows.map(&:id)).pluck(:snippet)).to all(eq(''))
    end

    it 'is blanked in every organisation, without a tenant set' do
      elsewhere = create(:organisation)
      row = ActsAsTenant.with_tenant(elsewhere) do
        other_project = create(:project, organisation: elsewhere)
        ticket = create(:ticket, organisation: elsewhere, project: other_project)
        row = create(:glossary_proposal_source, organisation: elsewhere, project: other_project, source: ticket,
                                                glossary_proposal: create(:glossary_proposal, organisation: elsewhere))
        ticket.destroy!
        row
      end

      perform

      expect(ActsAsTenant.without_tenant { GlossaryProposalSource.unscoped.where(id: row.id).pick(:snippet) }).to eq('')
    end

    it 'leaves a blank snippet untouched' do
      ticket = create(:ticket, organisation: organisation, project: project)
      row = place(proposal, ticket, snippet: '')
      ticket.destroy!
      row.update_columns(updated_at: 1.day.ago)

      perform

      expect(row.reload.updated_at).to be < 23.hours.ago
    end
  end

  describe 'the hint of a proposal' do
    let(:ticket) { create(:ticket, organisation: organisation, project: project) }
    let(:other_ticket) { create(:ticket, organisation: organisation, project: project) }

    it 'is blanked once one source of its model call is gone, and the proposal keeps the rest' do
      hinted = proposal(hint: 'Ein Gerät aus dem Ticket.', hint_sources: [reference(ticket), reference(other_ticket)],
                        variants: ['Zorbelhub'], occurrences: 5)
      other_ticket.destroy!

      perform

      expect(hinted.reload).to have_attributes(hint: '', variants: ['Zorbelhub'], occurrences: 5, status: 'open')
      expect(hinted.hint_sources).to contain_exactly(reference(ticket), reference(other_ticket))
    end

    it 'stays while every source of its model call exists' do
      hinted = proposal(hint: 'Ein Gerät aus dem Ticket.', hint_sources: [reference(ticket), reference(other_ticket)])

      perform

      expect(hinted.reload.hint).to eq('Ein Gerät aus dem Ticket.')
    end

    it 'is blanked when its provenance is empty or unreadable: nobody can ever see it' do
      legacy = proposal(hint: 'Ein alter Hinweis.', hint_sources: [])
      malformed = proposal(hint: 'Ein kaputter Hinweis.', hint_sources: [reference(ticket)])
      malformed.update_columns(hint_sources: [{ 'source_type' => 'Ticket' }])

      perform

      expect(legacy.reload.hint).to eq('')
      expect(malformed.reload.hint).to eq('')
    end

    it 'is blanked when a source of the model call is a row of another kind with the same id' do
      note = create(:note, organisation: organisation, project: project)
      hinted = proposal(hint: 'Ein Gerät aus dem Ticket.', hint_sources: [reference(ticket)])
      hinted.update_columns(hint_sources: [{ 'source_type' => 'Note', 'source_id' => ticket.id }])
      note_hinted = proposal(term: 'Wub', hint: 'Aus der Notiz.', hint_sources: [reference(note)])

      perform

      expect(hinted.reload.hint).to eq('')
      expect(note_hinted.reload.hint).to eq('Aus der Notiz.')
    end

    it 'leaves a blank hint untouched' do
      bare = proposal(hint: '', hint_sources: [])
      bare.update_columns(updated_at: 1.day.ago)

      perform

      expect(bare.reload.updated_at).to be < 23.hours.ago
    end
  end
end
