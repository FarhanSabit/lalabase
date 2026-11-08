# frozen_string_literal: true

# What this server's REST API offers, for a client that decides from it which
# features to show (cli_rest_plan D4), the way the terminal client reads MCP
# tools/list today. GET /api/v1/me hands it out with API_VERSION.
#
# ONE list. spec/requests/api/v1/capabilities_spec.rb pins it against the
# routes both ways: every endpoint capability has its route, every /api/v1
# route is named here. A new endpoint therefore adds its line here or turns
# that spec red.
#
# Entry point: names
module Api
  module V1
    module Capabilities
      # Minor for an additive change (a new endpoint, field or capability), major
      # never: an existing name, field or meaning does not change. 1.2.0 added
      # the People API; 1.3.0 added the REST ticket view (R1); 1.4.0 adds
      # time_sessions.book (R6); 1.5.0 adds posts.plain (R3a); 1.6.0 adds
      # knowledge.search (R2); 1.7.0 adds tickets.changes (R3b); 1.8.0 adds a
      # comment's attachments (R7), a field and no capability: a client takes
      # its presence as the signal; 1.9.0 adds meetings.create and the field
      # meeting_inbox on projects.list; 1.10.0 adds meetings.list and meetings.show
      # (R8); 1.11.0 adds terms.list, the working terms of an organisation's
      # glossary (K4c); 1.12.0 adds meetings.glossary_replacements, the list of
      # what a device replaced from the glossary, on meetings.create and
      # meetings.show (K4d).
      API_VERSION = '1.12.0'

      # name => [verb, path as the router spells it]
      ENDPOINTS = {
        'me.show' => ['GET', '/api/v1/me'],
        'organisations.list' => ['GET', '/api/v1/organisations'],
        'people.list' => ['GET', '/api/v1/organisations/:organisation_id/people'],
        'people.show' => ['GET', '/api/v1/organisations/:organisation_id/people/:id'],
        'meetings.create' => ['POST', '/api/v1/organisations/:organisation_id/meetings'],
        'terms.list' => ['GET', '/api/v1/organisations/:organisation_id/terms'],
        'projects.list' => ['GET', '/api/v1/projects'],
        'projects.ticket_attribute_definitions' => ['GET', '/api/v1/projects/:id/ticket_attribute_definitions'],
        'knowledge.search' => ['GET', '/api/v1/projects/:project_id/knowledge'],
        'meetings.list' => ['GET', '/api/v1/projects/:project_id/meetings'],
        'meetings.show' => ['GET', '/api/v1/meetings/:id'],
        'tickets.list' => ['GET', '/api/v1/projects/:project_id/tickets'],
        'tickets.create' => ['POST', '/api/v1/projects/:project_id/tickets'],
        'tickets.by_number' => ['GET', '/api/v1/projects/:project_id/tickets/number/:number'],
        'tickets.show' => ['GET', '/api/v1/tickets/:id'],
        'tickets.update' => ['PATCH', '/api/v1/tickets/:id'],
        'tickets.changes' => ['POST', '/api/v1/tickets/:id/changes'],
        'tickets.activities' => ['GET', '/api/v1/tickets/:id/activities'],
        'tickets.attachments' => ['GET', '/api/v1/tickets/:id/attachments'],
        'posts.create' => ['POST', '/api/v1/tickets/:ticket_id/posts'],
        'posts.show' => ['GET', '/api/v1/tickets/:ticket_id/posts/:id'],
        'time_sessions.list' => ['GET', '/api/v1/tickets/:ticket_id/time_sessions'],
        'time_sessions.create' => ['POST', '/api/v1/tickets/:ticket_id/time_sessions'],
        'time_sessions.open' => ['GET', '/api/v1/time_sessions/open'],
        'notifications.list' => ['GET', '/api/v1/notifications'],
        'notifications.mark_as_read' => ['POST', '/api/v1/notifications/:id/mark_as_read'],
        'notifications.archive' => ['POST', '/api/v1/notifications/:id/archive'],
        'notifications.mark_all_as_read' => ['POST', '/api/v1/notifications/mark_all_as_read']
      }.freeze

      # Abilities that are not one endpoint: `idempotency` (the Idempotency-Key
      # header on every write, D7), `error_codes` (`code` on every error body, D6),
      # `tickets.paging` (the opt-in pages of comments and attachments on
      # tickets.show and tickets.by_number, R1), `time_sessions.book`
      # (shared duration/date validation and actor-backed booking, R6), and
      # `posts.plain` (posts.create takes post[format] html or plain, by the
      # rule the MCP tool post_comment writes by, Posts::Comment; R3a), and
      # `meetings.glossary_replacements` (meetings.create takes the list
      # meeting[glossary_replacements] of what the sender replaced from the
      # glossary, meetings.show hands it back; K4d).
      FEATURES = %w[idempotency error_codes tickets.paging time_sessions.book posts.plain
                    meetings.glossary_replacements].freeze

      def self.names
        (ENDPOINTS.keys + FEATURES).sort
      end
    end
  end
end
