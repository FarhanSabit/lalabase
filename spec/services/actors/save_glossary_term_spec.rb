# frozen_string_literal: true

require 'rails_helper'

# Creating and changing a glossary term by hand (K4a). Invented words only.
RSpec.describe Actors::SaveGlossaryTerm, :ci_guard, type: :service do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:writer) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def save(params, id: nil)
    described_class.call(organisation: organisation, params: params, current_user: writer, id: id)
  end

  it 'creates a confirmed term with its category and its creator' do
    result = save({ term: '  Lala  Base ', category: 'product' })

    expect(result).to be_success
    term = result.resource
    expect([term.term, term.normalized_term, term.category, term.status]).to eq(['Lala Base', 'lala base', 'product', 'confirmed'])
    expect(term.created_by).to eq(writer)
    expect(term.organisation).to eq(organisation)
  end

  it 'takes neither a status nor a creator from the params' do
    other = create(:user)
    result = save({ term: 'Lalabase', status: 'rejected', created_by_id: other.id, organisation_id: other_organisation.id })

    expect(result.resource.reload.status).to eq('confirmed')
    expect(result.resource.created_by).to eq(writer)
    expect(result.resource.organisation).to eq(organisation)
  end

  it 'changes spelling and category of a term, and keeps its status' do
    term = create(:glossary_term, :proposed, organisation: organisation, term: 'Lalabse')

    result = save({ term: 'Lalabase', category: '' }, id: term.id)

    expect(result).to be_success
    expect(term.reload.term).to eq('Lalabase')
    expect(term.category).to be_nil
    expect(term.status).to eq('proposed')
  end

  it 'refuses a spelling that is already in the glossary, with a message' do
    create(:glossary_term, organisation: organisation, term: 'Lalabase')

    result = save({ term: 'LALABASE' })

    expect(result).not_to be_success
    expect(result.code).to eq(:validation_failed)
    expect(result.errors.join).to include(I18n.t('activerecord.errors.models.glossary_term.attributes.term.taken'))
  end

  it 'refuses a rename onto another term, with a message' do
    create(:glossary_term, organisation: organisation, term: 'Lalabase')
    term = create(:glossary_term, organisation: organisation, term: 'Lala Base')

    result = save({ term: 'lalabase' }, id: term.id)

    expect(result).not_to be_success
    expect(term.reload.term).to eq('Lala Base')
  end

  it 'answers a lost race on the unique index with the same refusal' do
    allow_any_instance_of(GlossaryTerm).to receive(:term_not_taken)
    create(:glossary_term, organisation: organisation, term: 'Lalabase')

    result = save({ term: 'lalabase' })

    expect(result).not_to be_success
    expect(result.code).to eq(:validation_failed)
    expect(result.errors.join).to include(I18n.t('activerecord.errors.models.glossary_term.attributes.term.taken'))
  end

  it 'refuses an unknown category' do
    result = save({ term: 'Lalabase', category: 'planet' })

    expect(result).not_to be_success
    expect(GlossaryTerm.count).to eq(0)
  end

  # Review round 2 of #113: the update ran on a stale row and reported success.
  it 'answers a term deleted between lookup and save as gone' do
    term = create(:glossary_term, organisation: organisation, term: 'Lalabse')
    actor = described_class.new(organisation: organisation, params: { term: 'Lalabase' }, current_user: writer, id: term.id)
    GlossaryTerm.where(id: term.id).delete_all

    result = actor.call

    expect(result).not_to be_success
    expect(result.code).to eq(:not_found)
    expect(result.errors).to eq([I18n.t('controllers.glossary.not_found')])
  end

  # Review round 4 of #113: the lock reloaded the row and the form's old values
  # wrote over the newer change.
  describe 'a stale save (lock_version)' do
    let!(:term) { create(:glossary_term, organisation: organisation, term: 'Lalabse', category: 'product') }

    it 'refuses a save from a form opened before another change, and keeps that change' do
      opened_with = term.lock_version
      save({ term: 'Lalabase', lock_version: opened_with }, id: term.id)

      result = save({ term: 'Lalabse', category: 'company', lock_version: opened_with }, id: term.id)

      expect(result).not_to be_success
      expect(result.code).to eq(:stale_object)
      expect(term.reload.slice(:term, :category)).to eq('term' => 'Lalabase', 'category' => 'product')
    end

    it 'saves with the lock_version the term has now, and counts it up' do
      result = save({ category: 'company', lock_version: term.lock_version }, id: term.id)

      expect(result).to be_success
      expect(term.reload.lock_version).to eq(1)
    end

    ['', 'drei', '-1', (2**31).to_s].each do |sent|
      it "answers the lock_version #{sent.inspect} as stale, a number the column cannot hold" do
        expect(save({ term: 'Neu', lock_version: sent }, id: term.id).code).to eq(:stale_object)
        expect(term.reload.term).to eq('Lalabse')
      end
    end

    it 'takes no lock_version for a new term' do
      result = save({ term: 'Wortmarke', lock_version: '7' })

      expect(result).to be_success
      expect(result.resource.reload.lock_version).to eq(0)
    end
  end

  it 'finds no term of another organisation' do
    foreign = ActsAsTenant.with_tenant(other_organisation) { create(:glossary_term, organisation: other_organisation, term: 'Fremd') }

    result = save({ term: 'Gekapert' }, id: foreign.id)

    expect(result).not_to be_success
    expect(result.code).to eq(:not_found)
    expect(GlossaryTerm.unscoped.find(foreign.id).term).to eq('Fremd')
  end
end
