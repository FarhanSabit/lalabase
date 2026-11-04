# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RolePolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:role_with_permission) do
    role = create(:role, organisation: organisation)
    create(:permission, role: role, category: 'accounts', action: 'add_edit_delete_roles', allowed: true)
    role
  end
  let(:role_with_denied_permission) do
    role = create(:role, organisation: organisation)
    create(:permission, role: role, category: 'accounts', action: 'add_edit_delete_roles', allowed: false)
    role
  end
  let(:regular_role) { create(:role, organisation: organisation) }

  let(:admin_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: admin_role)
    user
  end
  let(:permitted_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: role_with_permission)
    user
  end
  let(:denied_permission_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: role_with_denied_permission)
    user
  end
  let(:regular_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: regular_role)
    user
  end
  let(:other_org_admin) do
    ActsAsTenant.with_tenant(other_organisation) do
      user = create(:user)
      other_admin_role = create(:admin_role, organisation: other_organisation)
      create(:membership, user: user, organisation: other_organisation, role: other_admin_role)
      user
    end
  end
  let(:user_without_membership) { create(:user) }
  let(:user_without_role) do
    user = create(:user)
    membership = create(:membership, user: user, organisation: organisation, role: regular_role)
    membership.update_column(:role_id, nil)
    user
  end

  let(:target_role) { create(:role, title: 'custom_role', organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  # ── Unauthenticated user ──────────────────────────────────────────

  describe 'unauthenticated access' do
    it 'raises Pundit::NotAuthorizedError when user is nil' do
      expect { described_class.new(nil, target_role) }.to raise_error(Pundit::NotAuthorizedError)
    end

    it 'raises Pundit::NotAuthorizedError for Scope when user is nil' do
      expect { described_class::Scope.new(nil, Role) }.to raise_error(Pundit::NotAuthorizedError)
    end
  end

  # ── Standard CRUD actions ─────────────────────────────────────────

  describe 'standard CRUD actions' do
    %i[index? show? create? set_default?].each do |action|
      describe "##{action}" do
        it 'grants access to account admins' do
          expect(described_class.new(admin_user, target_role).public_send(action)).to be true
        end

        it 'grants access to users with add_edit_delete_roles permission' do
          expect(described_class.new(permitted_user, target_role).public_send(action)).to be true
        end

        it 'denies access to users without permission' do
          expect(described_class.new(regular_user, target_role).public_send(action)).to be false
        end

        it 'denies access when permission exists but allowed is false' do
          expect(described_class.new(denied_permission_user, target_role).public_send(action)).to be false
        end

        it 'denies access to admin of a different organisation' do
          expect(described_class.new(other_org_admin, target_role).public_send(action)).to be false
        end

        it 'denies access to user without membership in the organisation' do
          expect(described_class.new(user_without_membership, target_role).public_send(action)).to be false
        end

        it 'denies access to user with membership but no role' do
          expect(described_class.new(user_without_role, target_role).public_send(action)).to be false
        end
      end
    end
  end

  # ── Delegation: new? → create?, edit? → update? ──────────────────

  describe 'action delegation' do
    it 'new? delegates to create?' do
      policy = described_class.new(admin_user, target_role)
      expect(policy.new?).to eq(policy.create?)
    end

    it 'new? is denied for unpermitted users same as create?' do
      policy = described_class.new(regular_user, target_role)
      expect(policy.new?).to eq(policy.create?)
      expect(policy.new?).to be false
    end

    it 'edit? delegates to update?' do
      policy = described_class.new(admin_user, target_role)
      expect(policy.edit?).to eq(policy.update?)
    end

    it 'edit? is denied for unpermitted users same as update?' do
      policy = described_class.new(regular_user, target_role)
      expect(policy.edit?).to eq(policy.update?)
      expect(policy.edit?).to be false
    end
  end

  # ── update? ───────────────────────────────────────────────────────

  describe '#update?' do
    context 'with a regular role' do
      it 'grants access to account admins' do
        expect(described_class.new(admin_user, target_role).update?).to be true
      end

      it 'grants access to users with permission' do
        expect(described_class.new(permitted_user, target_role).update?).to be true
      end

      it 'denies access to users without permission' do
        expect(described_class.new(regular_user, target_role).update?).to be false
      end

      it 'denies access when permission allowed is false' do
        expect(described_class.new(denied_permission_user, target_role).update?).to be false
      end

      it 'denies access to admin of a different organisation' do
        expect(described_class.new(other_org_admin, target_role).update?).to be false
      end
    end

    context 'with the account_admin role' do
      let(:account_admin_role_record) { admin_role }

      it 'grants access to account admins' do
        expect(described_class.new(admin_user, account_admin_role_record).update?).to be true
      end

      it 'denies access to users with permission but not account admin' do
        expect(described_class.new(permitted_user, account_admin_role_record).update?).to be false
      end

      it 'denies access to users without permission' do
        expect(described_class.new(regular_user, account_admin_role_record).update?).to be false
      end

      it 'denies access to admin of a different organisation' do
        expect(described_class.new(other_org_admin, account_admin_role_record).update?).to be false
      end
    end
  end

  # ── destroy? ──────────────────────────────────────────────────────

  describe '#destroy?' do
    context 'with a regular role' do
      it 'grants access to account admins' do
        expect(described_class.new(admin_user, target_role).destroy?).to be true
      end

      it 'grants access to users with permission' do
        expect(described_class.new(permitted_user, target_role).destroy?).to be true
      end

      it 'denies access to users without permission' do
        expect(described_class.new(regular_user, target_role).destroy?).to be false
      end

      it 'denies access when permission allowed is false' do
        expect(described_class.new(denied_permission_user, target_role).destroy?).to be false
      end

      it 'denies access to admin of a different organisation' do
        expect(described_class.new(other_org_admin, target_role).destroy?).to be false
      end
    end

    context 'with the account_admin role' do
      let(:account_admin_role_record) { admin_role }

      it 'denies access even to account admins' do
        expect(described_class.new(admin_user, account_admin_role_record).destroy?).to be false
      end

      it 'denies access to users with permission' do
        expect(described_class.new(permitted_user, account_admin_role_record).destroy?).to be false
      end

      it 'denies access to users without permission' do
        expect(described_class.new(regular_user, account_admin_role_record).destroy?).to be false
      end
    end
  end

  # ── Scope ─────────────────────────────────────────────────────────

  describe 'Scope' do
    let!(:role_a) { create(:role, title: 'role_a', organisation: organisation) }
    let!(:role_b) { create(:role, title: 'role_b', organisation: organisation) }
    let!(:other_org_role) do
      ActsAsTenant.without_tenant { create(:role, title: 'other_org_role', organisation: other_organisation) }
    end

    it 'returns all roles for account admins' do
      scope = described_class::Scope.new(admin_user, Role).resolve
      expect(scope).to include(role_a, role_b)
    end

    it 'returns all roles for users with permission' do
      scope = described_class::Scope.new(permitted_user, Role).resolve
      expect(scope).to include(role_a, role_b)
    end

    it 'returns no roles for users without permission' do
      scope = described_class::Scope.new(regular_user, Role).resolve
      expect(scope).to be_empty
    end

    it 'returns no roles for users with denied permission' do
      scope = described_class::Scope.new(denied_permission_user, Role).resolve
      expect(scope).to be_empty
    end

    it 'returns no roles for admin of a different organisation' do
      scope = described_class::Scope.new(other_org_admin, Role).resolve
      expect(scope).to be_empty
    end

    it 'returns no roles for user without membership' do
      scope = described_class::Scope.new(user_without_membership, Role).resolve
      expect(scope).to be_empty
    end

    it 'does not include roles from other organisations' do
      scope = described_class::Scope.new(admin_user, Role).resolve
      expect(scope).not_to include(other_org_role)
    end
  end

  # ── Guest-Ceiling Governance (D10) ──────────────────────────────────

  describe '#update_billable?' do
    let(:account_owner) do
      user = create(:user)
      organisation.account.update!(owner: user)
      user
    end

    it 'grants access to the account owner' do
      expect(described_class.new(account_owner, target_role).update_billable?).to be true
    end

    # [CRITICAL] D10: editing roles is a standard org-admin right, but billable
    # must stay a cost lever only the Account-Owner controls -- otherwise any
    # org-admin could set every role to billable: false and self-serve a
    # free tier.
    it 'denies access to account admins who are not the account owner' do
      expect(described_class.new(admin_user, target_role).update_billable?).to be false
    end

    it 'denies access to users with the general add_edit_delete_roles permission' do
      expect(described_class.new(permitted_user, target_role).update_billable?).to be false
    end

    it 'denies access to regular users' do
      expect(described_class.new(regular_user, target_role).update_billable?).to be false
    end

    # Deploy-window state (account_id still NULL before `rails
    # accounts:backfill` has run): the organisation&.account guard must
    # degrade to a plain false, never raise on the missing account.
    it 'returns false (rather than raising) when the organisation has no account yet' do
      user = admin_user # materialize before detaching the account
      organisation.update_column(:account_id, nil)
      organisation.reload

      expect(described_class.new(user, target_role).update_billable?).to be false
    end
  end

  # Review of S1 (28.10.2026): manage_people includes view_people
  # (Permission::IMPLIED_BY), so a role editor holding it may grant both.
  describe '#change_permission?' do
    def editor_with(*rights)
      role = create(:role, organisation: organisation)
      create(:permission, role: role, category: 'accounts', action: 'add_edit_delete_roles', allowed: true)
      rights.each { |category, action| create(:permission, role: role, category: category, action: action, allowed: true) }
      user = create(:user)
      create(:membership, user: user, organisation: organisation, role: role)
      User.find(user.id)
    end

    def may_change?(user, category, action)
      ActsAsTenant.with_tenant(organisation) { described_class.new(user, regular_role).change_permission?(category, action) }
    end

    it 'lets an editor with manage_people change view_people too' do
      editor = editor_with(%w[people manage_people])

      expect(may_change?(editor, 'people', 'view_people')).to be(true)
      expect(may_change?(editor, 'people', 'manage_people')).to be(true)
    end

    it 'does not turn view_people into manage_people' do
      editor = editor_with(%w[people view_people])

      expect(may_change?(editor, 'people', 'view_people')).to be(true)
      expect(may_change?(editor, 'people', 'manage_people')).to be(false)
    end

    # The glossary (K4a) follows the same rule through the same table.
    it 'lets an editor with manage_glossary change view_glossary too' do
      editor = editor_with(%w[glossary manage_glossary])

      expect(may_change?(editor, 'glossary', 'view_glossary')).to be(true)
      expect(may_change?(editor, 'glossary', 'manage_glossary')).to be(true)
    end

    it 'does not turn view_glossary into manage_glossary' do
      editor = editor_with(%w[glossary view_glossary])

      expect(may_change?(editor, 'glossary', 'view_glossary')).to be(true)
      expect(may_change?(editor, 'glossary', 'manage_glossary')).to be(false)
    end
  end
end
