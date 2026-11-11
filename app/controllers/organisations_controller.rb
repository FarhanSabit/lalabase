# frozen_string_literal: true

class OrganisationsController < ApplicationController
  skip_before_action :load_tenant_from_session, only: %i[select set new create]

  def select
    authenticate_user!

    # The cockpit. NO tenant is set here (skip_before_action :load_tenant_from_session) and
    # require_tenant is true, so every tenant-scoped read MUST go through the service, which
    # wraps each org in ActsAsTenant.with_tenant. Do not query a tenanted model (Ticket,
    # Notification, ...) directly in this action or the view — it would raise NoTenantSet (500).
    @organisations = current_user.active_organisations.order(created_at: :desc)

    # Single per-org data source (cross-org action summary + permission-correct tile unread).
    # Importance level comes from the user's cockpit settings (user-global, no tenant needed).
    @action_summary = Dashboard::CrossOrgActionSummary.new(
      user: current_user, importance: current_user.preference_store.cockpit_importance
    )
    @unread_counts = @action_summary.unread_counts

    # User-private cross-org roll-up of open personal to-dos (Notizblock). Same per-org iteration;
    # scoped to the owner only. Lazy — the view renders nothing if there is nothing open.
    @personal_task_rollup = Dashboard::PersonalTaskRollup.new(user: current_user)

    # Row view-model for the rows_* layouts. Pure Ruby over the two services above (no new queries);
    # the view only renders it when the user picked a rows layout.
    @cockpit_rows = Dashboard::CockpitRows.new(
      organisations: @organisations, action_summary: @action_summary, rollup: @personal_task_rollup
    )

    # Member count per org in 1 grouped query (not org.users.count per tile). Membership is
    # NOT acts_as_tenant, so this cross-org count needs no tenant. Count == user count (uniq
    # user+org).
    @member_counts = Membership.where(organisation_id: @organisations.select(:id))
                               .group(:organisation_id)
                               .count

    @single_organisation = @organisations.count == 1
  end

  def set
    authenticate_user!

    if params[:organisation_id].blank?
      redirect_to select_organisation_path, alert: t('flash.organisations.select_required')
      return
    end

    begin
      # Find the organisation
      ActsAsTenant.without_tenant do
        organisation = current_user.organisations.find(params[:organisation_id])
        flash[:notice] = t('flash.organisations.selected')
        redirect_to_organisation(organisation, section: params[:section])
      end
    rescue StandardError => e
      # Error handling
      Rails.logger.error("Error setting the organisation: #{e.message}")
      redirect_to select_organisation_path, alert: t('flash.organisations.select_error')
    end
  end

  def new
    authenticate_user!
    @organisation = Organisation.new
    authorize @organisation
  end

  def create
    authenticate_user!
    @organisation = Organisation.new(organisation_params)
    authorize @organisation

    result = Actors::CreateOrganisation.call(
      organisation: @organisation,
      owner: current_user,
      current_user: current_user
    )

    if result.success?
      redirect_to_organisation(@organisation)
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            'new_organisation_form',
            partial: 'organisations/new_organisation_form',
            locals: { organisation: @organisation }
          ), status: :unprocessable_entity
        end
        format.html { render :new, status: :unprocessable_entity }
      end
    end
  end

  private

  def organisation_params
    params.require(:organisation).permit(:name)
  end

  # Helper to safely redirect to an organization
  def redirect_to_organisation(organisation, section: nil)
    # Set the tenant
    ActsAsTenant.current_tenant = organisation
    session[:current_organisation_id] = organisation.id

    # The open section of the management area, where the reader may manage the other
    # organisation and it offers the section (doc/verwaltung_seitennavigation_plan.md
    # §10); the organisation root otherwise.
    redirect_to management_section_path(organisation, section) || organisation_root_path(organisation_id: organisation.id)
  end

  def management_section_path(organisation, key)
    return unless key.is_a?(String) && helpers.can_manage_organisation?(organisation)

    helpers.organisation_settings_tabs(organisation).find { |tab| tab[:key].to_s == key }&.dig(:path)
  end
end
