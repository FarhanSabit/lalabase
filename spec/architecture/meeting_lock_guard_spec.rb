# frozen_string_literal: true

require 'rails_helper'

# What: a write that was authorized against a project takes the meeting's row
#   lock through Meeting#lock_in_project!, which answers whether the meeting is
#   still in that project. A bare lock on a meeting is refused outside the model.
# Why: Actors::MoveMeeting holds that lock while it moves a meeting. Three review
#   rounds of the move (lalabase/lalabase#45) found six writes that had been
#   authorized against the old project and still landed after a move: an edit,
#   a delete, a ticket link, a booking, an analysis publication, a second move.
#   Each had been fixed by hand with "lock, then compare the project". A rule
#   that has to be remembered at every write is not a rule.
#   The controllers lock through MeetingInProject#with_meeting_in_project, and
#   every write action of the meeting controllers is asked for it one by one:
#   a fourth round found create_summary unlocked in a file whose delete locked,
#   which a check per file had passed.
# Not seen: a write in a service or a controller this guard does not name.
#   WRITERS and CONTROLLERS pin the ones that exist; a new one is for the
#   person who reads the diff.
module MeetingLockGuard
  ROOTS = %w[app lib].freeze
  MODEL = 'app/models/meeting.rb'

  # A lock taken directly on a meeting: @meeting.lock!, meeting&.lock!,
  # Meeting.lock, project.meetings.lock. Not lock_in_project!, not the lock of
  # a meeting's analyses (meeting_analyses.lock).
  BARE_LOCK = /(?:@meeting|\bmeetings?|\bMeeting)\b&?\.lock(?:!|\b)(?!_)/

  # They lock and then authorize again, under the lock, against the project the
  # meeting is in NOW: safe after a move too, and their meeting may come from a
  # chat rather than from a project.
  ALLOWED = {
    'app/services/actors/accept_ticket_suggestion.rb' =>
      'asks MeetingPolicy#update? and tickets write in the current project under the lock',
    'app/services/actors/start_ticket_suggestion_run.rb' =>
      'asks MeetingPolicy#update? under the lock; the meeting may come from a chat reference'
  }.freeze

  WRITERS = %w[
    app/services/actors/correct_meeting_term.rb
    app/services/actors/link_meeting_participant.rb
    app/services/actors/move_meeting.rb
    app/services/actors/save_meeting.rb
    app/services/actors/save_meeting_analysis.rb
    app/services/actors/save_time_session.rb
    app/controllers/concerns/meeting_in_project.rb
  ].freeze

  # The write actions (every route but GET) of these controllers each run under
  # with_meeting_in_project, or hand the write to an actor that locks itself,
  # or write no meeting that exists.
  CONTROLLERS = {
    'organisations/meetings' => 'app/controllers/organisations/meetings_controller.rb',
    'organisations/meeting_ticket_links' => 'app/controllers/organisations/meeting_ticket_links_controller.rb',
    'organisations/meeting_participant_links' => 'app/controllers/organisations/meeting_participant_links_controller.rb'
  }.freeze

  CONTROLLER_LOCK = 'with_meeting_in_project'

  # Each one is in WRITERS (checked below).
  LOCKING_ACTORS = %w[Actors::SaveMeeting Actors::MoveMeeting Actors::LinkMeetingParticipant
                      Actors::CorrectMeetingTerm].freeze

  # Only shrinks; every entry gives its reason.
  NO_MEETING_YET = {
    'organisations/meetings#detect_participants' =>
      'reads a transcript from the form before any meeting is saved'
  }.freeze

  def self.write_actions(controller)
    actions = Rails.application.routes.routes.filter_map do |route|
      route.defaults[:action] if route.defaults[:controller] == controller && route.verb.present? && route.verb != 'GET'
    end
    actions.uniq!
    actions.sort!
  end

  # The lines of `def action` up to its own `end`, by indentation.
  def self.action_body(source, action)
    lines = source.lines
    start = lines.index { |line| line.match?(/^\s*def #{Regexp.escape(action)}\b/) }
    return unless start

    indent = lines[start][/^\s*/]
    finish = lines[(start + 1)..].index { |line| line.rstrip == "#{indent}end" }
    lines[start..(start + 1 + finish.to_i)].join
  end

  def self.locked?(body)
    body.include?(CONTROLLER_LOCK) || LOCKING_ACTORS.any? { |actor| body.include?(actor) }
  end

  def self.files
    ROOTS.each_with_object([]) do |root, files|
      Dir[Rails.root.join(root, '**', '*.{rb,erb}')].each do |path|
        relative = Pathname(path).relative_path_from(Rails.root).to_s
        files << relative unless relative == MODEL
      end
    end
  end

  def self.bare_locks(source)
    source.each_line.with_index(1).filter_map do |line, number|
      next if line.strip.start_with?('#')

      [number, line.strip] if line.match?(BARE_LOCK)
    end
  end
end

RSpec.describe 'Meeting locks go through Meeting#lock_in_project!', type: :architecture do
  it 'finds no bare lock on a meeting beyond the allow list' do
    found = MeetingLockGuard.files.filter_map do |file|
      next if MeetingLockGuard::ALLOWED.key?(file)

      hits = MeetingLockGuard.bare_locks(File.read(Rails.root.join(file)))
      "#{file}:\n#{hits.map { |n, text| "  #{n}: #{text}" }.join("\n")}" if hits.any?
    end

    expect(found).to be_empty,
                     "These lock a meeting directly:\n#{found.join("\n")}\n\n" \
                     'Use meeting.lock_in_project!(authorized_project_id) and treat false as ' \
                     '"the meeting is gone from this project".'
  end

  it 'keeps the allow list to files that still lock and authorize again' do
    MeetingLockGuard::ALLOWED.each_key do |file|
      hits = MeetingLockGuard.bare_locks(File.read(Rails.root.join(file)))

      expect(hits).to be_present, "#{file} no longer locks directly: remove it from ALLOWED"
    end
  end

  it 'has every known writer call lock_in_project!' do
    missing = MeetingLockGuard::WRITERS.reject { |file| File.read(Rails.root.join(file)).include?('lock_in_project!(') }

    expect(missing).to be_empty, "These writers no longer take the lock: #{missing.join(', ')}"
  end

  describe 'the write actions of the meeting controllers' do
    it 'runs each of them under the lock' do
      unlocked = MeetingLockGuard::CONTROLLERS.flat_map do |controller, file|
        source = File.read(Rails.root.join(file))
        MeetingLockGuard.write_actions(controller).filter_map do |action|
          key = "#{controller}##{action}"
          next if MeetingLockGuard::NO_MEETING_YET.key?(key)

          body = MeetingLockGuard.action_body(source, action)
          next "#{key} (not defined in #{file})" unless body

          key unless MeetingLockGuard.locked?(body)
        end
      end

      expect(unlocked).to be_empty,
                          "These write actions take no meeting lock: #{unlocked.join(', ')}\n" \
                          'Wrap the write in with_meeting_in_project { ... } (MeetingInProject), ' \
                          'or hand it to an actor in LOCKING_ACTORS.'
    end

    it 'finds write actions at all' do
      expect(MeetingLockGuard.write_actions('organisations/meetings')).to include('destroy', 'create_summary')
      expect(MeetingLockGuard.write_actions('organisations/meeting_ticket_links')).to eq(%w[create destroy])
    end

    it 'keeps the exception list to write actions that exist and take no lock' do
      MeetingLockGuard::NO_MEETING_YET.each_key do |key|
        controller, action = key.split('#')
        body = MeetingLockGuard.action_body(File.read(Rails.root.join(MeetingLockGuard::CONTROLLERS.fetch(controller))),
                                            action)

        expect(MeetingLockGuard.write_actions(controller)).to include(action), "#{key} is no write action any more"
        expect(MeetingLockGuard.locked?(body)).to be(false), "#{key} locks now: remove it from NO_MEETING_YET"
      end
    end

    it 'names only actors that lock themselves' do
      MeetingLockGuard::LOCKING_ACTORS.each do |actor|
        expect(MeetingLockGuard::WRITERS).to include("app/services/#{actor.underscore}.rb"), actor
      end
    end

    it 'reads an action up to its own end' do
      source = <<~RUBY
        class Example
          def create_summary
            if ready?
              with_meeting_in_project { write }
            end
          end

          def destroy
            @meeting.destroy
          end
        end
      RUBY

      expect(MeetingLockGuard.locked?(MeetingLockGuard.action_body(source, 'create_summary'))).to be(true)
      expect(MeetingLockGuard.locked?(MeetingLockGuard.action_body(source, 'destroy'))).to be(false)
    end
  end

  describe 'the matcher' do
    it 'sees the forms a direct lock takes' do
      ['@meeting.lock!', '@time_session.meeting&.lock!', 'meeting.lock!',
       'Meeting.lock.find(id)', 'project.meetings.lock.find(id)'].each do |code|
        expect(code).to match(MeetingLockGuard::BARE_LOCK), code
      end
    end

    it 'leaves the helper and the lock of an analysis alone' do
      ['@meeting.lock_in_project!(@project.id)', '@meeting.meeting_analyses.lock.find_by(id: @id)',
       'meeting_lock = true'].each do |code|
        expect(code).not_to match(MeetingLockGuard::BARE_LOCK), code
      end
    end
  end
end
