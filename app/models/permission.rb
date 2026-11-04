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
class Permission < ApplicationRecord
  belongs_to :role

  validates :category, presence: true
  validates :action, presence: true
  validates :role_id, uniqueness: { scope: %i[category action] }

  # Stored rows whose category and action the code no longer knows. Nothing
  # reads them as a right any more, but they are invalid records, and the guest
  # ceiling of their role (Role#guest_role_forbidden_state) still counts an
  # allowed 'projects' row. The data backfill permissions:prune_unknown_actions
  # removes them on every installation.
  scope :unknown_actions, lambda {
    known = CATEGORIES.map { |category, actions| arel_table[:category].eq(category.to_s).and(arel_table[:action].in(actions)) }
    where.not(known.reduce(:or))
  }

  # Predefined categories and actions.
  #
  # BREAKING-POINT NOTE: Role::FORBIDDEN_BILLABLE_FALSE_CATEGORIES (Guest-
  # Ceiling Verbotsliste, Plan doc/billing_agentur_konto_plan.md §4.3) treats
  # EVERY action in :accounts and :projects below as forbidden for a
  # billable: false role. Adding a new action to either category -- even a
  # read-only/harmless-looking one -- automatically joins that Verbotsliste.
  # Check deliberately whenever this hash grows.
  CATEGORIES = {
    accounts: %w[
      add_edit_delete_roles
      create_account_admins
      manage_users
      remove_account_admins
      close_account
    ],
    projects: [
      'change_project_properties',
      'create_new_projects',
      'delete_projects',
      # Fine-grained permissions
      'read_access_chats_all_projects',
      'read_access_notes_all_projects',
      'read_access_meetings_all_projects',
      'read_access_tickets_all_projects',
      'read_access_documents_all_projects',
      'read_access_documentation_all_projects',
      'read_access_time_tracking_all_projects',
      'write_access_chats_all_projects',
      'write_access_notes_all_projects',
      'write_access_meetings_all_projects',
      'write_access_tickets_all_projects',
      'write_access_documents_all_projects',
      'write_access_documentation_all_projects',
      'write_access_time_tracking_all_projects'
    ],
    tickets: %w[
      delete_tickets
      move_tickets
    ],
    # Its own category for the same reason as :assistant below: an action under
    # :projects would join the guest ceiling's forbidden list as a side effect.
    meetings: %w[
      move_meetings
    ],
    users: %w[
      view_user_contact_details
      view_user_full_name
    ],
    # S3a (§13-2, user level): the org-wide assistant permission. Deliberately its
    # OWN category -- an action added to :projects would auto-join the Guest-
    # Ceiling Verbotsliste (see BREAKING-POINT note above); this way that beitritt
    # stays a decision, not a side effect. Grantable to billable: false roles.
    assistant: %w[
      use_assistant
    ],
    # The shared people directory of the organisation (Person). Its own category
    # for the same reason as :assistant: customer roles are billable: false and
    # must be able to keep the list, which an action under :projects would
    # forbid. manage_people (create, edit, delete, link) implies view_people
    # (IMPLIED_BY). No role gets either automatically; account admins need none.
    people: %w[
      view_people
      manage_people
    ],
    # The glossary of the organisation (GlossaryTerm, K4a). Its own category
    # for the same reason as :people: an action under :projects would join the
    # guest ceiling's forbidden list, and whether a billable: false role may
    # read or keep the glossary is the admin's choice. manage_glossary (create,
    # change, confirm, reject, merge, delete) implies view_glossary
    # (IMPLIED_BY). No role gets either automatically; account admins need none.
    glossary: %w[
      view_glossary
      manage_glossary
    ]
  }.freeze

  # A right that another right includes: [category, action] => the actions of
  # the same category that grant it too. Asked by PersonPolicy and
  # GlossaryPolicy (who may view) and RolePolicy#change_permission? (who may
  # grant it), so the two cannot disagree.
  IMPLIED_BY = {
    %w[people view_people] => %w[manage_people],
    %w[glossary view_glossary] => %w[manage_glossary]
  }.freeze

  # The actions of a category that grant [category, action]: itself and every
  # action that includes it.
  def self.granting_actions(category, action)
    [action, *IMPLIED_BY.fetch([category.to_s, action.to_s], [])]
  end

  validates :category, inclusion: { in: CATEGORIES.keys.map(&:to_s) }
  validate :validate_action_for_category
  # Guest-Ceiling Verbotsliste (Plan doc/billing_agentur_konto_plan.md §4.3,
  # Fund F2). RolePermissionSync saves each Permission independently
  # (role.permissions.find_or_initialize_by(...).save!), bypassing Role's own
  # save cycle -- Role's guest_role_forbidden_state validation alone would
  # miss this write path (Fund 3), so the same rule is enforced here too.
  validate :validate_not_forbidden_for_guest_role

  private

  def validate_action_for_category
    return unless category.present?

    valid_actions = CATEGORIES[category.to_sym]
    return if valid_actions&.include?(action)

    errors.add(:action, :invalid_for_category, category: category)
  end

  def validate_not_forbidden_for_guest_role
    return unless allowed
    return unless role && role.billable == false
    return unless Role::FORBIDDEN_BILLABLE_FALSE_CATEGORIES.include?(category)

    errors.add(:allowed, :forbidden_for_guest_role)
  end
end
