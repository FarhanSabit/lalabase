# frozen_string_literal: true

# Loaded outside RSpec too (the rake task), where neither is required yet.
require 'active_support/testing/time_helpers'
require 'action_dispatch/testing/integration'

# The MCP contract (terminal client plan in lalabase-private, slice S0 a): what a
# client of this server sees, recorded from real requests through the Rack stack.
#
#   * `tools/list` exactly as the wire carries it (after Mcp::Dispatcher injected
#     `project_id` and `idempotency_key`), plus `initialize`;
#   * one answer per outcome (ok, empty, each error class) for every MCP tool and
#     REST reader the terminal client `lalabase` uses.
#
# Synthetic data only: fixed ids (IDS), frozen time, fixed token prefixes, no
# token in the file. An id the database generates (a new comment) is replaced by
# a numbered placeholder in order of appearance, so the file is the same on
# every run.
#
# Two users of this file, one rule: spec/contracts/mcp_contract_spec.rb COMPARES
# (and never writes), `RAILS_ENV=test bin/rails mcp:contract` WRITES (and never
# runs a spec). The client repository keeps a copy and checks its features
# against it, so a renamed argument or a vanished field turns red here first.
module McpContract
  FILE = Rails.root.join('spec/fixtures/mcp_contract.json')
  REGENERATE = 'RAILS_ENV=test bin/rails mcp:contract'

  def self.read
    JSON.parse(FILE.read)
  end

  def self.write(contract)
    FILE.write("#{JSON.pretty_generate('header' => header(contract), 'contract' => contract)}\n")
  end

  # Outside the compared payload. `core_commit` is the commit the working tree
  # was based on; `core_dirty` says the payload holds changes on top of it, the
  # normal case while a PR regenerates the file, so the commit alone cannot
  # rebuild it. `contract_sha256` names the payload itself: equal checksum, equal
  # contract, whatever the commit says.
  def self.header(contract)
    git = ->(*args) { IO.popen(['git', '-C', Rails.root.to_s, *args], &:read).strip }
    {
      'regenerate' => REGENERATE,
      'core_commit' => git.call('rev-parse', 'HEAD'),
      'core_dirty' => !git.call('status', '--porcelain').empty?,
      'contract_sha256' => checksum(contract)
    }
  end

  # SHA-256 of the compact JSON of the payload, keys in file order. The terminal
  # client rebuilds it to check its copy (lalabase/lalabase-cli,
  # tools/update-contract): it compacts the payload exactly as the file writes it
  # (Go's json.Compact, no re-escaping) and hashes that. So the file must keep the
  # escaping JSON.generate uses, which JSON.pretty_generate does; a writer that
  # escapes differently (\u00e4 for an umlaut, \/ for a slash) would fail the
  # check without any change to the contract.
  def self.checksum(contract)
    Digest::SHA256.hexdigest(JSON.generate(contract))
  end

  # The JSON paths where two contracts differ, `$` being the root. A missing
  # side shows as `(missing)`, so a vanished field and a new one read alike.
  def self.differences(expected, actual, path = '$')
    return [] if expected == actual

    if expected.is_a?(Hash) && actual.is_a?(Hash)
      (expected.keys | actual.keys).flat_map do |key|
        differences(expected.fetch(key, :missing), actual.fetch(key, :missing), "#{path}.#{key}")
      end
    elsif expected.is_a?(Array) && actual.is_a?(Array) && expected.size == actual.size
      expected.zip(actual).each_with_index.flat_map { |(left, right), index| differences(left, right, "#{path}[#{index}]") }
    else
      ["#{path}: #{brief(expected)} -> #{brief(actual)}"]
    end
  end

  def self.brief(value)
    return '(missing)' if value == :missing

    text = value.to_json
    text.length > 120 ? "#{text[0, 120]}..." : text
  end
  private_class_method :brief

  # Runs the recorder inside a transaction that is rolled back, the way the
  # rake task needs it. The spec runs Recorder directly, inside its own
  # example transaction.
  def self.record_isolated
    connection = ActiveRecord::Base.connection
    connection.begin_transaction(joinable: false, _lazy: false)
    Recorder.new.call
  ensure
    connection.rollback_transaction if connection.transaction_open?
  end

  class Recorder
    include FactoryBot::Syntax::Methods
    include ActiveSupport::Testing::TimeHelpers

    START = Time.utc(2026, 1, 5, 9, 0, 0)

    IDS = {
      organisation: 1, other_organisation: 2,
      anna: 11, ben: 12, carla: 13, dora: 14,
      role: 21, other_role: 22, guest_role: 23,
      website: 31, internal: 32, handbook: 33, foreign_project: 34, archive: 35,
      login_ticket: 41, export_ticket: 42, hidden_ticket: 43, archived_ticket: 44, internal_ticket: 45,
      first_post: 51, second_post: 52, first_post_file: 53,
      deploy_note: 61,
      unread_notification: 71, read_notification: 72, archived_notification: 73,
      write_token: 81, read_token: 82, deactivated_token: 83, limited_token: 84, dora_token: 85,
      doris_person: 91, ben_person: 92,
      kickoff_meeting: 101, review_meeting: 102, hidden_meeting: 103, internal_meeting: 104, foreign_meeting: 105,
      gone_meeting: 106, gone_user: 107, long_meeting: 108,
      missing: 999
    }.transform_values { |n| format('00000000-0000-4000-8000-%012d', n) }.freeze

    UUID = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/

    def call
      previous_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      travel_to(START) do
        build_world
        # Through JSON once, so the spec compares exactly what the file holds.
        JSON.parse(JSON.generate(canonical('mcp' => mcp_section, 'rest' => rest_section)))
      end
    ensure
      ActiveJob::Base.queue_adapter = previous_adapter
    end

    private

    def id(name) = IDS.fetch(name)

    # One minute between records, so an order by created_at has no ties.
    def tick
      travel(1.minute)
    end

    def build_world
      @organisation = record { create(:organisation, id: id(:organisation), name: 'Nordlicht GmbH', subdomain: 'nordlicht', domain: 'nordlicht.example.com') }
      @other_organisation = record { create(:organisation, id: id(:other_organisation), name: 'Fremdfirma AG', subdomain: 'fremdfirma', domain: 'fremdfirma.example.com') }

      @anna = record { create(:user, id: id(:anna), email: 'anna@example.com', first_name: 'Anna', last_name: 'Albers') }
      @ben = record { create(:user, id: id(:ben), email: 'ben@example.com', first_name: 'Ben', last_name: 'Berger') }
      @carla = record { create(:user, id: id(:carla), email: 'carla@example.com', first_name: 'Carla', last_name: 'Conrad') }

      in_org do
        role = record { create(:role, id: id(:role), organisation: @organisation, title: 'Mitglied') }
        [@anna, @ben, @carla].each do |user|
          record { create(:membership, user: user, organisation: @organisation, role: role, active: true) }
        end

        @website = record { create(:project, id: id(:website), organisation: @organisation, name: 'Website-Relaunch', description: 'Neue Website bis März') }
        @internal = record { create(:project, id: id(:internal), organisation: @organisation, name: 'Intern', description: 'Noch leer') }
        @handbook = record { create(:project, id: id(:handbook), organisation: @organisation, name: 'Handbuch', description: 'Nur Notizen') }
        @archive = record { create(:project, id: id(:archive), organisation: @organisation, name: 'Archiv', description: 'Nur lesen') }
        # The statuses and priorities a project gets from the "default attributes"
        # box on the new-project form, so tickets carry real status keys.
        [@website, @internal].each { |project| record { Projects::DefaultAttributeService.new(project).call } }

        record { create(:project_permission, user: @anna, project: @website, tickets_access: :read_write, notes_access: :read_write) }
        record { create(:project_permission, user: @ben, project: @website, tickets_access: :read_write) }
        record { create(:project_permission, user: @anna, project: @internal, tickets_access: :read_write) }
        record { create(:project_permission, user: @anna, project: @handbook, notes_access: :read_only) }
        record { create(:project_permission, user: @anna, project: @archive, tickets_access: :read_only) }

        @login = record do
          create(:ticket, id: id(:login_ticket), project: @website, organisation: @organisation, creator: @anna,
                          title: 'Login bricht ab', content: 'Nach dem Absenden bleibt die Seite weiß.', assignees: [@anna],
                          custom_attributes: { 'status' => 'in_progress', 'priority' => 'high' })
        end
        @export = record do
          create(:ticket, id: id(:export_ticket), project: @website, organisation: @organisation, creator: @ben, title: 'Export als CSV', content: 'Spalten wie in der Liste.',
                          custom_attributes: { 'status' => 'new', 'priority' => 'normal' })
        end
        record { create(:ticket, id: id(:hidden_ticket), project: @handbook, organisation: @organisation, creator: @anna, title: 'Vertraulich', content: 'Nicht für Notiz-Leser.') }
        record { create(:ticket, id: id(:archived_ticket), project: @archive, organisation: @organisation, creator: @anna, title: 'Alte Anfrage', content: 'Nur zum Nachlesen.') }

        record { create(:post, id: id(:first_post), ticket: @login, organisation: @organisation, user: @ben, content: 'Tritt nur in Safari auf.', create_embeddings: false) }
        record { create(:post, id: id(:second_post), ticket: @login, organisation: @organisation, user: @anna, content: 'Ich schaue es mir an.', create_embeddings: false) }

        record { create(:note, id: id(:deploy_note), project: @website, organisation: @organisation, creator: @anna, title: 'Deploy-Anleitung', content: 'Erst Staging, dann Produktion.', description: 'Ablauf', create_embeddings: false) }

        notification(:archived_notification, 'archived')
        notification(:read_notification, 'read')
        notification(:unread_notification, 'queued')
      end

      ActsAsTenant.with_tenant(@other_organisation) do
        other_role = record { create(:role, id: id(:other_role), organisation: @other_organisation, title: 'Mitglied') }
        record { create(:membership, user: @ben, organisation: @other_organisation, role: other_role, active: true) }
        @foreign_project = record { create(:project, id: id(:foreign_project), organisation: @other_organisation, name: 'Fremdprojekt', description: 'Gehört nicht Anna') }
      end

      @write_token = token(:write_token, @anna, read_only: false, prefix: 'lalab_pat_Wr')
      @read_token = token(:read_token, @anna, read_only: true, prefix: 'lalab_pat_Rd')
      @deactivated_token = token(:deactivated_token, @carla, read_only: true, prefix: 'lalab_pat_Dc')
      # Deactivated AFTER the token was made: the token stays valid, it just reaches nothing.
      in_org { Membership.find_by!(user: @carla, organisation: @organisation).update!(active: false) }
    end

    def in_org(&) = ActsAsTenant.with_tenant(@organisation, &)

    def record
      tick
      yield
    end

    # On a ticket no recorded write comments on: a comment marks the author's own
    # notifications about its ticket read (Actors::SavePost), and Anna comments on
    # the login ticket further down, which would empty the list_notifications answer.
    def notification(name, state)
      record do
        create(:notification, id: id(name), recipient: @anna, actor: @ben, organisation: @organisation, notifiable: @export,
                              state: state, event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
                              group_key: "contract-#{name}", dedupe_fingerprint: "contract-#{name}",
                              created_at: Time.current, updated_at: Time.current,
                              first_event_at: Time.current, last_event_at: Time.current,
                              read_at: state == 'read' ? Time.current : nil,
                              payload: { 'action' => 'commented', 'actor_name' => 'Ben Berger' })
      end
    end

    def token(name, user, read_only:, prefix:)
      record { mint_token(name, user, read_only: read_only, prefix: prefix) }
    end

    def mint_token(name, user, read_only:, prefix:, project_scopes: {})
      pat = create(:personal_access_token, id: id(name), user: user, organisations: [@organisation],
                                           project_scopes: project_scopes, read_only: read_only, name: "Vertrag #{name}")
      # The prefix is the only random field a response shows.
      pat.update_column(:token_prefix, prefix)
      pat.token
    end

    # People S3b: the directory the people answers read. Made once, right before the first of
    # them, without `record`: no clock moves for anything recorded later. Anna sees the
    # directory (the people right on the role she shares with Ben and Carla); Dora is a member
    # without that right and without a project, refused there and invisible to Anna; one more
    # token of Anna's is limited to the website project, which the directory does not open (E1).
    def people_world
      @people_world ||= begin
        in_org do
          create(:permission, role: Role.find(id(:role)), category: 'people', action: 'view_people', allowed: true)
          guest = create(:role, id: id(:guest_role), organisation: @organisation, title: 'Gast')
          @dora = create(:user, id: id(:dora), email: 'dora@example.com', first_name: 'Dora', last_name: 'Dorn')
          create(:membership, user: @dora, organisation: @organisation, role: guest, active: true)
          create(:person, id: id(:doris_person), organisation: @organisation, name: 'Doris Dienstleister',
                          salutation: 'Frau', function: 'Technische Ansprechpartnerin', department: 'Technik',
                          company: 'Hosting AG', email: 'doris@example.com', phone: '+49 30 1234567',
                          notes: 'Nur vormittags anrufen.',
                          additional_details: [{ 'kind' => 'phone', 'label' => 'Mobil', 'value' => '+49 170 1234567' }])
          create(:person, id: id(:ben_person), organisation: @organisation, user: @ben, name: 'Ben Berger',
                          function: 'Entwicklung', company: nil, email: nil, phone: '+49 30 7654321')
        end
        @limited_token = mint_token(:limited_token, @anna, read_only: true, prefix: 'lalab_pat_Lm',
                                                           project_scopes: { @organisation => [@website] })
        @dora_token = mint_token(:dora_token, @dora, read_only: true, prefix: 'lalab_pat_Do')
        true
      end
    end

    # --- MCP ---------------------------------------------------------------

    def mcp_section
      {
        'initialize' => rpc(@read_token, 'initialize',
                            { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'lalabase', version: '0.0.0' } }),
        'tools_list' => rpc(@read_token, 'tools/list', {}),
        'unauthorized' => rpc('lalab_pat_invalid', 'tools/list', {}),
        'calls' => calls
      }
    end

    # The tools the terminal client uses, one answer per outcome. `token` names
    # which of the three tokens asked.
    def calls
      website = id(:website)
      foreign = id(:foreign_project)
      {
        'list_tickets' => {
          'ok' => tool_call(:read, 'list_tickets', project_id: website),
          'empty' => tool_call(:read, 'list_tickets', project_id: id(:internal)),
          'invalid_input' => tool_call(:read, 'list_tickets', project_id: website, assignee: 'not-a-uuid'),
          'invalid_input_missing_argument' => tool_call(:read, 'list_tickets'),
          'not_found' => tool_call(:read, 'list_tickets', project_id: foreign)
        },
        'get_ticket' => {
          'ok' => tool_call(:read, 'get_ticket', project_id: website, ticket_id: id(:login_ticket)),
          'ok_by_number' => tool_call(:read, 'get_ticket', project_id: website, number: '1'),
          'empty' => tool_call(:read, 'get_ticket', project_id: website, ticket_id: id(:missing)),
          'invalid_input' => tool_call(:read, 'get_ticket', project_id: website, ticket_id: 'oops'),
          'not_found' => tool_call(:read, 'get_ticket', project_id: foreign, ticket_id: id(:login_ticket)),
          # No read access to the ticket: answered like a missing one, no
          # existence oracle (spec/requests/api/mcp_ticket_existence_spec.rb).
          'hidden' => tool_call(:read, 'get_ticket', project_id: id(:handbook), ticket_id: id(:hidden_ticket)),
          # Paging and full text (terminal client plan, S1 b/c).
          'page_newest' => tool_call(:read, 'get_ticket', project_id: website, ticket_id: id(:login_ticket),
                                                          posts_per_page: 1, posts_order: 'newest'),
          'one_post' => tool_call(:read, 'get_ticket', project_id: website, ticket_id: id(:login_ticket),
                                                       post_id: id(:first_post), full_text: true),
          'post_not_found' => tool_call(:read, 'get_ticket', project_id: website, ticket_id: id(:login_ticket),
                                                             post_id: id(:missing)),
          'invalid_paging' => tool_call(:read, 'get_ticket', project_id: website, ticket_id: id(:login_ticket),
                                                             posts_order: 'random')
        },
        'search_knowledge' => {
          'ok' => tool_call(:read, 'search_knowledge', project_id: website, q: 'Deploy'),
          'empty' => tool_call(:read, 'search_knowledge', project_id: website, q: 'Gibt es nicht'),
          'invalid_input' => tool_call(:read, 'search_knowledge', project_id: website, q: ' '),
          'not_found' => tool_call(:read, 'search_knowledge', project_id: foreign, q: 'Deploy')
        },
        'post_comment' => {
          'ok' => tool_call(:write, 'post_comment', project_id: website, ticket_id: id(:login_ticket), body: 'Behoben in 2.4.1.',
                                                    idempotency_key: 'contract-comment-1'),
          'empty' => tool_call(:write, 'post_comment', project_id: website, ticket_id: id(:missing), body: 'Hallo'),
          'invalid_input' => tool_call(:write, 'post_comment', project_id: website, ticket_id: id(:login_ticket), body: ' '),
          'read_only' => tool_call(:read, 'post_comment', project_id: website, ticket_id: id(:login_ticket), body: 'Hallo'),
          'not_found' => tool_call(:write, 'post_comment', project_id: foreign, ticket_id: id(:login_ticket), body: 'Hallo'),
          # The ticket may be read, not written: the refusal may say what it is.
          'forbidden' => tool_call(:write, 'post_comment', project_id: id(:archive), ticket_id: id(:archived_ticket), body: 'Hallo')
        },
        'list_notifications' => {
          'ok' => tool_call(:read, 'list_notifications'),
          'empty' => tool_call(:read, 'list_notifications', project_id: id(:internal)),
          'invalid_input' => tool_call(:read, 'list_notifications', status: 'bogus'),
          'invalid_input_in_tool' => tool_call(:read, 'list_notifications', project_id: 'oops'),
          'not_found' => tool_call(:read, 'list_notifications', project_id: foreign),
          'by_organisation' => tool_call(:read, 'list_notifications', organisation_id: id(:organisation), status: 'all'),
          'organisation_not_found' => tool_call(:read, 'list_notifications', organisation_id: id(:other_organisation))
        },
        'mark_notification_read' => {
          'ok' => tool_call(:write, 'mark_notification_read', notification_id: id(:unread_notification)),
          'empty' => tool_call(:write, 'mark_notification_read', notification_id: id(:missing)),
          'invalid_input' => tool_call(:write, 'mark_notification_read', notification_id: 'oops'),
          'read_only' => tool_call(:read, 'mark_notification_read', notification_id: id(:unread_notification)),
          'refused_archived' => tool_call(:write, 'mark_notification_read', notification_id: id(:archived_notification))
        },
        # Terminal client S2, appended last: the calls run in order and change the
        # world, so every answer above stays as it was.
        'update_ticket' => update_ticket_calls(website, foreign),
        # S2b runs after all existing calls, without advancing the clock.
        'post_comment_formats' => post_comment_format_calls(website),
        # Terminal client S6, appended last for the same reason: its bookings
        # and time rights are made right before it, without advancing the clock.
        'summarize_time_sessions' => time_report_calls(website, foreign),
        # People S3b, appended last for the same reason (people_world).
        'find_people' => find_people_calls,
        'get_person' => get_person_calls,
        # MCP 0.13.1, appended last: refusals that write nothing, so every
        # answer after them stays as it was.
        'idempotency_key' => idempotency_key_calls(website),
        # MCP 0.14 (REST R7), appended last: the file of Ben's comment, made
        # right before it.
        'comment_file' => comment_file_calls(website),
        # MCP 0.15, appended last: reads, so every answer above stays as it was.
        'list_organisations' => { 'ok' => tool_call(:read, 'list_organisations') },
        'list_projects' => list_projects_calls,
        # MCP 0.16, appended last: refusals that write nothing, so every answer
        # above stays as it was.
        'create_meeting' => create_meeting_calls,
        # MCP 0.17 (R9), appended last: reads of the meeting world, which is made here,
        # earlier than the REST section made it before; that moves the meetings' own
        # timestamps there, nothing else.
        'get_meeting' => get_meeting_calls
      }
    end

    # Spelled out, not a loop: each request from its own line (Prosopite).
    def get_meeting_calls
      meeting_world
      kickoff = { meeting_id: id(:kickoff_meeting) }
      {
        'ok' => tool_call(:read, 'get_meeting', **kickoff),
        # A page of one part, from an offset: the rest of the transcript.
        'ok_part' => tool_call(:read, 'get_meeting', **kickoff, part: 'transcript', offset: 6),
        'ok_past_end' => tool_call(:read, 'get_meeting', **kickoff, part: 'summary', offset: 1_000),
        # No duration, no notes, no transcript, an empty summary, nobody named.
        'ok_bare' => tool_call(:read, 'get_meeting', meeting_id: id(:review_meeting)),
        'empty' => tool_call(:read, 'get_meeting', meeting_id: id(:missing)),
        # All of these answer exactly like the missing one.
        'empty_malformed' => tool_call(:read, 'get_meeting', meeting_id: 'not-a-uuid'),
        'empty_no_area' => tool_call(:read, 'get_meeting', meeting_id: id(:hidden_meeting)),
        'empty_reach' => tool_call(:limited, 'get_meeting', meeting_id: id(:internal_meeting)),
        'empty_foreign' => tool_call(:read, 'get_meeting', meeting_id: id(:foreign_meeting)),
        'invalid_input' => tool_call(:read, 'get_meeting', **kickoff, offset: 3),
        'invalid_input_part' => tool_call(:read, 'get_meeting', **kickoff, part: 'analysis'),
        'ok_notes' => tool_call(:read, 'get_meeting', **kickoff, part: 'notes')
      }.merge(long_meeting_calls)
    end

    # A transcript longer than a page, so a page has a next one (next_offset a number) and the
    # last page follows it. The meeting is made for these two answers alone and removed after
    # them: every list and project answer recorded later stays as it was.
    def long_meeting_calls
      line = 'Anna: Wir prüfen den Plan für März, Seite für Seite.'
      transcript = Array.new(Meetings::TextPage::MAX_CHARS / line.length + 20) { |n| "#{line} #{n}" }.join("\n")
      in_org do
        create(:meeting, id: id(:long_meeting), project: @website, organisation: @organisation, creator: @anna,
                         title: 'Langes Gespräch', occurred_at: START - 7.days, transcript: transcript)
      end
      page = { meeting_id: id(:long_meeting), part: 'transcript' }
      first = tool_call(:read, 'get_meeting', **page, offset: 0)
      next_offset = JSON.parse(first.dig('response', 'body', 'result', 'content', 0, 'text')).dig('parts', 'transcript', 'next_offset')
      calls = { 'ok_page' => first, 'ok_last_page' => tool_call(:read, 'get_meeting', **page, offset: next_offset) }
      in_org { Meeting.find(id(:long_meeting)).destroy! }
      calls
    end

    # A comment's file, by the id of its PostDocument: fixed, because the file
    # proxy takes that id and the client builds its address from it. Ben's comment
    # is the oldest on the login ticket, so a page of one holds it. Without
    # `record`: no tick, no clock moved for the REST section, which lists this
    # file too (attachment_calls, ticket_view).
    def comment_file_calls(website)
      in_org do
        attach_fixture(PostDocument.new(id: id(:first_post_file), post: Post.find(id(:first_post)), organisation: @organisation,
                                        create_embeddings: false),
                       :post_document_file, :post)
      end
      login = { project_id: website, ticket_id: id(:login_ticket) }
      {
        'page' => tool_call(:read, 'get_ticket', **login, posts_per_page: 1),
        'one_post' => tool_call(:read, 'get_ticket', **login, post_id: id(:first_post)),
        # The comment beside it has no file, and says so.
        'no_file' => tool_call(:read, 'get_ticket', **login, post_id: id(:second_post))
      }
    end

    def create_meeting_calls
      meeting = { title: 'Abstimmung', occurred_at: '2026-01-01T10:00:00Z' }
      {
        'refused_no_inbox' => tool_call(:write, 'create_meeting', organisation_id: id(:organisation), **meeting),
        'read_only' => tool_call(:read, 'create_meeting', organisation_id: id(:organisation), **meeting),
        'invalid_input' => tool_call(:write, 'create_meeting', organisation_id: 'oops', **meeting),
        'not_found' => tool_call(:write, 'create_meeting', organisation_id: id(:other_organisation), **meeting)
      }
    end

    def list_projects_calls
      {
        'ok' => tool_call(:read, 'list_projects'),
        'one_organisation' => tool_call(:read, 'list_projects', organisation_id: id(:organisation), per_page: 2),
        'include_archived' => tool_call(:read, 'list_projects', include_archived: true),
        'invalid_input' => tool_call(:read, 'list_projects', organisation_id: 'oops'),
        'invalid_input_per_page' => tool_call(:read, 'list_projects', per_page: 0),
        'not_found' => tool_call(:read, 'list_projects', organisation_id: id(:other_organisation))
      }
    end

    # A key the store cannot hold is refused before the write (MCP 0.13.1).
    # Each from its own line (Prosopite), without `record`: nothing is written
    # and no clock moves. 256 bytes; 128 umlauts, which are 256 bytes in 128
    # characters (the bound counts bytes); a NUL inside the key. A key that is
    # no valid UTF-8 cannot be written into this file.
    def idempotency_key_calls(website)
      args = { project_id: website, ticket_id: id(:login_ticket), body: 'Hallo' }
      {
        'too_long' => tool_call(:write, 'post_comment', **args, idempotency_key: 'k' * 256),
        'too_long_multibyte' => tool_call(:write, 'post_comment', **args, idempotency_key: 'ä' * 128),
        'nul' => tool_call(:write, 'post_comment', **args, idempotency_key: "k#{0.chr}x")
      }
    end

    def find_people_calls
      people_world
      nordlicht = id(:organisation)
      {
        'ok' => tool_call(:read, 'find_people', organisation_id: nordlicht),
        'ok_query' => tool_call(:read, 'find_people', organisation_id: nordlicht, query: 'techn'),
        'ok_kind' => tool_call(:read, 'find_people', organisation_id: nordlicht, kind: 'members'),
        'empty' => tool_call(:read, 'find_people', organisation_id: nordlicht, query: 'Gibt es nicht'),
        'invalid_input' => tool_call(:read, 'find_people', organisation_id: 'oops'),
        'invalid_input_kind' => tool_call(:read, 'find_people', organisation_id: nordlicht, kind: 'member'),
        'invalid_input_missing_argument' => tool_call(:read, 'find_people'),
        # Anna is no member there: outside the token, like a missing organisation.
        'not_found' => tool_call(:read, 'find_people', organisation_id: id(:other_organisation)),
        'not_found_project_token' => tool_call(:limited, 'find_people', organisation_id: nordlicht),
        'refused' => tool_call(:dora, 'find_people', organisation_id: nordlicht)
      }
    end

    def get_person_calls
      people_world
      nordlicht = id(:organisation)
      doris = "person:#{id(:doris_person)}"
      {
        'ok' => tool_call(:read, 'get_person', organisation_id: nordlicht, id: doris),
        'ok_member' => tool_call(:read, 'get_person', organisation_id: nordlicht, id: "member:#{id(:ben)}"),
        'empty' => tool_call(:read, 'get_person', organisation_id: nordlicht, id: "person:#{id(:missing)}"),
        # Dora is a member Anna does not see: answered like a missing person.
        'hidden' => tool_call(:read, 'get_person', organisation_id: nordlicht, id: "member:#{id(:dora)}"),
        'invalid_input' => tool_call(:read, 'get_person', organisation_id: nordlicht, id: 'abc'),
        'not_found' => tool_call(:read, 'get_person', organisation_id: id(:other_organisation), id: doris),
        'not_found_project_token' => tool_call(:limited, 'get_person', organisation_id: nordlicht, id: doris),
        'refused' => tool_call(:dora, 'get_person', organisation_id: nordlicht, id: doris)
      }
    end

    # The booked time of the login ticket: Anna 30 minutes, Ben 45, plus 20 of
    # Ben's on the export ticket. The client has not settled on own time or the
    # ticket's total yet, so both answers are recorded, and the "own" tier once
    # Anna's right is narrowed to it.
    def time_report_calls(website, foreign)
      login = id(:login_ticket)
      in_org do
        create(:time_session_permission, user: @anna, project: @website, can_view_own: true, can_view_all: true)
        { @anna => [30, @login], @ben => [45, @login] }.each { |user, (minutes, ticket)| booking(user, minutes, ticket) }
        booking(@ben, 20, @export)
      end
      {
        'ok_own' => tool_call(:read, 'summarize_time_sessions', project_id: website, ticket: login, creator: 'me'),
        'ok_total' => tool_call(:read, 'summarize_time_sessions', project_id: website, ticket: login),
        'empty' => tool_call(:read, 'summarize_time_sessions', project_id: website, ticket: id(:missing)),
        # Notes only in the handbook, no time permission row: refused, no numbers.
        'refused' => tool_call(:read, 'summarize_time_sessions', project_id: id(:handbook), ticket: id(:hidden_ticket)),
        'not_found' => tool_call(:read, 'summarize_time_sessions', project_id: foreign, ticket: login),
        # The tool refuses a malformed date without a code, which MCP answers as refused.
        'invalid_date' => tool_call(:read, 'summarize_time_sessions', project_id: website, start_date: '05.01.2026'),
        'ok_own_tier' => with_own_time_only(@anna, on: @website) do
          tool_call(:read, 'summarize_time_sessions', project_id: website, ticket: login)
        end
      }
    end

    def booking(user, minutes, ticket)
      create(:time_session, project: ticket.project, organisation: @organisation, creator: user, ticket: ticket,
                            duration: minutes, occurred_on: START + 1.hour, description: 'Vertrag')
    end

    def with_own_time_only(user, on:)
      in_org { TimeSessionPermission.find_by!(user: user, project: on).update!(can_view_all: false) }
      yield
    end

    def post_comment_format_calls(project)
      args = { project_id: project, ticket_id: id(:login_ticket) }
      {
        'plain' => tool_call(:write, 'post_comment', **args, format: 'plain',
                                                             body: "line one\nline two\n\nsee <file.txt> &lt;tag&gt;"),
        'html' => tool_call(:write, 'post_comment', **args, format: 'html', body: '<p><b>bold</b></p>'),
        'invalid_format' => tool_call(:write, 'post_comment', **args, format: 'markdown', body: 'x'),
        'format_not_string' => tool_call(:write, 'post_comment', **args, format: 1, body: 'x'),
        'nul' => tool_call(:write, 'post_comment', **args, format: 'plain', body: "a#{0.chr}b"),
        'private' => tool_call(:write, 'post_comment', **args, format: 'plain', is_private: true, body: '<private>'),
        'read_only' => tool_call(:read, 'post_comment', **args, format: 'plain', body: 'x'),
        'hidden' => tool_call(:write, 'post_comment', project_id: id(:handbook), ticket_id: id(:hidden_ticket),
                                                      format: 'plain', body: 'x'),
        'forbidden' => tool_call(:write, 'post_comment', project_id: id(:archive), ticket_id: id(:archived_ticket),
                                                         format: 'plain', body: 'x'),
        # Appended after the gate rows: Unicode whitespace alone is not a body,
        # although String#strip would say otherwise.
        'whitespace_only' => tool_call(:write, 'post_comment', **args, format: 'plain', body: 0xA0.chr(Encoding::UTF_8))
      }
    end

    def update_ticket_calls(website, foreign)
      export = id(:export_ticket)
      {
        'ok_status' => tool_call(:write, 'update_ticket', project_id: website, ticket_id: export, status: 'in_progress',
                                                          idempotency_key: 'contract-update-1'),
        'ok_assign' => tool_call(:write, 'update_ticket', project_id: website, ticket_id: export, add_assignee_ids: ['me']),
        'ok_title' => tool_call(:write, 'update_ticket', project_id: website, ticket_id: export, title: 'Export als CSV und XLSX'),
        'mixed' => tool_call(:write, 'update_ticket', project_id: website, ticket_id: export, title: 'x', status: 'new'),
        'status_not_allowed' => tool_call(:write, 'update_ticket', project_id: website, ticket_id: export, status: 'erledigt'),
        'value_not_allowed' => tool_call(:write, 'update_ticket', project_id: website, ticket_id: export,
                                                                  add_assignee_ids: [id(:missing)]),
        # Carla's membership is inactive and she has no project permission: her
        # assignment is stale. Only the people a change ADDS must be assignable,
        # so Ben is added beside her and she stays. (user_not_assignable is left
        # to a race: a person added who lost access after the option list was
        # read. No case here.)
        'ok_assign_beside_stale' => with_stale_assignee(@carla, on: @login) do
          tool_call(:write, 'update_ticket', project_id: website, ticket_id: id(:login_ticket), add_assignee_ids: [id(:ben)])
        end,
        'no_status_field' => without_status_field(@internal) do
          tool_call(:write, 'update_ticket', project_id: id(:internal), ticket_id: id(:internal_ticket), status: 'new')
        end,
        'empty' => tool_call(:write, 'update_ticket', project_id: website, ticket_id: id(:missing), status: 'new'),
        # No read access to the ticket: answered like a missing one.
        'hidden' => tool_call(:write, 'update_ticket', project_id: id(:handbook), ticket_id: id(:hidden_ticket), status: 'new'),
        # The ticket may be read, not written.
        'forbidden' => tool_call(:write, 'update_ticket', project_id: id(:archive), ticket_id: id(:archived_ticket), status: 'new'),
        'not_found' => tool_call(:write, 'update_ticket', project_id: foreign, ticket_id: export, status: 'new'),
        'read_only' => tool_call(:read, 'update_ticket', project_id: website, ticket_id: export, status: 'new')
      }
    end

    # A ticket in `internal`, whose status field was switched off. Inside `calls`,
    # after every answer that reads `internal` (list_tickets/empty), and without
    # `record`, so no clock moves for the REST section.
    def without_status_field(project)
      in_org do
        create(:ticket, id: id(:internal_ticket), project: project, organisation: @organisation, creator: @anna, title: 'Ohne Status')
        project.ticket_attribute_definitions.where(name: 'status').update_all(active: false)
      end
      yield
    end

    # Written past the actor that would refuse it: the state an assignment is in
    # after its person lost access. Without `record`: its tick would move the
    # clock for the REST section below (a token's last_used_at).
    def with_stale_assignee(user, on:)
      in_org { TicketAssignment.create!(ticket: on, user: user) }
      yield
    end

    def tool_call(token_name, tool, **arguments)
      { 'token' => token_name.to_s }.merge(rpc(token_for(token_name), 'tools/call', { name: tool, arguments: arguments }))
    end

    def token_for(name)
      { read: @read_token, write: @write_token, deactivated: @deactivated_token, limited: @limited_token,
        dora: @dora_token }.fetch(name)
    end

    def rpc(token, method, params)
      request = { 'jsonrpc' => '2.0', 'id' => 1, 'method' => method, 'params' => params }
      session.post '/api/mcp', params: request.to_json, headers: headers(token).merge('CONTENT_TYPE' => 'application/json')
      { 'request' => request, 'response' => response }
    end

    # --- REST --------------------------------------------------------------

    def rest_section
      {
        'GET /api/v1/me' => {
          'ok' => rest_get(:write, '/api/v1/me'),
          'ok_read_only' => rest_get(:read, '/api/v1/me'),
          'unauthorized' => rest_get(nil, '/api/v1/me')
        },
        'GET /api/v1/organisations' => {
          'ok' => rest_get(:read, '/api/v1/organisations'),
          'empty' => rest_get(:deactivated, '/api/v1/organisations'),
          'unauthorized' => rest_get(nil, '/api/v1/organisations')
        },
        'GET /api/v1/projects' => {
          'ok' => rest_get(:read, '/api/v1/projects'),
          'ok_one_organisation' => rest_get(:read, "/api/v1/projects?organisation_id=#{id(:organisation)}"),
          'empty' => rest_get(:read, "/api/v1/projects?organisation_id=#{id(:other_organisation)}"),
          'unauthorized' => rest_get(nil, '/api/v1/projects')
        },
        # Terminal client S5, appended last: the ticket's file is made right before
        # it and the comment's after the MCP calls, so every answer above stays as
        # it was.
        'GET /api/v1/tickets/:id/attachments' => attachment_calls,
        # REST R0 (cli_rest_plan D6, D7), appended last for the same reason: one
        # answer per error code, then a write with an Idempotency-Key, its replay
        # and the key reused with another body.
        'errors' => rest_error_calls,
        'idempotency' => rest_idempotency_calls,
        # People S3b, appended last: the directory of people_world, made before the MCP calls.
        'GET /api/v1/organisations/:organisation_id/people' => rest_people_list_calls,
        'GET /api/v1/organisations/:organisation_id/people/:id' => rest_people_show_calls,
        # REST R1: the ticket view without MCP.
        'ticket_view' => rest_ticket_view_calls,
        # REST R6 runs after the reads above, so its bookings do not change their answers.
        'POST /api/v1/tickets/:ticket_id/time_sessions' => rest_booking_calls,
        # REST R3a (cli_rest_plan R3 a), appended last: its comments land on the
        # login ticket after every answer above, without advancing the clock.
        'POST /api/v1/tickets/:ticket_id/posts' => rest_comment_calls,
        # REST R2, appended last: reads only, over the deploy note of the website.
        'GET /api/v1/projects/:project_id/knowledge' => rest_knowledge_calls,
        # REST R3b, appended last: it changes the export and the login ticket
        # after every answer above, without advancing the clock.
        'POST /api/v1/tickets/:id/changes' => rest_ticket_change_calls,
        # REST R8, appended last: reads only, over meetings made right before them.
        'GET /api/v1/projects/:project_id/meetings' => rest_meeting_list_calls,
        'GET /api/v1/meetings/:id' => rest_meeting_show_calls
      }
    end

    # Each request from its own line (Prosopite). The export ticket has Anna on
    # it; on the login ticket Carla's assignment is stale (update_ticket_calls),
    # so a change that does not name her leaves her there. user_not_assignable
    # is left to a race, as on MCP: no case here.
    def rest_ticket_change_calls
      path = ->(ticket) { "/api/v1/tickets/#{id(ticket)}/changes" }
      export = path.call(:export_ticket)
      statuses = in_org { TicketAttributeDefinition.ordered_value_keys_for(@website, 'status') }
      once = { change: { status: statuses.last } }
      key = 'contract-rest-change-1'
      {
        'ok_status' => rest_send(:post, :write, export, params: { change: { status: statuses.first } }),
        'ok_assign' => rest_send(:post, :write, export, params: { change: { add_assignee_ids: [id(:ben)] } }),
        'ok_unassign' => rest_send(:post, :write, export, params: { change: { remove_assignee_ids: [id(:ben)] } }),
        'ok_assign_and_unassign' => rest_send(:post, :write, export,
                                              params: { change: { add_assignee_ids: [id(:ben)], remove_assignee_ids: ['me'] } }),
        'ok_title' => rest_send(:post, :write, export, params: { change: { title: 'Export als CSV, XLSX und PDF' } }),
        'ok_beside_stale' => rest_send(:post, :write, path.call(:login_ticket), params: { change: { remove_assignee_ids: [id(:ben)] } }),
        'invalid_input_mixed' => rest_send(:post, :write, export, params: { change: { title: 'x', status: statuses.first } }),
        'invalid_input_unknown_key' => rest_send(:post, :write, export, params: { change: { priority: 'low' } }),
        'invalid_input_no_change' => rest_send(:post, :write, export, params: {}),
        'invalid_input_title' => rest_send(:post, :write, export, params: { change: { title: "zwei\nZeilen" } }),
        'invalid_input_same_person' => rest_send(:post, :write, export,
                                                 params: { change: { add_assignee_ids: ['me'], remove_assignee_ids: [id(:anna)] } }),
        'refused_status' => rest_send(:post, :write, export, params: { change: { status: 'erledigt' } }),
        'refused_person' => rest_send(:post, :write, export, params: { change: { add_assignee_ids: [id(:missing)] } }),
        'refused_no_status_field' => rest_send(:post, :write, path.call(:internal_ticket), params: { change: { status: statuses.first } }),
        'not_found' => rest_send(:post, :write, path.call(:missing), params: { change: { status: statuses.first } }),
        # No read access to the ticket: answered like a missing one.
        'hidden' => rest_send(:post, :write, path.call(:hidden_ticket), params: { change: { status: statuses.first } }),
        # Anna reads the archive's tickets, she may not write them.
        'forbidden' => rest_send(:post, :write, path.call(:archived_ticket), params: { change: { status: statuses.first } }),
        'read_only' => rest_send(:post, :read, export, params: { change: { status: statuses.first } }),
        'idempotency_first' => rest_send(:post, :write, export, params: once, key: key),
        'idempotency_replay' => rest_send(:post, :write, export, params: once, key: key),
        'idempotency_mismatch' => rest_send(:post, :write, export, params: { change: { status: statuses.first } }, key: key)
      }
    end

    # The meetings the answers read. Made once, right before the first of them, without
    # `record`: no clock moves for anything recorded later. Anna reads the meetings of the
    # website and of the internal project (her limited token reaches only the website) and
    # none of the handbook, where she only reads notes.
    def meeting_world
      @meeting_world ||= begin
        people_world
        in_org do
          ProjectPermission.find_by!(user: @anna, project: @website).update!(meetings_access: :read_only)
          ProjectPermission.find_by!(user: @anna, project: @internal).update!(meetings_access: :read_only)
          kickoff = create(:meeting, id: id(:kickoff_meeting), project: @website, organisation: @organisation, creator: @anna,
                                     title: 'Kickoff Relaunch', occurred_at: START - 1.day, duration_minutes: 45,
                                     notes: 'Termin im März halten.', transcript: 'Anna: Wir starten im März.',
                                     generated_summary: '**Ergebnis:** Start im März.')
          create(:meeting_participant, meeting: kickoff, organisation: @organisation, user: @anna, display_name: 'Anna Albers')
          create(:meeting_participant, meeting: kickoff, organisation: @organisation, display_name: 'Erika Beispiel',
                                       created_at: Time.current + 1.second)
          create(:meeting, id: id(:review_meeting), project: @website, organisation: @organisation, creator: @ben,
                           title: 'Kurze Abstimmung', occurred_at: START - 2.days)
          create(:meeting, id: id(:hidden_meeting), project: @handbook, organisation: @organisation, creator: @anna,
                           title: 'Vertrauliches Gespräch', occurred_at: START - 3.days, transcript: 'Nicht für Notiz-Leser.')
          create(:meeting, id: id(:internal_meeting), project: @internal, organisation: @organisation, creator: @anna,
                           title: 'Interne Runde', occurred_at: START - 4.days)
        end
        in_org do
          # The creator's account is gone: the id stays, `name` is null.
          gone = create(:user, id: id(:gone_user), email: 'gone@example.com', first_name: 'Gerd', last_name: 'Gegangen')
          create(:membership, user: gone, organisation: @organisation, role: Role.find(id(:role)), active: true)
          create(:meeting, id: id(:gone_meeting), project: @internal, organisation: @organisation, creator: gone,
                           title: 'Altes Gespräch', occurred_at: START - 6.days)
          gone.soft_delete!
        end
        ActsAsTenant.with_tenant(@other_organisation) do
          create(:meeting, id: id(:foreign_meeting), project: @foreign_project, organisation: @other_organisation, creator: @ben,
                           title: 'Fremdes Gespräch', occurred_at: START - 5.days)
        end
        true
      end
    end

    def rest_meeting_list_calls
      meeting_world
      # Spelled out, not a loop: each request from its own line (Prosopite).
      path = "/api/v1/projects/#{id(:website)}/meetings"
      {
        'ok' => rest_get(:read, path),
        'ok_search' => rest_get(:read, "#{path}?q=M%C3%A4rz"),
        'ok_page' => rest_get(:read, "#{path}?page=2&per_page=1"),
        # The last row's creator has no account any more.
        'ok_creator_gone' => rest_get(:read, "/api/v1/projects/#{id(:internal)}/meetings"),
        'empty' => rest_get(:read, "#{path}?q=Gibt%20es%20nicht"),
        # The reader opens the project but reads no meetings there.
        'empty_no_area' => rest_get(:read, "/api/v1/projects/#{id(:handbook)}/meetings"),
        'invalid_input_per_page' => rest_get(:read, "#{path}?per_page=101"),
        'invalid_input_page' => rest_get(:read, "#{path}?page=0"),
        'not_found' => rest_get(:read, "/api/v1/projects/#{id(:foreign_project)}/meetings"),
        'not_found_reach' => rest_get(:limited, "/api/v1/projects/#{id(:internal)}/meetings"),
        'unauthorized' => rest_get(nil, path)
      }
    end

    def rest_meeting_show_calls
      meeting_world
      path = ->(meeting) { "/api/v1/meetings/#{id(meeting)}" }
      {
        'ok' => rest_get(:read, path.call(:kickoff_meeting)),
        # No duration, no notes, no transcript, no summary, nobody named.
        'ok_bare' => rest_get(:read, path.call(:review_meeting)),
        'ok_creator_gone' => rest_get(:read, path.call(:gone_meeting)),
        'not_found' => rest_get(:read, path.call(:missing)),
        'not_found_malformed' => rest_get(:read, '/api/v1/meetings/not-a-uuid'),
        # All of these answer exactly like the missing one.
        'not_found_no_area' => rest_get(:read, path.call(:hidden_meeting)),
        'not_found_reach' => rest_get(:limited, path.call(:internal_meeting)),
        'not_found_foreign' => rest_get(:read, path.call(:foreign_meeting)),
        'unauthorized' => rest_get(nil, path.call(:kickoff_meeting))
      }
    end

    def rest_knowledge_calls
      # Spelled out, not a loop: each request from its own line (Prosopite).
      path = "/api/v1/projects/#{id(:website)}/knowledge"
      {
        'ok' => rest_get(:read, "#{path}?q=Deploy"),
        'empty' => rest_get(:read, "#{path}?q=Gibt%20es%20nicht"),
        'list' => rest_get(:read, path),
        'list_type' => rest_get(:read, "#{path}?type=note&per_page=5"),
        'invalid_input' => rest_get(:read, "#{path}?type=ticket"),
        'invalid_input_per_page' => rest_get(:read, "#{path}?per_page=101"),
        'not_found' => rest_get(:read, "/api/v1/projects/#{id(:foreign_project)}/knowledge"),
        'unauthorized' => rest_get(nil, path)
      }
    end

    def rest_booking_calls
      # Spelled out, not a loop: each request from its own line (Prosopite).
      path = ->(ticket) { "/api/v1/tickets/#{id(ticket)}/time_sessions" }
      login = path.call(:login_ticket)
      once = { time_session: { duration_string: '0:15', description: 'Per REST, einmal.' } }
      key = 'contract-rest-book-1'
      {
        'ok_minutes_text' => rest_send(:post, :write, login, params: { time_session: { duration_string: '30' } }),
        'ok_hours_text' => rest_send(:post, :write, login,
                                     params: { time_session: { duration_string: '1:30', occurred_on: '2026-01-04',
                                                               description: 'Vertrag' } }),
        'ok_minutes' => rest_send(:post, :write, login, params: { time_session: { duration_minutes: 45 } }),
        'invalid_input_no_duration' => rest_send(:post, :write, login, params: { time_session: { description: 'x' } }),
        'invalid_input_both_durations' => rest_send(:post, :write, login,
                                                    params: { time_session: { duration_string: '30',
                                                                              duration_minutes: 30 } }),
        'invalid_input_date' => rest_send(:post, :write, login,
                                          params: { time_session: { duration_string: '30', occurred_on: '05.01.2026' } }),
        'invalid_input_over_a_day' => rest_send(:post, :write, login, params: { time_session: { duration_string: '24:01' } }),
        'not_found' => rest_send(:post, :write, path.call(:missing), params: { time_session: { duration_string: '30' } }),
        # No read access to the ticket: answered like a missing one.
        'hidden' => rest_send(:post, :write, path.call(:hidden_ticket), params: { time_session: { duration_string: '30' } }),
        # Anna reads the archive's tickets but has no time right there.
        'forbidden' => rest_send(:post, :write, path.call(:archived_ticket),
                                 params: { time_session: { duration_string: '30' } }),
        'read_only' => rest_send(:post, :read, login, params: { time_session: { duration_string: '30' } }),
        'idempotency_first' => rest_send(:post, :write, login, params: once, key: key),
        'idempotency_replay' => rest_send(:post, :write, login, params: once, key: key),
        'idempotency_mismatch' => rest_send(:post, :write, login, params: { time_session: { duration_string: '0:20' } },
                                                                  key: key),
        'invalid_input_minutes' => rest_send(:post, :write, login, params: { time_session: { duration_minutes: '1.5' } })
      }
    end

    # Each request from its own line (Prosopite). `show` is the ticket without
    # paging parameters: its body must stay what gboyke/lalabase-mcp reads. It
    # shows the export ticket: that body lists every comment by created_at only,
    # and the writes above left several comments on the login ticket in the same
    # second.
    # The answers after `show` are the R1 additions: a page, a refused option,
    # the ticket by number (and a number that is not there or not readable),
    # one comment and a missing one.
    def rest_ticket_view_calls
      login = "/api/v1/tickets/#{id(:login_ticket)}"
      export = "/api/v1/tickets/#{id(:export_ticket)}"
      by_number = ->(project, number) { "/api/v1/projects/#{id(project)}/tickets/number/#{number}" }
      {
        # Filtered to Ben's one ticket: the writes above left both website
        # tickets with the same updated_at, and the list has no second sort key.
        'list' => rest_get(:read, "/api/v1/projects/#{id(:website)}/tickets?assignee=#{id(:ben)}"),
        'show' => rest_get(:read, export),
        # Oldest first: the second comment was made with its own clock tick, while
        # the comments the recorded writes added share one second and would be
        # ordered by their random ids.
        'show_paged' => rest_get(:read, "#{login}?posts_per_page=1&posts_page=2&attachments_page=1"),
        # R7: page one is Ben's comment, with its file (comment_file_calls).
        'show_paged_comment_file' => rest_get(:read, "#{login}?posts_per_page=1"),
        'show_invalid_paging' => rest_get(:read, "#{login}?posts_order=random"),
        'by_number' => rest_get(:read, by_number.call(:website, 2)),
        'by_number_not_found' => rest_get(:read, by_number.call(:website, 999)),
        # No read access to the handbook's tickets: answered like a missing number.
        'by_number_hidden' => rest_get(:read, by_number.call(:handbook, 1)),
        'post' => rest_get(:read, "#{login}/posts/#{id(:first_post)}"),
        'post_not_found' => rest_get(:read, "#{login}/posts/#{id(:missing)}")
      }
    end

    def rest_people_list_calls
      people_world
      path = "/api/v1/organisations/#{id(:organisation)}/people"
      {
        'ok' => rest_get(:read, path),
        'ok_query' => rest_get(:read, "#{path}?q=techn"),
        'ok_paged' => rest_get(:read, "#{path}?kind=members&per_page=1&page=2"),
        'empty' => rest_get(:read, "#{path}?q=niemand"),
        'invalid_input' => rest_get(:read, "#{path}?per_page=101"),
        'invalid_input_kind' => rest_get(:read, "#{path}?kind=member"),
        # Dora is a member without the people right.
        'forbidden' => rest_get(:dora, path),
        # Anna is no member there: outside the token, like a missing organisation.
        'not_found' => rest_get(:read, "/api/v1/organisations/#{id(:other_organisation)}/people"),
        'not_found_project_token' => rest_get(:limited, path),
        'unauthorized' => rest_get(nil, path)
      }
    end

    def rest_people_show_calls
      people_world
      path = "/api/v1/organisations/#{id(:organisation)}/people"
      doris = "person:#{id(:doris_person)}"
      {
        'ok' => rest_get(:read, "#{path}/#{doris}"),
        'ok_member' => rest_get(:read, "#{path}/member:#{id(:ben)}"),
        'not_found' => rest_get(:read, "#{path}/person:#{id(:missing)}"),
        # Dora is a member Anna does not see: answered like a missing person.
        'hidden' => rest_get(:read, "#{path}/member:#{id(:dora)}"),
        'invalid_input' => rest_get(:read, "#{path}/abc"),
        'forbidden' => rest_get(:dora, "#{path}/#{doris}"),
        'not_found_organisation' => rest_get(:read, "/api/v1/organisations/#{id(:other_organisation)}/people/#{doris}"),
        'not_found_project_token' => rest_get(:limited, "#{path}/#{doris}")
      }
    end

    # Each request from its own line (Prosopite). The answers without `format`
    # (and with `format: html`) were recorded before R3a and must stay as
    # they were: existing callers send no format.
    def rest_comment_calls
      path = ->(ticket) { "/api/v1/tickets/#{id(ticket)}/posts" }
      login = path.call(:login_ticket)
      plain = { format: 'plain', body: "Zeile 1\nZeile 2\n\nAbsatz <b>&" }
      once = { post: { format: 'plain', body: 'Per REST, einmal, als Text.' } }
      key = 'contract-rest-comment-1'
      {
        'html' => rest_send(:post, :write, login, params: { post: { body: '<p>Ein <b>fetter</b> Satz &amp; mehr</p>' } }),
        'html_named' => rest_send(:post, :write, login, params: { post: { format: 'html', body: '<p>Noch ein <i>Satz</i></p>' } }),
        # The model refuses an empty body, with its own message.
        'html_empty' => rest_send(:post, :write, login, params: { post: { body: '' } }),
        # R3a: literal text, escaped, in paragraphs and line breaks.
        'plain' => rest_send(:post, :write, login, params: { post: plain }),
        'plain_private' => rest_send(:post, :write, login, params: { post: { format: 'plain', is_private: true, body: '<privat>' } }),
        'invalid_input_format' => rest_send(:post, :write, login, params: { post: { format: 'markdown', body: 'x' } }),
        'invalid_input_empty' => rest_send(:post, :write, login, params: { post: { format: 'plain', body: '' } }),
        # Unicode whitespace alone is no text, although String#strip keeps it.
        'invalid_input_whitespace' => rest_send(:post, :write, login,
                                                params: { post: { format: 'plain', body: " \n#{0xA0.chr(Encoding::UTF_8)}" } }),
        'invalid_input_nul' => rest_send(:post, :write, login, params: { post: { format: 'plain', body: "a#{0.chr}b" } }),
        'not_found' => rest_send(:post, :write, path.call(:missing), params: { post: plain }),
        # No read access to the ticket: answered like a missing one.
        'hidden' => rest_send(:post, :write, path.call(:hidden_ticket), params: { post: plain }),
        # Anna reads the archive's tickets, she may not write them.
        'forbidden' => rest_send(:post, :write, path.call(:archived_ticket), params: { post: plain }),
        'read_only' => rest_send(:post, :read, login, params: { post: plain }),
        'idempotency_first' => rest_send(:post, :write, login, params: once, key: key),
        'idempotency_replay' => rest_send(:post, :write, login, params: once, key: key),
        'idempotency_mismatch' => rest_send(:post, :write, login, params: { post: { format: 'plain', body: 'Anderer Text' } }, key: key)
      }
    end

    def rest_error_calls
      login_posts = "/api/v1/tickets/#{id(:login_ticket)}/posts"
      {
        'read_only' => rest_send(:post, :read, login_posts, params: { post: { body: 'Hallo' } }),
        # Anna may read the archive's tickets, not write them.
        'forbidden' => rest_send(:post, :write, "/api/v1/tickets/#{id(:archived_ticket)}/posts",
                                 params: { post: { body: 'Hallo' } }),
        'not_found' => rest_get(:read, "/api/v1/tickets/#{id(:missing)}"),
        'invalid_input' => rest_send(:post, :write, login_posts, params: {}),
        'invalid_input_validation' => rest_send(:post, :write, "/api/v1/projects/#{id(:website)}/tickets",
                                                params: { ticket: { title: '' } }),
        # Provoked: no endpoint reaches an actor refusal deterministically today
        # (tickets have no lock_version). The answer is the real one on the wire,
        # status, `error`, `code` and `reason` as the controller renders them.
        'refused' => refusing_ticket_writes do
          rest_send(:patch, :write, "/api/v1/tickets/#{id(:login_ticket)}", params: { ticket: { status: 'new' } })
        end
      }
    end

    # While the block runs, Actors::SaveTicket answers the failure BaseActor
    # builds for a lost optimistic lock, in the request's own locale.
    module RefuseTicketWrites
      def call(...)
        return super unless Thread.current[:mcp_contract_refuse_ticket_writes]

        Actors::BaseActor::Result.new(success: false, errors: [I18n.t('services.actors.stale_object')],
                                      code: :stale_object)
      end
    end

    def refusing_ticket_writes
      Actors::SaveTicket.singleton_class.prepend(RefuseTicketWrites) unless Actors::SaveTicket.singleton_class < RefuseTicketWrites
      Thread.current[:mcp_contract_refuse_ticket_writes] = true
      yield
    ensure
      Thread.current[:mcp_contract_refuse_ticket_writes] = nil
    end

    def rest_idempotency_calls
      # Spelled out, not a loop: each request from its own line, as everywhere
      # here (Prosopite reads one call site asked three times as an N+1).
      path = "/api/v1/tickets/#{id(:login_ticket)}/posts"
      once = { post: { body: 'Per REST, einmal.' } }
      key = 'contract-rest-1'
      {
        'first' => rest_send(:post, :write, path, params: once, key: key),
        'replay' => rest_send(:post, :write, path, params: once, key: key),
        'mismatch' => rest_send(:post, :write, path, params: { post: { body: 'Anderer Text' } }, key: key)
      }
    end

    # One file on the login ticket, made here, one on Ben's public comment there,
    # made by comment_file_calls, both from fixed fixture files so name, type and
    # size are the same on every run. Without `record`: no tick, no clock moved
    # for anything recorded later.
    ATTACHMENT_FIXTURES = {
      ticket: ['test_document.pdf', 'application/pdf'],
      post: ['test_file.txt', 'text/plain']
    }.freeze

    def attachment_calls
      in_org do
        attach_fixture(TicketDocument.new(ticket: @login, organisation: @organisation, create_embeddings: false),
                       :ticket_document_file, :ticket)
      end
      path = ->(ticket) { "/api/v1/tickets/#{id(ticket)}/attachments" }
      {
        'ok' => signed_urls_replaced(rest_get(:write, path.call(:login_ticket))),
        # A read-only token reads files like any other reader.
        'ok_read_only' => signed_urls_replaced(rest_get(:read, path.call(:login_ticket))),
        'empty' => rest_get(:read, path.call(:export_ticket)),
        'not_found' => rest_get(:read, path.call(:missing)),
        # No read access to the ticket: answered like a missing one.
        'hidden' => rest_get(:read, path.call(:hidden_ticket))
      }
    end

    def attach_fixture(document, attachment, kind)
      filename, content_type = ATTACHMENT_FIXTURES.fetch(kind)
      document.public_send(attachment).attach(io: Rails.root.join('spec/fixtures/files', filename).open('rb'),
                                              filename: filename, content_type: content_type, identify: false)
      document.save!
    end

    SIGNED_PART = '<signed-key>'

    # The URL is signed for five minutes and differs on every run: the request's
    # host, Active Storage's Disk route, a signed segment, the file name. Only the
    # signed segment becomes a placeholder; a URL of any other form stops the
    # recording instead of being written down in a form the server does not send.
    # The real URL's form is pinned in spec/requests/api/v1/read_endpoints_spec.rb.
    # Scheme and host follow the request (ActiveStorage::SetCurrent): `http` and
    # www.example.com here, https and the instance's host behind an SSL proxy.
    # The last segment is the file name escaped for a path; `filename` holds it.
    def signed_urls_replaced(answer)
      form = %r{\A(?<before>http://#{Regexp.escape(session.host)}/rails/active_storage/disk/)[^/?#]+(?<after>/[^/?#]+)\z}
      answer.dig('response', 'body', 'data').each do |file|
        match = form.match(file['url']) or raise "attachment URL of an unexpected form: #{file['url'].inspect}"
        file['url'] = "#{match[:before]}#{SIGNED_PART}#{match[:after]}"
      end
      answer
    end

    def rest_send(verb, token_name, path, params:, key: nil)
      extra = key ? { 'Idempotency-Key' => key } : {}
      session.public_send(verb, path, params: params, headers: headers(token_for(token_name)).merge(extra))
      request = { 'method' => verb.to_s.upcase, 'path' => path, 'params' => params }
      request['idempotency_key'] = key if key
      { 'token' => token_name.to_s, 'request' => request, 'response' => response }
    end

    def rest_get(token_name, path)
      token = token_name ? token_for(token_name) : 'lalab_pat_invalid'
      session.get path, headers: headers(token)
      { 'token' => (token_name || 'invalid').to_s, 'request' => { 'path' => path }, 'response' => response }
    end

    # --- plumbing ----------------------------------------------------------

    def session
      @session ||= ActionDispatch::Integration::Session.new(Rails.application)
    end

    def headers(token)
      { 'Authorization' => "Bearer #{token}" }
    end

    def response
      { 'status' => session.response.status, 'body' => JSON.parse(session.response.body) }
    end

    # Replaces every id this recorder did not choose with a numbered placeholder,
    # in order of appearance, inside nested strings too (a tool's text is JSON in
    # a string).
    def canonical(node, seen = {})
      case node
      when Hash then node.transform_values { |child| canonical(child, seen) }
      when Array then node.map { |child| canonical(child, seen) }
      when String then node.gsub(UUID) { |uuid| placeholder(uuid, seen) }
      else node
      end
    end

    def placeholder(uuid, seen)
      return uuid if IDS.value?(uuid)

      seen[uuid] ||= "<generated-id-#{seen.size + 1}>"
    end
  end
end
