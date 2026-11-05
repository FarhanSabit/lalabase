# frozen_string_literal: true

require 'rails_helper'

# Rejecting an open heard form (K4b, E3): its proposals at that term are
# deleted, like "delete a heard form" (K4a), but only the proposals. A
# confirmed correction of the same form stays: it was confirmed by someone
# with the right and still works.
RSpec.describe Actors::RejectHeardForm, type: :service do
  let(:organisation) { create(:organisation) }
  let(:writer) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:term) { create(:glossary_term, organisation: organisation, term: 'Lalabase') }
  let(:other_term) { create(:glossary_term, organisation: organisation, term: 'Zirbel') }

  def form(heard, status:, at: term)
    create(:term_correction, organisation: organisation, glossary_term: at, heard: heard, status: status)
  end

  it 'deletes the proposals of the form at this term and keeps its confirmed corrections and everything else' do
    open = form('lala bass', status: 'proposed')
    open_again = form('Lala Bass', status: 'proposed')
    confirmed = form('lala bass', status: 'confirmed')
    other_form = form('la la base', status: 'proposed')
    elsewhere = form('lala bass', status: 'proposed', at: other_term)

    result = described_class.call(correction: open, current_user: writer)

    expect(result).to be_success
    expect(TermCorrection.where(id: [open.id, open_again.id])).not_to exist
    expect(TermCorrection.where(id: [confirmed.id, other_form.id, elsewhere.id]).count).to eq(3)
    expect(GlossaryTerm.where(id: term.id)).to exist
  end

  it 'answers a form with nothing open any more as not open' do
    confirmed = form('lala bass', status: 'confirmed')

    result = described_class.call(correction: confirmed, current_user: writer)

    expect(result.code).to eq(:not_open)
    expect(TermCorrection.where(id: confirmed.id)).to exist
  end

  it 'answers a term deleted in the meantime as gone' do
    open = TermCorrection.find(form('lala bass', status: 'proposed').id)
    GlossaryTerm.where(id: term.id).delete_all

    expect(described_class.call(correction: open, current_user: writer).code).to eq(:not_found)
  end
end
