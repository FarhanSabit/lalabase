# frozen_string_literal: true

require 'rails_helper'
require 'json'
require 'open3'

# What:  Every dependency, and every piece of third-party code checked into this
#        repository, carries a license from a short allowlist.
# Type:  Static guard. Gems have an exception table that only shrinks, and so do single
#        checked-in data files; npm packages have none.
# Why:   The core is AGPL and has one copyright holder. While every dependency is
#        permissive, how this project is licensed is that holder's decision alone. A
#        single dependency under GPL or AGPL alone ends that: its terms apply to the
#        combined work whatever the project decides. The audit of 2026-09-30 found none,
#        by hand. The next `bundle update` can bring one, and nothing else in this
#        repository would notice.
#
# A package passes when EVERY license it declares is on the allowlist, not when one of
# them is. A gemspec lists licenses without saying whether they are a choice (ttfunk:
# Ruby terms OR GPL) or a sum (nio4r: MIT for its own code AND BSD for the bundled
# libev). Reading the list as a choice would wave a sum through. A real choice is an
# exception instead, and the exception names the license taken.
module ThirdPartyLicenseGuard
  ALLOWED = %w[MIT Apache-2.0 BSD-2-Clause BSD-3-Clause ISC 0BSD Ruby].freeze

  # Checked-in code may carry one more: the SIL Open Font License binds the font file,
  # not the software that ships it.
  NOTICE_ALLOWED = (ALLOWED + %w[OFL-1.1]).freeze

  # Data under a share-alike license, checked in unchanged: the word lists that sieve
  # common words out of the glossary extraction. Their license stays off NOTICE_ALLOWED,
  # so this table names single files, never a directory. `declared` is the License line
  # of the file's notice, `taken` the license we use the file under. A section of the
  # notices passes only when the table names every file of it with that License line:
  # one more file in the section, or another license, is red.
  #
  # Only shrinks, like GEM_EXCEPTIONS: an entry whose file is not tracked any more, or
  # whose notice no longer declares what the entry recorded, is red. And it is for
  # data only: an entry holds for a DATA_FILE under DATA_LICENSES (declared and
  # taken), anything else covers nothing and is red (invalid_file_exceptions).
  # And it names these two files: a new entry is a decision, and the example
  # "excepts exactly the two word lists" changes with it.
  FILE_EXCEPTIONS = {
    'vendor/wordlists/de_50k.txt' => {
      declared: 'CC-BY-SA-4.0', taken: 'CC-BY-SA-4.0',
      reason: 'Data, not code; unchanged; named in THIRD_PARTY_NOTICES.txt. Read by Glossary::WordLists.'
    },
    'vendor/wordlists/en_50k.txt' => {
      declared: 'CC-BY-SA-4.0', taken: 'CC-BY-SA-4.0',
      reason: 'Data, not code; unchanged; named in THIRD_PARTY_NOTICES.txt. Read by Glossary::WordLists.'
    }
  }.freeze

  # What FILE_EXCEPTIONS may name: a plain text data file directly in
  # vendor/wordlists/ (no folder below it, so no path leads elsewhere), under a
  # license written for data. A share-alike license on code, or a copyleft one on
  # anything, still has to go.
  DATA_FILE = %r{\Avendor/wordlists/[^/]+\.(?:txt|tsv|csv)\z}
  DATA_LICENSES = %w[CC-BY-SA-4.0 CC-BY-4.0].freeze

  NO_DECLARATION = [].freeze

  # `declared` is what the gemspec says today, and the entry holds only while that is
  # still true: a gem that changes its declaration has to be read again. `taken` is the
  # license this project uses the gem under.
  #
  # The entry is NOT tied to a version. A release that changes its license text and keeps
  # its gemspec stays green.
  GEM_EXCEPTIONS = {
    'ttfunk' => {
      declared: %w[Nonstandard GPL-2.0-only GPL-3.0-only], taken: "Matz's Ruby terms",
      reason: 'A choice of three, spelled out in the LICENSE file of the gem. Comes in through pdf-reader.'
    },
    'diff-lcs' => {
      declared: %w[MIT Artistic-1.0-Perl GPL-2.0-or-later], taken: 'MIT',
      reason: 'A choice of three, spelled out in LICENCE.md of the gem. Runs in production: the wiki version diff requires it.'
    },
    'brakeman' => {
      declared: ['Brakeman Public Use License'], taken: 'Brakeman Public Use License',
      reason: 'Forbids commercial use of the scanner, and names analysing your own software as not commercial ' \
              '(LICENSE.md, section 2). Development and test only, never loaded by the application.'
    },
    'reverse_markdown' => {
      declared: %w[WTFPL], taken: 'WTFPL',
      reason: 'No conditions at all. Kept off the allowlist because one gem does not make a rule.'
    },
    'acts_as_tenant' => {
      declared: NO_DECLARATION, taken: 'MIT',
      reason: 'The gemspec declares nothing; the gem ships MIT-LICENSE.'
    },
    'rtf' => {
      declared: NO_DECLARATION, taken: 'MIT',
      reason: 'The gemspec declares nothing; the LICENSE file of the gem is the MIT text.'
    },
    'ruby-rc4' => {
      declared: NO_DECLARATION, taken: 'MIT',
      reason: 'The gemspec declares nothing; the LICENSE file of the gem is the MIT text. Comes in through pdf-reader.'
    },
    'smart_properties' => {
      declared: NO_DECLARATION, taken: 'MIT',
      reason: 'The gemspec declares nothing; the LICENSE file of the gem is the MIT text. Development only, through erb_lint and better_html.'
    },
    'whatlanguage' => {
      declared: NO_DECLARATION, taken: 'MIT',
      reason: 'The gemspec declares nothing; LICENSE.txt of the gem is the MIT text.'
    }
  }.freeze

  # Our own code, loaded only under Gemfile.operator (from a path on a developer machine,
  # from git on the server). Named, because neither source type says whose code it is.
  OWN_GEMS = %w[lalabase-operator].freeze

  # In the lockfile, installed nowhere we run: build tools of native gems that arrive
  # precompiled. Their gemspecs cannot be read here, so each was read by hand.
  NOT_INSTALLED = {
    'mini_portile2' => 'MIT. Compiles the libraries of nokogiri when no precompiled gem fits.',
    'rake-compiler-dock' => 'MIT. Cross-compiles native gems, a build dependency of rb_sys.',
    'rb_sys' => 'MIT and Apache-2.0. Builds the Rust extension of commonmarker from source.'
  }.freeze

  # Where third-party code is checked in. `vendor` as a whole, so a new directory there
  # cannot slip past; the other two are copies that live outside it.
  BUNDLED_ROOTS = %w[vendor public/fonts app/assets/stylesheets/bootstrap-icons].freeze

  # Outside the roots nobody vendors on purpose, so there a file has to give itself away:
  # by a name nobody gives their own code, or by a license header at its top. The paid
  # theme scripts lived in app/javascript until #814, outside every root.
  BUNDLED_NAME = /\.min\.(js|css)\z|\.(woff2?|ttf|otf|eot)\z/
  LICENSE_HEADER = /@license|Copyright \(c\)|Licensed under|Released under/i
  HEADER_BYTES = 1500

  NOTICES = 'THIRD_PARTY_NOTICES.txt'

  module_function

  # nil when the package is fine, the complaint otherwise.
  def offense(name, declared, exceptions: GEM_EXCEPTIONS)
    exception = exceptions[name]
    return offense_without_exception(name, declared) unless exception
    return if exception.fetch(:declared).sort == declared.sort

    "#{name} declares #{list(declared)}, its exception was written for #{list(exception.fetch(:declared))}: " \
      'read the license again and update the entry'
  end

  def offense_without_exception(name, declared, allowed: ALLOWED)
    return "#{name} declares no license" if declared.empty?

    unlisted = declared - allowed
    "#{name} declares #{list(declared)}, not allowed: #{list(unlisted)}" if unlisted.any?
  end

  # An exception nobody needs is a standing invitation to the next one.
  def stale_exceptions(locked_names, exceptions: GEM_EXCEPTIONS)
    exceptions.filter_map do |name, entry|
      if locked_names.exclude?(name)
        "#{name} is no longer in the lockfile"
      elsif offense_without_exception(name, entry.fetch(:declared)).nil?
        "#{name} declares only allowed licenses and needs no exception"
      end
    end
  end

  def list(licenses)
    licenses.empty? ? 'nothing' : licenses.join(', ')
  end

  # The licenses of the installed gems of somebody else.
  def gem_licenses
    Bundler.load.specs.reject { |spec| OWN_GEMS.include?(spec.name) }
           .to_h { |spec| [spec.name, Array(spec.licenses).map(&:to_s)] }
  end

  # Every platform, not only the one this process runs on: an exception for a gem that
  # exists only on Linux must not read as stale on a Mac.
  def locked_gem_names
    Bundler::LockfileParser.new(Bundler.read_file(Bundler.default_lockfile)).specs.map(&:name).uniq
  end

  # Locked gems nobody looked at: not installed here, and not read by hand either.
  def unread_gems(locked_names, read_names, not_installed: NOT_INSTALLED)
    locked_names - read_names - OWN_GEMS - not_installed.keys
  end

  # package-lock.json carries the license of every package, so this needs no node_modules.
  def npm_licenses
    packages = JSON.parse(Rails.root.join('package-lock.json').read).fetch('packages')
    packages.except('').to_h do |path, entry|
      ["#{path.split('node_modules/').last}@#{entry['version']}", Array(entry['license'])]
    end
  end

  # What git tracks, so an installed bundle in vendor/bundle or a font copied by
  # `npm run copy:fonts` does not count.
  def tracked_files
    output, status = Open3.capture2('git', 'ls-files', '-z', chdir: Rails.root.to_s)
    raise "git ls-files failed in #{Rails.root}" unless status.success?

    output.split("\0")
  end

  def bundled?(path, head = nil)
    return false if File.basename(path) == '.keep'

    BUNDLED_ROOTS.any? { |root| path.start_with?("#{root}/") } || path.match?(BUNDLED_NAME) || head.to_s.match?(LICENSE_HEADER)
  end

  # Only scripts and stylesheets of the application are opened: that is where a copied
  # library lands.
  def head_of(path)
    return unless path.match?(%r{\A(app|lib)/.*\.(js|css)\z})

    File.binread(Rails.root.join(path), HEADER_BYTES).to_s.scrub
  end

  def bundled_files
    tracked_files.select { |path| bundled?(path, head_of(path)) }
  end

  # One entry for every section of the notices file that names paths. A section ends at
  # the next rule of equal signs. `License:` lines may be indented: a library bundled
  # inside another one states its own.
  def notice_sections(text = Rails.root.join(NOTICES).read)
    text.split(/^={20,}$/).filter_map do |section|
      paths = section.scan(/^Path: (\S+)$/).flatten
      { paths: paths, licenses: section.scan(/^\s*License:\s+(\S+)/).flatten } if paths.any?
    end
  end

  def notice_paths(sections = notice_sections)
    sections.flat_map { |section| section.fetch(:paths) }
  end

  # A notice is not a permit: the license it states has to be allowed as well, or
  # FILE_EXCEPTIONS names every file of the section with that license. The complaint
  # names a file without such an entry, so a newcomer next to excepted files is found.
  def notice_offenses(sections = notice_sections, exceptions: FILE_EXCEPTIONS)
    sections.filter_map do |section|
      paths, licenses = section.values_at(:paths, :licenses)
      without_entry = files_without_exception(paths, licenses - NOTICE_ALLOWED, exceptions)
      next if licenses.any? && without_entry.empty?

      offense_without_exception("The notice for #{(without_entry + paths).first}", licenses, allowed: NOTICE_ALLOWED)
    end
  end

  # The files of a section that no entry covers for every license off the list. An entry
  # covers its own path and the one license it declares: a directory line has no entry,
  # and a second license off the list is never declared. An entry for anything but data
  # covers nothing.
  def files_without_exception(paths, unlisted, exceptions)
    return [] if unlisted.empty?

    paths.reject do |path|
      entry = exceptions[path]
      entry && data_exception?(path, entry) && unlisted.all? { |license| entry[:declared] == license }
    end
  end

  def data_exception?(path, entry)
    path.match?(DATA_FILE) && exception_licenses(entry).all? { |license| DATA_LICENSES.include?(license) }
  end

  # Both licenses of an entry, a missing one as nil.
  def exception_licenses(entry)
    entry.values_at(:declared, :taken).uniq
  end

  # The entries of FILE_EXCEPTIONS that name no data file in vendor/wordlists/, or a
  # license that is not for data.
  def invalid_file_exceptions(exceptions = FILE_EXCEPTIONS)
    exceptions.filter_map do |path, entry|
      if !path.match?(DATA_FILE)
        "#{path} is no data file in vendor/wordlists/: FILE_EXCEPTIONS names word lists, never code"
      elsif !data_exception?(path, entry)
        "#{path} names #{list(exception_licenses(entry).map { |license| license || 'nothing' })}, " \
          "not only licenses for data (#{list(DATA_LICENSES)})"
      end
    end
  end

  # An exception for a file that went, or for a license its notice no longer states.
  def stale_file_exceptions(files, sections = notice_sections, exceptions: FILE_EXCEPTIONS)
    exceptions.filter_map do |path, entry|
      licenses = sections.find { |section| section.fetch(:paths).include?(path) }&.fetch(:licenses)
      if files.exclude?(path)
        "#{path} is not tracked any more"
      elsif licenses.nil?
        "#{path} is named in no notice"
      elsif licenses.exclude?(entry.fetch(:declared))
        "The notice for #{path} declares #{list(licenses)}, its exception was written for #{entry.fetch(:declared)}: " \
          'read the license again and update the entry'
      elsif (licenses - NOTICE_ALLOWED).empty?
        "#{path} declares only allowed licenses and needs no exception"
      end
    end
  end

  # The `Path:` lines. A trailing slash names a whole directory.
  def covers?(path, file)
    path.end_with?('/') ? file.start_with?(path) : file == path
  end

  def without_notice(files, paths)
    files.reject { |file| paths.any? { |path| covers?(path, file) } }
  end

  # A notice for a file that was deleted, renamed or never checked in.
  def without_file(files, paths)
    paths.reject { |path| files.any? { |file| covers?(path, file) } }
  end

  # A directory line above another entry. `Path: vendor/` would cover every file there is
  # and every file to come, under whatever license the one section states.
  def swallowed_paths(paths)
    paths.select { |inner| paths.any? { |outer| outer != inner && outer.end_with?('/') && inner.start_with?(outer) } }
  end
end

RSpec.describe 'Third-party license guard' do
  describe 'the rule' do
    def offense(declared, exceptions: {})
      ThirdPartyLicenseGuard.offense('some_gem', declared, exceptions: exceptions)
    end

    it 'accepts a package whose every license is allowed' do
      expect(offense(%w[MIT])).to be_nil
      expect(offense(%w[Ruby BSD-2-Clause])).to be_nil
    end

    it 'rejects a copyleft license' do
      expect(offense(%w[GPL-3.0-only])).to include('not allowed: GPL-3.0-only')
      expect(offense(%w[AGPL-3.0-or-later])).to include('not allowed: AGPL-3.0-or-later')
      expect(offense(%w[LGPL-2.1-only])).to include('not allowed: LGPL-2.1-only')
    end

    it 'rejects a list that holds one allowed license and one that is not' do
      expect(offense(%w[MIT GPL-2.0-only])).to include('not allowed: GPL-2.0-only')
    end

    it 'rejects a package that declares nothing' do
      expect(offense([])).to eq('some_gem declares no license')
    end

    it 'accepts an exception while the package declares what the entry recorded' do
      exceptions = { 'some_gem' => { declared: %w[GPL-2.0-only Nonstandard] } }

      expect(offense(%w[Nonstandard GPL-2.0-only], exceptions: exceptions)).to be_nil
    end

    it 'rejects an exception once the package declares something else' do
      exceptions = { 'some_gem' => { declared: %w[Nonstandard GPL-2.0-only] } }

      expect(offense(%w[GPL-3.0-only], exceptions: exceptions)).to include('read the license again')
      expect(offense([], exceptions: exceptions)).to include('declares nothing')
    end

    it 'calls an exception stale when its gem left the lockfile or passes on its own' do
      exceptions = {
        'gone' => { declared: %w[GPL-2.0-only] },
        'harmless' => { declared: %w[MIT] },
        'needed' => { declared: %w[GPL-2.0-only] },
        'undeclared' => { declared: [] }
      }

      expect(ThirdPartyLicenseGuard.stale_exceptions(%w[harmless needed undeclared], exceptions: exceptions))
        .to contain_exactly('gone is no longer in the lockfile',
                            'harmless declares only allowed licenses and needs no exception')
    end

    it 'calls a locked gem unread unless it was installed, is our own, or was read by hand' do
      locked = %w[rails build_tool lalabase-operator newcomer]

      expect(ThirdPartyLicenseGuard.unread_gems(locked, %w[rails], not_installed: { 'build_tool' => 'MIT' }))
        .to eq(%w[newcomer])
    end
  end

  describe 'the rule for checked-in code' do
    it 'takes a file under a root, a file with a vendored name, and a file with a license header' do
      expect(ThirdPartyLicenseGuard.bundled?('vendor/javascript/a.js')).to be(true)
      expect(ThirdPartyLicenseGuard.bundled?('app/javascript/lib/chart.min.js')).to be(true)
      expect(ThirdPartyLicenseGuard.bundled?('app/assets/fonts/inter.woff2')).to be(true)
      expect(ThirdPartyLicenseGuard.bundled?('app/javascript/lib/picker.js', "/*! Picker 2.1\n * @license MIT */")).to be(true)
      expect(ThirdPartyLicenseGuard.bundled?('lib/assets/x.css', '/* Copyright (c) 2020 Somebody */')).to be(true)
    end

    it 'leaves our own files alone' do
      expect(ThirdPartyLicenseGuard.bundled?('app/javascript/lib/breakpoints.js', '// The mobile boundary (768px)')).to be(false)
      expect(ThirdPartyLicenseGuard.bundled?('vendored/notes.md')).to be(false)
      expect(ThirdPartyLicenseGuard.bundled?('vendor/javascript/.keep')).to be(false)
    end

    it 'covers a file by its own path or by a directory above it, and by nothing else' do
      files = %w[vendor/javascript/a.js vendor/javascript/b.js vendor/grammar/src/parser.c vendor/grammar-two/x.c]

      expect(ThirdPartyLicenseGuard.without_notice(files, %w[vendor/javascript/a.js vendor/grammar/]))
        .to eq(%w[vendor/javascript/b.js vendor/grammar-two/x.c])
    end

    it 'calls a notice orphaned when no checked-in file stands behind it' do
      files = %w[vendor/javascript/a.js vendor/grammar/src/parser.c]

      expect(ThirdPartyLicenseGuard.without_file(files, %w[vendor/javascript/a.js vendor/grammar/ vendor/javascript/gone.js vendor/old/]))
        .to eq(%w[vendor/javascript/gone.js vendor/old/])
    end

    it 'catches a directory line that swallows another entry' do
      expect(ThirdPartyLicenseGuard.swallowed_paths(%w[vendor/ vendor/javascript/a.js vendor/grammar/ public/fonts/x.woff2]))
        .to eq(%w[vendor/javascript/a.js vendor/grammar/])
      expect(ThirdPartyLicenseGuard.swallowed_paths(%w[vendor/javascript/a.js vendor/grammar/])).to be_empty
    end

    describe 'reading the notices' do
      let(:rule) { '=' * 80 }
      let(:notices) do
        <<~NOTICES
          Every "Path:" line names a file.

          #{rule}
          Editor
          #{rule}

          License:  MIT (text below)
          Path: vendor/javascript/editor.js
          Path: vendor/assets/stylesheets/editor.css

          Contains:

            Parser
            License: BSD-3-Clause (text below)

          #{rule}
          A font
          #{rule}

          License:  OFL-1.1 (text next to the file)
          Path: public/fonts/a.woff2

          #{rule}
          MIT License
          #{rule}

          Permission is hereby granted ...
        NOTICES
      end

      it 'finds the paths and every license of each section, the indented ones too' do
        expect(ThirdPartyLicenseGuard.notice_sections(notices)).to eq(
          [
            { paths: %w[vendor/javascript/editor.js vendor/assets/stylesheets/editor.css], licenses: %w[MIT BSD-3-Clause] },
            { paths: %w[public/fonts/a.woff2], licenses: %w[OFL-1.1] }
          ]
        )
        expect(ThirdPartyLicenseGuard.notice_offenses(ThirdPartyLicenseGuard.notice_sections(notices))).to be_empty
      end

      it 'rejects a notice that states a license off the allowlist, also for a library inside another' do
        top = notices.sub('License:  MIT (text below)', 'License:  GPL-3.0-only (text below)')
        inner = notices.sub('License: BSD-3-Clause', 'License: LGPL-2.1-only')

        expect(ThirdPartyLicenseGuard.notice_offenses(ThirdPartyLicenseGuard.notice_sections(top)))
          .to contain_exactly(a_string_including('vendor/javascript/editor.js', 'not allowed: GPL-3.0-only'))
        expect(ThirdPartyLicenseGuard.notice_offenses(ThirdPartyLicenseGuard.notice_sections(inner)))
          .to contain_exactly(a_string_including('not allowed: LGPL-2.1-only'))
      end

      it 'rejects a notice that states no license' do
        bare = notices.sub("License:  OFL-1.1 (text next to the file)\n", '')

        expect(ThirdPartyLicenseGuard.notice_offenses(ThirdPartyLicenseGuard.notice_sections(bare)))
          .to contain_exactly('The notice for public/fonts/a.woff2 declares no license')
      end

      describe 'with an exception for single files' do
        let(:exceptions) do
          {
            'vendor/wordlists/zorbel.txt' => { declared: 'CC-BY-SA-4.0', taken: 'CC-BY-SA-4.0', reason: 'Data.' },
            'vendor/wordlists/quarnix.txt' => { declared: 'CC-BY-SA-4.0', taken: 'CC-BY-SA-4.0', reason: 'Data.' }
          }
        end

        def data_notice(*paths, license: 'CC-BY-SA-4.0')
          <<~NOTICES
            #{rule}
            Word lists
            #{rule}

            License:  #{license} (text at its address)
            #{paths.map { |path| "Path: #{path}" }.join("\n")}
          NOTICES
        end

        def offenses(text)
          ThirdPartyLicenseGuard.notice_offenses(ThirdPartyLicenseGuard.notice_sections(text), exceptions: exceptions)
        end

        it 'accepts a license off the list when the table names every file of the section with it' do
          expect(offenses(data_notice('vendor/wordlists/zorbel.txt', 'vendor/wordlists/quarnix.txt'))).to be_empty
        end

        it 'gives nothing to a file the table does not name, and names that file' do
          expect(offenses(data_notice('vendor/wordlists/zorbel.txt', 'vendor/wordlists/other.txt')))
            .to contain_exactly('The notice for vendor/wordlists/other.txt declares CC-BY-SA-4.0, not allowed: CC-BY-SA-4.0')
        end

        it 'gives nothing to a directory line, also next to named files' do
          expect(offenses(data_notice('vendor/wordlists/zorbel.txt', 'vendor/wordlists/')))
            .to contain_exactly('The notice for vendor/wordlists/ declares CC-BY-SA-4.0, not allowed: CC-BY-SA-4.0')
        end

        it 'gives nothing when the notice states another license than the entry recorded' do
          expect(offenses(data_notice('vendor/wordlists/zorbel.txt', license: 'CC-BY-SA-3.0')))
            .to contain_exactly(a_string_including('not allowed: CC-BY-SA-3.0'))
          expect(offenses(data_notice('vendor/wordlists/zorbel.txt', license: 'GPL-3.0-only')))
            .to contain_exactly(a_string_including('not allowed: GPL-3.0-only'))
        end

        it 'gives nothing to a second license off the list in the same section' do
          text = data_notice('vendor/wordlists/zorbel.txt').sub('Path:', "  License: GPL-3.0-only\nPath:")

          expect(offenses(text)).to contain_exactly(a_string_including('not allowed: CC-BY-SA-4.0, GPL-3.0-only'))
        end

        it 'gives nothing to a section that states no license' do
          bare = data_notice('vendor/wordlists/zorbel.txt').sub(/^License:.*\n/, '')

          expect(offenses(bare)).to contain_exactly('The notice for vendor/wordlists/zorbel.txt declares no license')
        end

        # The table is for word lists, data and not code: an entry that names
        # code, or a license meant for code, covers nothing, even when its
        # notice matches it word for word.
        {
          'a file outside vendor/wordlists/' => ['vendor/javascript/zorbel.js', 'GPL-3.0-only'],
          'a file in a folder below it' => ['vendor/wordlists/wub/zorbel.txt', 'CC-BY-SA-4.0'],
          'a file of vendor/wordlists/ that holds no data' => ['vendor/wordlists/zorbel.rb', 'CC-BY-SA-4.0'],
          'a license that is not for data' => ['vendor/wordlists/zorbel.txt', 'GPL-3.0-only']
        }.each do |label, (path, license)|
          it "gives nothing to an entry for #{label}, even with a notice that matches it" do
            table = { path => { declared: license, taken: license, reason: 'Data.' } }
            sections = ThirdPartyLicenseGuard.notice_sections(data_notice(path, license: license))

            expect(ThirdPartyLicenseGuard.notice_offenses(sections, exceptions: table))
              .to contain_exactly(a_string_including(path, "not allowed: #{license}"))
          end
        end

        it 'calls an entry invalid unless it names a data file in vendor/wordlists/ and licenses for data' do
          table = {
            'vendor/wordlists/zorbel.txt' => { declared: 'CC-BY-SA-4.0', taken: 'CC-BY-SA-4.0' },
            'vendor/wordlists/quarnix.tsv' => { declared: 'CC-BY-4.0', taken: 'CC-BY-4.0' },
            'vendor/javascript/zorbel.js' => { declared: 'CC-BY-SA-4.0', taken: 'CC-BY-SA-4.0' },
            'vendor/wordlists/zorbel.rb' => { declared: 'CC-BY-SA-4.0', taken: 'CC-BY-SA-4.0' },
            'vendor/wordlists/gpl.txt' => { declared: 'GPL-3.0-only', taken: 'GPL-3.0-only' },
            'vendor/wordlists/taken.txt' => { declared: 'CC-BY-SA-4.0', taken: 'GPL-3.0-only' },
            'vendor/wordlists/bare.txt' => { declared: 'CC-BY-SA-4.0' }
          }

          expect(ThirdPartyLicenseGuard.invalid_file_exceptions(table)).to contain_exactly(
            a_string_including('vendor/javascript/zorbel.js', 'no data file'),
            a_string_including('vendor/wordlists/zorbel.rb', 'no data file'),
            a_string_including('vendor/wordlists/gpl.txt', 'GPL-3.0-only'),
            a_string_including('vendor/wordlists/taken.txt', 'GPL-3.0-only'),
            a_string_including('vendor/wordlists/bare.txt', 'nothing')
          )
        end

        it 'calls an entry stale when its file is not tracked, no notice names it, or its notice states something else' do
          table = {
            'vendor/data/zorbel.txt' => { declared: 'CC-BY-SA-4.0' },
            'vendor/data/gone.txt' => { declared: 'CC-BY-SA-4.0' },
            'vendor/data/unnamed.txt' => { declared: 'CC-BY-SA-4.0' },
            'vendor/data/older.txt' => { declared: 'CC-BY-SA-3.0' },
            'vendor/data/plain.txt' => { declared: 'MIT' }
          }
          sections = ThirdPartyLicenseGuard.notice_sections(
            data_notice('vendor/data/zorbel.txt', 'vendor/data/gone.txt', 'vendor/data/older.txt') +
            data_notice('vendor/data/plain.txt', license: 'MIT')
          )
          files = %w[vendor/data/zorbel.txt vendor/data/unnamed.txt vendor/data/older.txt vendor/data/plain.txt]

          expect(ThirdPartyLicenseGuard.stale_file_exceptions(files, sections, exceptions: table)).to contain_exactly(
            'vendor/data/gone.txt is not tracked any more',
            'vendor/data/unnamed.txt is named in no notice',
            'The notice for vendor/data/older.txt declares CC-BY-SA-4.0, its exception was written for CC-BY-SA-3.0: ' \
            'read the license again and update the entry',
            'vendor/data/plain.txt declares only allowed licenses and needs no exception'
          )
        end
      end
    end
  end

  describe 'gems' do
    let(:licenses) { ThirdPartyLicenseGuard.gem_licenses }
    let(:locked) { ThirdPartyLicenseGuard.locked_gem_names }

    it 'reads the bundle it guards' do
      expect(licenses.size).to be > 100
      expect(licenses).to include('rails' => %w[MIT], 'ttfunk' => %w[Nonstandard GPL-2.0-only GPL-3.0-only])
    end

    # A bundle installed without a group, or a gem that exists only for another platform,
    # would otherwise be checked less and still be green.
    it 'reads every gem of the lockfile, or names the ones it cannot' do
      unread = ThirdPartyLicenseGuard.unread_gems(locked, licenses.keys)

      expect(unread).to be_empty, <<~MESSAGE
        Locked gems whose license nobody read, because they are not installed here:

        #{unread.join("\n")}

        Install the whole bundle (every group). A gem that is installed on no platform we run
        goes into NOT_INSTALLED, with its license read by hand.
      MESSAGE
      expect(ThirdPartyLicenseGuard::NOT_INSTALLED.keys - locked).to be_empty
    end

    it 'finds only allowed licenses, or an exception that still fits' do
      offenses = licenses.filter_map { |name, declared| ThirdPartyLicenseGuard.offense(name, declared) }

      expect(offenses).to be_empty, <<~MESSAGE
        A gem carries a license that is not on the allowlist:

        #{offenses.join("\n")}

        Read its license text. GPL or AGPL alone: find another gem. A choice that includes an
        allowed license, or a gemspec that declares nothing: add an entry to GEM_EXCEPTIONS
        with the license taken and the reason.
      MESSAGE
    end

    it 'keeps no exception it does not need' do
      stale = ThirdPartyLicenseGuard.stale_exceptions(locked)

      expect(stale).to be_empty, "GEM_EXCEPTIONS only shrinks. Remove:\n#{stale.join("\n")}"
    end
  end

  describe 'npm packages' do
    let(:licenses) { ThirdPartyLicenseGuard.npm_licenses }

    it 'reads the lockfile it guards' do
      expect(licenses.size).to be > 40
      expect(licenses.keys).to include(a_string_starting_with('bootstrap-icons@'))
      expect(licenses.values.flatten.uniq).to include('MIT', 'ISC')
    end

    it 'finds only allowed licenses, with no exception' do
      offenses = licenses.filter_map { |name, declared| ThirdPartyLicenseGuard.offense(name, declared, exceptions: {}) }

      expect(offenses).to be_empty, <<~MESSAGE
        An npm package carries a license that is not on the allowlist:

        #{offenses.join("\n")}

        There is no exception table for npm. The first entry needs the same care as a gem:
        the license taken and the reason.
      MESSAGE
    end
  end

  describe 'code checked into the repository' do
    let(:files) { ThirdPartyLicenseGuard.bundled_files }
    let(:sections) { ThirdPartyLicenseGuard.notice_sections }
    let(:paths) { ThirdPartyLicenseGuard.notice_paths(sections) }

    it 'reads the files it guards' do
      expect(files).to include('vendor/javascript/slim-select.js', 'public/fonts/lalabase/archivo-latin.woff2')
      expect(files).to include(a_string_starting_with('vendor/tree-sitter-typescript/'))
      expect(files).not_to include('vendor/javascript/.keep', 'app/javascript/application.js')
      expect(paths).to include('vendor/javascript/slim-select.js', 'vendor/tree-sitter-typescript/')
      expect(sections.flat_map { |section| section.fetch(:licenses) }.uniq).to include('MIT', 'OFL-1.1')
    end

    it 'names every file in the notices' do
      missing = ThirdPartyLicenseGuard.without_notice(files, paths)

      expect(missing).to be_empty, <<~MESSAGE
        Third-party code is checked in without a notice:

        #{missing.join("\n")}

        Read its license first: it has to be one of #{ThirdPartyLicenseGuard::NOTICE_ALLOWED.join(', ')}.
        Then add a section to #{ThirdPartyLicenseGuard::NOTICES} with name, version, source,
        `License:`, the copyright line, and one `Path:` line per file.
      MESSAGE
    end

    it 'states an allowed license in every notice' do
      offenses = ThirdPartyLicenseGuard.notice_offenses(sections)

      expect(offenses).to be_empty, <<~MESSAGE
        A notice is not a permit. Checked-in code under one of these licenses has to go:

        #{offenses.join("\n")}
      MESSAGE
    end

    it 'keeps no file exception it does not need' do
      stale = ThirdPartyLicenseGuard.stale_file_exceptions(ThirdPartyLicenseGuard.tracked_files, sections)

      expect(stale).to be_empty, "FILE_EXCEPTIONS only shrinks. Read the license again, or remove:\n#{stale.join("\n")}"
    end

    # Every other check here holds for any number of entries: a new word list
    # with its notice and its entry would pass them all. A share-alike file is
    # a decision, not a routine entry, so this example names the two lists the
    # table was written for. A new entry is such a decision and changes this
    # example too, in the same diff.
    it 'excepts exactly the two word lists of Glossary::WordLists' do
      expect(ThirdPartyLicenseGuard::FILE_EXCEPTIONS.keys)
        .to contain_exactly('vendor/wordlists/de_50k.txt', 'vendor/wordlists/en_50k.txt')
    end

    it 'keeps every file exception to a data file in vendor/wordlists/ under a license for data' do
      invalid = ThirdPartyLicenseGuard.invalid_file_exceptions

      expect(invalid).to be_empty, <<~MESSAGE
        FILE_EXCEPTIONS is for word lists, never for code:

        #{invalid.join("\n")}
      MESSAGE
    end

    it 'names no file that is not there' do
      gone = ThirdPartyLicenseGuard.without_file(files, paths)

      expect(gone).to be_empty, <<~MESSAGE
        #{ThirdPartyLicenseGuard::NOTICES} names paths behind which no checked-in third-party file stands:

        #{gone.join("\n")}
      MESSAGE
    end

    it 'lets no directory line swallow another entry' do
      swallowed = ThirdPartyLicenseGuard.swallowed_paths(paths)

      expect(swallowed).to be_empty, <<~MESSAGE
        A directory `Path:` lies above these entries and would cover them under its own license:

        #{swallowed.join("\n")}
      MESSAGE
    end
  end
end
