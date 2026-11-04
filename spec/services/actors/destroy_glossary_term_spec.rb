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
end
