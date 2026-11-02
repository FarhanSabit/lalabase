# frozen_string_literal: true

# Entry point: other_ticket
#
# Read object: what a relation write may touch for one holder. #other_ticket finds the ticket at
# the other end, #relation a relation of the shown ticket. Each gives the row or nil, so missing,
# foreign, unreadable and out of reach look the same to the caller.
#
# It only finds: no rights decision, no wording, no raising. Those stay with the caller. token:
# means what it means in Tickets::ReadableForToken: nil is no second limit, so the web controller
# writes it out, and the keyword is required: a tool that forgot it would find tickets out of its
# token's reach, and the actors behind it check no rights.
module Tickets
  class RelationAccess
    def initialize(user:, organisation:, token:)
      @user = user
      @organisation = organisation
      @token = token
    end

    def other_ticket(id)
      ReadableForToken.call(user: @user, organisation: @organisation, token: @token).find_by(id: id)
    end

    def relation(ticket, id)
      TicketRelation.visible_to(@user, @organisation, token: @token).touching(ticket).find_by(id: id)
    end
  end
end
