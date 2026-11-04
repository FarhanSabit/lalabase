# frozen_string_literal: true

# The glossary of an organisation (GlossaryTerm and its heard forms,
# TermCorrection; K4a). A right of its own (Permission::CATEGORIES[:glossary],
# E2): account admins have it without a row, every other role only when an
# admin grants it; no role gets it by itself. manage_glossary (create, change,
# confirm, reject, merge, delete) implies view_glossary
# (Permission::IMPLIED_BY). Grantable to billable: false roles.
#
# view_glossary shows the WHOLE glossary with its heard forms, speakers and
# projects, also from projects the reader may not read (E3). The title and the
# link of a meeting are not part of that: they need read access to the
# meeting (MeetingPolicy), and the link to a person needs view_people
# (PersonPolicy). Both are asked where they are shown.
#
# Every predicate asks for an ACTIVE membership itself:
# User#has_permission_in_organisation? reads the role and does not look at
# membership.active (the reason of PersonPolicy).
class GlossaryPolicy < ApplicationPolicy
  class Scope < ApplicationPolicy::Scope
    # The rows of this organisation (terms or heard forms), nothing without
    # the right.
    def resolve
      return scope.none unless organisation && GlossaryPolicy.view_allowed?(user, organisation)

      scope.where(organisation: organisation)
    end
  end

  def self.view_allowed?(user, organisation)
    return false unless user.active_member_of_organisation?(organisation)

    user.account_admin_in?(organisation) ||
      Permission.granting_actions('glossary', 'view_glossary').any? do |action|
        user.has_permission_in_organisation?(organisation, 'glossary', action)
      end
  end

  def self.manage_allowed?(user, organisation)
    return false unless user.active_member_of_organisation?(organisation)

    user.account_admin_in?(organisation) ||
      user.has_permission_in_organisation?(organisation, 'glossary', 'manage_glossary')
  end

  def index?
    can_view?
  end

  def show?
    can_view? && same_organisation?
  end

  def create?
    can_manage?
  end

  def new?
    create?
  end

  def update?
    can_manage? && same_organisation?
  end

  def edit?
    update?
  end

  def destroy?
    update?
  end

  def confirm?
    update?
  end

  def reject?
    update?
  end

  def merge?
    update?
  end

  private

  def can_view?
    return false unless organisation

    self.class.view_allowed?(user, organisation)
  end

  def can_manage?
    return false unless organisation

    self.class.manage_allowed?(user, organisation)
  end

  # A term or a heard form of the current organisation, never a class.
  def same_organisation?
    (record.is_a?(GlossaryTerm) || record.is_a?(TermCorrection)) && record.organisation_id == organisation.id
  end
end
