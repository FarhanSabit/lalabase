# frozen_string_literal: true

# Addresses and labels of the inbox list head (organisations/notifications).
# A link of the head changes one dimension of the list and keeps the others;
# it never carries the open notification or a page number along. A list
# rendered by a stream answers an action address, not the inbox: it passes
# the list state it was given (query:) instead of the request's query.
module InboxHelper
  INBOX_DROPPED_PARAMS = %w[notification page items].freeze

  # The list address with one status view: unread, all or archived.
  def inbox_status_view_url(view, query: nil)
    query = inbox_list_query(query).except('state', 'state_filters')
    query['state_filters'] = Inbox::MasterListPresenter::STATUS_VIEWS.fetch(view)
    inbox_list_url(query)
  end

  def inbox_view_mode_url(mode)
    inbox_list_url(inbox_list_query.merge('view_mode' => mode))
  end

  # The list address without search, project and type: the status view stays.
  def inbox_reset_narrowing_url(query: nil)
    inbox_list_url(inbox_list_query(query).except('search', 'project_id', 'event_type'))
  end

  # The rest of the list state as hidden fields of a head form, so that the
  # search keeps the status view and the project keeps the search.
  def inbox_hidden_query_fields(except:)
    fields = inbox_list_query.except(*except).flat_map do |key, value|
      case value
      when Array then value.grep(String).map { |item| hidden_field_tag("#{key}[]", item, id: nil) }
      when String then [hidden_field_tag(key, value, id: nil)]
      else [] # a nested hash from a hand-made address is no list state
      end
    end
    safe_join(fields)
  end

  def inbox_period_label(period)
    t("views.organisations.notifications.periods.#{period}")
  end

  private

  def inbox_list_query(query = nil)
    (query || request.query_parameters).to_h.deep_stringify_keys.except(*INBOX_DROPPED_PARAMS)
  end

  def inbox_list_url(query)
    path = organisation_notifications_path(current_organisation)
    query.present? ? "#{path}?#{query.to_query}" : path
  end
end
