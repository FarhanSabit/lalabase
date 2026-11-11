# frozen_string_literal: true

class Organisations::RolesController < Organisations::BaseController
  before_action :set_role, only: %i[show edit update destroy set_default]

  # Two views of one page: the list of the roles, or the matrix of every role
  # against every right. The address chooses (?view=matrix, as the time list's
  # ?view=overview), any other value is the list, and nothing is remembered
  # between requests (doc/verwaltung_seitennavigation_plan.md §7a, 3). The
  # template renders the chosen view only.
  def index
    @roles = policy_scope(Role).includes(:permissions, :memberships)
    authorize @roles
    @view = params[:view] == 'matrix' ? 'matrix' : 'list'
  end

  def show
    authorize @role
  end

  def new
    @role = Role.new
    authorize @role
  end

  def edit
    authorize @role

    # The account admin role cannot be edited
    return redirect_to organisation_roles_path, alert: t('flash.roles.account_admin_no_edit') if @role.account_admin?

    load_permissions_for_edit
  end

  def create
    @role = current_organisation.roles.new(role_params)
    authorize @role

    if @role.save
      redirect_to edit_organisation_role_path(current_organisation, @role), notice: t('flash.roles.created')
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    authorize @role

    # The account admin role cannot be changed
    return redirect_to organisation_roles_path, alert: t('flash.roles.account_admin_no_change') if @role.account_admin?

    result = Actors::SaveRole.call(
      role: @role,
      role_params: role_params,
      permissions: submitted_permission_params,
      current_user: current_user
    )

    if result.success?
      redirect_to organisation_roles_path, notice: t('flash.roles.updated')
    else
      # On errors, reload the permissions for the edit view.
      load_permissions_for_edit
      # Use flash here not flash.now because flash.now is only for immediate rendering
      flash[:alert] = t('flash.shared.save_error', error: result.errors.join(', '))
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @role

    # The account admin role cannot be deleted
    return redirect_to organisation_roles_path, alert: t('flash.roles.account_admin_no_delete') if @role.account_admin?

    if @role.memberships.any?
      redirect_to organisation_roles_path, alert: t('flash.roles.has_members')
    else
      @role.destroy
      redirect_to organisation_roles_path, notice: t('flash.roles.deleted')
    end
  end

  def set_default
    authorize @role, :set_default?

    # The account admin role cannot be set as the default
    return redirect_to organisation_roles_path, alert: t('flash.roles.account_admin_no_default') if @role.account_admin?

    # Reset the previous default role
    current_organisation.roles.where(is_default: true).update_all(is_default: false)

    # Set the new default role
    @role.update(is_default: true)

    redirect_to organisation_roles_path, notice: t('flash.roles.default_set')
  end

  private

  def set_role
    @role = Role.find(params[:id])
  end

  # GUARD-RAIL: do NOT add :billable to this permit list without first
  # authorizing against RolePolicy#update_billable? (Account-Owner-only, D10,
  # doc/billing_agentur_konto_plan.md), separately from the `authorize @role`
  # call above. That call only checks the NORMAL role-editing permission
  # (any org-admin) -- adding :billable here without the extra check would
  # let any org-admin flip billable and self-serve a free tier, exactly the
  # cost bypass D10 exists to prevent. There is currently NO UI for changing
  # billable at all (Phase 1 scope, T6), so this permit list is deliberately
  # missing it, not an oversight.
  def role_params
    params.require(:role).permit(:title, :description)
  end

  def permission_params
    permitted = {}
    Permission::CATEGORIES.each do |category, actions|
      permitted[category] = actions
    end
    params.require(:permissions).permit(permitted)
  end

  # Whitelisted permissions submitted with the role form, or {} when none were submitted.
  # Using permission_params (not raw params[:permissions]) strips actions not in
  # Permission::CATEGORIES, so a tampered/injected action no longer fails the whole update.
  def submitted_permission_params
    return {} if params[:permissions].blank?

    permission_params.to_h
  end

  # The per-category/action permission map the edit view renders, for #edit and
  # after a failed update. One query for the role's rows, not one per checkbox.
  def load_permissions_for_edit
    @permission_categories = Permission::CATEGORIES
    @permissions = {}
    stored = @role.permissions.reload.index_by { |permission| [permission.category, permission.action] }

    Permission::CATEGORIES.each do |category, actions|
      @permissions[category] = {}

      actions.each do |action|
        @permissions[category][action] = stored[[category.to_s, action]]&.allowed || false
      end
    end
  end
end
