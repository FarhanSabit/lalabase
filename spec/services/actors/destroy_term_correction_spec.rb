# frozen_string_literal: true

require 'rails_helper'

# Deleting one heard form that was learnt wrong (K4a); the term stays.
RSpec.describe Actors::DestroyTermCorrection, type: :service do
  let(:organisation) { create(:organisation) }
  let(:writer) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  it 'deletes the heard form and keeps the term and its other forms' do
    term = create(:glossary_term, organisation: organisation)
    wrong = create(:term_correction, organisation: organisation, glossary_term: term, heard: 'lala bass')
    right = create(:term_correction, organisation: organisation, glossary_term: term, heard: 'la la base')

    result = described_class.call(correction: wrong, current_user: writer)

    expect(result).to be_success
    expect(TermCorrection.where(id: wrong.id)).not_to exist
    expect(TermCorrection.where(id: right.id)).to exist
    expect(GlossaryTerm.where(id: term.id)).to exist
  end
end
