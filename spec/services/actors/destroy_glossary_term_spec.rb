# frozen_string_literal: true

require 'rails_helper'

# Deleting a glossary term takes its heard forms along (K4a, plan §3.3).
RSpec.describe Actors::DestroyGlossaryTerm, type: :service do
  let(:organisation) { create(:organisation) }
  let(:writer) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  it 'deletes the term and its heard forms, and no other term' do
    term = create(:glossary_term, organisation: organisation)
    correction = create(:term_correction, organisation: organisation, glossary_term: term)
    other = create(:glossary_term, organisation: organisation)
    kept = create(:term_correction, organisation: organisation, glossary_term: other)

    result = described_class.call(term: term, current_user: writer)

    expect(result).to be_success
    expect(GlossaryTerm.where(id: term.id)).not_to exist
    expect(TermCorrection.where(id: correction.id)).not_to exist
    expect(TermCorrection.where(id: kept.id)).to exist
  end

  # Review round 1 of #113: a delete and a merge of the same term at once must
  # take their locks in the same order (the term first), or they deadlock:
  # the delete held the heard forms and waited for the term the merge held.
  it 'locks the term before it deletes the heard forms' do
    term = create(:glossary_term, organisation: organisation)
    create(:term_correction, organisation: organisation, glossary_term: term)
    statements = []
    callback = ->(*, payload) { statements << payload[:sql] }

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      described_class.call(term: term, current_user: writer)
    end

    lock = statements.index { |sql| sql.include?('FROM "glossary_terms"') && sql.include?('FOR UPDATE') }
    delete = statements.index { |sql| sql.start_with?('DELETE FROM "term_corrections"') }
    expect(lock).not_to be_nil
    expect(delete).not_to be_nil
    expect(lock).to be < delete
  end

  it 'answers a term deleted in the meantime as gone' do
    term = create(:glossary_term, organisation: organisation)
    GlossaryTerm.where(id: term.id).delete_all

    result = described_class.call(term: term, current_user: writer)

    expect(result).not_to be_success
    expect(result.code).to eq(:not_found)
    expect(result.errors).to eq([I18n.t('controllers.glossary.not_found')])
  end
end
