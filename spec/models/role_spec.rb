# frozen_string_literal: true

# == Schema Information
#
# Table name: roles
#
#  id              :uuid             not null, primary key
#  billable        :boolean          default(TRUE), not null
#  description     :text
#  is_default      :boolean          default(FALSE)
#  title           :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#
# Indexes
#
#  index_roles_on_organisation_id_and_title  (organisation_id,title) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#
require 'rails_helper'

RSpec.describe Role, type: :model do
  let(:organisation) { create(:organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  describe 'validations' do
    it { should validate_presence_of(:title) }

    it 'validates uniqueness of title scoped to organisation_id' do
      create(:role, title: 'Unique Role')
      duplicate_role = build(:role, title: 'Unique Role')
      expect(duplicate_role).not_to be_valid
      expect(duplicate_role.errors[:title]).to be_present
    end
  end

  describe '#billable (Plan doc/billing_agentur_konto_plan.md §5)' do
    it 'defaults to true for newly created roles' do
      role = create(:role)

      expect(role.billable).to be true
    end

    it 'can be explicitly set to false (Gast-/Kunden-Rolle)' do
      role = create(:role, billable: false)

      expect(role.billable).to be false
    end
  end

  # [CRITICAL] Guest-Ceiling Verbotsliste (Plan doc/billing_agentur_konto_plan.md
  # §4.3, Fund F2) -- the only remaining HARD, blocking rule from §4.3.
  describe 'Verbotsliste: billable: false forbidden combinations' do
    it 'rejects the account_admin title with billable: false' do
      role = build(:role, title: Role::ACCOUNT_ADMIN_TITLE, billable: false)

      expect(role).not_to be_valid
      expect(role.errors[:billable]).to be_present
    end

    it 'allows the account_admin title with billable: true (default)' do
      role = build(:role, title: Role::ACCOUNT_ADMIN_TITLE, billable: true)

      expect(role).to be_valid
    end

    it 'rejects flipping an existing role to billable: false while it has an accounts-category permission' do
      role = create(:role, billable: true)
      create(:permission, role: role, category: 'accounts', action: 'manage_users', allowed: true)

      role.billable = false

      expect(role).not_to be_valid
      expect(role.errors[:billable]).to be_present
    end

    it 'rejects flipping an existing role to billable: false while it has a projects-category permission' do
      role = create(:role, billable: true)
      create(:permission, role: role, category: 'projects', action: 'create_new_projects', allowed: true)

      role.billable = false

      expect(role).not_to be_valid
      expect(role.errors[:billable]).to be_present
    end

    it 'rejects flipping an existing role to billable: false while it has an *_all_projects permission' do
      role = create(:role, billable: true)
      create(:permission, role: role, category: 'projects',
                          action: 'read_access_tickets_all_projects', allowed: true)

      role.billable = false

      expect(role).not_to be_valid
    end

    it 'allows billable: false when only tickets/users-category permissions are present' do
      role = create(:role, billable: true)
      create(:permission, role: role, category: 'tickets', action: 'delete_tickets', allowed: true)

      role.billable = false

      expect(role).to be_valid
    end

    it 'allows billable: false with people-category permissions (customer roles keep the list)' do
      role = create(:role, billable: true)
      create(:permission, role: role, category: 'people', action: 'view_people', allowed: true)
      create(:permission, role: role, category: 'people', action: 'manage_people', allowed: true)

      role.billable = false

      expect(role).to be_valid
    end

    it 'allows billable: false with glossary-category permissions (the admin decides for guest roles)' do
      role = create(:role, billable: true)
      create(:permission, role: role, category: 'glossary', action: 'view_glossary', allowed: true)
      create(:permission, role: role, category: 'glossary', action: 'manage_glossary', allowed: true)

      role.billable = false

      expect(role).to be_valid
    end

    it 'does not block a non-billable role with no forbidden permissions' do
      role = build(:role, billable: false)

      expect(role).to be_valid
    end
  end

  describe 'associations' do
    # Organisation association is handled by acts_as_tenant
    it 'belongs to organisation through acts_as_tenant' do
      expect(Role.reflect_on_association(:organisation)).to be_present
    end
    it { should have_many(:permissions).dependent(:destroy) }
    it { should have_many(:memberships).dependent(:nullify) }
    it { should have_many(:users).through(:memberships) }

    it 'creates a regular role with expected attributes' do
      role = create(:role, title: 'Project Manager', description: 'Manages projects', is_default: false)
      expect(role.title).to eq('Project Manager')
      expect(role.description).to eq('Manages projects')
      expect(role.is_default).to be false
      expect(role.organisation).to eq(organisation)
    end

    it 'creates an admin role with the admin_role factory' do
      admin = create(:admin_role)
      expect(admin.title).to eq('account_admin')
      expect(admin.description).to eq('Administrator mit vollen Zugriffsrechten')
      expect(admin.account_admin?).to be true
    end
  end

  describe 'scopes' do
    it '.default_roles returns only default roles' do
      default_role = create(:role, is_default: true)
      non_default_role = create(:role, is_default: false)

      expect(Role.default_roles).to include(default_role)
      expect(Role.default_roles).not_to include(non_default_role)
    end
  end

  describe 'instance methods' do
    describe '#account_admin?' do
      it 'returns true for account_admin roles' do
        admin_role = create(:role, title: 'account_admin')
        expect(admin_role.account_admin?).to be true
      end

      it 'returns false for non-admin roles' do
        regular_role = create(:role, title: 'regular_user')
        expect(regular_role.account_admin?).to be false
      end
    end

    describe '#has_permission?' do
      let(:role) { create(:role, organisation: organisation) }
      let(:admin_role) { create(:admin_role, organisation: organisation) }

      it 'returns true if the role has the specific permission' do
        create(:permission, role: role, category: 'projects', action: 'create_new_projects', allowed: true)

        expect(role.has_permission?('projects', 'create_new_projects')).to be true
      end

      it 'returns false if the role does not have the specific permission' do
        expect(role.has_permission?('projects', 'create_new_projects')).to be false
      end

      it 'returns false if the permission exists but is not allowed' do
        create(:permission, role: role, category: 'projects', action: 'create_new_projects', allowed: false)

        expect(role.has_permission?('projects', 'create_new_projects')).to be false
      end

      it 'returns true for any permission if the role is account_admin' do
        expect(admin_role.has_permission?('any_category', 'any_action')).to be true
      end
    end
  end

  describe 'class methods' do
    describe '.find_or_create_account_admin' do
      it 'finds an existing account_admin role' do
        admin_role = create(:admin_role)

        found_role = Role.find_or_create_account_admin(organisation)
        expect(found_role).to eq(admin_role)
        expect(Role.count).to eq(1)
      end

      it 'creates an account_admin role if none exists' do
        expect do
          Role.find_or_create_account_admin(organisation)
        end.to change(Role, :count).by(1)

        admin_role = Role.find_by(title: 'account_admin')
        expect(admin_role).to be_present
        expect(admin_role.description).to eq('Administrator mit vollen Zugriffsrechten')
      end
    end

    describe '.default_for_organisation' do
      it 'returns the default role for an organisation' do
        default_role = create(:role, title: 'Default Role', is_default: true)
        create(:role, title: 'Non-Default Role', is_default: false)

        expect(Role.default_for_organisation(organisation)).to eq(default_role)
      end

      it 'returns nil if no default role exists' do
        create(:role, is_default: false)

        expect(Role.default_for_organisation(organisation)).to be_nil
      end
    end
  end

  describe 'multi-tenant behavior' do
    it 'scopes roles to the current organisation' do
      org1 = create(:organisation)
      org2 = create(:organisation)

      role1 = nil
      role2 = nil

      ActsAsTenant.with_tenant(org1) do
        role1 = create(:role, title: 'Role for Org1')
        expect(Role.count).to eq(1)
        expect(Role.first.title).to eq('Role for Org1')
      end

      ActsAsTenant.with_tenant(org2) do
        role2 = create(:role, title: 'Role for Org2')
        expect(Role.count).to eq(1)
        expect(Role.first.title).to eq('Role for Org2')
      end

      # Verify both roles exist in the database
      expect(Role.unscoped.count).to eq(2)
    end

    it 'allows roles with the same title in different organisations' do
      org1 = create(:organisation)
      org2 = create(:organisation)

      role1 = nil
      role2 = nil

      ActsAsTenant.with_tenant(org1) do
        role1 = create(:role, title: 'Project Manager')
      end

      ActsAsTenant.with_tenant(org2) do
        role2 = create(:role, title: 'Project Manager')
      end

      expect(role1).to be_valid
      expect(role2).to be_valid
      expect(role1.title).to eq(role2.title)
      expect(role1.organisation_id).not_to eq(role2.organisation_id)
    end
  end

  describe 'integration with permissions' do
    let(:role) { create(:role, organisation: organisation) }

    it 'can have multiple permissions' do
      create(:permission, role: role, category: 'projects', action: 'create_new_projects')
      create(:permission, role: role, category: 'projects', action: 'change_project_properties')
      create(:permission, role: role, category: 'tickets', action: 'delete_tickets')

      expect(role.permissions.count).to eq(3)
      expect(role.permissions.pluck(:category).uniq.sort).to eq(%w[projects tickets])
      expect(role.permissions.where(category: 'projects').count).to eq(2)
    end

    it 'deletes associated permissions when destroyed' do
      create(:permission, role: role, category: 'projects', action: 'create_new_projects')
      create(:permission, role: role, category: 'tickets', action: 'delete_tickets')

      expect do
        role.destroy
      end.to change(Permission, :count).by(-2)
    end
  end

  describe 'integration with memberships' do
    let(:role) { create(:role, organisation: organisation) }
    let(:user) { create(:user) }

    it 'can have multiple users through memberships' do
      user1 = create(:user)
      user2 = create(:user)

      create(:membership, user: user1, role: role, organisation: organisation)
      create(:membership, user: user2, role: role, organisation: organisation)

      expect(role.users.count).to eq(2)
      expect(role.users.to_a).to include(user1, user2)
    end

    it 'nullifies membership.role_id when destroyed' do
      membership = create(:membership, user: user, role: role, organisation: organisation)

      expect do
        role.destroy
      end.not_to change(Membership, :count)

      expect(membership.reload.role_id).to be_nil
    end
  end
end
