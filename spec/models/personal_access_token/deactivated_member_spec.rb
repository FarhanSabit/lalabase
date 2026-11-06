# frozen_string_literal: true

require 'rails_helper'

# What: PersonalAccessToken#deactivated_member_of?, whether a token names an organisation (a
#   link, or with all_organisations every organisation of its owner) while the owner's
#   membership there is deactivated (K4c).
# Why: such an organisation is outside the reach (#organisation_scopes counts ACTIVE memberships
#   only) and stays so: the predicate opens nothing. It only lets a door refuse it as the missing
#   right of an inactive member (the glossary's 403) instead of answering "not found", for an
#   organisation the holder knows anyway. A removed membership and an organisation the token does
#   not name are no inactive membership of the token: they stay "not found".
RSpec.describe PersonalAccessToken, :ci_guard, type: :model do
  let(:user) { create(:user) }
  let(:org_a) { create(:organisation) }
  let(:org_b) { create(:organisation) }

  def member(org, active: true)
    ActsAsTenant.with_tenant(org) { create(:membership, user: user, organisation: org, active: active) }
  end

  def membership(org)
    ActsAsTenant.with_tenant(org) { Membership.find_by!(user: user, organisation: org) }
  end

  # A fresh instance, as the next request would load it: #reach is memoised per instance.
  def reloaded(token)
    described_class.find(token.id)
  end

  before do
    Prosopite.pause do
      member(org_a)
      member(org_b)
    end
  end

  context 'with organisation links' do
    let(:token) { create(:personal_access_token, user: user, organisations: [org_a]) }

    it 'is false while the membership is active, when the token reaches the organisation' do
      expect(token.deactivated_member_of?(org_a.id)).to be false
      expect(token.reach.organisation?(org_a.id)).to be true
    end

    it 'is true once the membership of a named organisation is deactivated, which the reach leaves out' do
      token
      ActsAsTenant.with_tenant(org_a) { membership(org_a).update!(active: false) }

      expect(reloaded(token).deactivated_member_of?(org_a.id)).to be true
      expect(reloaded(token).reach.organisation?(org_a.id)).to be false
    end

    it 'is true for a token limited to some projects of that organisation as well' do
      project = ActsAsTenant.with_tenant(org_a) { create(:project, organisation: org_a) }
      limited = create(:personal_access_token, user: user, organisations: [org_a], project_scopes: { org_a => [project] })
      ActsAsTenant.with_tenant(org_a) { membership(org_a).update!(active: false) }

      expect(reloaded(limited).deactivated_member_of?(org_a.id)).to be true
    end

    it 'is false for an organisation the token does not name, deactivated or not' do
      token
      ActsAsTenant.with_tenant(org_b) { membership(org_b).update!(active: false) }

      expect(reloaded(token).deactivated_member_of?(org_b.id)).to be false
    end

    it 'is false once the membership is removed: no membership, nothing inactive' do
      token
      Prosopite.pause { ActsAsTenant.with_tenant(org_a) { membership(org_a).destroy! } }

      expect(reloaded(token).deactivated_member_of?(org_a.id)).to be false
    end
  end

  context 'with all_organisations' do
    let(:token) { create(:personal_access_token, :all_organisations, user: user) }

    it 'is true for every organisation where the owner is a deactivated member, false elsewhere' do
      token
      ActsAsTenant.with_tenant(org_b) { membership(org_b).update!(active: false) }
      foreign = create(:organisation)

      expect(reloaded(token).deactivated_member_of?(org_b.id)).to be true
      expect(reloaded(token).deactivated_member_of?(org_a.id)).to be false
      expect(reloaded(token).deactivated_member_of?(foreign.id)).to be false
    end
  end

  it 'is false for a blank or missing id' do
    token = create(:personal_access_token, user: user, organisations: [org_a])

    expect(token.deactivated_member_of?(nil)).to be false
    expect(token.deactivated_member_of?('')).to be false
    expect(token.deactivated_member_of?(SecureRandom.uuid)).to be false
  end
end
