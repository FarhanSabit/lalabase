# frozen_string_literal: true

require 'rails_helper'

# Deleting a heard form that was learnt wrong (K4a, plan §6): every correction
# of that form at this term goes, the term and its other forms stay. Review
# round 2 of #113: deleting one correction left the form learnt as long as
# another correction of it remained.
RSpec.describe Actors::DestroyHeardForm, type: :service do
  let(:organisation) { create(:organisation) }
  let(:writer) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:term) { create(:glossary_term, organisation: organisation) }
  let(:other_term) { create(:glossary_term, organisation: organisation) }

  it 'deletes every correction of the form at this term, whatever its spelling, and nothing else' do
    wrong = create(:term_correction, organisation: organisation, glossary_term: term, heard: 'lala bass')
    wrong_again = create(:term_correction, organisation: organisation, glossary_term: term, heard: 'Lala  Bass')
    right = create(:term_correction, organisation: organisation, glossary_term: term, heard: 'la la base')
    same_form_elsewhere = create(:term_correction, organisation: organisation, glossary_term: other_term, heard: 'lala bass')

    result = described_class.call(correction: wrong, current_user: writer)

    expect(result).to be_success
    expect(TermCorrection.where(id: [wrong.id, wrong_again.id])).not_to exist
    expect(TermCorrection.where(id: [right.id, same_form_elsewhere.id]).count).to eq(2)
    expect(GlossaryTerm.where(id: term.id)).to exist
  end

  it 'answers a form deleted in the meantime as gone' do
    gone = create(:term_correction, organisation: organisation, glossary_term: term, heard: 'lala bass')
    TermCorrection.where(id: gone.id).delete_all

    result = described_class.call(correction: gone, current_user: writer)

    expect(result).not_to be_success
    expect(result.code).to eq(:not_found)
    expect(result.errors).to eq([I18n.t('controllers.glossary.heard_form.not_found')])
  end

  it 'answers a term deleted in the meantime as gone, read fresh as the controller reads it' do
    correction = TermCorrection.find(create(:term_correction, organisation: organisation, glossary_term: term).id)
    GlossaryTerm.where(id: term.id).delete_all

    result = described_class.call(correction: correction, current_user: writer)

    expect(result).not_to be_success
    expect(result.code).to eq(:not_found)
  end

  it 'locks the term before it deletes' do
    correction = create(:term_correction, organisation: organisation, glossary_term: term)
    statements = []
    callback = ->(*, payload) { statements << payload[:sql] }

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      described_class.call(correction: correction, current_user: writer)
    end

    lock = statements.index { |sql| sql.include?('FROM "glossary_terms"') && sql.include?('FOR UPDATE') }
    delete = statements.index { |sql| sql.start_with?('DELETE FROM "term_corrections"') }
    expect([lock, delete]).to all(be_present)
    expect(lock).to be < delete
  end
end
