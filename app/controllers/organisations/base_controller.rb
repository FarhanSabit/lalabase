# frozen_string_literal: true

class Organisations::BaseController < ApplicationController
  include Pundit::Authorization

  helper_method :current_organisation, :current_membership, :current_project

  # the order of the before_actions is important
  before_action :set_organisation
  before_action :set_current_membership
  before_action :ensure_items_parameter
  # After set_organisation: it reads the organisation to tell an app page of it.
  include Organisations::ManagementReturn

  # Enforce Pundit checks in all environments
  # Use lambda conditions instead of only:/except: to avoid errors on controllers
  # without an index action (raise_on_missing_callback_actions)
  after_action :verify_authorized, if: -> { action_name != 'index' }
  after_action :verify_policy_scoped, if: -> { action_name == 'index' }

  private

  attr_reader :current_organisation, :current_membership, :current_project

  # Sets the current organisation and the tenant.
  # `current_user.organisations.find(...)` raises RecordNotFound when the user
  # is not a member of the organisation (not even with an inactive membership).
  def set_organisation
    # Session expired (current_user nil): cleanly redirect to login instead
    # of crashing on current_user.organisations with nil (500). redirect_to in
    # a before_action halts the filter chain.
    return redirect_to(new_user_session_path) unless current_user

    @current_organisation = if params[:organisation_id]
                              current_user.organisations.find(params[:organisation_id])
                            else
                              current_user.organisations.first
                            end
    ActsAsTenant.current_tenant = @current_organisation
  end

  # Sets the user's active membership for the current organisation.
  # Blocks access if there is no active membership (e.g. deactivated/blocked).
  # AcceptInvitationsController DELIBERATELY skips this check (invitation flow).
  #
  # Redirects to the organisation picker, which is TERMINAL (it only renders), NOT
  # to root_path: static#index sends a signed-in single-org user straight back to
  # the org root, which re-enters this filter -> root_path -> ... an infinite
  # redirect loop. The picker breaks the cycle and lets the user choose another org.
  def set_current_membership
    @current_membership ||= current_user.active_memberships.find_by(organisation: @current_organisation)
    return if @current_membership.present?

    redirect_to select_organisation_path, alert: t('shared.errors.not_authorized')
  end

  def pundit_user
    current_user
  end

  # Ensure items parameter is set from user preference if not present
  def ensure_items_parameter
    return if params[:items].present?
    return unless request.headers['Turbo-Frame'].present?
    return unless user_signed_in? && current_user.respond_to?(:items_per_page_preference)

    value = current_user.items_per_page_preference
    params[:items] = value if value.present? && value.to_i > 0
  end

  # Guest-Ceiling (§4.3, doc/billing_agentur_konto_plan.md): a non-blocking
  # hint for the acting org-admin when a write leaves `user` over the
  # account's configured guest limits. Detection only -- NEVER prevents the
  # write that triggered it (s. Subscriptions::GuestCeiling); Lalabase staff
  # see the same violation in the Admin-Backend (§4.4) and react manually.
  #
  # Deliberately wired into the two admin-facing EDIT paths only
  # (memberships#update, project_permissions#create incl. restore). The
  # membership CREATION paths -- invitation accept, admin-backend user
  # creation, org bootstrap -- show no hint on purpose: those flows face the
  # invitee/operator, not the org-admin managing the guest's footprint. The
  # Admin-Backend sweep (§4.4, GuestCeiling#violations) is the backstop that
  # still surfaces violations created there.
  def warn_if_guest_ceiling_exceeded(user)
    # account can be nil in the (bounded, deploy-time) window between the T1
    # migration landing and Account.backfill_all! (T4) having run -- fail
    # silently here, the same organisation will get its Account on the next
    # backfill run, and no hint is worse than a crash on every write.
    account = current_organisation.account
    return unless account

    # #violation_for (not #violations.find), so a single write doesn't load
    # and group every OTHER user's memberships/project counts in the account.
    violation = Subscriptions::GuestCeiling.new(account).violation_for(user)
    return unless violation

    flash[:warning] = t('shared.guest_ceiling.exceeded_hint', user: user.display_name)
  rescue StandardError => e
    # Best-effort by design: the triggering write has already committed when
    # this runs, so a detection failure (broken sibling-org data in the same
    # account, timeout) must never turn a successful change into a 500 --
    # log and move on. Same precedent as the onboarding seed in
    # Users::RegistrationsController#seed_onboarding.
    Rails.logger.error("[GuestCeiling] hint check failed for user #{user.id}: #{e.class}: #{e.message}")
  end
end
