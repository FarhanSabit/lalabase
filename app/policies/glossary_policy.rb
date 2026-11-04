# frozen_string_literal: true

# The glossary of an organisation (GlossaryTerm and its heard forms,
# TermCorrection; K4a). A right of its own (Permission::CATEGORIES[:glossary],
# E2): account admins have it without a row, every other role only when an
# admin grants it; no role gets it by itself. manage_glossary (create, change,
# confirm, reject, merge, delete) implies view_glossary
# (Permission::IMPLIED_BY). Grantable to billable: false roles.
#
# view_glossary shows the WHOLE glossary with its heard forms and their
# projects, also from projects the reader may not read (E3). Three things are
# not part of that and are asked where they are shown (GlossaryHelper): the
# title and the link of a meeting (read access to the meeting,
# MeetingPolicy); the name of a speaker (only someone the reader may see on
# the members page, MembershipPolicy::Scope, or on the people page,
# PersonPolicy::Scope, so a guest of one project sees no names from other
# projects; anyone else shows as a neutral word); and the link to a speaker
# (view_people as well, PersonPolicy).
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

    user.account_admin_in?(organisation) || granted?(user, organisation, 'view_glossary')
  end

  def self.manage_allowed?(user, organisation)
    return false unless user.active_member_of_organisation?(organisation)

    user.account_admin_in?(organisation) || granted?(user, organisation, 'manage_glossary')
  end

  # A permission ROW of the member's role grants the action, or an action
  # that includes it (Permission::IMPLIED_BY). Read through
  # Role#permission_row_allows?, not has_permission?, which answers yes for an
  # account admin by itself: the admin answer above is the only door for an
  # admin, so "admins need no row" (E2) is this policy's own rule.
  def self.granted?(user, organisation, action)
    role = user.role_in_organisation(organisation)
    return false unless role

    Permission.granting_actions('glossary', action).any? { |granting| role.permission_row_allows?('glossary', granting) }
  end
  private_class_method :granted?

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
