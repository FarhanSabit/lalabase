# frozen_string_literal: true

# The one lock order of the glossary writes (K4a): the term row first. Every
# actor that changes a term or its heard forms takes this lock before it
# writes anything, and Actors::MergeGlossaryTerms takes both of its rows in one
# statement in the order of their ids. Two writes on the same term then wait
# for each other instead of deadlocking (review round 1 of #113: a delete held
# the heard forms and waited for the term a merge held).
#
# The row is read again under the lock. A term deleted or merged away in the
# meantime is refused as gone (code :not_found), never written as a success
# on a row that no longer exists (review round 2 of #113).
module Glossary
  class TermLock
    # term may be nil: a heard form whose term is gone reads its term as nil.
    def self.call(term:)
      gone! unless term
      term.lock!
    rescue ActiveRecord::RecordNotFound
      gone!
    end

    def self.gone!
      raise Actors::ActorError.new(I18n.t('controllers.glossary.not_found'), code: :not_found)
    end
    private_class_method :gone!
  end
end
