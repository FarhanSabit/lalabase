# frozen_string_literal: true

module Organisations
  # The way out of the management area (doc/verwaltung_seitennavigation_plan.md §3):
  # while a management page is open the sidebar lists the sections instead of the app,
  # and its "‹ Zurück" leads to the app page the reader came from.
  #
  # That page is the referer of the first management page: when a full page of the area
  # is opened from an app page of the same organisation, its path is kept in the session.
  # A page opened from inside the area keeps what is there, so the way out survives any
  # number of sections. Only a path is kept, never a host: a foreign referer is no way
  # out, and NavigationHelper#management_return_path only follows a path below the
  # current organisation.
  module ManagementReturn
    extend ActiveSupport::Concern

    SESSION_KEY = :management_return_path
    # Leave room in the 4 KB encrypted session cookie for authentication and preferences.
    MAX_RETURN_PATH_BYTES = 1024

    included do
      before_action :remember_management_return
    end

    private

    # NavigationHelper.section_key_for, not `helpers`: the helper proxy is memoised, and
    # built here it would keep the view assigns of this moment, before the controller's
    # own before_actions set @project and the like (the knowledge lane lost its project
    # that way on the first build of this).
    def remember_management_return
      return unless request.get? && request.format.html? && !turbo_frame_request?
      return unless NavigationHelper.section_key_for(controller_name)

      path = management_referer_path
      session[SESSION_KEY] = path if path
    end

    # The referer's path when it is an app page of this organisation (not one of the
    # management area itself), else nil.
    def management_referer_path
      uri = URI.parse(request.referer.to_s)
      return unless uri.host == request.host && current_organisation

      root = organisation_root_path(organisation_id: current_organisation.id)
      return unless uri.path == root || uri.path.start_with?("#{root}/")

      route = Rails.application.routes.recognize_path(uri.path)
      return if NavigationHelper.section_key_for(route[:controller].to_s.split('/').last)

      path = [uri.path, uri.query].compact.join('?')
      path.bytesize <= MAX_RETURN_PATH_BYTES ? path : root
    rescue URI::InvalidURIError, ActionController::RoutingError
      nil
    end
  end
end
