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
class Role < ApplicationRecord
  acts_as_tenant(:organisation)

  # A billable flip moves the seats of every membership of this role at once,
  # and no membership is saved while it happens -- see the concern.
  include SeatRoleFlipRecording

  has_many :permissions, dependent: :destroy
  has_many :memberships, dependent: :nullify
  has_many :users, through: :memberships

  validates :title, presence: true, uniqueness: { scope: :organisation_id }

  scope :default_roles, -> { where(is_default: true) }

  ACCOUNT_ADMIN_TITLE = 'account_admin'

  # Guest-Ceiling Verbotsliste (Plan doc/billing_agentur_konto_plan.md §4.3,
  # Fund F2) -- the only remaining HARD, blocking rule (everything else in
  # §4.3 is detection-only, s. Subscriptions::GuestCeiling). A billable: false
  # role may never carry org-admin rights or org-wide project access, since
  # that would make the org's guest-ceiling detection meaningless and let a
  # single "free" role administer the whole organisation.
  # accounts:  add_edit_delete_roles/create_account_admins/manage_users/
  #            remove_account_admins/close_account
  # projects:  create_new_projects/delete_projects/change_project_properties
  #            + every *_all_projects fine-grained permission
  FORBIDDEN_BILLABLE_FALSE_CATEGORIES = %w[accounts projects].freeze

  validate :guest_role_forbidden_state, if: -> { billable == false }

  # Method to check whether this is an account admin
  def account_admin?
    title == ACCOUNT_ADMIN_TITLE
  end

  # Find or create the account-admin role for an organisation
  def self.find_or_create_account_admin(organisation)
    role = organisation.roles.find_or_initialize_by(title: ACCOUNT_ADMIN_TITLE)
    if role.new_record?
      role.description = 'Administrator mit vollen Zugriffsrechten'
      role.save!
    end
    role
  end

  # Find the default role for an organisation
  def self.default_for_organisation(organisation)
    organisation.roles.default_roles.first
  end

  # Check the permission
  def has_permission?(category, action)
    return true if account_admin?

    permission_row_allows?(category, action)
  end

  # Whether a stored permission row of this role allows the action. Unlike
  # has_permission?, an account admin's implicit yes is left out: a policy that
  # names the admin rule itself (GlossaryPolicy) asks this, so its own admin
  # answer is the only door for an admin.
  def permission_row_allows?(category, action)
    permissions.load unless permissions.loaded?
    permissions.any? { |p| p.category == category.to_s && p.action == action.to_s && p.allowed }
  end

  private

  def guest_role_forbidden_state
    errors.add(:billable, :account_admin_cannot_be_non_billable) if account_admin?

    # persisted? is a performance shortcut, not a correctness guard: a new
    # (unsaved) Role has no persisted permissions to query yet -- skipping
    # the query here is just avoiding pointless work, never hiding a real
    # violation (Permission's OWN validation, s. permission.rb, still catches
    # a forbidden permission built in-memory on a new Role via autosave).
    return unless persisted?
    return unless permissions.where(category: FORBIDDEN_BILLABLE_FALSE_CATEGORIES, allowed: true).exists?

    errors.add(:billable, :forbidden_permission_present)
  end
end
