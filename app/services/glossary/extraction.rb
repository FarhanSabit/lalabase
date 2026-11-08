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
#   of the last succeeded run over the organisation, stored as scope['since'].
#   A run over one document never sets that bound: it read nothing else.
# * A run over one document (K5c, scope kind document): only the version its
#   scope names, current or not by now, whole, without a bound (since stays nil),
#   with the same caps. Its document must still be readable by the starter, by
#   the same reach and policy scope as above, and the version must have text,
#   else the run fails as document_unavailable (after starter_inactive). Its
#   stats count its one project as one of one.
# * Known, and dropped by the scan: every glossary term (any status), every heard
#   form, the spellings of accepted and dismissed proposals, the names of the people
#   directory and of the active members (whole, first and last).
# * A candidate of an open proposal (its term or one of its variants, compared by
#   GlossaryText.compact) goes to that proposal instead of the model: new
#   spellings, new places and the occurrences of those places. Such candidates
#   take none of the MAX_CANDIDATES places of the others: open proposals left
#   undecided would else fill every later run.
# * The rest, at most MAX_CANDIDATES, in batches of BATCH_SIZE, at most
#   MAX_AI_CALLS calls (a safety net: five calls hold them today). An answer that
#   could not be read skips its batch; when none could be read the run fails as
#   parse_error. Any other failure ends the run with its code. What a batch brought
#   is written before the next call, so it stays whatever comes after. At most
#   MAX_PROPOSALS_PER_RUN new proposals.
# * Every write first touches the run while it is running, in the same
#   transaction, and so does every load batch of the scan: a run ended elsewhere
#   (a start that found it stale) reads and writes nothing more, and a run that
#   moves does not turn stale. While the model answers, Glossary::RunHeartbeat
#   touches it from a thread of its own: a call to the provider can outlast
#   STALE_AFTER, and a run ended as stale in the middle of one would be paid
#   for twice.
# * Memory and time: the texts are loaded LOAD_BATCH at a time, each cut to
#   MAX_SOURCE_CHARS, and read once by the scan, which keeps counts and snippets
#   of at most CandidateScan::MAX_GROUPS keys, never a whole text.
# * stats: the shape in the header of GlossaryExtractionRun, plus parse_errors and
#   since. truncated says whether MAX_SOURCES, MAX_SOURCE_CHARS, the scan's bound
#   on keys (CandidateScan::MAX_GROUPS), MAX_CANDIDATES, MAX_AI_CALLS or
#   MAX_PROPOSALS_PER_RUN cut anything.
#
# Entry point: .call(run:), for a run the job has claimed (running).
module Glossary
  class Extraction
    MAX_SOURCES = 2_000
    MAX_CANDIDATES = 300
    # The classifier's own bound per call (60): it refuses a bigger batch.
    BATCH_SIZE = Classifier::MAX_CANDIDATES
    # A safety net: MAX_CANDIDATES fit into five calls today, so this binds
    # only should those numbers change (the guard in the spec says so).
    MAX_AI_CALLS = 8
    MAX_PROPOSALS_PER_RUN = 300
    # Texts held in memory at a time.
    LOAD_BATCH = 100
    # The characters of one text the scan reads; the rest is cut. Some 40
    # pages: a long document names its terms early and often, so its start
    # finds them, and a whole book would hold up the run. The bound of a batch:
    # LOAD_BATCH texts of this length are ten million characters in memory,
    # which the scan reads in some ten seconds on a developer machine (about a
    # million characters a second), far below
    # GlossaryExtractionRun::STALE_AFTER; the run is touched before each batch.
    MAX_SOURCE_CHARS = 100_000
    # The areas of ProjectPermission whose reach the run reads.
    AREAS = %i[tickets notes documents].freeze
    # The kind of a run over the organisation (GlossaryExtractionRun::SCOPE_KINDS),
    # the only kind whose runs set the bound of the next one.
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
    PROPOSAL_COLUMNS = %w[organisation_id term normalized_term category variants hint hint_sources occurrences status].freeze

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
      return @run.mark_failed!('document_unavailable', from: ['running']) if @run.document? && !document_readable?

      @since = since
      touch!(scope: @run.scope.to_h.merge('since' => @since&.iso8601(6)))
      keys = open_proposal_keys
      scan = CandidateScan.call(sources: sources(picks), known: known_forms, common_words: WordLists.common,
                                max_candidates: MAX_CANDIDATES + keys.size)
      touch!
      @counts['candidates'] = scan.total
      code = classify(attach_to_open_proposals(scan, keys))
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

    # The start of the last succeeded run over the organisation, never this one's.
    # What changed while that run was reading may have changed after it read the
    # row, so the next run reads it again. A run over one document reads it whole.
    def since
      return if @run.everything? || @run.document?

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

    # The current version of each readable document, never an older one. A run
    # over one document reads the version it names, while its document is
    # readable.
    def document_versions
      if @run.document?
        DocumentVersion.where(organisation_id: @organisation.id, id: @run.document_version_id,
                              document_id: readable(Document, :documents).select(:id))
      else
        DocumentVersion.where(organisation_id: @organisation.id,
                              id: readable(Document, :documents).select(:current_version_id))
      end
    end

    # The version of a run over one document is there, readable by the starter
    # now, and holds text: something besides whitespace, as text_status reads
    # present.
    def document_readable?
      document_versions.where(DocumentVersion.arel_table[:plain_text_version].matches_regexp('[^[:space:]]')).exists?
    end

    def relations
      return { 'DocumentVersion' => document_versions } if @run.document?

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
    # kind and batch, through the same rights as the picks, each text cut to
    # MAX_SOURCE_CHARS. A row gone or out of reach in between, or without text,
    # is skipped and not counted. The scan reads while it pulls the texts, so
    # the run is touched before each batch: a long scan does not turn it stale,
    # and a run ended elsewhere reads no further batch.
    def sources(picks)
      Enumerator.new do |yielder|
        picks.each_slice(LOAD_BATCH) do |slice|
          touch!
          texts = slice.group_by(&:type).to_h { |type, group| [type, send(TEXT_READERS.fetch(type), group.map(&:id))] }
          slice.each do |pick|
            project_id, text = texts.fetch(pick.type)[pick.id]
            text = cut_to_size(text)
            next if text.blank?

            @read[SOURCE_KEYS.fetch(pick.type)] += 1
            yielder << CandidateScan::Source.new(type: pick.type, id: pick.id, project_id: project_id, text: text)
          end
        end
      end
    end

    # At most MAX_SOURCE_CHARS, cut between words as the scan cuts a snippet
    # (CandidateScan#beginning): the piece of a word at the cut would be a
    # candidate of its own. A text without a break keeps its first characters.
    # A cut text was read only in part, so the run says it cut.
    def cut_to_size(text)
      return text if text.nil? || text.length <= MAX_SOURCE_CHARS

      cut!
      piece = text[0, MAX_SOURCE_CHARS]
      return piece if text[MAX_SOURCE_CHARS].match?(/[[:space:]]/)

      space = piece.rindex(/[[:space:]]/)
      space ? piece[0, space] : piece
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
    # into the next. The database sends at most one character more than
    # MAX_SOURCE_CHARS of each column, so a batch holds no whole file and the cut
    # (cut_to_size) still sees whether it falls into a word. A ticket's
    # description comes whole through Action Text and is cut once it is text.
    def texts(relation, project_column, *columns)
      table = relation.model.arel_table
      relation.pluck(table[:id], project_column, *columns.map { |column| capped(table[column]) })
              .to_h { |id, project_id, *parts| [id, [project_id, parts.compact_blank.join("\n")]] }
    end

    # LEFT counts characters, not bytes.
    def capped(column)
      Arel::Nodes::NamedFunction.new('LEFT', [column, Arel::Nodes.build_quoted(MAX_SOURCE_CHARS + 1)])
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

    # The candidates for the model: the best MAX_CANDIDATES of those of no open
    # proposal. The others go to their proposal now. They take no place of a
    # fresh one: a key names at most one candidate, so the scan, keeping one
    # more per key of an open proposal, holds the best MAX_CANDIDATES fresh ones
    # whatever it found of the open proposals. Cut is what the scan left out or
    # a fresh one past MAX_CANDIDATES.
    def attach_to_open_proposals(scan, keys)
      found, fresh = scan.candidates.partition { |candidate| keys.key?(candidate.key) }
      cut! if scan.truncated || fresh.size > MAX_CANDIDATES
      add_to_open_proposals(found.group_by { |candidate| keys.fetch(candidate.key) }) if found.any?
      fresh.first(MAX_CANDIDATES)
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
    #
    # A proposal gains the occurrences of the places it gains, so a place it has
    # counts once however often a run reads it again (a run that reads
    # everything, a row that changed). What a run finds past the places a
    # proposal holds (GlossaryProposal::MAX_SOURCES) adds nothing: there the
    # proposal cannot tell a source it counted before from a new one, and a count
    # that stays low orders the review list better than one that grows with every
    # read.
    def add_to_open_proposals(found)
      GlossaryProposal.transaction do
        touch!
        proposals = GlossaryProposal.where(organisation_id: @organisation.id, id: found.keys, status: 'open')
                                    .order(:id).lock.to_a
        places = known_places(proposals.map(&:id))
        rows = proposals.flat_map do |proposal|
          candidates = found.fetch(proposal.id)
          gained = new_places(proposal.id, candidates, places.fetch(proposal.id, []))
          proposal.occurrences += gained.sum { |place| place.fetch(:occurrences) }
          proposal.variants = with_new_spellings(proposal, candidates)
          proposal.save!
          gained
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

    # One call, counted whatever it answers, with the run's heartbeat around
    # it. nil when the answer could not be read: that batch is skipped. Any
    # other failure ends the run.
    def ask(batch)
      @counts['ai_calls'] += 1
      RunHeartbeat.call(run: @run) do
        Classifier.call(organisation: @organisation, user: @starter, run: @run, candidates: batch)
      end
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
      hint_sources = hint_sources_for(batch)
      checked = rows.first(room).filter_map do |row|
        candidate = candidates.fetch(row.key)
        proposal = checked_proposal(row, candidate, hint_sources)
        [proposal, candidate] if proposal
      end
      GlossaryProposal.transaction do
        touch!
        written = insert_proposals(checked.map(&:first))
        insert_places(checked.flat_map { |proposal, candidate| places_of(written[proposal.normalized_term], candidate) })
        @counts['proposals_created'] += written.size
      end
    end

    # The exact context selection of Classifier#payload, for the WHOLE input
    # batch, including candidates the model drops. The model's free-text hint
    # can combine any of those snippets; the candidate's own places alone do
    # not authorize it. Only identifiers from our tenant-bound scan are stored.
    def hint_sources_for(batch)
      batch.flat_map { |candidate| candidate.snippets.first(Classifier::SNIPPETS_PER_CANDIDATE) }
           .map { |snippet| { 'source_type' => snippet.type, 'source_id' => snippet.id } }.uniq
    end

    # Checked by the model, its cleaning and its rules, before anything is written.
    # The reference to the run is set after the check, when the row is written: it
    # is this run, read in this organisation, and checking it again would ask the
    # database the same question once per batch. A form taken in the meantime
    # (another run wrote it at the same moment) is an existing proposal, not an
    # error; anything else invalid is a mistake and raises.
    def checked_proposal(row, candidate, hint_sources)
      proposal = GlossaryProposal.new(organisation: @organisation, term: row.term, category: row.category,
                                      variants: row.variants, hint: row.hint, hint_sources: hint_sources,
                                      occurrences: candidate.occurrences)
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
      reached, total = projects_counted
      { 'sources' => @read, 'projects_reached' => reached, 'projects_total' => total, **@counts,
        'truncated' => @truncated, 'since' => @since&.iso8601(6) }
    end

    # The projects the starter reached of all of the organisation; a run over one
    # document reached the one project it read (else it failed before).
    def projects_counted
      return [1, 1] if @run.document?

      [AREAS.flat_map { |area| reach(area) }.uniq.size, Project.where(organisation_id: @organisation.id).count]
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
