# frozen_string_literal: true

class Organisations::NotificationsController < Organisations::BaseController
  # Allowed values for the viewport param (see TicketsController#set_viewport_mode).
  # Whitelist, because the value is reflected into a redirect URL.
  ALLOWED_VIEWPORT_MODES = %w[desktop mobile].freeze

  before_action :set_notification, only: %i[show update destroy mark_read mark_unread archive unarchive mark_group_read activities]
  before_action :set_notification_for_open, only: [:open]

  def index
    # Default selection on the "bare" /inbox call: the "Alle" view, unread
    # and read (user, 2026-11-10; it was "Ungelesen" before). As soon as any
    # query param is present (even an empty state_filters[]), we respect the
    # explicit user choice.
    if request.query_string.blank?
      skip_policy_scope # Pundit after_action: no scoping needed for redirect.
      return redirect_to organisation_notifications_path(
        current_organisation, state_filters: Inbox::MasterListPresenter::STATUS_VIEWS.fetch('all')
      )
    end

    # List render logic (filter + pagination + grouping + empty state)
    # encapsulated in the MasterListPresenter — same code path as for
    # turbo_stream refreshes after state changes.
    @presenter = build_master_list_presenter
    @notifications             = @presenter.notifications
    @grouped_notifications     = @presenter.grouped_notifications
    @pagy                      = @presenter.pagy
    @total_notifications_count = @presenter.total_count

    @unread_count = current_user.unread_notifications_count(current_organisation)
    @projects     = policy_scope(Project).includes(:organisation)

    # Inbox pane: with ?notification=:id the associated ticket is shown in the
    # pane. Sets @selected_notification, @ticket, @project as well as
    # @pane_state (:ticket / :missing / :unauthorized / :non_ticket).
    load_inbox_pane_context if params[:notification].present?

    respond_to do |format|
      format.html do
        case params[:partial]
        when 'badge'
          # Instance variable is already set above, render template directly
          render 'notifications/badge'
        when 'list'
          @notifications = @notifications.limit(params[:limit] || 10)
          render 'notifications/list'
        else
          # Turbo Frame request for the pane: render only the pane content.
          if turbo_frame_request? && request.headers['Turbo-Frame'] == 'ticket_pane'
            render partial: inbox_pane_partial, layout: false
          else
            render :index
          end
        end
      end
      format.json { render json: @notifications }
    end
  end

  def show
    authorize @notification

    # Mark as read when viewed
    @notification.mark_as_read! if @notification.unread?

    # Redirect to the actual content if applicable
    if @notification.action_url.present?
      redirect_to @notification.action_url
    else
      render :show
    end
  end

  def open
    authorize @notification

    # Mark all related notifications as read (all channels - in_app and email).
    # This includes the current notification and any other notifications for the
    # same notifiable, ensuring that clicking an email link also marks the
    # corresponding in-app notification as read. Each marked notification gets
    # a BroadcastService update so the UI reflects the new state.
    mark_notifications_for_notifiable(@notification, all_channels: true)

    target_path = notification_redirect_target_with_params(@notification)

    # Use Turbo-compatible redirect with proper status
    # This ensures the page state is maintained during redirect
    redirect_to target_path, allow_other_host: false, status: :see_other
  end

  def update
    authorize @notification

    action_type = params[:action_type] || params.dig(:notification, :state)

    case action_type
    when 'read', 'mark_read'
      @notification.mark_as_read!
      cascade_notifiable_state(@notification, :read)
      @unread_count = current_user.unread_notifications_count(current_organisation)

      respond_to do |format|
        format.turbo_stream
        format.json { render json: { status: 'read', unread_count: @unread_count } }
      end
    when 'archive'
      @notification.archive!
      cascade_notifiable_state(@notification, :archived)
      @unread_count = current_user.unread_notifications_count(current_organisation)

      respond_to do |format|
        format.turbo_stream
        format.json { render json: { status: 'archived', unread_count: @unread_count } }
      end
    else
      respond_to do |format|
        format.turbo_stream { render turbo_stream: turbo_stream.replace('flash_messages', partial: 'shared/flash', locals: { flash: { alert: t('flash.notifications.invalid_action') } }) }
        format.json { render json: { error: 'Invalid action' }, status: :unprocessable_entity }
      end
    end
  end

  # Individual Actions (for member routes)
  def mark_read
    authorize @notification, :mark_read?
    @notification.mark_as_read!
    # Bundling: one ticket = one inbox row. Reading cascades to ALL
    # notifications of this ticket — you look in once, everything done.
    cascade_notifiable_state(@notification, :read)
    @unread_count = current_user.unread_notifications_count(current_organisation)
    @action_type = 'mark_read'
    setup_pane_vars_from_action_notification

    respond_to do |format|
      format.turbo_stream { render :update }
      format.json { render json: { status: 'read', unread_count: @unread_count } }
    end
  end

  def mark_unread
    authorize @notification, :mark_unread?
    if @notification.state_archived?
      @notification.restore_from_archived!
    else
      @notification.mark_as_unread!
    end
    @unread_count = current_user.unread_notifications_count(current_organisation)
    @action_type = 'mark_unread'
    setup_pane_vars_from_action_notification

    respond_to do |format|
      format.turbo_stream { render :update }
      format.json { render json: { status: 'unread', unread_count: @unread_count } }
    end
  end

  def archive
    authorize @notification, :archive?
    @notification.archive!
    # Bundling: archiving applies to the whole ticket (all siblings).
    cascade_notifiable_state(@notification, :archived)
    @unread_count = current_user.unread_notifications_count(current_organisation)
    @action_type = 'archive'
    setup_pane_vars_from_action_notification

    respond_to do |format|
      format.turbo_stream { render :update }
      format.json { render json: { status: 'archived', unread_count: @unread_count } }
    end
  end

  def unarchive
    # Reuse archive policy: whoever may archive may also bring it back out.
    authorize @notification, :archive?
    if @notification.state_archived?
      @notification.update!(
        state: :read,
        archived_at: nil,
        read_at: @notification.read_at || Time.current
      )
    end
    # Bundling: archiving took the whole ticket, so does the way back.
    cascade_notifiable_state(@notification, :unarchived)
    @unread_count = current_user.unread_notifications_count(current_organisation)
    @action_type = 'unarchive'
    setup_pane_vars_from_action_notification

    respond_to do |format|
      format.html { redirect_back fallback_location: organisation_notifications_path(current_organisation) }
      format.turbo_stream { render :update }
      format.json { render json: { status: 'read', unread_count: @unread_count } }
    end
  end

  def stats
    authorize :notifications, :stats?

    # Optimized statistics query - single DB hit with conditional aggregation
    base_scope = policy_scope(current_user.notifications).for_current_tenant_user(current_user).channel_in_app

    stats_query = base_scope.group(
      "CASE
         WHEN state = 'archived' THEN 'archived'
         WHEN state = 'read' THEN 'read'
         WHEN state IN ('queued', 'sent', 'delivered') THEN 'unread'
         ELSE 'other'
       END",
      "CASE WHEN created_at > '#{7.days.ago.to_fs(:db)}' THEN 'recent' ELSE 'older' END"
    ).count

    # Parse results efficiently
    @stats = {
      total_count: base_scope.count,
      unread_count: stats_query.select { |k, _| k[0] == 'unread' }.values.sum,
      read_count: stats_query.select { |k, _| k[0] == 'read' }.values.sum,
      archived_count: stats_query.select { |k, _| k[0] == 'archived' }.values.sum,
      recent_count: stats_query.select { |k, _| k[1] == 'recent' }.values.sum
    }

    respond_to do |format|
      format.html { render :stats }
      format.json { render json: @stats }
    end
  end

  def destroy
    authorize @notification

    @notification.destroy
    redirect_to organisation_notifications_path(current_organisation),
                notice: t('flash.notifications.deleted')
  end

  def mark_all_read
    # Authorize bulk operation (Controller-level authorization)
    authorize :notifications, :mark_all_read?

    scope = policy_scope(current_user.notifications)
            .for_current_tenant_user(current_user)
            .channel_in_app
    scope = scope.where(notifiable_type: params[:notifiable_type], notifiable_id: params[:notifiable_id]) if params[:notifiable_type].present? && params[:notifiable_id].present?
    # Inbox bulk select: individual notification IDs (Gmail-style).
    selected_ids = Array(params[:ids]).reject(&:blank?)
    return refuse_empty_selection if empty_selection?(selected_ids)

    scope = with_whole_tickets(scope, selected_ids) if selected_ids.any?
    marked_count = scope.unread
                        .bulk_transition!(state: 'read', read_at: Time.current)

    @unread_count = current_user.unread_notifications_count(current_organisation)
    @notifications = policy_scope(current_user.notifications)
                     .for_current_tenant_user(current_user)
                     .channel_in_app
                     .inbox
                     .includes(:actor, :notifiable, :organisation, :project)
                     .recent
                     .limit(10)

    respond_to do |format|
      format.turbo_stream
      format.html do
        redirect_to organisation_notifications_path(current_organisation),
                    notice: t('flash.notifications.marked_read', count: marked_count)
      end
      format.json { render json: { success: true, marked_count: marked_count, unread_count: 0 } }
    end
  end

  def archive_all
    # Authorize bulk operation (Controller-level authorization)
    authorize :notifications, :archive_all?

    begin
      # Archive all read notifications for current organisation
      scope = policy_scope(current_user.notifications)
              .for_current_tenant_user(current_user)
              .channel_in_app
      scope = scope.where(notifiable_type: params[:notifiable_type], notifiable_id: params[:notifiable_id]) if params[:notifiable_type].present? && params[:notifiable_id].present?
      # Inbox bulk select: individual notification IDs (Gmail-style).
      # If ids are given: archive the selected ones regardless of their
      # state (i.e. also unread), not only the already-read ones.
      selected_ids = Array(params[:ids]).reject(&:blank?)
      return refuse_empty_selection if empty_selection?(selected_ids)

      if selected_ids.any?
        scope = with_whole_tickets(scope, selected_ids)
        archived_count = scope.bulk_transition!(state: 'archived', archived_at: Time.current)
      else
        archived_count = scope.read
                              .bulk_transition!(
                                state: 'archived',
                                archived_at: Time.current
                              )
      end

      # Refresh data for response (exclude archived)
      @notifications = policy_scope(current_user.notifications)
                       .for_current_tenant_user(current_user)
                       .channel_in_app
                       .inbox
                       .includes(:actor, :notifiable)
                       .recent
                       .limit(10)

      flash_message = "#{archived_count} notifications archived"
    rescue StandardError => e
      Rails.logger.error "Failed to archive notifications: #{e.message}"
      flash_message = 'Failed to archive notifications'

      respond_to do |format|
        format.html do
          redirect_to organisation_notifications_path(current_organisation),
                      alert: flash_message
        end
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            'flash_messages',
            partial: 'shared/flash',
            locals: { type: :alert, message: flash_message }
          ), status: :internal_server_error
        end
        format.json { render json: { error: flash_message }, status: :internal_server_error }
      end
      return
    end

    respond_to do |format|
      format.html do
        redirect_to organisation_notifications_path(current_organisation),
                    notice: flash_message
      end
      format.turbo_stream { render :archive_all }
      format.json do
        render json: {
          success: true,
          archived_count: archived_count,
          message: flash_message
        }
      end
    end
  end

  def ticket_exceptions
    authorize :notifications, :ticket_exceptions?

    # Load all of the user's ticket subscriptions in this organisation
    subscriptions = NotificationSubscription
                    .for_tickets
                    .for_user(current_user)
                    .includes(subscribable: :project)
                    .order(updated_at: :desc)

    # Ticket IDs for efficient batch checking (avoids N+1)
    ticket_ids = subscriptions.map(&:subscribable_id)
    assigned_ticket_ids = TicketAssignment.where(user: current_user, ticket_id: ticket_ids).pluck(:ticket_id).to_set
    created_ticket_ids = Ticket.where(id: ticket_ids, creator_id: current_user.id).pluck(:id).to_set
    auto_follow = current_user.ticket_auto_follow_created?

    # Determine exceptions:
    # 1. Muted → always an exception (explicit opt-out)
    # 2. Follow/Immediate → exception if auto_would_subscribe? would be false (manually followed)
    @exceptions = subscriptions.filter_map do |sub|
      ticket = sub.subscribable
      next unless ticket # Skip deleted tickets

      would_auto = assigned_ticket_ids.include?(sub.subscribable_id) ||
                   (created_ticket_ids.include?(sub.subscribable_id) && auto_follow)

      if sub.mode_mute?
        { subscription: sub, ticket: ticket, reason: :muted }
      elsif (sub.mode_follow? || sub.mode_immediate?) && !would_auto
        { subscription: sub, ticket: ticket, reason: :manual_follow }
      end
    end
  end

  def remove_ticket_exception
    authorize :notifications, :remove_ticket_exception?

    subscription = NotificationSubscription.find(params[:subscription_id])

    # Ensure that the subscription belongs to the current user
    if subscription.user_id != current_user.id
      redirect_to ticket_exceptions_organisation_notifications_path(current_organisation), alert: t('flash.notifications.no_permission')
      return
    end

    if subscription.mode_mute?
      # Lift mute → switch to follow
      subscription.update!(mode: 'follow')
      redirect_to ticket_exceptions_organisation_notifications_path(current_organisation),
                  notice: t('flash.notifications.unmuted')
    else
      # Remove manual follow → delete subscription
      subscription.destroy
      redirect_to ticket_exceptions_organisation_notifications_path(current_organisation),
                  notice: t('flash.notifications.exception_removed')
    end
  end

  def preferences
    authorize :notifications, :preferences?

    # Ticket notification settings (from user.preferences JSONB)
    ticket_prefs = current_user.preferences['ticket_notifications'] || {}
    @ticket_settings = {
      on_status_change: ticket_prefs['on_status_change'] != false,
      on_priority_change: ticket_prefs['on_priority_change'] != false,
      on_comment: ticket_prefs['on_comment'] != false,
      auto_follow_created: ticket_prefs['auto_follow_created'] != false
    }

    # Non-ticket preferences (existing system for project/document/system events)
    @preferences = current_user.notification_preferences
                               .where(organisation: current_organisation)
                               .includes(:organisation, :scope)
                               .group_by(&:event_type)

    @available_event_types = NotificationPreference.event_types.keys
    @available_channels = NotificationPreference.channels.keys
  end

  def update_preferences
    authorize :notifications, :update_preferences?

    success = true
    messages = []

    # 1. Handle ticket notification settings (new simple system)
    if params[:ticket_notifications].present?
      current_user.notification_settings.update(
        'on_status_change' => params.dig(:ticket_notifications, :on_status_change) == '1',
        'on_priority_change' => params.dig(:ticket_notifications, :on_priority_change) == '1',
        'on_comment' => params.dig(:ticket_notifications, :on_comment) == '1',
        'auto_follow_created' => params.dig(:ticket_notifications, :auto_follow_created) == '1'
      )
      messages << t('flash.notifications.ticket_settings_saved')
    end

    # 2. Handle non-ticket preferences (existing system for project/document/system)
    if preference_update_params.present?
      submitted_scope = extract_submitted_scope_from_params
      result = Notifications::UpdatePreferencesService.call(
        user: current_user,
        organisation: current_organisation,
        preference_params: preference_update_params,
        submitted_scope: submitted_scope,
        full_matrix: false
      )

      if result[:success]
        messages << build_success_message(result)
      else
        success = false
        messages << result[:error]
      end
    end

    if success
      redirect_to preferences_organisation_notifications_path(current_organisation),
                  notice: messages.any? ? messages.join('. ') : t('flash.notifications.settings_saved')
    else
      redirect_to preferences_organisation_notifications_path(current_organisation),
                  alert: t('flash.notifications.settings_error', error: messages.join('. '))
    end
  end

  private

  def notification_object_display_name(notification)
    if notification.notifiable.present?
      case notification.notifiable_type
      when 'Ticket'
        ticket = notification.notifiable
        project = ticket.project if ticket.respond_to?(:project)
        project_name = project&.name || 'Unknown Project'
        "#{project_name} - ##{ticket.number} #{ticket.title}"
      when 'Project'
        notification.notifiable.title
      when 'Document'
        notification.notifiable.title
      when 'Note'
        notification.notifiable.title
      else
        notification.notifiable_type.humanize
      end
    else
      t('flash.notifications.notifiable_deleted', type: notification.notifiable_type.humanize)
    end
  rescue StandardError => e
    Rails.logger.error "Error in notification_object_display_name: #{e.message}"
    notification.notifiable_type.humanize
  end

  def extract_submitted_scope_from_params
    # Extract scope hints from hidden form fields if provided
    submitted_events = params[:submitted_event_types]&.compact_blank
    submitted_channels = params[:submitted_channels]&.compact_blank

    return nil unless submitted_events || submitted_channels

    {
      events: submitted_events,
      channels: submitted_channels
    }
  end

  def build_success_message(result)
    parts = []
    parts << "#{result[:updated_count]} preferences updated" if result[:updated_count] > 0
    parts << "#{result[:created_count]} new preferences saved" if result[:created_count] > 0

    if parts.any?
      "Preferences updated successfully (#{parts.join(', ')})."
    else
      'Preferences updated successfully.'
    end
  end

  public

  def mark_group_read
    authorize @notification, :mark_group_read?

    # Mark all notifications in the same group as read
    if @notification.grouped?
      # Find all notifications with the same group_key for this user
      grouped_notifications = policy_scope(current_user.notifications)
                              .for_current_tenant_user(current_user)
                              .channel_in_app
                              .where(group_key: @notification.group_key)
                              .unread

      grouped_notifications.bulk_transition!(
        state: 'read',
        read_at: Time.current
      )

      render json: {
        success: true,
        marked_count: grouped_notifications.count,
        message: "Marked #{grouped_notifications.count} notifications as read"
      }
    else
      # Just mark this single notification as read
      @notification.mark_as_read!

      render json: {
        success: true,
        marked_count: 1,
        message: 'Marked notification as read'
      }
    end
  rescue StandardError => e
    render json: {
      success: false,
      error: e.message
    }, status: :unprocessable_entity
  end

  def activities
    authorize @notification, :activities?

    # Return individual activities that make up this grouped notification
    if @notification.grouped?
      # Get all activities from the payload
      actor_ids = @notification.payload['actor_ids'] || [@notification.actor_id].compact
      activities_data = []

      # Batch load all actors to prevent N+1 queries
      actors = User.where(id: actor_ids).index_by(&:id)

      # Build activity information from stored data
      actor_ids.each_with_index do |actor_id, index|
        actor = actors[actor_id]
        next unless actor

        # Estimate timestamps based on group timing
        estimated_time = @notification.last_event_at - (index * 30).seconds

        activities_data << {
          actor_name: actor.full_name,
          action: @notification.payload['action']&.humanize || 'performed an action',
          timestamp: estimated_time,
          time_ago: time_ago_in_words(estimated_time)
        }
      end

      render partial: 'notifications/group_activities',
             locals: { activities: activities_data }
    else
      # Single notification - return basic info
      activity_data = [{
        actor_name: @notification.actor&.full_name || 'System',
        action: @notification.payload['action']&.humanize || @notification.event_type.humanize,
        timestamp: @notification.created_at,
        time_ago: time_ago_in_words(@notification.created_at)
      }]

      render partial: 'notifications/group_activities',
             locals: { activities: activity_data }
    end
  rescue StandardError => e
    Rails.logger.error "Failed to load notification activities: #{e.message}"
    render json: {
      success: false,
      error: 'Failed to load activities'
    }, status: :internal_server_error
  end

  private

  def set_notification
    @notification = policy_scope(current_user.notifications)
                    .for_current_tenant_user(current_user)
                    .channel_in_app
                    .find(params[:id])
  end

  def set_notification_for_open
    # For the open action, we need to find notifications from ANY channel
    # because email notifications need to be openable too
    @notification = Notification.where(
      id: params[:id],
      recipient_id: current_user.id,
      organisation_id: current_organisation.id
    ).first

    unless @notification
      # Try to find the notification anyway to get the target
      notification = Notification.where(id: params[:id]).first

      if notification
        # Notification exists but belongs to different user
        # Still try to navigate to the target if user has access
        if notification.notifiable_type == 'Ticket' && notification.notifiable
          ticket = notification.notifiable
          # Only on to a ticket the person may read: a redirect to one they may not
          # would confirm that it exists, and where.
          if ticket.project && ticket.project.organisation_id == current_organisation.id && policy(ticket).show?
            # User has access to the ticket, redirect there with a warning
            flash[:warning] = t('flash.notifications.wrong_user')

            target_path = safe_notification_target_path(notification)
            if target_path && target_path != '#'
              redirect_to append_notification_redirect_params(target_path),
                          allow_other_host: false, status: :see_other
              return
            end
          end
        end

        # Can't access the target, redirect to notifications with message
        flash[:alert] = t('flash.notifications.wrong_user_redirect')
        redirect_to organisation_notifications_path(current_organisation) and return
      end

      # Notification doesn't exist at all
      flash[:alert] = t('flash.notifications.not_found_deleted')
      redirect_to organisation_notifications_path(current_organisation) and return
    end

    # Still check authorization
    authorize @notification
  end

  # Bundling: set all in_app notifications of the same notifiable (ticket) to
  # one target state. read → only unread; archived → all non-
  # archived; unarchived → the archived ones back to read. Via update_all (no callbacks) — consistent with
  # mark_all_read/archive_all. mark_unread DELIBERATELY does NOT cascade (only the
  # newest/displayed notification flips back to unread).
  # Only rows the person sees: rows about the same project can differ by the area of
  # their event, and a hidden one archived along would be gone when the right returns.
  def cascade_notifiable_state(notification, target_state)
    return unless notification.notifiable_type && notification.notifiable_id

    scope = current_user.notifications
                        .for_current_tenant_user(current_user)
                        .accessible_for(current_user, current_organisation)
                        .channel_in_app
                        .where(notifiable_type: notification.notifiable_type,
                               notifiable_id: notification.notifiable_id)

    case target_state
    when :read
      scope.unread.bulk_transition!(state: 'read', read_at: Time.current)
    when :archived
      scope.where.not(state: Notification.states[:archived])
           .bulk_transition!(state: 'archived', archived_at: Time.current)
    when :unarchived
      # Back as read, like the single unarchive: a row the bulk bar archived
      # unread has no read_at yet and gets one, the others keep theirs.
      archived = scope.where(state: Notification.states[:archived])
      archived.where(read_at: nil).bulk_transition!(state: 'read', archived_at: nil, read_at: Time.current)
      archived.bulk_transition!(state: 'read', archived_at: nil)
    end
  rescue StandardError => e
    Rails.logger.warn("cascade_notifiable_state failed: #{e.class}: #{e.message}")
  end

  def mark_notifications_for_notifiable(notification, all_channels: false)
    return unless notification.notifiable

    scope = policy_scope(current_user.notifications)
            .for_current_tenant_user(current_user)

    # Optionally filter by channel (default: only in_app)
    scope = scope.channel_in_app unless all_channels

    scope = scope.where(
      notifiable_type: notification.notifiable_type,
      notifiable_id: notification.notifiable_id
    )

    unread_ids = scope.unread.pluck(:id)
    return if unread_ids.blank?

    scope.where(id: unread_ids).bulk_transition!(state: 'read', read_at: Time.current)

    Notification.where(id: unread_ids).find_each do |notif|
      Notifications::BroadcastService.new(notif).broadcast_update
    rescue StandardError => e
      Rails.logger.warn("Failed to broadcast notification update for #{notif.id}: #{e.class}: #{e.message}")
    end
  rescue StandardError => e
    Rails.logger.warn("Failed to mark notifications as read via deep link: #{e.class}: #{e.message}")
  end

  def safe_notification_target_path(notification)
    path = view_context.notification_target_path(notification)
    return path if path.present? && path != '#'

    organisation_notifications_path(current_organisation)
  rescue StandardError => e
    Rails.logger.warn("Falling back to notifications index for redirect: #{e.class}: #{e.message}")
    organisation_notifications_path(current_organisation)
  end

  def notification_redirect_target_with_params(notification)
    append_notification_redirect_params(safe_notification_target_path(notification))
  end

  # Appends the deep link params to the redirect target path:
  # - from_notification signals the notification origin to the frontend
  # - source is preserved (e.g. source=email, source=inbox)
  # - viewport MUST be passed through: the viewport Stimulus controller
  #   (tickets page) appends ?viewport=mobile to the /open URL still standing
  #   in the address bar on the mobile switch. If the redirect swallows the
  #   param, the target renders in desktop mode and the client reloads /open
  #   endlessly (inbox mobile infinite loop, bug 2026-06-11).
  def append_notification_redirect_params(target_path)
    extra = ['from_notification=true']
    extra << "source=#{CGI.escape(params[:source])}" if params[:source].present?
    extra << "viewport=#{params[:viewport]}" if ALLOWED_VIEWPORT_MODES.include?(params[:viewport])

    separator = target_path.include?('?') ? '&' : '?'
    "#{target_path}#{separator}#{extra.join('&')}"
  end

  # Whitelist-based filtering for NotificationPreference updates.
  # Only known event types and channels are accepted.
  def preference_update_params
    return {} unless params[:preferences]

    allowed_events = NotificationPreference.event_types.keys
    allowed_channels = NotificationPreference.channels.keys

    sanitized = {}
    params[:preferences].each do |event_type, channels|
      next unless allowed_events.include?(event_type.to_s)
      next unless channels.respond_to?(:each)

      sanitized[event_type] = {}
      channels.each do |channel, settings|
        next unless allowed_channels.include?(channel.to_s)
        next unless settings.respond_to?(:[])

        sanitized[event_type][channel] = { 'enabled' => settings['enabled'] }
      end
    end

    sanitized
  end

  def filter_params
    params.permit(:search, :project_id, :state, :event_type, :view_mode, :page,
                  state_filters: [])
  end

  # The bulk bar of the inbox names its requests (selection=1). One of them
  # without ids would be the whole-inbox action the bar never offers, so it is
  # refused; the header dropdown asks for that action without the marker.
  # One ticket is one row: a selected row stands for every notification of its
  # ticket, as the single actions do (cascade_notifiable_state). In the bundled
  # view a row carries the id of its newest notification only; archiving that
  # one alone left the row standing with the next.
  def with_whole_tickets(scope, selected_ids)
    selected = scope.where(id: selected_ids)
    tickets = selected.where.not(notifiable_id: nil).distinct.pluck(:notifiable_type, :notifiable_id)
    return selected if tickets.empty?

    tickets.map { |type, id| scope.where(notifiable_type: type, notifiable_id: id) }.reduce(selected, :or)
  end

  def empty_selection?(selected_ids)
    params[:selection].present? && selected_ids.empty?
  end

  def refuse_empty_selection
    message = t('flash.notifications.nothing_selected')
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace('flash_messages', partial: 'shared/flash',
                                                                    locals: { type: :alert, message: message }),
               status: :unprocessable_content
      end
      format.html { redirect_to organisation_notifications_path(current_organisation), alert: message }
      format.json { render json: { error: message }, status: :unprocessable_content }
    end
  end

  # Builds the presenter with the current filter/pagination state.
  # Used in index AND in the stream templates after state changes, so that
  # live update and initial render use the same code.
  #
  # State filter param sources (priority):
  # 1. params[:state_filters] (a status view link or a form of the list head)
  # 2. Referrer URL (Stimulus fetch without param, e.g. delayed mark-read)
  # 3. Default → no filters
  def build_master_list_presenter(extra_params = {})
    merged = filter_params.to_h.merge(extra_params.transform_keys(&:to_s))
    merge_referrer_filters(merged) unless request.get? || request.head?
    # A type that does not exist (a hand-made address) is no filter: Postgres
    # refuses the value of its enum, and the page would answer 500.
    merged.delete('event_type') unless Notification.event_types.key?(merged['event_type'])

    # The rows and the presenter read the SAME filters. The rows used to be
    # read with the request's own (none, on an action address) while the
    # presenter had the referrer's: a list narrowed to a project showed every
    # project again after the first stream.
    base_scope = policy_scope(current_user.notifications)
                 .for_current_tenant_user(current_user)
                 .channel_in_app
                 .apply_filters(merged)
    Inbox::MasterListPresenter.new(
      pagy_helper: self,
      scope: base_scope,
      params: merged,
      time_zone: current_user.time_zone
    )
  end
  helper_method :build_master_list_presenter

  # Referrer fallback for ALL master filter dimensions, on action addresses
  # only. On Stimulus fetches (e.g. delayed mark-read) and member action
  # forms, the action URL carries no filter context: it lives only in the
  # inbox URL (= referrer). Per dimension: only adopt if params did NOT
  # explicitly set the key (explicit user choice wins).
  # ⚠️ Never on a GET of the inbox itself: its address says what the list
  # shows, and the page before it (the referrer of a pill, of the reset link)
  # would bring back the search the reader has just dropped.
  def merge_referrer_filters(merged)
    ref = master_filters_from_referrer
    merged['state_filters'] = ref[:state_filters] if !params.key?(:state_filters) && ref[:state_filters].any?
    %w[view_mode search project_id event_type].each do |key|
      merged[key] = ref[key.to_sym] if !params.key?(key) && ref[key.to_sym].present?
    end
  end

  # Extracts the master filter dimensions from the referrer (inbox URL).
  def master_filters_from_referrer
    blank = { state_filters: [], view_mode: nil, search: nil, project_id: nil, event_type: nil }
    q = inbox_referrer_query
    return blank unless q

    {
      state_filters: Array(q['state_filters']).reject(&:blank?),
      view_mode: q['view_mode'].presence,
      search: q['search'].presence,
      project_id: q['project_id'].presence,
      event_type: q['event_type'].presence
    }
  end

  # Shared guard for both referer-based filter fallbacks: the Referer header
  # is user-controlled, so parsing must never break the request. URI.parse
  # raises URI::InvalidURIError on malformed referers; Rack's nested-query
  # parser raises ParameterTypeError (conflicting nesting like `a[]=1&a[b]=2`),
  # ParamsTooDeepError and InvalidParameterError on hostile query strings.
  # Any parse failure degrades to nil (= no referrer filter context).
  # Returns the parsed query hash, or nil unless the referer is the inbox URL.
  def inbox_referrer_query
    ref = request.referer.to_s
    return nil if ref.empty?

    uri = URI.parse(ref)
    return nil unless uri.path == organisation_notifications_path(current_organisation)

    Rack::Utils.parse_nested_query(uri.query || '')
  # NOTE: on a Rack bump to >= 3.1.16 / 3.2 also rescue
  # Rack::QueryParser::QueryLimitError (new umbrella for query limits).
  rescue URI::InvalidURIError, Rack::QueryParser::ParameterTypeError,
         Rack::QueryParser::InvalidParameterError, Rack::QueryParser::ParamsTooDeepError
    nil
  end

  # Inbox pane loader: reads params[:notification], loads the notification +
  # associated ticket (with Pundit), marks the notification as read
  # and sets @selected_notification + @ticket + @project + @pane_state.
  # See doc/inbox_feature_spec.md chapter 4.4.
  def load_inbox_pane_context
    @pane_state = :missing
    # Through the policy scope (Notification.accessible_for): a row the person may
    # not see, a ticket of a lost area say, is no row to select.
    notification = policy_scope(current_user.notifications)
                   .for_current_tenant_user(current_user)
                   .find_by(id: params[:notification])
    return unless notification

    @selected_notification = notification
    notifiable = notification.notifiable

    # V1: Only tickets get the pane pattern. Other notifiables
    # keep navigating via "Open in ticket". See spec 4.6.
    unless notifiable.is_a?(Ticket)
      @pane_state = :non_ticket
      return
    end

    @ticket   = notifiable
    @project  = notifiable.project
    return unless @project

    # Pundit: can the user see the ticket? If not: unauthorized pane.
    begin
      authorize @ticket, :show?
    rescue Pundit::NotAuthorizedError
      @pane_state = :unauthorized
      return
    end

    # "What was new" block: the unread notifications of this ticket are
    # exactly what the user has not yet seen. Loaded NOW —
    # i.e. before the 5s cascade sets them to read — and then remains
    # as a snapshot in the pane (the mark-read stream swaps only
    # pills + master, not the pane). No separate last_visit tracking
    # needed: the unread state IS the "since-last-visit" information.
    @new_activities = current_user.notifications
                                  .for_current_tenant_user(current_user)
                                  .channel_in_app
                                  .where(notifiable_type: 'Ticket', notifiable_id: @ticket.id)
                                  .unread
                                  .includes(:actor)
                                  .recent

    # DELIBERATELY no more immediate mark_as_read — the user should be able to
    # glance briefly before the status is committed. A Stimulus
    # controller in the pane (see pane_mark_read_delay_controller.js) fires
    # a PATCH /mark_read after ~5s, if the notification is still open.
    @pane_state = :ticket
  end

  def inbox_pane_partial
    case @pane_state
    when :ticket        then 'organisations/notifications/pane_ticket'
    when :unauthorized  then 'organisations/notifications/pane_unauthorized'
    when :non_ticket    then 'organisations/notifications/pane_non_ticket'
    else                     'organisations/notifications/pane_missing'
    end
  end
  helper_method :inbox_pane_partial

  # After member actions (archive/unarchive/mark_read/mark_unread) we want
  # to also update the pane, in case the affected notification
  # is currently open. Sets @selected_notification + @pane_state, so that
  # update.turbo_stream.erb can re-render the pane partial.
  # The open notification is the one the page's address names (?notification=,
  # the referrer), NOT the one acted on: since the "···" menu of a row acts on
  # any row, taking the acted one swapped the lane's buttons to it and moved
  # the selected row (spec/requests/inbox_row_actions_spec.rb).
  def setup_pane_vars_from_action_notification
    return unless @notification

    @selected_notification = open_notification_from_referrer
    notifiable = @notification.notifiable
    if @selected_notification&.id == @notification.id && notifiable.is_a?(Ticket)
      @ticket = notifiable
      @project = notifiable.project
      @pane_state = :ticket
    end

    # Derive active filters from the source URL, so that update.turbo_stream.erb
    # can decide whether the notification still matches the filter or must be
    # removed from the list.
    @active_state_filters = active_state_filters_from_request
    @notification_still_in_filter = notification_matches_state_filters?(
      @notification, @active_state_filters
    )
  end

  # The notification open in the lane of the page the action came from, through
  # the policy scope like the pane loader; nil without one.
  def open_notification_from_referrer
    id = inbox_referrer_query&.dig('notification').presence
    return nil unless id.is_a?(String)
    return @notification if id == @notification.id

    policy_scope(current_user.notifications).for_current_tenant_user(current_user).find_by(id: id)
  end

  # Reads state_filters[] either from params (pill click) or from the
  # referrer URL (delayed mark-read from a Stimulus fetch without param).
  # IMPORTANT: if params[:state_filters] is present (even empty/blank),
  # it is an EXPLICIT user choice — no referrer fallback.
  def active_state_filters_from_request
    return Array(params[:state_filters]).reject(&:blank?) if params.key?(:state_filters)

    query = inbox_referrer_query
    return [] unless query

    Array(query['state_filters']).reject(&:blank?)
  end

  # Corresponds to the default filter logic from index: without explicit filters
  # = "everything except archived"; with filters = explicit selection.
  def notification_matches_state_filters?(notification, filters)
    if filters.empty?
      !notification.state_archived?
    else
      allowed = []
      allowed += %w[queued sent delivered] if filters.include?('unread')
      allowed << 'read'     if filters.include?('read')
      allowed << 'archived' if filters.include?('archived')
      allowed.include?(notification.state)
    end
  end
  helper_method :notification_matches_state_filters?
end
