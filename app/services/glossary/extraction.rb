# frozen_string_literal: true

# One run of the glossary extraction (K5b): reads the texts of an organisation that
# the account which started the run may read when the run runs, sieves them for
# candidate terms without AI (Glossary::CandidateScan), asks the organisation's own
# model which of them are terms (Glossary::Classifier) and writes GlossaryProposal
# rows with the places they were found (GlossaryProposalSource), for a person to
# accept, merge or dismiss. Glossary::ExtractionJob claims the run and calls this.
#
# * The starter (run.started_by) must still be an active member, else the run fails
#   as starter_inactive. The reach is theirs, computed now:
#   ProjectAccessService.accessible_project_ids for the areas tickets, notes and
#   documents. The rows come through the policy scope of their kind as well
#   (TicketPolicy, NotePolicy, DocumentPolicy::Scope). Each of the three restricts to
#   those same project ids and to nothing per record today; a rule added there
#   holds here too. An account admin reads every project this way.
# * Read, the newest first by updated_at over all six kinds, at most MAX_SOURCES:
#   tickets (Ticket#plain_text_version: title and description), their public
#   comments, the files of both, notes and the current version of each document.
#   Never a private comment, not even for an account admin (public_posts, and of
#   those what Post.readable_by gives the starter), never a meeting or its
#   transcript, never product knowledge.
# * Incremental unless the run reads everything: only rows changed after the start
#   of the last succeeded run of the organisation, stored as scope['since'].
# * Known, and dropped by the scan: every glossary term (any status), every heard
#   form, the spellings of accepted and dismissed proposals, the names of the people
#   directory and of the active members (whole, first and last).
# * A candidate of an open proposal (its term or one of its variants, compared by
#   GlossaryText.compact) goes to that proposal instead of the model: occurrences,
#   new spellings, new places.
# * The rest in batches of BATCH_SIZE, at most MAX_AI_CALLS calls. An answer that
#   could not be read skips its batch; when none could be read the run fails as
#   parse_error. Any other failure ends the run with its code. What a batch brought
#   is written before the next call, so it stays whatever comes after. At most
#   MAX_PROPOSALS_PER_RUN new proposals.
# * Every write first touches the run while it is running, in the same
#   transaction: a run ended elsewhere (a start that found it stale) writes nothing
#   more, and a run that moves does not turn stale.
# * Memory: the texts are loaded LOAD_BATCH at a time and read once by the scan,
#   which keeps counts and snippets, never a whole text.
# * stats: the shape in the header of GlossaryExtractionRun, plus parse_errors and
#   since. truncated says whether MAX_SOURCES, MAX_CANDIDATES, MAX_AI_CALLS or
#   MAX_PROPOSALS_PER_RUN cut anything.
#
# Entry point: .call(run:), for a run the job has claimed (running).
module Glossary
  class Extraction
    MAX_SOURCES = 2_000
    MAX_CANDIDATES = 300
    # The classifier's own bound per call (60): it refuses a bigger batch.
    BATCH_SIZE = Classifier::MAX_CANDIDATES
    MAX_AI_CALLS = 8
    MAX_PROPOSALS_PER_RUN = 300
    # Texts held in memory at a time.
    LOAD_BATCH = 100
    # The areas of ProjectPermission whose reach the run reads.
    AREAS = %i[tickets notes documents].freeze
    # The one kind of scope there is (GlossaryExtractionRun::SCOPE_KINDS).
    KIND = 'organisation'
    # The keys of stats['sources'], one per kind of source.
    SOURCE_KEYS = GlossaryProposalSource::SOURCE_TYPES.index_with { |type| type.underscore.pluralize }.freeze
    # The kinds whose only text is the column plain_text_version: a row without one
    # (a file whose text is not extracted yet) takes no place among MAX_SOURCES.
    COLUMN_TEXT_TYPES = %w[Post TicketDocument PostDocument].freeze
    # The loader of the texts of each kind.
    TEXT_READERS = {
      'Ticket' => :ticket_texts, 'Post' => :comment_texts, 'TicketDocument' => :ticket_file_texts,
      'PostDocument' => :comment_file_texts, 'Note' => :note_texts, 'DocumentVersion' => :document_texts
    }.freeze
    # What a new proposal writes, read from the model once it has checked the row.
    PROPOSAL_COLUMNS = %w[organisation_id term normalized_term category variants hint occurrences status].freeze

    # A source chosen by kind, id and time. Its text is loaded later, in batches.
    Pick = Data.define(:type, :id, :updated_at)
    # The run is no longer running here: a start found it stale and ended it.
    class Lost < StandardError; end
    private_constant :Pick, :Lost

    def self.call(run:)
      new(run: run).call
    end

    def initialize(run:)
      @run = run
      @organisation = run.organisation
      @read = SOURCE_KEYS.values.index_with(0)
      @counts = { 'candidates' => 0, 'ai_calls' => 0, 'parse_errors' => 0, 'proposals_created' => 0,
                  'proposals_updated' => 0 }
      @truncated = false
    end

    # The reads run under the run's organisation; the caller sets nothing.
    def call
      ActsAsTenant.with_tenant(@organisation) { extract }
      @run
    end

    private

    def extract
      @starter = active_starter
      return @run.mark_failed!('starter_inactive', from: ['running']) unless @starter

      @since = since
      touch!(scope: @run.scope.to_h.merge('since' => @since&.iso8601(6)))
      scan = CandidateScan.call(sources: sources(picks), known: known_forms, common_words: WordLists.common,
                                max_candidates: MAX_CANDIDATES)
      touch!
      @counts['candidates'] = scan.total
      cut! if scan.truncated
      code = classify(attach_to_open_proposals(scan.candidates))
      code ? end_failed(code) : end_succeeded
    rescue Lost
      nil
    end

    # Read fresh, not through the run's association: the run runs later than the
    # start, and the membership may have ended in between.
    def active_starter
      starter = User.find_by(id: @run.started_by_id) if @run.started_by_id
      starter if AccessCheck::ProjectAccessService.active_member?(starter, @organisation)
    end

    # The start of the last succeeded run of the organisation, never this one's.
    # What changed while that run was reading may have changed after it read the
    # row, so the next run reads it again.
    def since
      return if @run.everything?

      GlossaryExtractionRun.where(organisation_id: @organisation.id, status: 'succeeded')
                           .where("scope ->> 'kind' = ?", KIND)
                           .where.not(id: @run.id)
                           .maximum(:created_at)
    end

    # The projects of one area, asked once per area by the kind that reads it.
    def reach(area)
      @reach ||= {}
      @reach[area] ||= AccessCheck::ProjectAccessService.accessible_project_ids(@starter, @organisation,
                                                                                action: :read, area: area)
    end

    # The rows of a kind in its reach, through its policy scope.
    def readable(model, area)
      Pundit.policy_scope!(@starter, model.where(organisation_id: @organisation.id)).where(project_id: reach(area))
    end

    def tickets
      @tickets ||= readable(Ticket, :tickets)
    end

    # The public comments of those tickets, also for an account admin, whom
    # readable_by alone would give every private one.
    def comments
      @comments ||= Post.public_posts.readable_by(@starter, @organisation)
                        .where(organisation_id: @organisation.id, ticket_id: tickets.select(:id))
    end

    def ticket_files
      TicketDocument.where(organisation_id: @organisation.id, ticket_id: tickets.select(:id))
    end

    def comment_files
      PostDocument.where(organisation_id: @organisation.id, post_id: comments.select(:id))
    end

    def notes
      @notes ||= readable(Note, :notes)
    end

    # The current version of each readable document, never an older one.
    def document_versions
      DocumentVersion.where(organisation_id: @organisation.id,
                            id: readable(Document, :documents).select(:current_version_id))
    end

    def relations
      { 'Ticket' => tickets, 'Post' => comments, 'TicketDocument' => ticket_files, 'PostDocument' => comment_files,
        'Note' => notes, 'DocumentVersion' => document_versions }
    end

    # The newest MAX_SOURCES over all six kinds, by id and time only. One more of
    # each kind than fits tells whether anything is cut: more than MAX_SOURCES in all
    # of these means more than MAX_SOURCES in the organisation, and the reverse.
    def picks
      found = relations.flat_map do |type, relation|
        newest(type, relation).map { |id, updated_at| Pick.new(type: type, id: id, updated_at: updated_at) }
      end
      cut! if found.size > MAX_SOURCES
      found.sort_by { |pick| [-pick.updated_at.to_r, GlossaryProposalSource::SOURCE_TYPES.index(pick.type), pick.id] }
           .first(MAX_SOURCES)
    end

    def newest(type, relation)
      table = relation.model.arel_table
      relation = relation.where(table[:updated_at].gt(@since)) if @since
      relation = relation.where.not(plain_text_version: [nil, '']) if COLUMN_TEXT_TYPES.include?(type)
      relation.reorder(table[:updated_at].desc, table[:id].asc).limit(MAX_SOURCES + 1)
              .pluck(table[:id], table[:updated_at])
    end

    # Read once, as the scan reads it: LOAD_BATCH texts at a time, one query per
    # kind and batch, through the same rights as the picks. A row gone or out of
    # reach in between, or without text, is skipped and not counted.
    def sources(picks)
      Enumerator.new do |yielder|
        picks.each_slice(LOAD_BATCH) do |slice|
          texts = slice.group_by(&:type).to_h { |type, group| [type, send(TEXT_READERS.fetch(type), group.map(&:id))] }
          slice.each do |pick|
            project_id, text = texts.fetch(pick.type)[pick.id]
            next if text.blank?

            @read[SOURCE_KEYS.fetch(pick.type)] += 1
            yielder << CandidateScan::Source.new(type: pick.type, id: pick.id, project_id: project_id, text: text)
          end
        end
      end
    end

    # Each text reader answers { id => [project_id, text] }. A ticket's text is the
    # method plain_text_version (title and description), never a column.
    def ticket_texts(ids)
      tickets.where(id: ids).with_rich_text_content
             .to_h { |ticket| [ticket.id, [ticket.project_id, ticket.plain_text_version]] }
    end

    def comment_texts(ids)
      texts(comments.where(id: ids).joins(:ticket), Ticket.arel_table[:project_id], :plain_text_version)
    end

    def ticket_file_texts(ids)
      texts(ticket_files.where(id: ids).joins(:ticket), Ticket.arel_table[:project_id], :plain_text_version)
    end

    def comment_file_texts(ids)
      texts(comment_files.where(id: ids).joins(post: :ticket), Ticket.arel_table[:project_id], :plain_text_version)
    end

    def note_texts(ids)
      texts(notes.where(id: ids), Note.arel_table[:project_id], :title, :plain_text_version)
    end

    def document_texts(ids)
      texts(document_versions.where(id: ids).joins(:document), Document.arel_table[:project_id],
            :title, :description, :plain_text_version)
    end

    # The parts of a text joined by line breaks, so a name never runs from one part
    # into the next.
    def texts(relation, project_column, *columns)
      table = relation.model.arel_table
      relation.pluck(table[:id], project_column, *columns.map { |column| table[column] })
              .to_h { |id, project_id, *parts| [id, [project_id, parts.compact_blank.join("\n")]] }
    end

    def known_forms
      [*GlossaryTerm.where(organisation_id: @organisation.id).pluck(:term),
       *TermCorrection.where(organisation_id: @organisation.id).distinct.pluck(:heard),
       *decided_spellings, *people_names, *member_names].compact_blank
    end

    def decided_spellings
      GlossaryProposal.where(organisation_id: @organisation.id, status: %w[accepted dismissed])
                      .pluck(:term, :variants)
                      .flat_map { |term, variants| [term, *Array(variants).grep(String)] }
    end

    # A row of the people directory has one name: whole, without a note in
    # brackets, and its first and its last word.
    def people_names
      Person.where(organisation_id: @organisation.id).pluck(:name).flat_map do |name|
        words = PersonName.without_note(name).split
        [name, words.join(' '), words.first, words.last]
      end
    end

    def member_names
      User.where(id: Membership.active.where(organisation_id: @organisation.id).select(:user_id))
          .pluck(:first_name, :last_name)
          .flat_map { |first, last| [[first, last].compact_blank.join(' '), first, last] }
    end

    # The candidates for the model: those of no open proposal. The others go to
    # their proposal now.
    def attach_to_open_proposals(candidates)
      keys = open_proposal_keys
      found, fresh = candidates.partition { |candidate| keys.key?(candidate.key) }
      add_to_open_proposals(found.group_by { |candidate| keys.fetch(candidate.key) }) if found.any?
      fresh
    end

    # Each compared key of an open proposal to that proposal: the terms first, so a
    # term always names its own proposal, then the variants (a merge leaves the
    # spellings of the merged one there).
    def open_proposal_keys
      rows = GlossaryProposal.where(organisation_id: @organisation.id, status: 'open').order(:id).pluck(:id, :term, :variants)
      terms = rows.map { |id, term, _variants| [GlossaryText.compact(term), id] }
      variants = rows.flat_map { |id, _term, forms| Array(forms).grep(String).map { |form| [GlossaryText.compact(form), id] } }
      (terms + variants).each_with_object({}) { |(key, id), keys| keys[key] ||= id }
    end

    # Under the lock of each proposal (in the order of their ids, as
    # Actors::MergeGlossaryProposals locks two), and only while it is open: one
    # accepted, dismissed or merged away in the meantime stays as it is. No glossary
    # term is locked, so the one lock order of the glossary (the term first) holds.
    def add_to_open_proposals(found)
      GlossaryProposal.transaction do
        touch!
        proposals = GlossaryProposal.where(organisation_id: @organisation.id, id: found.keys, status: 'open')
                                    .order(:id).lock.to_a
        places = known_places(proposals.map(&:id))
        rows = proposals.flat_map do |proposal|
          candidates = found.fetch(proposal.id)
          proposal.occurrences += candidates.sum(&:occurrences)
          proposal.variants = with_new_spellings(proposal, candidates)
          proposal.save!
          new_places(proposal.id, candidates, places.fetch(proposal.id, []))
        end
        insert_places(rows)
        @counts['proposals_updated'] = proposals.size
      end
    end

    def known_places(proposal_ids)
      GlossaryProposalSource.where(organisation_id: @organisation.id, glossary_proposal_id: proposal_ids)
                            .pluck(:glossary_proposal_id, :source_type, :source_id)
                            .group_by(&:first).transform_values { |rows| rows.map { |row| row.drop(1) } }
    end

    # Its own variants first, then the spellings it lacks, the most frequent first;
    # never its term and never a second spelling of one compared form; at most
    # GlossaryProposal::MAX_VARIANTS.
    def with_new_spellings(proposal, candidates)
      seen = Set[proposal.normalized_term]
      spellings = [*proposal.variants, *candidates.flat_map(&:forms)].grep(String)
      spellings.select { |form| seen.add?(GlossaryText.normalize(form)) }.first(GlossaryProposal::MAX_VARIANTS)
    end

    # The places a proposal lacks, the busiest first, until it holds
    # GlossaryProposal::MAX_SOURCES. A place it has keeps its own snippet.
    def new_places(proposal_id, candidates, known)
      room = GlossaryProposal::MAX_SOURCES - known.size
      return [] unless room.positive?

      seen = known.to_set
      candidates.flat_map(&:snippets)
                .sort_by.with_index { |snippet, index| [-snippet.occurrences, index] }
                .select { |snippet| seen.add?([snippet.type, snippet.id]) }
                .first(room)
                .map { |snippet| place(proposal_id, snippet) }
    end

    # nil, or the code that ends the run. Once MAX_PROPOSALS_PER_RUN are written
    # the model is asked no more: what it would answer could not be written.
    def classify(candidates)
      batches = candidates.each_slice(BATCH_SIZE).to_a
      cut! if batches.size > MAX_AI_CALLS
      answered = 0
      batches.first(MAX_AI_CALLS).each do |batch|
        if @counts['proposals_created'] >= MAX_PROPOSALS_PER_RUN
          cut!
          break
        end

        rows = ask(batch)
        if rows
          answered += 1
          write_proposals(rows, batch)
        else
          touch!
        end
      end
      'parse_error' if answered.zero? && @counts['parse_errors'].positive?
    rescue Classifier::Failure => e
      e.code
    end

    # One call, counted whatever it answers. nil when the answer could not be
    # read: that batch is skipped. Any other failure ends the run.
    def ask(batch)
      @counts['ai_calls'] += 1
      Classifier.call(organisation: @organisation, user: @starter, run: @run, candidates: batch)
    rescue Classifier::Failure => e
      raise unless e.code == 'parse_error'

      @counts['parse_errors'] += 1
      nil
    end

    # The rows of one batch, with the places of their candidates, in one
    # transaction. Each row is checked by the model first; the places come from
    # what the scan kept, never from the model.
    def write_proposals(rows, batch)
      room = MAX_PROPOSALS_PER_RUN - @counts['proposals_created']
      cut! if rows.size > room
      candidates = batch.index_by(&:key)
      checked = rows.first(room).filter_map do |row|
        candidate = candidates.fetch(row.key)
        proposal = checked_proposal(row, candidate)
        [proposal, candidate] if proposal
      end
      GlossaryProposal.transaction do
        touch!
        written = insert_proposals(checked.map(&:first))
        insert_places(checked.flat_map { |proposal, candidate| places_of(written[proposal.normalized_term], candidate) })
        @counts['proposals_created'] += written.size
      end
    end

    # Checked by the model, its cleaning and its rules, before anything is written.
    # The reference to the run is set after the check, when the row is written: it
    # is this run, read in this organisation, and checking it again would ask the
    # database the same question once per batch. A form taken in the meantime
    # (another run wrote it at the same moment) is an existing proposal, not an
    # error; anything else invalid is a mistake and raises.
    def checked_proposal(row, candidate)
      proposal = GlossaryProposal.new(organisation: @organisation, term: row.term, category: row.category,
                                      variants: row.variants, hint: row.hint, occurrences: candidate.occurrences)
      proposal.validate
      return if proposal.errors.of_kind?(:term, :taken)
      raise ActiveRecord::RecordInvalid, proposal if proposal.errors.any?

      proposal
    end

    # In one statement, as the model has checked the rows. A form another run
    # wrote at the same moment is skipped by the unique index and stays its
    # proposal. Answers { normalized_term => id } of the rows written.
    def insert_proposals(proposals)
      return {} if proposals.empty?

      rows = proposals.map { |proposal| proposal.attributes.slice(*PROPOSAL_COLUMNS).merge('glossary_extraction_run_id' => @run.id) }
      GlossaryProposal.insert_all(rows, unique_by: :index_glossary_proposals_on_org_and_normalized_term,
                                        returning: %w[id normalized_term])
                      .rows.to_h { |id, normalized_term| [normalized_term, id] }
    end

    def places_of(proposal_id, candidate)
      return [] unless proposal_id

      candidate.snippets.first(GlossaryProposal::MAX_SOURCES).map { |snippet| place(proposal_id, snippet) }
    end

    def place(proposal_id, snippet)
      { organisation_id: @organisation.id, glossary_proposal_id: proposal_id, source_type: snippet.type,
        source_id: snippet.id, project_id: snippet.project_id, snippet: snippet.text, occurrences: snippet.occurrences }
    end

    # Past the model's checks, in one statement, and safe that way: every value
    # comes from this run, never from a request or the model. The proposals are
    # this organisation's, written or locked by this run; the sources and their
    # projects are rows the run read through queries bound to this organisation;
    # the kinds are the six of SOURCE_TYPES (CandidateScan::Source refuses any
    # other); the scan cuts a snippet to MAX_SNIPPET and counts at least one
    # occurrence. The foreign keys and check constraints hold the rest. A place a
    # proposal got in the meantime is kept once.
    def insert_places(rows)
      return if rows.empty?

      GlossaryProposalSource.insert_all(rows, unique_by: :index_glossary_proposal_sources_on_proposal_and_source)
    end

    def cut!
      @truncated = true
    end

    def stats
      { 'sources' => @read, 'projects_reached' => AREAS.flat_map { |area| reach(area) }.uniq.size,
        'projects_total' => Project.where(organisation_id: @organisation.id).count, **@counts,
        'truncated' => @truncated, 'since' => @since&.iso8601(6) }
    end

    def end_succeeded
      update_running(status: 'succeeded', finished_at: Time.current, stats: stats)
    end

    def end_failed(code)
      update_running(stats: stats)
      @run.mark_failed!(code, from: ['running'])
    end

    # Touches the run with the values given, or raises Lost when the run is no
    # longer running here.
    def touch!(**values)
      raise Lost unless update_running(**values)
    end

    # One UPDATE whose condition is the status of the row, as mark_failed! writes
    # one: true only when it changed the row, then the copy in memory says the same.
    def update_running(**values)
      values[:updated_at] = Time.current
      changed = GlossaryExtractionRun.where(id: @run.id, organisation_id: @organisation.id, status: 'running')
                                     .update_all(values) == 1
      return false unless changed

      values.each { |name, value| @run[name] = value }
      @run.clear_attribute_changes(values.keys)
      true
    end
  end
end
