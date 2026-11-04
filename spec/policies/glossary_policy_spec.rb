# frozen_string_literal: true

require 'rails_helper'

# The glossary is a right of its own (E2): account admins without a row,
# everyone else only with view_glossary / manage_glossary, and only while the
# membership is active. Invented words only.
RSpec.describe GlossaryPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:reads) { %i[index? show?] }
  let(:all_predicates) { reads + %i[create? update? destroy? confirm? reject? merge?] }

  def role_with(*actions, billable: true, title: nil)
    role = create(:role, organisation: organisation, billable: billable, **{ title: title }.compact)
    actions.each { |action| create(:permission, role: role, category: 'glossary', action: action, allowed: true) }
    role
  end

  def member_with(role, active: true)
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: role, active: active)
    User.find(user.id)
  end

  let(:admin) { member_with(role_with(title: Role::ACCOUNT_ADMIN_TITLE)) }
  let(:viewer) { member_with(role_with('view_glossary')) }
  let(:manager) { member_with(role_with('manage_glossary')) }
  let(:nobody) { member_with(role_with) }
  let(:term) { create(:glossary_term, organisation: organisation) }

  def allowed(user, record = term)
    policy = described_class.new(user, record)
    all_predicates.select { |predicate| policy.public_send(predicate) }
  end

  it 'is the policy of terms and heard forms' do
    expect(Pundit::PolicyFinder.new(GlossaryTerm).policy).to eq(described_class)
    expect(Pundit::PolicyFinder.new(TermCorrection.new).policy).to eq(described_class)
  end

  it 'lets an account admin do everything without a permission row' do
    expect(Permission.where(category: 'glossary').exists?).to be(false)
    expect(allowed(admin)).to eq(all_predicates)
  end

  it 'lets view_glossary read, not write' do
    expect(allowed(viewer)).to eq(reads)
  end

  it 'lets manage_glossary read and write (it implies view_glossary)' do
    expect(allowed(manager)).to eq(all_predicates)
    expect(described_class.view_allowed?(manager, organisation)).to be(true)
  end

  it 'denies a member without the right' do
    expect(allowed(nobody)).to be_empty
  end

  it 'does not count the people right' do
    role = create(:role, organisation: organisation)
    %w[view_people manage_people].each do |action|
      create(:permission, role: role, category: 'people', action: action, allowed: true)
    end

    expect(allowed(member_with(role))).to be_empty
  end

  it 'lets a guest role (billable: false) with the right use it' do
    expect(allowed(member_with(role_with('view_glossary', billable: false)))).to eq(reads)
    expect(allowed(member_with(role_with('manage_glossary', billable: false)))).to eq(all_predicates)
  end

  it 'denies a deactivated member who still holds the right' do
    expect(allowed(member_with(role_with('view_glossary'), active: false))).to be_empty
    expect(allowed(member_with(role_with('manage_glossary'), active: false))).to be_empty
  end

  it 'denies a deactivated account admin' do
    expect(allowed(member_with(role_with(title: Role::ACCOUNT_ADMIN_TITLE), active: false))).to be_empty
  end

  it 'denies a member of another organisation' do
    stranger = create(:user)
    ActsAsTenant.with_tenant(other_organisation) do
      role = create(:role, organisation: other_organisation, title: Role::ACCOUNT_ADMIN_TITLE)
      create(:membership, user: stranger, organisation: other_organisation, role: role)
    end

    expect(allowed(User.find(stranger.id))).to be_empty
  end

  it 'answers no for a term or a heard form of another organisation' do
    foreign_term, foreign_correction = ActsAsTenant.with_tenant(other_organisation) do
      found = create(:glossary_term, organisation: other_organisation)
      [found, create(:term_correction, organisation: other_organisation, glossary_term: found)]
    end

    expect(allowed(admin, foreign_term)).to eq(%i[index? create?])
    expect(allowed(admin, foreign_correction)).to eq(%i[index? create?])
  end

  it 'answers for a heard form of this organisation like for its term' do
    correction = create(:term_correction, organisation: organisation, glossary_term: term)

    expect(allowed(viewer, correction)).to eq(reads)
    expect(allowed(manager, correction)).to eq(all_predicates)
  end

  describe 'Scope' do
    let!(:mine) { term }
    let!(:theirs) { ActsAsTenant.with_tenant(other_organisation) { create(:glossary_term, organisation: other_organisation) } }

    def rows(user, model = GlossaryTerm)
      described_class::Scope.new(user, model).resolve
    end

    it 'lists the terms of this organisation with the right' do
      expect(rows(viewer)).to contain_exactly(mine)
      expect(rows(manager)).to contain_exactly(mine)
      expect(rows(admin)).to contain_exactly(mine)
    end

    it 'lists the heard forms of this organisation with the right' do
      correction = create(:term_correction, organisation: organisation, glossary_term: mine)

      expect(rows(viewer, TermCorrection)).to contain_exactly(correction)
    end

    it 'lists nothing without the right' do
      expect(rows(nobody)).to be_empty
    end
  end
end
