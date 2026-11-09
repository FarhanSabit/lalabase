# frozen_string_literal: true

require 'rails_helper'

# Merging two terms of the glossary (K4a, plan §6): the heard forms move to
# the target, the source goes; never a term into itself, never across
# organisations. Invented words and names only.
RSpec.describe Actors::MergeGlossaryTerms, :ci_guard, type: :service do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:writer) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:project) { create(:project, organisation: organisation) }
  let(:person) { create(:person, organisation: organisation) }
  let(:source) { create(:glossary_term, organisation: organisation, term: 'Lala Base', category: 'domain') }
  let(:target) { create(:glossary_term, :proposed, organisation: organisation, term: 'Lalabase', category: 'product') }

  def merge(from = source, into = target)
    described_class.call(source: from, target: into, current_user: writer)
  end

  # K4d: the trace of where a device applied the source goes along; its spelling stays as sent.
  it 'moves the applications of the source to the target and keeps their spelling' do
    meeting = create(:meeting, organisation: organisation, project: project, creator: writer)
    moved = create(:term_application, organisation: organisation, meeting: meeting, glossary_term: source, heard: 'lala bass')
    own = create(:term_application, organisation: organisation, meeting: meeting, glossary_term: target, heard: 'lalabas')

    expect(merge).to be_success
    expect(target.term_applications.reload).to contain_exactly(moved, own)
    expect(moved.reload.term).to eq('Lala Base')
  end

  it 'moves every heard form of the source to the target, with speaker, project and place' do
    moved = create(:term_correction, organisation: organisation, glossary_term: source, heard: 'lala bass', project: project,
                                     person: person, line_index: 2, char_offset: 5)
    second = create(:term_correction, organisation: organisation, glossary_term: source, heard: 'la la base')
    own = create(:term_correction, organisation: organisation, glossary_term: target, heard: 'lalabas')

    result = merge

    expect(result).to be_success
    expect(result.resource).to eq(target)
    expect(target.term_corrections.reload).to contain_exactly(moved, second, own)
    moved.reload
    expect([moved.heard, moved.project_id, moved.person_id, moved.line_index, moved.char_offset])
      .to eq(['lala bass', project.id, person.id, 2, 5])
  end

  # Review round 2 of #129. An accepted proposal names the term it became or
  # was merged into (K5b); the source going would leave it naming none (the
  # foreign key clears it), so it names the target from now on.
  it 'moves the proposals accepted into the source to the target' do
    moved = create(:glossary_proposal, :accepted, organisation: organisation, term: 'Zorbel-Hub', glossary_term: source)
    own = create(:glossary_proposal, :accepted, organisation: organisation, term: 'Quarnix', glossary_term: target)
    open = create(:glossary_proposal, organisation: organisation, term: 'Wubbel')

    expect(merge).to be_success

    expect(moved.reload).to have_attributes(status: 'accepted', glossary_term_id: target.id)
    expect(own.reload.glossary_term_id).to eq(target.id)
    expect(open.reload).to have_attributes(status: 'open', glossary_term_id: nil)
  end

  it 'deletes the source and keeps spelling, category and status of the target' do
    merge

    expect(GlossaryTerm.where(id: source.id)).not_to exist
    target.reload
    expect([target.term, target.category, target.status]).to eq(%w[Lalabase product proposed])
  end

  it 'refuses a term into itself and changes nothing' do
    create(:term_correction, organisation: organisation, glossary_term: source)

    result = merge(source, source)

    expect(result).not_to be_success
    expect(result.code).to eq(:same_term)
    expect(result.errors.join).to eq(I18n.t('controllers.glossary.merge.same_term'))
    expect(source.reload.term_corrections.count).to eq(1)
  end

  it 'refuses a term of another organisation and changes nothing' do
    create(:term_correction, organisation: organisation, glossary_term: source)
    foreign = ActsAsTenant.with_tenant(other_organisation) { create(:glossary_term, organisation: other_organisation) }

    result = merge(source, foreign)

    expect(result).not_to be_success
    expect(result.code).to eq(:other_glossary)
    expect(GlossaryTerm.where(id: source.id)).to exist
    expect(TermCorrection.unscoped.where(glossary_term_id: foreign.id)).not_to exist
  end

  it 'refuses a target deleted in the meantime' do
    create(:term_correction, organisation: organisation, glossary_term: source)
    gone = target
    GlossaryTerm.where(id: gone.id).delete_all

    result = merge(source, gone)

    expect(result).not_to be_success
    expect(result.code).to eq(:not_found)
    expect(source.reload.term_corrections.count).to eq(1)
  end

  # Review round 4 of #113 (optional): the other half of lock_both's check.
  it 'refuses a source deleted in the meantime, and the target keeps its heard forms' do
    kept = create(:term_correction, organisation: organisation, glossary_term: target)
    gone = source
    GlossaryTerm.where(id: gone.id).delete_all

    result = merge(gone, target)

    expect(result).not_to be_success
    expect(result.code).to eq(:not_found)
    expect(target.reload.term_corrections).to contain_exactly(kept)
  end

  # The one lock order of the glossary (Glossary::TermLock): rows in the order
  # of their ids, in one statement, before any heard form moves.
  it 'locks both terms in one statement ordered by id, before it moves anything' do
    create(:term_correction, organisation: organisation, glossary_term: source)
    statements = []
    callback = ->(*, payload) { statements << payload[:sql] }

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      merge
    end

    lock = statements.index { |sql| sql.include?('FROM "glossary_terms"') && sql.include?('FOR UPDATE') }
    move = statements.index { |sql| sql.start_with?('UPDATE "term_corrections"') }
    # The term before the proposal, the one lock order of the glossary.
    proposals = statements.index { |sql| sql.start_with?('UPDATE "glossary_proposals"') }
    expect([lock, move, proposals]).to all(be_present)
    expect(statements[lock]).to include('ORDER BY "glossary_terms"."id"')
    expect(lock).to be < move
    expect(lock).to be < proposals
  end
end
