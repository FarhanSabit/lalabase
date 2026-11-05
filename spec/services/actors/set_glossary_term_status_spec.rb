# frozen_string_literal: true

require 'rails_helper'

# Confirming and rejecting a glossary term (K4a, E5).
RSpec.describe Actors::SetGlossaryTermStatus, type: :service do
  let(:organisation) { create(:organisation) }
  let(:writer) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:term) { create(:glossary_term, :proposed, organisation: organisation) }

  it 'confirms a proposal' do
    expect(described_class.call(term: term, status: 'confirmed', current_user: writer)).to be_success
    expect(term.reload.status).to eq('confirmed')
  end

  it 'rejects a proposal and can confirm it again later' do
    described_class.call(term: term, status: 'rejected', current_user: writer)
    expect(term.reload.status).to eq('rejected')

    described_class.call(term: term, status: 'confirmed', current_user: writer)
    expect(term.reload.status).to eq('confirmed')
  end

  # K4b (E3): a proposed term came with its heard forms, proposed alike, and
  # the one who confirms it sees them in the lane. Rejecting leaves the forms
  # (they work nowhere at a rejected term anyway); a term confirmed again
  # later keeps what is open.
  describe 'the open heard forms' do
    let!(:open_form) { create(:term_correction, organisation: organisation, glossary_term: term, heard: 'lala bass', status: 'proposed') }

    it 'are confirmed with the proposal they came with' do
      described_class.call(term: term, status: 'confirmed', current_user: writer)

      expect(open_form.reload).to be_confirmed
    end

    it 'stay open when the term is rejected, and when a rejected term is confirmed' do
      described_class.call(term: term, status: 'rejected', current_user: writer)
      expect(open_form.reload).to be_proposed

      described_class.call(term: term, status: 'confirmed', current_user: writer)
      expect(open_form.reload).to be_proposed
    end

    it 'of another term stay open' do
      other = create(:glossary_term, :proposed, organisation: organisation, term: 'Zirbel')
      elsewhere = create(:term_correction, organisation: organisation, glossary_term: other, heard: 'zirbel holz', status: 'proposed')

      described_class.call(term: term, status: 'confirmed', current_user: writer)

      expect(elsewhere.reload).to be_proposed
    end
  end

  it 'never proposes, and refuses any other value' do
    confirmed = create(:glossary_term, organisation: organisation)

    %w[proposed maybe].each do |status|
      result = described_class.call(term: confirmed, status: status, current_user: writer)

      expect(result).not_to be_success
      expect(result.code).to eq(:invalid_status)
    end
    expect(confirmed.reload.status).to eq('confirmed')
  end

  # Review round 2 of #113: the update ran on a stale row and reported success.
  it 'answers a term deleted in the meantime as gone' do
    GlossaryTerm.where(id: term.id).delete_all

    result = described_class.call(term: term, status: 'confirmed', current_user: writer)

    expect(result).not_to be_success
    expect(result.code).to eq(:not_found)
  end

  it 'locks the term before it changes it' do
    statements = []
    callback = ->(*, payload) { statements << payload[:sql] }

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      described_class.call(term: term, status: 'confirmed', current_user: writer)
    end

    lock = statements.index { |sql| sql.include?('FROM "glossary_terms"') && sql.include?('FOR UPDATE') }
    update = statements.index { |sql| sql.start_with?('UPDATE "glossary_terms"') }
    expect([lock, update]).to all(be_present)
    expect(lock).to be < update
  end
end
