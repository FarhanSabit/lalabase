# frozen_string_literal: true

# == Schema Information
#
# Table name: permissions
#
#  id         :uuid             not null, primary key
#  action     :string           not null
#  allowed    :boolean          default(FALSE)
#  category   :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  role_id    :uuid             not null
#
# Indexes
#
#  index_permissions_on_role_id_and_category_and_action  (role_id,category,action) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (role_id => roles.id)
#
require 'rails_helper'

RSpec.describe Permission, type: :model do
  let(:organisation) { create(:organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  describe 'associations' do
    it 'is destroyed when its role is destroyed (dependent: :destroy)' do
      role = create(:role, organisation: organisation)
      create(:permission, role: role, category: 'tickets', action: 'delete_tickets')

      expect { role.destroy! }.to change(Permission, :count).by(-1)
    end
  end

  describe 'validations' do
    subject { build(:permission) }

    it { should validate_presence_of(:category) }
    it { should validate_presence_of(:action) }
    it { should validate_inclusion_of(:category).in_array(Permission::CATEGORIES.keys.map(&:to_s)) }

    it 'validates uniqueness of role_id scoped to category and action' do
      ActsAsTenant.with_tenant(organisation) do
        permission = create(:permission)
        duplicate = build(:permission,
                          role: permission.role,
                          category: permission.category,
                          action: permission.action)
        expect(duplicate).not_to be_valid
        expect(duplicate.errors[:role_id]).to be_present
      end
    end

    context 'with invalid action for category' do
      let(:permission) do
        ActsAsTenant.with_tenant(organisation) do
          build(:permission, category: 'projects', action: 'invalid_action')
        end
      end

      it 'is invalid' do
        expect(permission).not_to be_valid
        expect(permission.errors[:action]).to include('ist für die Kategorie projects nicht gültig')
      end
    end

    context 'with valid action for category' do
      it 'is valid for projects category' do
        ActsAsTenant.with_tenant(organisation) do
          permission = build(:permission, category: 'projects', action: 'create_new_projects')
          expect(permission).to be_valid
        end
      end

      it 'is valid for accounts category' do
        ActsAsTenant.with_tenant(organisation) do
          permission = build(:permission, category: 'accounts', action: 'manage_users')
          expect(permission).to be_valid
        end
      end

      it 'is valid for tickets category' do
        ActsAsTenant.with_tenant(organisation) do
          permission = build(:permission, category: 'tickets', action: 'delete_tickets')
          expect(permission).to be_valid
        end
      end

      it 'is valid for users category' do
        ActsAsTenant.with_tenant(organisation) do
          permission = build(:permission, category: 'users', action: 'view_user_full_name')
          expect(permission).to be_valid
        end
      end
    end

    it 'has a valid project_read_permission factory' do
      ActsAsTenant.with_tenant(organisation) do
        expect(build(:project_read_permission)).to be_valid
      end
    end

    it 'has a valid project_write_permission factory' do
      ActsAsTenant.with_tenant(organisation) do
        expect(build(:project_write_permission)).to be_valid
      end
    end

    it 'can create project read permissions for different areas' do
      ActsAsTenant.with_tenant(organisation) do
        %w[chats notes tickets documents time_tracking].each do |area|
          permission = build(:project_read_permission, area: area)
          expect(permission).to be_valid
          expect(permission.action).to eq("read_access_#{area}_all_projects")
        end
      end
    end

    it 'can create project write permissions for different areas' do
      ActsAsTenant.with_tenant(organisation) do
        %w[chats notes tickets documents time_tracking].each do |area|
          permission = build(:project_write_permission, area: area)
          expect(permission).to be_valid
          expect(permission.action).to eq("write_access_#{area}_all_projects")
        end
      end
    end

    # [CRITICAL] Guest-Ceiling Verbotsliste (Plan doc/billing_agentur_konto_plan.md
    # §4.3, Fund F2/F3): RolePermissionSync saves each Permission independently
    # of Role's own save cycle, so this rule must ALSO be enforced here, not
    # only on Role.
    describe 'Verbotsliste: forbidden for a billable: false role' do
      it 'rejects an accounts-category permission' do
        ActsAsTenant.with_tenant(organisation) do
          guest_role = create(:role, billable: false)
          permission = build(:permission, role: guest_role, category: 'accounts',
                                          action: 'manage_users', allowed: true)

          expect(permission).not_to be_valid
          expect(permission.errors[:allowed]).to be_present
        end
      end

      it 'rejects a projects-category permission' do
        ActsAsTenant.with_tenant(organisation) do
          guest_role = create(:role, billable: false)
          permission = build(:permission, role: guest_role, category: 'projects',
                                          action: 'create_new_projects', allowed: true)

          expect(permission).not_to be_valid
        end
      end

      it 'rejects an *_all_projects permission' do
        ActsAsTenant.with_tenant(organisation) do
          guest_role = create(:role, billable: false)
          permission = build(:project_read_permission, role: guest_role, area: 'tickets')

          expect(permission).not_to be_valid
        end
      end

      it 'allows a tickets-category permission' do
        ActsAsTenant.with_tenant(organisation) do
          guest_role = create(:role, billable: false)
          permission = build(:permission, role: guest_role, category: 'tickets',
                                          action: 'delete_tickets', allowed: true)

          expect(permission).to be_valid
        end
      end

      # move_meetings sits in its own category on purpose: an action under
      # :projects would join the guest ceiling's forbidden list automatically.
      it 'allows a meetings-category permission' do
        ActsAsTenant.with_tenant(organisation) do
          guest_role = create(:role, billable: false)
          permission = build(:permission, role: guest_role, category: 'meetings',
                                          action: 'move_meetings', allowed: true)

          expect(permission).to be_valid
        end
      end

      it 'allows a forbidden category when allowed is false (the permission grants nothing)' do
        ActsAsTenant.with_tenant(organisation) do
          guest_role = create(:role, billable: false)
          permission = build(:permission, role: guest_role, category: 'accounts',
                                          action: 'manage_users', allowed: false)

          expect(permission).to be_valid
        end
      end

      it 'allows a forbidden category when the role is billable: true' do
        ActsAsTenant.with_tenant(organisation) do
          billable_role = create(:role, billable: true)
          permission = build(:permission, role: billable_role, category: 'accounts',
                                          action: 'manage_users', allowed: true)

          expect(permission).to be_valid
        end
      end
    end
  end

  describe 'predefined categories and actions' do
    it 'has predefined categories' do
      expect(Permission::CATEGORIES.keys).to include(:accounts, :projects, :tickets, :users)
    end

    it 'has predefined actions for accounts category' do
      expect(Permission::CATEGORIES[:accounts]).to include(
        'add_edit_delete_roles',
        'create_account_admins',
        'manage_users',
        'remove_account_admins',
        'close_account'
      )
    end

    it 'has predefined actions for projects category' do
      expect(Permission::CATEGORIES[:projects]).to include(
        'change_project_properties',
        'create_new_projects',
        'delete_projects',
        'read_access_chats_all_projects',
        'write_access_documents_all_projects'
      )
    end

    it 'has predefined actions for tickets category' do
      expect(Permission::CATEGORIES[:tickets]).to include('delete_tickets')
    end

    it 'has predefined actions for meetings category' do
      expect(Permission::CATEGORIES[:meetings]).to eq(%w[move_meetings])
    end

    it 'has predefined actions for users category' do
      expect(Permission::CATEGORIES[:users]).to include(
        'view_user_contact_details',
        'view_user_full_name'
      )
    end
  end

  describe 'usage with Role' do
    let(:role) do
      ActsAsTenant.with_tenant(organisation) do
        create(:role, organisation: organisation)
      end
    end

    it 'can be associated with a role' do
      ActsAsTenant.with_tenant(organisation) do
        permission = create(:permission, role: role)
        expect(role.permissions).to include(permission)
      end
    end

    it 'is checked through the role has_permission? method' do
      ActsAsTenant.with_tenant(organisation) do
        create(:permission,
               role: role,
               category: 'projects',
               action: 'create_new_projects',
               allowed: true)

        expect(role.has_permission?('projects', 'create_new_projects')).to be true
        expect(role.has_permission?('projects', 'delete_projects')).to be false
      end
    end

    it 'respects the allowed flag' do
      ActsAsTenant.with_tenant(organisation) do
        create(:permission,
               role: role,
               category: 'projects',
               action: 'change_project_properties',
               allowed: false)

        expect(role.has_permission?('projects', 'change_project_properties')).to be false
      end
    end
  end

  describe 'project area permissions' do
    let(:role) do
      ActsAsTenant.with_tenant(organisation) do
        create(:role, organisation: organisation)
      end
    end
    let(:project) do
      ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation)
      end
    end
    let(:user) { create(:user) }
    let!(:membership) do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation, role: role, active: true)
      end
    end

    it 'provides read access to an area' do
      ActsAsTenant.with_tenant(organisation) do
        create(:project_read_permission, role: role, area: 'chats')

        # Simulate the ProjectAccessService check
        has_permission = role.has_permission?('projects', 'read_access_chats_all_projects')
        expect(has_permission).to be true
      end
    end

    it 'provides write access to an area' do
      ActsAsTenant.with_tenant(organisation) do
        create(:project_write_permission, role: role, area: 'documents')

        # Simulate the ProjectAccessService check
        has_permission = role.has_permission?('projects', 'write_access_documents_all_projects')
        expect(has_permission).to be true
      end
    end

    it 'does not provide access to other areas' do
      ActsAsTenant.with_tenant(organisation) do
        create(:project_read_permission, role: role, area: 'notes')

        # User shouldn't have access to chats
        has_permission = role.has_permission?('projects', 'read_access_chats_all_projects')
        expect(has_permission).to be false
      end
    end
  end

  # ── Mutation hardening ─────────────────────────────────────────────────────

  describe 'category/action whitelist completeness' do
    # Positive iteration over the WHOLE constant: deleting any allowed action from a
    # category (whitelist shrink) turns exactly that example red. Iterates the constant,
    # so newly added actions are covered automatically.
    Permission::CATEGORIES.each do |category, actions|
      actions.each do |action|
        it "accepts #{category}/#{action}" do
          expect(build(:permission, category: category.to_s, action: action)).to be_valid
        end
      end
    end

    it 'rejects an action that is only valid for a DIFFERENT category (per-category boundary)' do
      # manage_users is valid under accounts, NOT under projects. Kills checking the action
      # against the flattened union of all categories instead of CATEGORIES[category].
      permission = build(:permission, category: 'projects', action: 'manage_users')

      expect(permission).not_to be_valid
      expect(permission.errors[:action]).to be_present
    end
  end

  describe 'uniqueness — defense in depth & scope isolation' do
    let(:role) { create(:role, organisation: organisation) }

    it 'enforces the composite unique index at the DB level when validation is bypassed' do
      create(:permission, role: role, category: 'tickets', action: 'delete_tickets')
      dup = build(:permission, role: role, category: 'tickets', action: 'delete_tickets')

      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'allows the same role + category with a DIFFERENT action (action is part of the scope)' do
      create(:permission, role: role, category: 'projects', action: 'create_new_projects')

      expect(build(:permission, role: role, category: 'projects', action: 'delete_projects')).to be_valid
    end

    it 'allows the same category + action under a DIFFERENT role (role is the unique subject)' do
      create(:permission, role: role, category: 'projects', action: 'create_new_projects')
      other_role = create(:role, organisation: organisation)

      expect(build(:permission, role: other_role, category: 'projects', action: 'create_new_projects')).to be_valid
    end
  end

  describe 'allowed default (contract)' do
    it 'defaults allowed to false when omitted on insert (NOT set via the factory)' do
      role = create(:role, organisation: organisation)
      permission = described_class.create!(role: role, category: 'tickets', action: 'move_tickets')

      expect(permission.reload.allowed).to be false
    end
  end

  # S3a (§13-2): the assistant permission lives in its OWN category, precisely so
  # that it does NOT auto-join the Guest-Ceiling Verbotsliste the way any new
  # :projects action would (BREAKING-POINT note in Permission::CATEGORIES).
  describe 'assistant category (S3a)' do
    it 'accepts assistant/use_assistant as a valid pair' do
      ActsAsTenant.with_tenant(organisation) do
        permission = build(:permission, role: create(:role), category: 'assistant',
                                        action: 'use_assistant', allowed: true)

        expect(permission).to be_valid
      end
    end

    it 'stays grantable to a billable: false role (deliberately NOT in the Verbotsliste)' do
      ActsAsTenant.with_tenant(organisation) do
        guest_role = create(:role, billable: false)
        permission = build(:permission, role: guest_role, category: 'assistant',
                                        action: 'use_assistant', allowed: true)

        expect(permission).to be_valid
      end
    end
  end

  # The people directory: its own category for the same reason as :assistant,
  # customer roles are billable: false and must be able to keep the list.
  describe 'people category' do
    it 'knows view_people and manage_people' do
      expect(Permission::CATEGORIES[:people]).to eq(%w[view_people manage_people])
    end

    it 'is not on the guest ceiling list' do
      expect(Role::FORBIDDEN_BILLABLE_FALSE_CATEGORIES).not_to include('people')
    end

    %w[view_people manage_people].each do |action|
      it "stays grantable to a billable: false role (#{action})" do
        ActsAsTenant.with_tenant(organisation) do
          guest_role = create(:role, billable: false)
          permission = build(:permission, role: guest_role, category: 'people', action: action, allowed: true)

          expect(permission).to be_valid
        end
      end
    end
  end

  # The glossary (K4a): its own category for the same reason as :people. No
  # role gets it by itself; whether a guest role may hold it is the admin's
  # choice, so it stays off the guest ceiling list.
  describe 'glossary category' do
    it 'knows view_glossary and manage_glossary' do
      expect(Permission::CATEGORIES[:glossary]).to eq(%w[view_glossary manage_glossary])
    end

    it 'is not on the guest ceiling list' do
      expect(Role::FORBIDDEN_BILLABLE_FALSE_CATEGORIES).not_to include('glossary')
    end

    it 'lets manage_glossary grant view_glossary, and not the other way round' do
      expect(Permission.granting_actions('glossary', 'view_glossary')).to eq(%w[view_glossary manage_glossary])
      expect(Permission.granting_actions('glossary', 'manage_glossary')).to eq(%w[manage_glossary])
    end

    %w[view_glossary manage_glossary].each do |action|
      it "stays grantable to a billable: false role (#{action})" do
        ActsAsTenant.with_tenant(organisation) do
          guest_role = create(:role, billable: false)
          permission = build(:permission, role: guest_role, category: 'glossary', action: action, allowed: true)

          expect(permission).to be_valid
        end
      end
    end
  end
end
