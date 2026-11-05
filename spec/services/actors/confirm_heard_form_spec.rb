# frozen_string_literal: true

require 'rails_helper'

# Confirming an open heard form (K4b, E3): the proposals of that form at that
# term become confirmed, so they work from now on (TermCorrection.effective).
# Nothing else changes: the term keeps its status, other forms stay open.
RSpec.describe Actors::ConfirmHeardForm, type: :service do
  let(:organisation) { create(:organisation) }
  let(:writer) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:term) { create(:glossary_term, organisation: organisation, term: 'Lalabase') }
  let(:other_term) { create(:glossary_term, organisation: organisation, term: 'Zirbel') }

  def form(heard, status:, at: term)
    create(:term_correction, organisation: organisation, glossary_term: at, heard: heard, status: status)
  end

  it 'confirms every proposal of the form at this term, whatever its spelling, and nothing else' do
    open = form('lala bass', status: 'proposed')
    open_again = form('Lala  Bass', status: 'proposed')
    other_form = form('la la base', status: 'proposed')
    elsewhere = form('lala bass', status: 'proposed', at: other_term)

    result = described_class.call(correction: open, current_user: writer)

    expect(result).to be_success
    expect(TermCorrection.where(id: [open.id, open_again.id]).pluck(:status)).to eq(%w[confirmed confirmed])
    expect(TermCorrection.where(id: [other_form.id, elsewhere.id]).pluck(:status)).to eq(%w[proposed proposed])
    expect(term.reload).to be_confirmed
  end

  it 'makes the form work at a confirmed term' do
    open = form('lala bass', status: 'proposed')

    expect { described_class.call(correction: open, current_user: writer) }
      .to change { TermCorrection.effective.where(id: open.id).exists? }.from(false).to(true)
  end

  it 'answers a form with nothing open any more as not open' do
    confirmed = form('lala bass', status: 'confirmed')

    result = described_class.call(correction: confirmed, current_user: writer)

    expect(result.code).to eq(:not_open)
    expect(result.errors).to eq([I18n.t('controllers.glossary.heard_form.not_open')])
  end

  it 'answers a term deleted in the meantime as gone' do
    open = TermCorrection.find(form('lala bass', status: 'proposed').id)
    GlossaryTerm.where(id: term.id).delete_all

    expect(described_class.call(correction: open, current_user: writer).code).to eq(:not_found)
  end

  it 'locks the term before it changes the form' do
    open = form('lala bass', status: 'proposed')
    expect(Glossary::TermLock).to receive(:call).with(term: open.glossary_term).ordered.and_call_original
    expect(TermCorrection).to receive(:where).ordered.and_call_original

    described_class.call(correction: open, current_user: writer)
  end
end
