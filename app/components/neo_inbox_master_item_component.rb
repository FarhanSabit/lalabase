# frozen_string_literal: true

# Compact list-row representation of a Notification, used in the Inbox
# master list (see doc/inbox_feature_spec.md chapter 4.1).
#
# DELIBERATELY NOT a clone of NeoNotificationCardComponent — the card component
# renders a full-width card look (briefing lane, dropdown). The
# inbox master needs a compact list look (~60px height). The
# data source is shared (Notification model + Notifications::Constants),
# only the display markup differs.
class NeoInboxMasterItemComponent < ViewComponent::Base
  include Notifications::Constants

  def initialize(notification:, selected: false, group_count: 1, group_unread: nil, query_context: nil)
    @notification = notification
    @selected = selected
    # Bundle counts (grouped view): how many notifications belong to the
    # same ticket, of which unread. group_unread: nil → single mode
    # (chronological), unread state then comes from the individual notification.
    @group_count = group_count
    @group_unread = group_unread
    # Optional: explicit query params for link_url. Needed on turbo_stream
    # re-renders, because request.query_parameters there mirrors the action
    # URL (e.g. ?items=20 instead of the master filter).
    @query_context = query_context
  end

  def render?
    @notification.present?
  end

  private

  attr_reader :notification, :selected, :group_count

  def activity_line
    @activity_line ||= Inbox::ActivityLine.new(notification)
  end

  # "3 neu": how many notifications of a bundled row are unread, shown from
  # two on (one unread is the dot and the bold title already). Chronological
  # rows (group_unread nil) are single notifications and never show it.
  def new_count
    count = @group_unread.to_i
    count > 1 ? count : 0
  end

  # The small line under the title: who did what, and in which project. A
  # notification without an actor (a system message) names the event alone.
  def meta_line
    what = notification.actor ? "#{actor_name} #{event_label}" : event_label
    [what, project_name].compact_blank.join(' · ')
  end

  # In bundled mode the row counts as unread as soon as ANY
  # of its notifications is unread (group_unread). In single mode
  # (group_unread nil) the state of the individual notification counts.
  def unread?
    return false if archived?

    if @group_unread.nil?
      !notification.state_read?
    else
      @group_unread.to_i.positive?
    end
  end

  def archived?
    notification.respond_to?(:state_archived?) && notification.state_archived?
  end

  def actor_name
    activity_line.actor_name
  end

  def time_ago
    activity_line.time_ago
  end

  def event_label
    activity_line.label
  end

  def notifiable_title
    notifiable = notification.notifiable
    return nil unless notifiable

    notifiable.try(:title).presence ||
      notifiable.try(:name).presence ||
      notifiable.try(:subject).presence
  end

  def project_name
    notification.project&.name
  end

  # If the notifiable is a ticket → open the inbox pane (same URL, just
  # with ?notification=:id, click loads the pane via Turbo frame).
  # Otherwise → deep link as before (full view).
  def link_url
    if notification.notifiable.is_a?(Ticket)
      base = @query_context.presence || helpers.request.query_parameters
      current = base.to_h.with_indifferent_access.except(:notification, :items)
      current[:notification] = notification.id
      "#{helpers.organisation_notifications_path(helpers.current_organisation)}?#{current.to_query}"
    else
      helpers.notification_deeplink_path(notification, source: 'inbox')
    end
  end

  # On mobile (no pane visible) the Stimulus controller navigates
  # to the full view instead — for that it needs the direct ticket URL.
  def fullview_url
    helpers.notification_deeplink_path(notification, source: 'inbox')
  end

  # On desktop (lg+): load the pane. On mobile (< lg): full view (the pane
  # is not visible). Tailwind cannot toggle this directly, so on desktop we
  # provide data-turbo-frame, and Stimulus overrides it on mobile in a
  # follow-up commit if needed. V1: a frame click falls back to
  # _top when the frame does not exist (mobile).
  #
  # turbo-action="advance" provides URL sync: after the frame loads the
  # browser URL is pushed to the link's href → back, reload, share
  # work. See doc/inbox_feature_spec.md chapter 4.8.
  def link_data
    if notification.notifiable.is_a?(Ticket)
      # NO turbo_action: 'advance' — that promotes the frame load to a
      # drive visit, which right after loading overwrites the freshly filled pane
      # with the placeholder (visible flicker). URL sync is instead done
      # by the Stimulus controller via history.pushState.
      {
        turbo_frame: 'ticket_pane',
        controller: 'inbox-master-item',
        action: 'click->inbox-master-item#handleClick',
        inbox_master_item_fullview_url_value: fullview_url
      }
    else
      { turbo_frame: '_top' }
    end
  end

  # The look lives in the inbox block of application.tailwind.css, the row
  # only names its state: unread (bold title), archived (muted), selected
  # (the shared selected-row tint).
  def row_classes
    ['people-row inbox-row',
     ('inbox-row--unread' if unread?),
     ('inbox-row--archived' if archived?),
     ('selected-row' if selected)].compact.join(' ')
  end
end
