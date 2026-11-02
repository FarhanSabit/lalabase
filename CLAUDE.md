# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Projektstruktur & Architektur

### Core Domain Models
- **Account**: Billing entity ABOVE organisations (bundles orgs for billing; tenant-independent, owner ≠ org data access — see `doc/billing_agentur_konto_plan.md`)
- **Organisation**: Multi-tenant root entity
- **User**: Authentication + tenant membership via roles
- **Project**: Container for work items within organization
- **Ticket**: Work items with status, assignments, comments
- **Document**: File management with versions
- **TimeSession**: Time tracking with project/ticket association
- **Notification**: Real-time notification system with channels
- **Activity**: Audit trail for all model changes

### Key Architectural Patterns
- **Multi-tenancy**: Every model scoped to Organisation via acts_as_tenant
- **Component-based UI**: ViewComponent + Stimulus hybrid architecture
- **Activity Tracking**: Automatic audit trail via callbacks and observers
- **Notification System**: Event-driven notifications with fanout service
- **Service Objects**: Complex business logic encapsulation
- **Background Processing**: Solid Queue (einziges Job-Backend; Sidekiq ist entfernt)

---

## Build & Test Commands

* **Runtime**: Ruby 4.0.7 (`.ruby-version`), Rails 8.1.4, `config.load_defaults 7.2`.
  CI reads Ruby from `.ruby-version`.

* **Development server**: **zwei Prozesse nötig** — `bin/dev` (Tailwind-Watch + Solid Queue via
  `Procfile.dev`) UND `bin/rails server -b 0.0.0.0`. `Procfile.dev` enthält **keinen** `web:`-Eintrag
  (entfernt in `9e4673fc`), `bin/dev` allein startet also keine Anwendung.
* **Background jobs**: Jobs laufen automatisch mit Solid Queue in Development
* **Tests ausführen**:
  * Alle Tests: `rspec`
  * Einzelne Datei: `rspec spec/path/to/file_spec.rb`
  * Einzelner Test: `rspec spec/path/to/file_spec.rb:LINE_NUMBER`
  * Mit Debug-Output: `RAILS_LOG_LEVEL=debug rspec ...`
* **JS-Tests** (reine Stimulus-Lib/Parser via Node `node:test`, kein Chrome nötig): `npm test`
* **Python-Tests** (`bin/lala`, Attrappe des MCP-Endpunkts im selben Prozess, nur Standardbibliothek):
  `python3 -m unittest discover -s spec/python -p '*_test.py'`
* **Product screenshots** for the project website: `MARKETING_SCREENSHOTS=1 bundle exec rspec spec/marketing/screenshots_spec.rb`,
  output in `tmp/screenshots/marketing/<locale>/`, excluded from every normal run. The README's
  four pictures are copied from there by hand to `.github/readme/`; then
  `bundle exec ruby script/readme_gallery` redraws the framed tiles of its gallery.
* **System-/JS-Tests auf einer ARM-Maschine** (Parallels-VM): `selenium-webdriver` liefert für
  Linux nur eine x86-64-Binary von `selenium-manager`, für macOS dagegen eine Universal-Binary.
  Auf aarch64 lehnt der Kernel sie ab und `/bin/sh` meldet stattdessen
  `1: Syntax error: "(" unexpected`, ohne die Architektur zu erwähnen. Abhilfe: chromedriver aus
  der Distribution installieren (`sudo apt install chromium-driver`) und, falls er nicht unter
  einem der Standardpfade liegt, `CHROMEDRIVER_BIN` (und bei Bedarf `CHROME_BIN`) setzen.
  Besitzer der Auflösung ist `LocalChrome` in `spec/support/capybara.rb`, Guard:
  `spec/architecture/chrome_driver_binary_guard_spec.rb`. Auf dem Mac greift nichts davon, dort
  bleibt Selenium Manager zuständig.
* **CI**: `.github/workflows/guards.yml` runs six jobs on every PR, with no path filter
  (not on a push to main, and a new push cancels the superseded run; by hand via
  `workflow_dispatch`, reasons in the workflow header):
  `guards` (curated specs plus `browser_database_cleanup_spec.rb`,
  `mobile_ticket_navigation_spec.rb`,
  `mobile_assistant_layout_spec.rb` and `mobile_shell_regressions_spec.rb`),
  `javascript` (Node unit tests), `lala` (Python tests of `bin/lala`, `spec/python/`),
  `rubocop`, `brakeman` and `dependencies`.
  The Rails/browser job needs no `RAILS_MASTER_KEY` (Rails generates a local test secret); npm lifecycle scripts are disabled
  with `npm ci --ignore-scripts`, and fonts are copied explicitly. Browser fixtures
  are nontransactional so Puma can read them; failure artifacts include
  `tmp/screenshots/`, `tmp/capybara/` and explicit mobile captures.
  A red RuboCop run means a new offense against the frozen baseline. A red guards
  job needs inspection of the failing step, including browser/infrastructure failures.
  ⚠️ **Die kuratierte Liste ist handgepflegt.** Wer eine Spec löscht, löscht ihre Zeile dort
  mit: rspec kann die Datei nicht LADEN und meldet „0 examples, 1 error occurred outside of
  examples", was nach Infrastruktur aussieht und keine ist. Ein lokaler Lauf der Liste fängt
  das nicht, wenn man die Pfade vorher auf existierende filtert. Wächter:
  `spec/architecture/ci_guard_list_spec.rb` (prüft auch, dass kein `.js` an rspec geht, das
  fährt der `javascript`-Job mit Node).
  ⚠️ **Ein Sicherheits-Spec trägt `:ci_guard`** an seinem `describe`
  (`RSpec.describe Foo, :ci_guard, type: :request do`, das Tag vor den Keyword-Argumenten).
  Derselbe Wächter verlangt, dass jede so markierte Datei in der Liste steht, einzeln oder über
  ein Verzeichnis darüber. Eine gestrichene Zeile wird damit rot statt still. Bis zum
  27.09.2026 liefen die Regressions-Specs von #895 und #896 nirgends. Neue Specs zu Rechten,
  Mandantengrenzen oder behobenen Lücken: Tag setzen **und** Pfad eintragen.
  The full suite and full `erblint` still run locally (known drift, separate cleanup).
* **Docker** (`Dockerfile`, `compose.yml`, `compose.build.yml`, `.env.docker.example`): for
  self-hosters only, our servers deploy with Capistrano and never run the image. Each published
  release builds `ghcr.io/lalabase/lalabase:<version>` for amd64 and arm64
  (`.github/workflows/docker-release.yml`), checks it with `script/docker_check` and only then
  pushes it. `compose.yml` pulls the release in its `image:` line, which `script/release
  prepare` writes and `publish` holds against the version (guard: `changelog_guard_spec.rb`);
  never edit that line by hand. `.github/workflows/docker.yml` builds from the checkout
  (`compose.build.yml`) and boots the stack, only for PRs touching the image or `config/`.
  Every production setting that
  names a host goes through `Lalabase::InstanceSettings`; without `LALABASE_HOST` it returns our
  servers' values unchanged (pinned by `spec/config/instance_settings_spec.rb`).
  ⚠️ **The compiled CSS carries the asset host.** The image precompiles with `ASSET_HOST=` set
  and empty; without it every instance would load its fonts from lalabase.com.
* **Leaks** (`.github/workflows/leaks.yml`): a workflow of its own on **every** PR and on
  every push to main. One job, `leaks`, over everything the PR makes public, not
  only its end state: every commit (merges by their diff against main, so a conflict resolution
  counts), every commit message, who wrote and committed it, every name a commit adds
  (binaries, links, renames), the PR's branch name, title and body (GitHub writes them into the
  commit on main), and the files as they end up. **gitleaks** with `.gitleaks.toml` (default rules without any upstream
  exception by path, `--redact`, `--text` so a `-diff` attribute hides nothing), and **leak
  guard** (`script/leak_guard`, `Lalabase::LeakGuard`): forbidden file types, runtime data,
  symbolic links, and keyed digests (`config/leak_guard.digests`, HMAC with the secret
  `LEAK_GUARD_KEY`) of what only the maintainers may know. The plain list and the generator live
  in the private repository; never write one of those words here, not even in a comment.
  Locally: `LEAK_GUARD_KEY` in `.env`, then `script/leak_guard` and
  `script/leak_guard history origin/main..HEAD`.
  ⚠️ **Commits to this repository carry the maintainer's GitHub noreply address** (repository
  `user.email`). A private address as author is public with every commit, and the guard turns
  it red: set it in every new clone and on every machine or agent environment that commits.
  ⚠️ **The net comes from the base, not from the PR** (`script/leak_guard net`): a PR that
  weakens it, say by allowing a real key "to make the CI green", is still checked by the old
  one, and the job summary names the change. The label `leak-net-change` makes a run use the
  PR's own net; set it only after reading that part of the diff (a new dummy key in the
  allowlist needs it). The `.gitleaks.toml` check in `gitleaks_config_problems` is a tripwire,
  not a proof; do not extend it, the base net is the protection.
  ⚠️ **Green only means checked.** Ways it once said green after checking nothing: a wrong key
  (the digests carry a key check), a base commit missing from the clone (the `Range` step stops
  first), a NUL byte or a marker line that cut the log short, a range without commits. A new
  way of skipping is a red test first.
  Not covered, on purpose (accidental leaks are the threat model): a secret in a UTF-16 file
  (gitleaks does not read it; the guard reads its words), what is pushed without a PR (the
  pre-push hook on switch day), tags and notes.
* **Zwei Sicherheits-Jobs, absichtlich getrennt.** Ein Job trägt genau einen Status, und
  `dependencies` ist heute rot (s. u.). Zusammengelegt wäre brakemans Rot von diesem Rot nicht
  mehr zu unterscheiden, und brakemans ganzer Wert ist die Aussage „Rot = NEUER Befund":
  * `brakeman`, gegen die frozen `config/brakeman.ignore`-Baseline (38 Einträge, Stand
    20.10.2026; der `constantize`-Eintrag im Datei-Proxy ist mit #915 behoben statt neu
    eingefroren, der Eintrag der Titelsuche ging mit dem Umbau der Ticketsuche).
    Rot = NEUER Befund. **Jeder Eintrag ist geprüft** und nennt im `note`-Feld
    den Grund, warum er sicher ist; die Datei darf nur schrumpfen, und ein neuer Eintrag
    braucht dieselbe Begründung. Ausnahme seit 20.10.2026: das TRUNCATE des Demo-Resets
    (`lib/lalabase/demo/reset.rb`), ohne Eingabe; Brakeman sieht die Quotierung durch
    `map` und `join` nicht. Bei der Prüfung am 26.09.2026 war einer eine echte
    SQL-Injection (Ticketsuche, #889); fünf weitere wurden gehärtet statt eingefroren.
    ⚠️ Ein eingefrorener Eintrag ist öffentlich sichtbar: „ungeprüft" darin ist eine Liste mit
    Angriffszielen.
    Ein früherer hochkonfidenter Eintrag, `_filter_pills.html.erb:97` (XSS), wurde am 31.08.2026 **behoben
    statt neu eingefroren**: eine Zeilenverschiebung änderte seinen Fingerabdruck, und da die
    Datei nur schrumpfen darf, sind die fünf handgebauten `"#{request.path}?#{...}"` jetzt ein
    Erbauer mit benannter Route (`TimeSessionsHelper#time_list_filter_url`). Genauso am
    08.09.2026 `ad_hoc_filter_service.rb:248` (SQLi im Datumsfilter): die Zeile verschob sich,
    der Fingerabdruck änderte sich, und die Bedingung ist jetzt Arel statt SQL-String
  * `dependencies` (`bundler-audit`), **ohne** Ignore-Liste. Ein verwundbares Gem ist keine Drift,
    sondern eine Versionsnummer; die Antwort ist ein Update, kein Vermerk. Seit dem fünften
    Schritt der Abhängigkeits-Serie (#640, #641, #649, #657, Rails 8.0.5.1 auf main) ist der
    Job grün: rot = NEUE Meldung, und die Antwort ist wieder eine Versionsnummer
* **Code-Qualität**:
  * Ruby linten: `rubocop`
  * ERB linten: `erblint --lint-all`  
  * Security Scanner: `bundle exec brakeman` — **nicht** `bin/brakeman`: der Shim erzwingt `--ensure-latest` und bricht mit Exit 5 ab, sobald es upstream eine neuere Version gibt, ohne überhaupt zu scannen
  * Abhängigkeiten prüfen: `gem install bundler-audit && bundle-audit check --update` (bewusst nicht im Gemfile: das Werkzeug prüft die `Gemfile.lock` und darf nicht von ihr gepinnt werden)
* **Assets**:
  * Tailwind-CSS baut `tailwindcss-rails` (dev: `bin/rails tailwindcss:watch` via Procfile.dev, einmalig: `bin/rails tailwindcss:build`); die übrigen Stylesheets bündelt Sprockets über die `*= require`-Direktiven in `application.css`
  * Bootstrap-Icons-Fonts nach `public/fonts` kopieren (einmalig nach `npm install`): `npm run copy:fonts`
* **Database**: 
  * Migrationen: `bin/rails db:migrate`
  * Schema laden: `bin/rails db:schema:load`
  * Seeds: `bin/rails db:seed` (läuft auch automatisch, wenn `db:prepare` eine Datenbank neu anlegt).
    Lädt immer die Persona-Stammdaten, in Development zusätzlich eine kleine Demo
    (`db/seeds/demo.rb`). Die Seeds löschen **nie** etwas und enthalten keine echten Adressen,
    nur `@example.com` (Guard: `spec/architecture/seeds_guard_spec.rb`)
  * Erster Instanz-Admin einer frischen Installation: `bin/rails lalabase:setup`
    (`LALABASE_ADMIN_EMAIL`/`LALABASE_ADMIN_PASSWORD` oder Abfrage im Terminal; verweigert,
    sobald ein Beuser existiert). Der erste Nutzer registriert sich danach unter `/users/sign_up`

---

## Multi-Tenancy & Security

### acts_as_tenant Essentials
**Kritische Prüfungen:**
* `acts_as_tenant` gesetzt?
* Default-Scope korrekt?
* Seeds/Factories tenant-aware?
* Queries filtern korrekt auf tenant?
* **Optionaler `belongs_to` auf ein mandantenfähiges Modell steht VOR `acts_as_tenant`** (oder
  hat eine eigene Validierung). acts_as_tenant 1.0.1 prüft Fremd-IDs nur für Verweise, die vor
  dem Aufruf deklariert sind. Pflicht-Verweise schützt Rails selbst, weil der Lesezugriff durch
  den Mandanten-Scope läuft. `SmartFolder.project` stand dahinter und nahm bis zum 16.09.2026
  das Projekt einer fremden Organisation an (Guard: `smart_folders_tenant_boundary_spec.rb`).
* Eine rohe `*_id` aus Params wird über eine mandanten- oder policy-gebundene Abfrage aufgelöst,
  nie direkt zugewiesen. Ein Wechsel des Projekts prüft die Rechte im **Ziel**projekt
  (Vorbild: `TimeSessionsController#move_to_requested_project`).

### Private Kommentare: eine Regel, kein nacktes `ticket.posts`

**Verbindlich** (Guard-Spec: `spec/architecture/post_visibility_guard_spec.rb`; läuft über den
Verzeichnis-Eintrag `spec/architecture/` in der CI-Guard-Liste):

Einen privaten Kommentar lesen sein Adressat, sein Autor und die Kontoadmins. Das entscheidet
**nur** `Post.readable_by(user, organisation)` (bzw. `#readable_by?`, `PostPolicy` fragt es).

| Wer liest das Ergebnis? | Dann |
|---|---|
| eine Person (Zeitleiste, Suche, Mail an sie, API, MCP) | `ticket.posts.readable_by(user, organisation)` |
| alle Leser des Tickets (Aktivitäts-Auszug, Zusammenfassung, KI-Antwort) | `ticket.posts.public_posts` |

* Der Wächter lehnt in Controllern, Services, Queries, Mailern, Komponenten, Views, Presentern,
  Jobs und Helpern jedes `.posts` ohne eine dieser Fortsetzungen ab (erlaubt sind noch `find`,
  `build`, `create!`), dazu `association(:posts)` und ein `JOIN posts` ohne `posts.id IN (`.
  Die Ausnahmeliste darf nur schrumpfen, jeder Eintrag nennt seinen Grund.
* ⚠️ **Kein Vorladen von `posts` für eine Anzeige.** Eine vorgeladene Assoziation enthält alle
  Posts. Die Zeitleiste hat bis zum 27.09.2026 genau so jeden privaten Kommentar gezeigt.
* Bis zum Audit vom 26.09.2026 stand die Regel nur in `PostPolicy`. Fünf Leser hatten sie
  vergessen, zwei weitere fanden sich beim Beheben.

### A meeting write locks through `Meeting#lock_in_project!`

**Binding** (guard spec: `spec/architecture/meeting_lock_guard_spec.rb`; runs through the
directory entry `spec/architecture/` in the CI guard list):

A meeting can move into another project (`Actors::MoveMeeting`, under the meeting's row lock).
A write that was authorized against a project takes the same lock through
`meeting.lock_in_project!(authorized_project_id)` and treats `false` as "the meeting is gone
from this project": refuse, or answer as if it were not found.

* The guard refuses a bare lock on a meeting (`@meeting.lock!`, `Meeting.lock`,
  `project.meetings.lock`) anywhere outside `app/models/meeting.rb`. Its allow list names two
  actors that lock and then authorize again, under the lock, in the project the meeting is in
  now (`AcceptTicketSuggestion`, `StartTicketSuggestionRun`). It only shrinks, and every entry
  gives its reason.
* In a controller the lock is `with_meeting_in_project { ... }` (`MeetingInProject`): the
  block runs under the lock, a moved meeting answers 404. The guard asks **every write
  action** (each route but GET) of `MeetingsController` and `MeetingTicketLinksController`
  for that call or for an actor that locks itself (`LOCKING_ACTORS`). A check per file had
  passed `create_summary`, unlocked next to a delete that locked, until a fourth review round.
  The exception list (`NO_MEETING_YET`, a write before any meeting exists) only shrinks.
* `WRITERS` pins the services that lock: the move, the edit, the analysis publication, the
  booking, and the controller helper. Four review rounds of the move found each of these
  writes landing in the old project after a move.
* ⚠️ **Not seen: a write in a service or controller the guard does not name.** Writing a
  meeting's data (its project, links, analyses, bookings) elsewhere means calling the helper
  and adding the file to `WRITERS` or `CONTROLLERS`.
* Lock order: the meeting before a booking or an analysis, never the other way round.

---

## ViewComponent & Design System

### Komponenten-Entwicklung Patterns
* **Naming**: `Neo[Name]Component` für Komponenten, Buttons unter `Neo::Buttons::` Namespace (z.B. `Neo::Buttons::ButtonComponent`)
* **Stimulus Controller**: `neo_[name]_controller.js` (z.B. `neo_button_controller.js`)
* **Hybrid-Ansatz**: Struktur/Styling in ViewComponent, Interaktivität in Stimulus

### Neo Brutalist Design Language
* **Stil**: Border-2 black, box-shadow hover effects, bold typography
* **Components verfügbar**: Button, Card, Tag, Flash, Modal, Forms
* **Style Guide**: Entwicklung unter `/style-guide`, Dokumentation `docs/design/grundlegendes.md`

### Icons: one set, Bootstrap Icons

**Binding** (guard spec: `spec/architecture/one_icon_set_guard_spec.rb`; runs through the
directory entry `spec/architecture/` in the CI guard list, no allowlist):

| What | How |
|---|---|
| an icon | `<i class="bi bi-..." aria-hidden="true"></i>` |
| a drawing of our own (the plus of the main action, the deadline flag, the view switch, a chevron) | an inline SVG of straight strokes and basic shapes |

* No template, component, helper, script or stylesheet carries an icon pasted from another
  set. Until 2026-09-30 six files carried nine of them (Heroicons, Lucide, the spinner from
  the Tailwind documentation). Each is somebody's work under its own license, and a pasted
  path is not a file the license guard can see.
* The guard is a tripwire, not a proof. It takes a path with arcs or Béziers for a pasted
  icon, because what we draw ourselves has none, and it knows the classes of other icon
  fonts. ⚠️ It does NOT see a pasted icon of straight strokes only (a cross, a check mark, a
  menu), a path held in a constant, an SVG file or a sprite. Those are for the person who
  reads the diff.
* A drawing of our own that really needs a curve (a chart, a gauge) computes its path from
  numbers in code. A curve written out as a literal is what a pasted icon looks like.
* A state with two signs (pinned or not) puts both icons in the markup and lets the
  attribute pick one in CSS (`column_picker.css`, `aria-pressed`). The script flips the
  attribute and repaints nothing.
* The spinner of a button is a ring drawn with a border, in the button's own colour
  (`Neo::Buttons::Base#render_spinner`).
* ⚠️ **An icon that is told to turn names its own box**: `bi bi-arrow-repeat inline-block
  animate-spin`. An `<i>` is an inline box, and a transform does not apply to one. It turns
  only while its parent happens to be a flex or grid container. Two waiting signs stood
  still that way until 2026-09-30 (ticket header, admin mail log); four others turned by
  the luck of their parent. The guard reads class lists in templates and scripts; a list
  put together in Ruby (`NeoInfoTagComponent`) is held by its component spec.
* The cross of a removable tag says what it removes (`components.neo_tag.remove`,
  "%{name} entfernen"): a row of chips is a row of buttons.

### CSS-Konvention: KEINE `<style>`-Blöcke in Views
**Verbindlich** (Guard-Spec: `spec/views/no_style_blocks_guard_spec.rb` schlägt sonst fehl):
* CSS gehört in `app/assets/stylesheets/*`, niemals als `<style>`-Block in eine View:
  * `layout.css` → globales Spalten-/Layout-System, Listen-/Karten-Interaktionen
  * `views.css` → seitenspezifische Regeln (gescoped auf Seiten-Anker, thematisch gruppiert)
  * `components/rich_text_embeds.css` → Rich-Text-Anzeige (Zoom-Link, Lightbox, Platzhalter); Editor und Inhalt stylt Lexxys eigenes Stylesheet (`lexxy-content`)
  * `components/*.css` → gekapselte Komponenten (Vorbild: `components/custom_select.css`)
  * `style_guide.css` → lädt nur im Style-Guide-Layout
* **Einzige Ausnahme**: Mailer-Layouts (`layouts/mailer.html.erb`, `layouts/notification_mailer.html.erb`) — E-Mail-Clients laden keine externen Stylesheets (Allowlist im Guard-Spec).
* **`@apply` funktioniert NUR in `application.tailwind.css`** (Build-Zeit). In Runtime-CSS oder `<style>`-Blöcken ist `@apply` wirkungslos und damit toter Code.
* Generische Klassennamen (z. B. SortableJS `.sortable-ghost`) beim Zentralisieren auf einen Seiten-Anker scopen, sonst kollidieren Seiten-Varianten.

### Frontend: the application loads nothing from a foreign host

**Binding** (guard spec: `spec/architecture/no_runtime_cdn_guard_spec.rb`; runs through the
directory entry `spec/architecture/` in the CI guard list):

The scripts, stylesheets and fonts of the application, and the markup of its own templates,
are served by the instance. A new frontend dependency is vendored (`vendor/javascript`,
`vendor/assets`, with a notice in `THIRD_PARTY_NOTICES.txt`) or comes from a gem.

The guard asks three questions:

| Question | Where |
|---|---|
| Does a tag, a stylesheet, an import or a request in a script name a foreign address as a literal? | our own files and the vendored ones |
| Does a file carry the address of a public CDN at all? | the same files |
| Both again | the scripts and stylesheets that gems put into the page (Turbo, Stimulus, Action Text, Lexxy), found through the importmap and the stylesheet bundle |

* ⚠️ **A vendored file is not a local file.** Until 2026-09-30 the Markdown editor of the old
  note form sat in `vendor/assets` and fetched a spelling dictionary from jsDelivr and an icon
  font from BootstrapCDN on every full load of that page: both addresses were strings inside
  its minified file, both features on by default. Read a new library for addresses before it
  goes in. The guard reads it again, and reads the gems' files after every update.
* ⚠️ **The content security policy stops none of this.** It runs in report-only mode
  (`config/initializers/content_security_policy.rb`): it logs a violation and lets the request
  through. Do not count on it until that line says `false`.
* **Synced documentation pages load nothing from elsewhere either**, since 2026-11-01.
  The sync copies the images a page shows out of the clone (`Documentation::AssetCollector`) and the file proxy serves them behind the right of
  the documentation; an image that is not served shows as its alt text, one with a foreign
  address becomes a link. Until then every reader of such a page contacted
  raw.githubusercontent.com. Held by `documentation_sync_job_spec` ("names no repository
  host and no address outside the instance").
* ⚠️ Other content is not covered by this guard, and `img-src` still allows any https.
* Not seen either: an address built at run time (a host in a constant, an interpolated string).
* One named exception, `SAMPLES`: the code samples of the style guide are printed as text, and
  one of them shows the forbidden thing on purpose. A comment that quotes a foreign tag or
  address trips the guard like the real thing: describe it in words.
* The list of public CDNs is incomplete by nature. It is there for the case the first question
  cannot see.

### View-Konvention: KEINE rails-ujs-Optionen
**Verbindlich** (Guard-Spec: `spec/views/no_rails_ujs_options_guard_spec.rb`, in der CI-Guard-Liste):

`rails-ujs` ist in dieser App **nicht geladen** (`config/importmap.rb`: „Not used with Turbo").
Zwei verbreitete Rails-Idiome sind damit **stiller toter Code** — sie werfen keinen Fehler,
sie tun einfach nichts:

| ❌ rails-ujs (wirkungslos) | ✅ Turbo | Symptom ohne Fix |
|---|---|---|
| `link_to path, method: :delete` | `link_to path, data: { turbo_method: :delete }` | Link feuert ein **GET** → RoutingError bei POST/PATCH-only-Routen, oder stille Navigation, wenn die Route auch GET beantwortet |
| `data: { confirm: "..." }` | `data: { turbo_confirm: "..." }` | Der Bestätigungsdialog **erscheint nie**, destruktive Aktionen feuern beim ersten Klick |

* Bei `Neo::Buttons::*`-Komponenten stattdessen den Top-Level-Kwarg `confirm:` nutzen — die
  Komponente mappt ihn selbst korrekt auf `turbo_confirm`.
* `button_to` darf `method:` verwenden: dort ist es die dokumentierte Rails-API und rendert ein
  echtes Formular. Nur bei `link_to` ist `method:` die Falle.
* Der Guard hat **keine Allowlist** — er startet bei null. Neue Ausnahme heißt: Eintrag anlegen
  **und** begründen, warum UJS-Semantik in einer App ohne UJS nötig ist.

### View-Konvention: Seitenbreite nur über die Klasse
**Verbindlich** (Guard-Spec: `spec/architecture/page_width_guard_spec.rb`; läuft über den
Verzeichnis-Eintrag `spec/architecture/` automatisch in der CI-Guard-Liste):

Welche Breite eine Seite bekommt, entscheidet eine Frage: **vergleicht man senkrecht Spalten, oder
liest man waagerecht Zeilen?** (Abschnitt „Breiten“ in `doc/belegungstabelle_oberflaeche.md`)

| Klasse | Wann | Im Code |
|---|---|---|
| Voll | Tabelle, Kanban, Matrix: man vergleicht Spalten | kein Deckel |
| Geteilt | Liste und Bahn nebeneinander | kein Deckel; eine offene Bahn hebt jeden Deckel auf |
| Gedeckelt | pro Zeile ein Gegenstand mit einem Wert | `.width-capped` (620 px), mit Zeichen- oder Zeitspalte `.width-capped--wide` (820 px) |

* Fließtext in jeder Klasse: `.width-text` (70ch).
* Die Werte stehen **einmal** in `layout.css` (`--width-capped`, `--width-capped-wide`,
  `--width-text`). Eine View nennt die Klasse, nie ein eigenes `max-w-*`; neues CSS liest die
  Variable und gibt derselben Zahl keinen zweiten Namen.
* Der Deckel sitzt am Inhaltsblock, nie an der Schale, und ist **nie zentriert**: gedeckelt heißt
  „endet früher“, nicht „beginnt woanders“. Der Seitenkopf (Titel, Reiter, Titelaktion) bleibt
  volle Breite.
* Die Altlasten stehen im Guard auf einer Liste, die **nur schrumpfen** darf: eine umgestellte
  Seite senkt ihren Eintrag, ein zu hoher Eintrag schlägt ebenfalls an.

### View-Konvention: die Seiten ohne Anmeldung teilen EIN Gerüst

**Verbindlich** (Guard-Spec: `spec/requests/auth_pages_skeleton_spec.rb`; steht mit eigenem
Eintrag in der CI-Guard-Liste, `spec/requests/` ist dort kein Verzeichnis-Eintrag):

Sieben Seiten sieht ein Besucher, bevor er angemeldet ist: Anmeldung, Registrierung,
Registrierung gesperrt, Passwort vergessen, neues Passwort, Bestätigung erneut, Entsperren.
Sie teilen ein Gerüst, und **das Gerüst gehört dem Layout `application_auth`**, nicht der View.
Eine View liefert vier Dinge:

| Schlitz | Inhalt |
|---|---|
| `yield` | Formularspalte: Vorzeile, Überschrift, Formular |
| `content_for :auth_cross` | der Link oben rechts |
| `content_for :auth_panel` | der Inhalt des dunklen Panels |
| `content_for :auth_panel_decorative` | gesetzt, wenn das Panel ein Schaubild ist |

* Der Guard hat **keine Ausnahmeliste**: keine View unter `app/views/devise/` enthält
  `lp-auth-form-col`, `lp-auth-legal` oder ein `<aside>`. Bis zum 20.09.2026 war das Gerüst
  dreimal von Hand abgeschrieben, und die vier fehlenden Seiten hätten sieben daraus gemacht.
* **`application_sessionless` ist NICHT dasselbe Layout.** Es behält die Admin-Anmeldung
  (eigener Styleguide) und die Rechtsseiten einer Instanz und lädt `auth.css` nicht.
* Passwortfelder rendert **immer** `devise/shared/_password_field` (Augen-Umschalter,
  optional Stärkeanzeige). Die Beschriftungen stehen unter
  `views.devise.shared.password_field`, nicht je Seite.
* Eine neue Seite braucht einen Controller-Eintrag in `devise_for` **und** `layout
  'application_auth'`. Ohne den `devise_for`-Eintrag läuft Devise's eigener Controller mit dem
  Standard-Layout und rendert die Anwendungshülle für jemanden ohne Sitzung. Genau so stand
  `/users/unlock/new` da, seit `:lockable` scharf ist.

⚠️ **Eine Frist im Panel kommt aus der Konfiguration, nie aus dem Text.** „Der Link gilt
6 Stunden" liest `Devise.reset_password_within`, „nach 5 Fehlversuchen" liest
`Devise.maximum_attempts`. Ein getippter Wert überlebt die geänderte Einstellung und belügt den
Leser; der Guard ändert die Einstellung und holt die Seite noch einmal. Ein Satz, der nur für
bestimmte Einstellungen gilt (Selbstentsperrung nur bei `unlock_strategy` `:time`/`:both`),
steht hinter der passenden Bedingung.

⚠️ **Keine Sackgassen.** Jede Seite ohne Anmeldung ist von der Anmeldeseite aus anklickbar.
Bis zum 20.09.2026 verlinkte nur `devise/shared/_links` auf Bestätigung und Entsperrung, und
gerendert hat dieses Partial **nichts**: beide Seiten waren nur über die Adresszeile
erreichbar, während die Hilfeseite den Link „auf der Anmeldeseite" versprach. Der Guard folgt
dem Link und prüft die Zielseite.

⚠️ **`aria-hidden` nur auf einem Schaubild.** Das Panel der Anmeldung zeigt erfundene
Inbox-Zeilen und bleibt versteckt. Ein Panel mit der einzigen Fassung einer Tatsache muss
lesbar sein. Und auf dem Handy blendet `auth.css` den letzten Schritt einer Schrittliste aus
(`.lp-auth-step:last-child`) — dort darf keine Tatsache allein stehen, und eine Überschrift
darf die Schritte nicht zählen.

### Beispiel-Implementation
```erb
<%= render Neo::Buttons::ButtonComponent.new(
  variant: :primary,
  size: :medium,
  icon: "plus-lg",
  interactive: true,
  form: { action: path, method: :post }
) do %>
  Button Text
<% end %>
```

```javascript
// app/javascript/controllers/neo_button_controller.js
export default class extends Controller {
  static values = { confirm: String }
  
  handleClick(event) {
    if (this.confirmValue && !confirm(this.confirmValue)) {
      event.preventDefault()
    }
  }
}
```

---

## Notification System Architecture

### Event-Driven Pattern
1. **OutboxEvent**: Captures model changes via callbacks
2. **FanoutService**: Determines notification recipients  
3. **ScoreCalculator**: Calculates notification priority
4. **Notification**: Final notification with channels (in_app, email, webhook)

### Zentrales Constants System
```ruby
# app/models/concerns/notifications/constants.rb
module Notifications::Constants
  EVENT_TYPE_TICKET_ASSIGNED = 'ticket_assigned'.freeze
  EVENT_TYPE_MAPPING = {
    'ticket.assigned' => EVENT_TYPE_TICKET_ASSIGNED
  }.freeze
end
```

**Thread-Safety**: Verwende vollqualifizierte Namespaces in Background Jobs
```ruby
# ✅ Richtig in Jobs/Services
event_type = Notifications::Constants::EVENT_TYPE_MAPPING[key]
```

---

## Critical Bug Fixes (NICHT ÜBERSCHREIBEN!)

### Turbo URL-Objekt Bug (12.08.2025)
**Problem**: Paginierung funktionierte nicht von Detail-Ansichten, generierte `/tickets/undefined` URLs.

**Fix**: Zeile ~211 in application.js:
```javascript
// ✅ RICHTIG - Turbo erwartet URL-Objekt
event.detail.url = currentUrl;

// ❌ FALSCH - würde Bug verursachen!
// event.detail.url = currentUrl.toString();
```

**Wichtig**: Diese Zeile NIEMALS auf `.toString()` ändern! Turbo's interne Verarbeitung erwartet ein URL-Objekt.

### Stimulus Controller Index Bug (20.08.2025)
**Problem**: JavaScript Stimulus Controller 404-Fehler auf Production/Staging durch relative Imports.

**KRITISCHE REGEL**: Die Datei `app/javascript/controllers/index.js` verwendet eine **custom Implementierung** mit `eagerLoadControllersFrom`. 

**NIEMALS:**
- Die Datei mit expliziten Controller-Imports überschreiben
- `rails stimulus:manifest:update` direkt ausführen (zerstört custom Version)
- Zurück zu relativen Imports (`from "./controller"`) gehen

**IMMER:**
- Die custom `eagerLoadControllersFrom`-Lösung beibehalten
- Bei Updates `rails stimulus:manifest:update_safe` verwenden
- Dokumentation in `docs/STIMULUS_CONTROLLER_MANAGEMENT.md` beachten

**Warum**: Relative Imports umgehen Importmap-Resolution → ungehashte URLs → 404-Fehler in Production.

### Signierte Active-Storage-Adressen in Listen (08.09.2026)
**Problem**: Die Ticketliste antwortete auf Production manchmal mit 429 „Zu viele Anfragen".
Jede Avatar-Kachel lud ihr Bild über `rails_storage_proxy_path`, und die Route stempelt den
Ablauf (`config.active_storage.urls_expire_in`, 15 Minuten) millisekundengenau in die Signatur.
Dasselbe Bild war damit in jeder Zeile eine andere Adresse: kein Browser-Cache, 53 bis 59
Rails-Requests je Listenaufruf, und Rack::Attack (`requests/ip`, 300 je 5 Minuten,
`/rails/active_storage` zählt mit) drosselte die Liste selbst.

**Fix**: `Neo::Users::AvatarComponent#picture_url_expires_at` rundet den Ablauf auf Slots der
konfigurierten Länge und übergibt ihn als `expires_at:`; der Link gilt bis zum Ende des
übernächsten Slots. Guards: `spec/components/neo/users/avatar_component_spec.rb` (Slot-Regel)
und `spec/requests/organisations/tickets_name_display_spec.rb` (vier Zeilen, eine Adresse).
Hergang: `docs/letzte_arbeiten/2026_09_08_1_letzte_arbeiten_avatar_adresse_slot.md`.

**Wichtig**:
- Wer ein Bild **je Zeile** über eine signierte Adresse rendert (`rails_storage_proxy_path`,
  `rails_blob_path`, `url_for(variant)`), bekommt ohne gerundetes `expires_at:` denselben
  Fehler. Die Adresse stabil machen, **nicht** die Drossel lockern.
- `freeze_time` macht diesen Fehler in einer Spec unsichtbar: alle Zeilen rendern dann zur
  selben Millisekunde und auch der alte Code liefert eine Adresse. Solche Guards laufen in
  Echtzeit.

---

## Database Schema & Migrations

### UUID Primary Keys
Alle Tabellen verwenden UUID als Primary Key mit `gen_random_uuid()` default.

### PostgreSQL Enums
```sql
-- Beispiel für Event Types
CREATE TYPE notification_event_type AS ENUM (
  'ticket_commented', 'ticket_assigned', 'ticket_unassigned', 
  'ticket_status_changed', 'ticket_blocker', 'project_announcement',
  'document_added', 'mention', 'system_message'
);
```

### Migration Best Practices
* Migrationen mit `ActiveRecord::Migration[8.1]` erstellen
* Enum-Erweiterungen: `ALTER TYPE ... ADD VALUE IF NOT EXISTS`
* Reversible Migrationen schreiben
* Lange Locks vermeiden (add_column ohne Default, dann UPDATE separat)
* Datenmigrationen als Task/Service, **NICHT** in Schema-Migration

---

## Background Jobs & Performance

### Solid Queue (Rails 8 Native)
Haupt-Job-System für Notifications, E-Mails, Cleanup-Tasks.
```ruby
# Job-Definition
class ProcessNotificationJob < ApplicationJob
  queue_as :notifications
  
  def perform(notification)
    # Job-Logik
  end
end
```

### Performance-kritische Scopes
```ruby
# app/models/notification.rb
scope :for_notification_center, -> {
  includes(:actor, :notifiable, :project)
}

scope :with_email_log_counts, -> {
  left_joins(:email_logs)
  .group('notifications.id')
  .select('notifications.*, COUNT(email_logs.id) as email_logs_count')
}
```

### Caching Strategy
* Fragment Caching für Komponenten: `cache [@notification, 'card_v2']`
* Russian Doll Caching für verschachtelte Strukturen
* Database-Level Indizierung für häufige Queries

---

## Testing Strategy

### Test-Pyramide
* **System-Tests** (Capybara): Haupte User-Flows
* **Request-Tests**: Authentication, Authorization, API-Endpunkte  
* **Model-Tests**: Validations, Scopes, Callbacks, Business Logic
* **Component-Tests**: ViewComponent isoliert testen
* **JS-Tests**: Stimulus Controller (wenn komplexe Logik)

### Bugfix-Regel
**IMMER**: Erst reproduzierenden, fehlschlagenden Test schreiben → dann fixen → Test bleibt als Regression Guard.

```ruby
# spec/models/notification_spec.rb
it 'prevents duplicate notifications for ticket creation with assignees' do
  ticket = create(:ticket, assignees: [user])
  activity = create(:activity, trackable: ticket, key: 'ticket.created')
  
  expect {
    Notifications::FanoutService.new(activity).call
  }.not_to change(Notification, :count)
end
```

### Test-Konvention: Statussymbole gehen ungeschützt an Rack

**Verbindlich** (Guard-Spec: `spec/architecture/rack_status_symbol_guard_spec.rb`; läuft über den
Verzeichnis-Eintrag `spec/architecture/` automatisch in der CI-Guard-Liste, ohne eigenen Eintrag):

Rack 3.1 hat zwei Statussymbole umbenannt, Rack 3.2 warnt bei jedem Aufruf der alten Schreibweise
und kündigt ihre Entfernung an. Der Zahlenwert bleibt in beiden Fällen gleich.

| ❌ veraltet | ✅ aktuell | Code |
|---|---|---|
| `:unprocessable_entity` | `:unprocessable_content` | 422 |
| `:payload_too_large` | `:content_too_large` | 413 |

* **Im Controller ist die alte Schreibweise harmlos, aber erst ab actionpack 8.0.5.1**:
  `ActionDispatch::Response.rack_status_code` übersetzt in beide Richtungen, bevor Rack gefragt
  wird. Unter 8.0.2 gibt es diese Schicht noch nicht, dort warnt auch `render status:`. Rails und
  Rack müssen deshalb zusammen wandern.
* **In Specs gibt es die Schicht nie.** rspec-rails reicht das Symbol unverändert an
  `Rack::Utils.status_code` weiter (`have_http_status.rb:219`). Genau darum deckt der Guard `spec/`
  ab und nicht `app/`.
* Der Guard prüft gegen `Rack::Utils::SYMBOL_TO_STATUS_CODE` statt gegen eine Wortliste: was dort
  fehlt, ist veraltet. Die nächste Umbenennung fängt er ohne Pflege mit ab.

### Factory Patterns
```ruby
# spec/factories/notifications.rb
FactoryBot.define do
  factory :notification do
    association :recipient, factory: :user
    association :organisation
    event_type { Notifications::Constants::EVENT_TYPE_TICKET_ASSIGNED }
    channel { 'in_app' }
    # tenant-aware factory
  end
end
```

---

## Verzeichnis-Karten (nested CLAUDE.md)

Für die teuersten Bereiche existieren verzeichnis-lokale Karten, die Claude Code automatisch
lädt, sobald dort gearbeitet wird: `app/models/`, `app/services/` (+ `notifications/`,
`lalabase/`), `app/controllers/concerns/`, `app/javascript/controllers/`. Karten sind ≤ ~40 Zeilen,
tragen ein Stand-Datum und **verweisen statt zu duplizieren**.

### Boy-Scout-Regeln (bei ohnehin anstehender Berührung, kein Big Bang)

* Flaches Modell einer Namespace-Domäne substanziell angefasst → in den Namespace ziehen (`self.table_name` behalten).
* Nicht-trivialer Controller-Write angefasst → Actor extrahieren (Seam-Regel oben).
* Service ohne `.call(**kwargs)`-Konvention substanziell geändert → migrieren + von der Guard-Allowlist streichen.
* Inline-`<script>`-Heredocs in Controller-Actions angefasst → in Turbo-Stream-Templates/Stimulus verlagern.
* Duplikat-Stimulus-Controller berührt → auf die `neo_*`-Variante konsolidieren (Liste: `app/javascript/controllers/CLAUDE.md`).

---

## Pattern-Auswahl Quick Reference

* **ViewComponent**: Wiederverwendbare UI-Komponenten mit Kapselung, Testbarkeit
* **Service Object**: Komplexe Business-Logik, mehrere Schritte, externe APIs
* **Concern**: Kleine, wiederverwendbare Logik über mehrere Modelle/Controller
* **Job (Solid Queue)**: >200 ms, externe Requests, Batch/Retry nötig
* **Turbo Stream**: Kleines, lokales UI-Update, serverseitig getriggert
* **Stimulus Controller**: Komplexere Client-Interaktionen oder State im Browser
* **Feature Flag**: Riskante Änderungen, inkrementelles Rollout
* **Form Object / View Model**: Komplexe Formulare, mehrere Modelle

---

## Actor-Pattern (Write-Seam)

Nicht-triviale Schreibvorgänge laufen über **Command-Objekte** unter `app/services/actors/`
(`Actors::SaveTicket`, `Actors::DestroyPost`, …). Ein Actor kapselt **einen** Write: Transaktion,
Validierungs-/Fehler-Mapping, `Current.user` fürs Activity-Tracking, Side-Effect-Jobs nach Commit.
Gehärtet in `Actors::BaseActor`; der Vertrag wird per Guard-Spec
(`spec/services/actors/actor_contract_guard_spec.rb`) erzwungen.

### Naming (Kollision auflösen)
„Actor" meint hier ein **Command-Objekt**. Es hat **nichts** mit `Activity#actor` /
`Notification#actor` zu tun — die bezeichnen den **Audit-User**, der eine Änderung ausgelöst hat.
Bewusst disjunkt; nicht vermischen.

### Seam-Regel: wann Actor, wann Controller?
* **Nicht-trivialer Write → Actor.** Nicht-trivial = Multi-Step / eigene Transaktion /
  Activity-Tracking / Fanout / Background-Job / externer API-Call / Assoziations-Sync.
* **Trivialer Write → Controller.** Trivial = einzelnes `update!`/`create!` auf einem Model
  ohne Side-Effects. Triviales CRUD bleibt im Controller (kein Blanket-Rollout).

### Vertrag (verbindlich, Guard-geprüft)
* **Keyword-Args** überall: `Actors::X.new(project:, params:, id: nil, current_user:)`. Der
  User-Parameter heißt `current_user:` (NICHT `actor:` — Kollision, s. Naming).
* Einstieg bevorzugt `Actors::X.call(...)`; `.new(...).call` nur, wenn der Aufrufer `#record`
  vor `#call` braucht (z. B. `PostUpdateService`).
* **Tier 1** (Standardfall): nur `#perform` (+ `#record`, optional `#enqueue_jobs`)
  implementieren — `BaseActor#call` übernimmt Transaktion, Fehler-Mapping, `Current.user`, Enqueue.
* **Tier 2** (Ausnahme, in der Guard-Allowlist `tier_2_actors` im Guard-Spec): eigener `#call`, teilt nur die
  Helper. Die maßgebliche Liste ist die Allowlist selbst (aktuell 5: `SaveTicket`,
  `AcceptTicketSuggestion`, `CreateAiPost`, `GenerateGroupCustomerDescriptions`, `CreateSignup`; `MoveTicket` ist seit
  08.09.2026 Tier 1, sein Nummern-Retry lebt in `Tickets::Mover`) — Begründungen je Actor
  stehen als Kommentar am `tier_2_actors`-Let im Guard-Spec.
* **Fehler:** Domänen-Fehlschläge per `raise Actors::ActorError, msg` (→ failure-Result);
  `RecordInvalid` wird automatisch gemappt. Alles andere ist „unerwartet" →
  `handle_unexpected_error`: dev/test **re-raise** (laut crashen), production loggen + failure.
* **Jobs:** NIE rohes `perform_later` — immer `enqueue_after_commit { SomeJob.perform_later(...) }`,
  damit der Job erst nach dem äußersten echten Commit feuert (korrekt bei Verschachtelung).
* **`Current.user`:** NIE selbst setzen — `with_actor_context` setzt + stellt wieder her (kein Leak).
* **`#record`:** liefert den primären Datensatz oder `nil` (nie eine Collection).

---

## Service-Konvention (app/services)

Neue Services: Entry-Point ist `Klass.call(**kwargs)`, `#initialize` nur Keyword-Args, mindestens
eine erklärende Kommentarzeile am Dateikopf. Read-/Query-Objekte mit Domänen-Verben deklarieren
stattdessen `# Entry point: <methode>` im Header. Erzwungen durch
`spec/services/service_convention_guard_spec.rb` (Bestand auf shrink-only-Legacy-Allowlist —
bei substanzieller Änderung migrieren + streichen). Details: `app/services/CLAUDE.md`.

---

## API-Namensräume (Kern gegen getrennte Website)

Drei Namensräume unter `/api`, und sie unterscheiden sich darin, **wer** ruft:

| Namensraum | Aufrufer | Ausweis | Vertrag |
|---|---|---|---|
| `Api::V1::*`, `Api::McpController` | ein Mensch mit Konto | persönliches Zugangstoken + Pundit | `doc/mcp_server_plan.md` |
| `Api::Public::*` | jeder, auch niemand | keiner, nur lesend | `docs/api/public_v1.md` |
| `Api::Provisioning::*` | die getrennte Website | ein geteiltes Geheimnis aus ENV | `docs/api/provisioning_v1.md` |

* Beide neuen Namensräume erben von einer **eigenen** `ActionController::API`-Basis, nie von
  `ApplicationController`: keine Session, kein Pundit, kein Mandant aus der Sitzung. Wächter:
  `spec/architecture/{public,provisioning}_api_contract_guard_spec.rb` prüfen die **Klassen**,
  nicht den Text.
* Die Provisioning-Tür ist **aus, wenn kein Geheimnis gesetzt ist** (404, nicht 403): eine
  fremde Instanz trägt keine Tür, die sie nicht benutzt. Ein persönliches Zugangstoken wird dort
  nie akzeptiert, es gehört zu einem Menschen mit Organisationen.
* Der Schreibvorgang selbst gehört dem Actor, den auch das Formular im Kern nutzt
  (`Actors::CreateSignup`). Eine zweite Registrierungslogik neben ihm ist der Fehler, den W2
  gerade beseitigt hat.
* **Zwei Formulare, ein Schreibvorgang.** Unser Registrierungsformular lebt in
  `gboyke/lalabase-website` und darf aussehen, wie wir wollen; das Formular im Kern gehört den
  Instanzen, die ihn selbst betreiben, und den Eingeladenen (ein Einladungstoken kann eine
  fremde Anmeldeseite nicht einlösen). Getrennt sind die **Formulare**, nie der Actor. Was nur
  unserem Geschäft gehört, steht deshalb im Website-Formular: der Neugründer-Rabatt ist am
  20.09.2026 aus dem Kern-Formular verschwunden, `FounderSignup` und die Provisioning-Tür
  bleiben.
* Antworten tragen **eine** Hülle: `data.<ding>` im Erfolg, `error.{code,messages}` im Fehler.
  `code` ist maschinenlesbar, `messages` sind übersetzter Text.

For the REST ticket member routes (including `GET /tickets/:ticket_id/posts/:id`) and the
number route, `Api::V1::ReadableTicket` resolves tickets
through the token's effective organisation/project reach and `TicketPolicy::Scope`:
missing and unreadable tickets return 404 with `{"error":"not_found","code":"not_found"}`.
Denied actions on readable tickets remain 403; read-only tokens reject writes with 403
(`"code":"read_only"`) before any ticket lookup, including missing IDs. Status and body are equal for missing and
unreadable tickets, but queries are not: discovering the unknown tenant reads only
`organisation_id` and `project_id` first. Ticket IDs are random UUIDs, not sequential
numbers; this deliberately accepts query asymmetry instead of searching every
organisation the token reaches. It makes no constant-time guarantee.

What a token holder can find is decided by `Tickets::ReadableForToken` alone (REST, MCP tools,
`Tickets::RelationAccess`), reach before policy scope. `token:` is required on it and on
`Tickets::RelationAccess`: `nil` means no second limit and is written out by the callers without
a token. Guards: `spec/architecture/ticket_token_lookup_guard_spec.rb` (also refuses these
finders and `TicketRelation.visible_to` without a token on the token surfaces) and
`ticket_relation_actor_callers_guard_spec.rb`.

**`/api/v1` for programs** (REST R0, 2026-10-28; the terminal client moves from MCP to REST
feature by feature):

* **Error bodies** keep `error` and the HTTP status as they always were and add `code`, the
  MCP vocabulary (`invalid_input`, `read_only`, `forbidden`, `not_found`, `refused`, plus
  `unauthorized`); an unmapped actor code is `refused` with the old value as `reason`. One
  status changed on purpose: an unexpected actor failure (`internal_error`) on
  `time_sessions.create` (R6) and `posts.create` (R3a) answers 500 without the exception's
  text, where it was a 422 that carried it. Every
  body comes from `Api::V1::ErrorBody` through `BaseController#render_error`; guard
  `spec/architecture/api_v1_error_body_guard_spec.rb`. Answers outside the controllers carry
  no `code`: the Rack::Attack 429 (plain text), a 500 from the exceptions app, a 400 for a
  query string Rack cannot decode (`?x=%`; raised in middleware before any controller), and a
  400 for a body parameter of raw bytes that are no valid UTF-8, form or JSON (Rails raises
  `ActionController::BadRequest` when it first reads the parameters, in its params wrapper or
  its request log, before any callback or `rescue_from` of `BaseController` runs; a JSON escape
  of a lone surrogate is a parse error instead, answered as 400 `bad_request` with `code`). The 401 of `/api/mcp` (same concern,
  `render_unauthorized`) keeps its old body.
* **`Idempotency-Key`** on every write (`idempotent :create` in the controller,
  `Api::V1::Idempotent`): the same key and request replays the first 2xx answer (status and
  body), another request answers 422 `idempotency_key_reused`. Same table and store as MCP
  (`Mcp::IdempotencyStore`); the REST fingerprint includes method and path, so a key never
  crosses surfaces. Runs inside authentication and the read-only gate. A key is at most 255
  bytes of valid UTF-8 without NUL (else: 422 `invalid_idempotency_key`, nothing written).
  One rule for both surfaces, `Mcp::IdempotencyStore.client_key` (strip, blank is no key) and
  `.storable_key?` (`IdempotencyStore.new` raises on any other key, before the write, so a
  third caller cannot skip it): since MCP 0.13.1 a write tool refuses such an `idempotency_key` as
  `invalid_input` before it runs, after the project and read-only gates (guard
  `spec/requests/api/mcp_idempotency_key_bound_spec.rb`; it used to write, fail to remember
  the key with -32603 and write again on every retry). A replay checks no rights
  (it repeats what the same token already got; keys do not expire), and a retry must send
  the same bytes. Multipart bytes Rack accepts but JSON cannot encode are fingerprinted
  without decoding, so the action still applies its permissions and input validation.
  Existing JSON fingerprints stay unchanged. Every write route must be `idempotent`
  (`spec/architecture/api_v1_writes_idempotent_guard_spec.rb`).
* **`GET /api/v1/me`** names `api_version` and `capabilities` from `Api::V1::Capabilities`,
  pinned against the routes both ways (`spec/requests/api/v1/capabilities_spec.rb`): a new
  endpoint adds its line there. Additive changes bump the minor.

`POST /api/v1/tickets/:ticket_id/time_sessions` books by the rule the MCP tool
`create_time_session` books by (REST R6, 2026-10-29; feature `time_sessions.book` in
`/me`): `TimeSessions::Booking` refuses no duration, both `duration_string` and
`duration_minutes`, `duration_minutes` that is no whole number, and an `occurred_on` that is
no ISO 8601 date or timestamp (422
`validation_failed`/`invalid_input`, inside the read gate), dates the booking as the
calendar day in the token owner's profile zone (stored as midnight; absent = today there),
and writes through `Actors::SaveTimeSession`; an unexpected actor failure (`internal_error`)
answers 500 without its message. Rights stay in the controller. A booking
writes no activity and no notification; it touches the ticket's `updated_at`. Guard:
`spec/requests/api/v1/time_session_booking_spec.rb`.

**Ticket view** (REST R1, 2026-10-29, API 1.3.0):

* `GET /projects/:project_id/tickets` names `meta.available_statuses`, the project's status
  keys from the same source as MCP `list_tickets`.
* `GET /tickets/:id` takes opt-in pages: any one of `posts_page`, `posts_per_page` (at most
  50, above is 422), `posts_order` (`oldest`, `newest`), `attachments_page` (10 per page)
  switches the answer to the paged fields of MCP `get_ticket` (`posts_total`,
  `posts_truncated`, `attachments`, ...). **Without them the body stays what it was** (the
  contract records it; gboyke/lalabase-mcp reads it and passes it on), but for the additive
  `attachments` on a comment since R7, below. Invalid values: 422 `invalid_input`,
  checked before the ticket is looked up. A key without a value switches too. REST does not
  truncate bodies, nor the extracted `text` of attachments (up to 10 per page). These
  `attachments` are the ticket's own files only, with text and without URL (`attachments_total`
  counts those); `GET /tickets/:id/attachments` lists ticket and comment files with signed URLs.
* `GET /projects/:project_id/tickets/number/:number` answers what `GET /tickets/:id` answers,
  paging included. Missing, malformed (`abc`, `0`), unreadable, out of reach or foreign: the
  same 404. The number is looked up only inside that project.
* `GET /tickets/:ticket_id/posts/:id`: one readable comment, whole, in the shape of a comment
  in the ticket. Hidden private, foreign and missing comments: the same 404.
* Options and pages come from `Tickets::Reading`, shared with MCP `get_ticket`; MCP keeps its
  caps. Guard: `spec/requests/api/v1/ticket_view_spec.rb`.
* **A comment lists its files** (REST R7, 2026-10-30, API 1.8.0, MCP 0.14): `attachments`
  beside `attachments_count`, wherever a comment is served (`Tickets::Serializer#post_payload`:
  the ticket, whole or in pages, the number route, the comment route, MCP `get_ticket`), each
  with `id`, `filename`, `content_type`, `byte_size`, in id order. ⚠️ `id` is the
  `PostDocument`'s, which the file proxy takes (`/org/:org/files/post_document/:id`), NOT the
  Active Storage attachment's that `GET /tickets/:id/attachments` hands out with a signed URL.
  No URL and no text, so `get_ticket`'s caps hold as they were. No capability: a client takes
  the field's presence as the signal. Visibility is the comment's (`readable_by`), no second
  rule. `attachments_count` counts rows: a document that lost its blob stays in the count and
  leaves the list. Guard: `spec/requests/api/v1/comment_files_spec.rb`.

`GET /api/v1/time_sessions/open` lists the person's own open hours within the token's
reach, organisations AND projects, and only the rows the web time list shows them
(`TimeSessions::ViewingScope`). A booking on a ticket they cannot read keeps its row and
its minutes, with `ticket: null`. Owner: `TimeSessions::OpenHours`; guard:
`spec/requests/api/v1/time_sessions_open_access_spec.rb`.

`GET /api/v1/organisations` and `GET /api/v1/projects` read through
`PersonalAccessTokens::ReachListing`, the reader of the MCP tools `list_organisations` and
`list_projects` (MCP 0.15.0). The rows are the same, the rest differs on purpose: REST answers 200
with `[]` for an organisation out of reach and shows an admin archived projects unpaged and uncut;
MCP answers `not_found`, shows archived projects on request, pages by 100 and cuts a description.
MCP also lists only what the project gate opens; REST lists what the policy scope shows, which
is wider for a role holding nothing but time tracking.
Guards: `spec/services/personal_access_tokens/reach_listing_spec.rb`,
`spec/requests/api/mcp_list_projects_spec.rb`, `spec/requests/api/v1/projects_listing_spec.rb`.

`GET /api/v1/projects/:project_id/knowledge` (REST R2, 2026-10-29, API 1.6.0, capability
`knowledge.search`) lists a project's notes and documents by title through `Knowledge::Lookup`,
the read the MCP tool `search_knowledge` uses: the same rows, order (`updated_at` newest first,
then id), fields (`type`, `id`, `title`, `updated_at`, `link`) and `total` for the same search.
Rows only through the per-type policy scope: no title and no count of a type the reader may not
read; a reader who may open the project but read no knowledge gets an empty list. Without `q`
(or blank) REST lists every readable row; MCP keeps `q` required. `type` other than `note` or
`document`, and `page`/`per_page` that are no whole number from 1 to the maximum (`per_page` at
most 100, where MCP clamps) and a NUL in `q` or `type` answer 422 `invalid_input`, checked
before the project; an absent or empty `page`/`per_page` is the default. A page beyond the total
reads no rows. The project gate is MCP's (token reach and `ProjectAccessService`): missing,
malformed, beyond the reach, not openable (an archived project for a non-admin included) and foreign answer the same 404.
Guards: `spec/requests/api/v1/knowledge_spec.rb`, `spec/services/knowledge/lookup_spec.rb`.

`GET /api/v1/organisations/:organisation_id/people` and `.../people/:id` (People S3b) read
the people directory through `People::Lookup`, the object the assistant's `find_people` /
`get_person` and their MCP twins read as well: one rights question (the people right, 403
without it), one search, one field selection (a list row never carries contact details or
notes; the card carries the notes, MCP and the assistant never do). Only a token that
reaches every project of the organisation reads its directory: a token limited to some
projects, an organisation outside the token (a deactivated membership included) and a
missing one answer the same 404, as do a missing and an invisible person. The list pages
by 50, at most 100; a value outside is a 400, never cut. Guards:
`spec/requests/api/v1/people_spec.rb`, `spec/requests/api/mcp_people_spec.rb`,
`spec/requests/api/people_parity_spec.rb` (REST and MCP answer the same rows).

`POST /api/v1/tickets/:ticket_id/posts` (REST R3a) writes by the rule the MCP tool
`post_comment` writes by, `Posts::Comment`, through `Actors::SavePost` like the web form:
`post[format]` `html` (the default, the body stored as sent) or `plain` (literal text through
`Posts::PlainTextBody`: escaped, blank lines into paragraphs, single breaks into `<br>`). An
unknown format, one that is no string (read raw: strong parameters would drop a list and fall
back to html), NUL in a plain body and a plain body that converts to nothing answer 422
`validation_failed`/`invalid_input` with a text from `services.post_comment.*`, checked inside
the read gate. Without `format` the answer stays byte for byte: an empty body is the model's
refusal, after the write check, with every model message (the contract case `html_empty` was
recorded before R3a), and a JSON `false` as body counts as none, as before. Raw invalid bytes
in a form or JSON body never reach the rule (the 400 above); MCP refuses them. Only a multipart
part can name a charset of its own (`text/plain; charset=...`): `html` hands it to ActionText as
it came, as before (a Latin-1 comment keeps its letters), `plain` transcodes it to UTF-8, and a
`plain` part declared binary must hold UTF-8. An unexpected actor failure (`internal_error`) answers 500 without the exception's
text, every other failure 422 `validation_failed` as before; MCP answers `comment failed:
unexpected error`. ⚠️ A failure after the commit (an after_commit callback or a job enqueue
that raised) leaves the comment written: `Posts::Comment#save` counts it as saved, so REST
answers 201 and keeps its Idempotency-Key, and MCP returns the comment. Answered as an error,
a retry with the same key wrote it twice, because the key keeps only successes. Capability
`posts.plain`. Guards:
`spec/requests/api/v1/post_comment_format_spec.rb`, `spec/services/posts/comment_spec.rb`,
`spec/requests/api/mcp_plain_comment_spec.rb`, `spec/locales/token_rule_refusal_texts_spec.rb`
(the refusals of `Posts::Comment`, `TimeSessions::Booking` and `Tickets::Change`, the MCP texts and
the de and en keys are three lists kept by hand; the guard holds them together).

`POST /api/v1/tickets/:id/changes` (REST R3b, 2026-10-30, API 1.7.0, capability
`tickets.changes`) changes ONE thing by the rule the MCP tool `update_ticket` changes by,
`Tickets::Change`: `change[title]`, `change[status]` (a key of `meta.available_statuses`), or
`change[add_assignee_ids]` and `change[remove_assignee_ids]` (at most 50 each, `"me"` is the token
owner) against the current list. The kind is decided by the keys present, not their values. It
answers 200 with the ticket summary, like `PATCH /tickets/:id`, which stays as it is: its
`assignee_ids` REPLACE the list, and `gboyke/lalabase-mcp` relies on that. `parent_id` on that
PATCH reaches the model (`Ticket#parent_unchanged`, a saved ticket keeps its parent): another
parent or an empty value is a 422 `validation_failed`/`invalid_input`, the current parent is no
change, so a client may send back what it read. Status and assignees
go through `Actors::ApplyTicketChanges` like a board drag (a `TicketBulkRun` included), the title
through `Actors::SaveTicket` alone under a lock on the row in its project, so the side effects are
the web's and MCP's, once. Order: read-only token 403, then the read gate (missing, malformed,
foreign, out of reach, hidden: one 404, whatever the body), then `authorize :update?` (403, whatever
the body), and only then the input, so a refusal of it only ever answers a caller who may write. A
body Rails cannot read comes before the gate: a 400, the same for every ticket.
Input refused (mixed kinds, an unknown key, no `change`, the title rule, a list that is no list,
over 50, the same person in both lists, text that is no UTF-8): 422
`validation_failed`/`invalid_input`, a text from `services.ticket_change.*` that repeats nothing the
client sent. One difference to MCP is Rails', not the rule's: a JSON `null` in a list is gone before
the rule reads it, so `[id, null]` is `[id]` here and refused there; it names nobody either way.
Stopped by the project's state: 422 with `code: refused`, and `error` and `reason` the
same word (`value_not_allowed`, `user_not_assignable`, `no_status_field`, `validation_failed`), a
text from `services.ticket_change_failure.*` in `errors` and, for a title the model refuses, its
messages behind it. The code is named in the controller: `Api::V1::ErrorBody` alone would read
`validation_failed` as invalid input. Nobody is removed by a refused change, and a stale assignment
stays unless it is named. A ticket that moved or was deleted after the rights check answers the same
404. After the write commits, the response takes a fresh lock in that same project and reads
the whole summary under it, so a concurrent move cannot disclose destination data.
A failure the rule does not name answers 500 without its text. Guards:
`spec/requests/api/v1/ticket_changes_spec.rb`, `spec/requests/api/v1/ticket_changes_side_effects_spec.rb`
(the same trail as MCP), `spec/requests/api/v1/ticket_changes_concurrency_spec.rb`
(the response against a concurrent move), `spec/services/tickets/change_spec.rb`.

## Admin: Betreiber-Teile kommen nur über Schlitze

**Verbindlich** (Guard-Spec: `spec/architecture/admin_operator_boundary_guard_spec.rb`; läuft über
den Verzeichnis-Eintrag `spec/architecture/` in der CI-Guard-Liste):

Der Adminbereich wird geteilt (`doc/oss_core_split_plan.md` 5.5 bis 5.7). 17 Controller bleiben
als Instanz-Admin im Kern. Sieben werden eine private Engine, die nur ein interner Prozess lädt:
`accounts`, `account_discounts`, `price_lists`, `billing_lists`, `founder_signups`,
`founder_signup_settings`, `acquisitions`. Im öffentlichen Prozess und auf jeder fremden Instanz
gibt es ihre Routen nicht.

* **Kein Kern-Code ruft eine Route dieser sieben Controller.** Ein `admin_account_path` in einer
  Kern-View rendert dort keinen toten Link, er **wirft**, und die Seite ist weg. Der Wächter liest
  Routennamen und Pfade aus dem Router, nicht aus einer Wortliste, und kennt drei Formen: den
  benannten Helfer, das polymorphe Array (`[:admin, account]`) und den getippten Pfad
  (`'/admin/accounts'`, auch in `.js`). Ein Grep sieht nur **Namen**: `[:admin, record]` mit
  einem Konto in `record` findet erst der Request-Spec mit leerem Register.
* **Keine Ausnahmeliste.** Es gab eine, mit den beiden Templates der Gründer-Mail, und sie ist
  seit dem 22.09.2026 leer und gelöscht.
* ⚠️ **Ein Link aus dem Kern in die Konsole ist eine gespeicherte Adresse, nie eine Route.** Die
  Gründer-Mail rendert im öffentlichen Prozess und zeigt auf eine Seite der Konsole, die unter
  einem anderen Host läuft (Tunnel). Der Betreiber hinterlegt deshalb eine Vorlage mit einem
  Platzhalter (`SystemSetting.founder_signup_console_url`, `%{account_id}`), und der Kern setzt
  nur die ID ein. Leer heißt: kein Link. Eingesetzt wird per Ersetzung, **nicht** mit
  `Kernel#format`: das wirft bei einem zweiten Platzhalter oder einem losen Prozentzeichen,
  und zwar in einem Mailer-Job, für einen Wert, den jemand Wochen vorher getippt hat.
* Eine Kern-Seite, die einen Betreiber-Abschnitt zeigen soll, nennt einen **Schlitz**:
  `<%= admin_extension_slot(:user_sections, user: @user) %>`. Wer geladen ist, meldet ein Partial
  an (`Lalabase::AdminExtensions.register`). Ohne Anmeldung rendert der Schlitz nichts.
* Die Schlitz-Liste ist eine **geschlossene Konstante** (`Lalabase::AdminExtensions::SLOTS`). Ein
  vertippter Name wirft, statt auf einer Seite still nichts zu rendern, auf der „nichts" ein
  gültiger Zustand ist. Ein neuer Schlitz heißt: Konstante ergänzen.
* **Anmelden nur in `config.to_prepare`.** `lib/` wird automatisch geladen; ein Code-Reload
  ersetzt das Register, `to_prepare` läuft danach erneut.
* Der Controller einer Kern-Seite lädt nichts, was nur die Konsole zeigt. Das Partial holt es
  sich selbst (Vorbild: `Admin::Operator::UserBillingAccounts`).
* Wie der öffentliche Prozess den Admin ausliefert, hält
  `spec/requests/admin/without_operator_extensions_spec.rb` fest: die Seiten mit leerem
  Register (`Lalabase::AdminExtensions.with_empty_registry`).

## Was lalabase.com über diesen Code behauptet

Die öffentlichen Seiten liegen seit W3 in `gboyke/lalabase-website` und können den Code nicht
mehr lesen. **Drei** Wächter in `spec/architecture/` halten die Verbindung, alle über den
Verzeichnis-Eintrag automatisch in der CI-Guard-Liste:

| Wächter | Hält |
|---|---|
| `website_quoted_facts_guard_spec.rb` | **Werte**, die eine Seite wörtlich nennt: Devise `confirm_within`, `UnconfirmedSignupPurgeJob::RETENTION`, `AcquisitionSource::RETENTION`, `FounderSignup::REVENUE_BANDS`, der `path_prefix`-Default. Die Website hält die Kopie in `CoreFacts` |
| `website_feature_claims_guard_spec.rb` | **Mechanismen** hinter den Zusagen der Funktionsseiten: keine Stoppuhr, keine Beträge, sieben Schalter, nur GitHub und GitLab, Chat schreibt nicht, … |
| `ai_provider_disclosure_guard_spec.rb` | **Welche KI-Anbieter** der Code anbieten kann. Die Datenschutzerklärung drüben muss jeden davon formell nennen; hier steht die Hälfte, die nur dieses Repo beantworten kann |

* **Rot heißt hier nie nur „Code".** Entweder die Änderung ist falsch, oder ein Satz auf einer
  öffentlichen Seite ist gerade unwahr geworden und muss dort umgeschrieben werden. Die
  Fehlermeldung nennt die Datei im anderen Repo.
* Jeder Wächter zitiert den Satz, den er stützt; die Spec drüben nennt das Beispiel, das ihn
  stützt. Wer eine Seite ändert, findet die Mechanik, und umgekehrt.
* ⚠️ **Bei W6 nicht mitlöschen.** Wenn der Kern seine Kopien der Seiten entfernt, gehen die
  Seiten-Specs mit. Diese beiden bleiben: sie sind das Einzige, was eine öffentliche Zusage
  noch an den Code bindet (`doc/oss_core_split_plan.md` § 11.4).

## Third-party licenses: every dependency is permissive

**Binding** (guard spec: `spec/architecture/third_party_license_guard_spec.rb`; runs through
the directory entry `spec/architecture/` in the CI guard list):

The core is AGPL-3.0-only and has one copyright holder. While every dependency is permissive, how this
project is licensed is that holder's decision alone. One dependency under GPL or AGPL alone
ends that, and a `bundle update` can bring one without anybody noticing.

| What | Rule |
|---|---|
| Gems (the installed bundle) | every declared license is on the allowlist: MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause, ISC, 0BSD, Ruby |
| npm packages (`package-lock.json`) | the same rule, without exceptions |
| Third-party code checked into the repository | every file has a `Path:` line in `THIRD_PARTY_NOTICES.txt`, and its section states a license from the same list (plus OFL-1.1 for fonts) |

* **Every** declared license has to be allowed, not one of them. A gemspec does not say whether
  its list is a choice (`ttfunk`: Ruby terms or GPL) or a sum (`nio4r`: MIT plus BSD for the
  bundled libev). A real choice is an entry in `GEM_EXCEPTIONS`, with the license taken and
  the reason.
* `GEM_EXCEPTIONS` only shrinks (nine entries on 2026-09-30). An entry holds while the gemspec
  declares what the entry recorded: a gem that changes its declaration turns red and has to
  be read again. An entry for a gem that left the lockfile, or that would pass on its own, is
  red as well.
* **Every gem of the lockfile is read**, not only the installed ones. A bundle installed
  without a group turns red instead of checking less. The three build tools that are
  installed on no platform we run stand in `NOT_INSTALLED`, read by hand.
* Red after a `bundle update` means: read the license text of the new gem. GPL or AGPL alone:
  find another gem.
* **What counts as checked-in third-party code:** everything git tracks under `vendor/`,
  `public/fonts/` and `app/assets/stylesheets/bootstrap-icons/`, and anywhere else a file
  named `*.min.js`, `*.min.css` or like a font, and a script or stylesheet under `app/` or
  `lib/` that opens with a license header. The paid theme scripts lived in `app/javascript`
  until #814, outside every vendor directory.
* **A notice is not a permit.** A new vendored file needs its name, version, source,
  `License:` and copyright line in `THIRD_PARTY_NOTICES.txt`, and the guard reads the
  `License:` line: a GPL file with a tidy notice is still red. A directory `Path:` may not lie
  above another entry (`Path: vendor/` would cover everything to come).
* ⚠️ **Not covered**, because no lockfile and no file name shows it:
  * what a gem carries inside itself: the Rust crates compiled into `commonmarker`, native
    libraries (the macOS build of `nokogiri` ships LGPL `libiconv`, the Linux build does
    not), the JavaScript inside `lexxy`, `turbo-rails` and `stimulus-rails`, the gems
    `brakeman` vendors;
  * system libraries loaded into the process (`libvips`, LGPL, through `ruby-vips`);
  * programs the application calls as separate processes (ImageMagick; for PDF previews
    Poppler or MuPDF);
  * a release that changes its license text and keeps its gemspec: an exception is tied to
    the declaration, not to the version;
  * single icon paths copied into views (Heroicons, Lucide) and locale files generated by
    gems (`pagy`, `devise`).

---

## Development Checklisten

### Multi-Tenancy
- [ ] `acts_as_tenant` gesetzt?
- [ ] Default-Scope korrekt?
- [ ] Seeds/Factories tenant-aware?
- [ ] Queries filtern korrekt auf tenant?

### Security & Authorization
- [ ] Strong Parameters korrekt?
- [ ] Pundit Policies angewendet?
- [ ] Negative Tests: Unberechtigte bekommen 403?
- [ ] Positive Tests: Berechtigte dürfen Aktion?

### Performance
- [ ] N+1 Queries vermieden mit `includes`/`joins`?
- [ ] Indizes für neue komplexe Queries?
- [ ] Caching-Strategie bedacht?

### i18n
- [ ] Alle neuen User-facing Strings via `t()` eingebunden?
- [ ] Keys in DE **UND** EN der passenden Bereichsdatei (`config/locales/views/<bereich>.{de,en}.yml`) angelegt?
- [ ] **Geänderte** Texte in DE **UND** EN nachgezogen, auch wenn nur eine Sprache besprochen wurde?
- [ ] Keine hardcoded deutschen/englischen Strings in Views/Controllers?
- [ ] JavaScript-Strings über ERB oder `data-*` Attribute übersetzt?

### Code Quality
- [ ] Tests grün: `rspec`
- [ ] Linter clean: `rubocop`, `erblint`
- [ ] Security clean: `brakeman`
- [ ] Policies geprüft/neu angelegt

---

## Häufige Scripts & Hilfsmittel

* **Style Guide**: Entwicklung unter `/style-guide` verfügbar
* **Wording der öffentlichen Seiten ändern**: `/de?wording=1` schaltet in Development den
  In-Place-Editor ein (`?wording=0` aus). Text anklicken, Deutsch und Englisch stehen
  nebeneinander, Speichern schreibt zeilengenau in `config/locales`. Nur `static.*`, nur
  Development, keine mehrzeiligen Werte. Details: `lib/dev/wording_mode.rb`
* **Server-Betrieb (Backup, Log-Retention)**: `ops/backup/` — Skripte, systemd-Units und logrotate-Konfigurationen der Produktion, plus Restore-Anleitung in `ops/backup/README.md`. Die Dateien werden **nicht** automatisch ausgerollt: bei Änderungen Repo **und** Server nachziehen. **Unsere konkreten Koordinaten stehen hier nicht** (Storage-Box-Unterkonten, Hosts, Schlüsselpfade): die Skripte lesen sie zur Laufzeit aus `/etc/lalabase-backup/backup.conf` (Vorlage: `ops/backup/backup.conf.example`) und brechen ohne sie laut ab.

---

## Authentication für Development
- Für die Entwicklung ein lokales Demo-Konto anlegen.
- **Demo aus den Seeds** (frische Dev-Datenbank): `anna@example.com` (Admin), `ben@example.com` (Standardrolle), `clara@example.com` (Projektmanager), `david@example.com` (Betrachter), `/admin` mit `admin@example.com`, Passwort jeweils `lalabase-demo`

---

## Internationalisierung (i18n)

### Grundregel
**NIEMALS** hardcoded User-facing Strings in Views, Controllers, Models oder Mailers. **IMMER** `t()` verwenden.

### Locale-Struktur
* **Dateien**: View-Strings liegen pro Bereich in `config/locales/views/<bereich>.{de,en}.yml`
  (tickets, ansichten, zeiterfassung, meetings, inbox, wissen, dokumente, hilfe, organisation,
  personen);
  Rest (common/shared/layouts/devise/admin/components) in `views.{de,en}.yml`. Unterordner werden
  von Rails automatisch geladen. Cross-File-Duplikate mit abweichenden Werten bricht der Guard
  (`spec/locales/no_duplicate_keys_guard_spec.rb`) — jeder Key hat genau EINEN Besitzer.
* **Key-Konvention**: `views.organisations.<controller>.<action>.<key>` für Views
* **Shared Keys**: `views.organisations.<controller>.shared.<key>` für partialübergreifende Strings
* **Flash Messages**: `controllers.<controller>.<action>.<key>`
* **Models/Validations**: `activerecord.errors.models.<model>.<key>`
* **Zahlen/Beträge**: `rails-i18n` ist **nicht** eingebunden — die Formate stehen selbst
  gepflegt unter `number.*` in `de.yml` **und** `en.yml`. Ohne den DE-Zweig fällt
  `number_to_currency` & Co. lautlos auf die englischen Rails-Defaults zurück und die deutsche
  Oberfläche zeigt „€14.50" statt „14,50 €". Preisbeträge nie selbst formatieren, sondern über
  `PriceHelper#format_price_cents` (Guard: `spec/helpers/price_helper_spec.rb` pinnt beide
  Locales).
* **Aufzählungen**: Aus demselben Grund steht `support.array` selbst gepflegt in `de.yml`
  **und** `en.yml`. Ohne den DE-Zweig verbindet `to_sentence` auf deutschen Seiten mit
  „, and" („Status, Priorität, and Titel"), auch in jeder Flash-Meldung, die
  Validierungsfehler aneinanderreiht (Guard: `spec/helpers/timeline_helper_spec.rb`).
* **Dates** (guard: `spec/architecture/locale_date_format_guard_spec.rb`): a date on a page
  goes through `l()` with a named format from `date.formats` / `time.formats`, never through
  `strftime` with a format of its own. strftime writes English month names on the German
  page, and a typed `%d.%m.%Y` is German on the English one. A literal format stays only
  where it reads the same in both languages (ISO dates, the clock, month or day names alone
  through `l()`). The legacy list (51 formats in 29 files on 2026-10-18) only shrinks.

### Die Sprache einer Anfrage (seit 20.08.2026, Kern-Fassung seit D5)

Die öffentlichen Seiten liegen seit W6 in `gboyke/lalabase-website`, die Dokumentation seit
D5 in `gboyke/lalabase-documentation`. Was hier blieb, ist die Frage, in welcher Sprache der
Kern antwortet.

* **Entschieden wird sie in `ApplicationController#switch_locale`**, einem `around_action`
  vor `authenticate_user!` (Devise übersetzt seine Anmelde-Hinweise in der Sprache, die in
  diesem Moment gilt). Reihenfolge: gültiges `?locale=`, Profilsprache eines Angemeldeten,
  gemerkte Sprache dieser Sitzung (`session[:public_locale]`), `Accept-Language`, Deutsch.
  Im Demo-Modus (`LALABASE_DEMO=1`) gilt davor immer `Lalabase::Demo::LOCALE`: Die Welt ist
  in dieser Sprache geschrieben, und das geteilte Konto darf keine Wahl festhalten
  (Guard: `spec/requests/demo_mode_spec.rb`).
  Ein gültiges `?locale=` wird gemerkt. Die Registrierung übernimmt die Sprache des
  Formulars ins Profil. Guard: `spec/requests/locale_per_request_spec.rb`.
  ⚠️ **Über dieser Leiter stand eine Sprosse: die Sprache im PFAD.** `/docs/:locale/…`
  waren die letzten Routen, die eine trugen, und sie sind mit D5 weg (die öffentlichen
  Seiten nahmen ihre bei W6 mit). `request.path_parameters[:locale]` kann von keiner Route
  mehr gesetzt werden, also ist die Sprosse gelöscht statt ungeprüft behalten. Wer eine
  Route mit Sprache im Pfad baut, holt sie zurück: zuerst lesen, und wie `?locale=` merken.
* ⚠️ `I18n.locale` ist Thread-Zustand und **überlebt die Anfrage**. `switch_locale` setzt es
  per `I18n.with_locale` und stellt es danach zurück; eine Action darf es darin umsetzen
  (die Spracheinstellung). Außerhalb dieses Rahmens, etwa in einem Controller, der nicht
  von `ApplicationController` erbt, bleibt es für die nächste Anfrage auf demselben
  Puma-Thread liegen. Genau so bekamen Registrierung und Login bis zum 10.09.2026 die
  Sprache der vorigen Anfrage.
* Die Sprache kommt aus `request.query_parameters['locale']`, **nicht** aus `params`:
  `params` erzwingt das Parsen des Request-Bodys, und dieser Callback läuft auf jedem
  Controller, auch auf den Mail-Webhooks mit ihren fremden Nutzlasten.
* Welche Sprachen es gibt, beantwortet **I18n**, nicht mehr eine Tabelle der öffentlichen
  Seiten (`supported_locale`). Ein fehlender englischer Text ist dabei nicht laut:
  `config/initializers/i18n.rb` setzt `fallbacks = [:de]`.

### Rechtsangaben gehören dem Betreiber, nicht uns

Der Kern hostet keine Rechtsseiten und nennt unsere Firma nirgends. Betreibername und die
Adressen von Impressum, Datenschutz und AGB stehen in den Systemeinstellungen
(`LegalIdentity`, vier `SystemSetting`-Zeilen, eine Abfrage je Anfrage über `Current`).

* Gerendert wird **ausschließlich** über `legal_operator_credit`, `legal_page_link` und
  `legal_footer_links`. Ohne Betreibername steht dort der übersetzte Text
  `powered by Lalabase`, ohne Adresse erscheint kein Link.
* **Wer keine eigene Website hat**, schreibt den Text im Adminbereich; die Instanz liefert
  ihn unter `/legal/<seite>` aus (`LegalPagesController`, Markdown, sanitisiert). Eine
  eingetragene **Adresse gewinnt** über den Text.
* ⚠️ Kein Kern-Code liest die öffentliche Website: keine `StaticHelper`-Konstante, keine
  öffentliche Rechts-Route, kein `static.*`-Text. Guard:
  `spec/architecture/app_legal_identity_guard_spec.rb`, **ohne Ausnahmeliste**.
* Was lalabase.com über diesen Code behauptet, halten zwei weitere Wächter fest — siehe
  den eigenen Abschnitt dazu.

### Der Kern wirbt nicht für unsere Cloud

**Verbindlich** (Guard-Spec: `spec/architecture/app_operator_claims_guard_spec.rb`; läuft über
den Verzeichnis-Eintrag `spec/architecture/` in der CI-Guard-Liste):

Die Seiten ohne Anmeldung liest ein Besucher, der nicht weiß, auf wessen Instanz er ist. Was
dort steht, muss der **Betreiber** sagen können, nicht nur wir. Bis zum 20.09.2026 stand auf
jeder Anmeldeseite „Hosting in Deutschland | AVV inklusive", in der Fensterleiste des Panels
`lalabase.app/inbox`, und die Registrierung bot unseren Gründerrabatt an.

Der Wächter prüft die I18n-Bereiche der sieben Seiten ohne Anmeldung gegen fünf Muster:

| Muster | Beispiel |
|---|---|
| unsere Domain | `lalabase.app`, `lalabase.com` |
| Ort des Hostings | „Deutschland", „Germany", „hosted" |
| Vertrag mit uns | „AVV", „DPA", „Auftragsverarbeitung" |
| Preis oder Rabatt | „50 %", „14,50 €" |
| Zahlungsbedingungen | „Rechnung", „kündbar", „Abo" |

Dazu die Auszeichnung selbst: kein `lalabase.*` in `app/views/devise/**` und im Auth-Layout.
Der Instanz-Name kommt aus `request.host`.

* ⚠️ **`app_legal_identity_guard_spec.rb` deckt das NICHT ab.** Es sucht `StaticHelper::`,
  öffentliche Rechts-Routen und `t('static.`. Diese Texte lagen unter `views.devise.*`, weil
  die Keys eigens aus der Preisseite herauskopiert wurden, damit sie nicht mehr `static.*`
  heißen. Die Zusage ist dabei mitgewandert. Zwei Wächter, zwei Fragen: der eine hält den Kern
  von der **Website** fern, dieser von unserem **Geschäft**.
* **Keine Ausnahmeliste.** Es gab eine, mit einem Eintrag, und der Gründerrabatt verließ das
  Registrierungsformular am 20.09.2026. Eine leere Liste lädt den ersten neuen Eintrag ein.
* ⚠️ **Die Auszeichnung wird mit weggeschnittenen ERB-Tags gelesen**
  (`AppOperatorClaimsGuard.literal_text`). Sonst liest sich `<%= index + 1 %>` als „1 %" und
  schlägt beim Preismuster an, und jeder Kommentar, der eine entfernte Zusage erklärt, schlägt
  bei ihrem eigenen Muster an.
* Die Vorzeile einer Auth-Seite nennt einen **Zustand** („Konto gesperrt", „Bestätigung fehlt"),
  nie eine Zusage.

### Bei jedem neuen Feature / jeder Änderung
0. **Bestehende Texte ändern** → IMMER beide Sprachen. Eine Wording-Änderung an einem
   deutschen Text ohne die englische Fassung ist unfertig, und sie fällt niemandem auf:
   der Key existiert, die Seite rendert, nur der Satz ist veraltet. Gilt auch dann, wenn
   nur die deutsche Seite besprochen wurde (Anweisung des Users, 21.08.2026).
1. **Neue Strings** → sofort als `t()` Call schreiben, Key in DE + EN Locale anlegen
2. **Bestehende Views ändern** → prüfen ob noch hardcoded Strings vorhanden sind, ggf. gleich mit extrahieren
3. **JavaScript-Strings** → über ERB-Interpolation (`<%= t("...") %>`) in `.js.erb` oder via `data-*` Attribute
4. **Confirmation-Dialoge** → Keys unter `views.confirm.<key>` in beiden Locales

### Beispiel
```erb
<%# ✅ Richtig %>
<h1><%= t('views.organisations.tickets.index.title') %></h1>
<%= link_to t('views.organisations.tickets.shared.back'), tickets_path %>

<%# ❌ Falsch — hardcoded String %>
<h1>Aufgaben</h1>
<%= link_to "Zurück", tickets_path %>
```

---

## Konstanten & Magic Numbers

* Keine "Magic Numbers/Strings" im Code – in **Konstanten** (`ALL_CAPS`) oder I18n auslagern
* Konstanten in thematischen Namespaces bündeln: `Notifications::Constants::EVENT_TYPE_MAPPING`
* Immutable machen (`.freeze` bei Arrays/Hashes)
* Thread-safe Zugriff in Background Jobs: `Notifications::Constants::EVENT_TYPE_MAPPING`

---

## Code-Review Checklist

- [ ] Tests grün & vollständig (System-, Request-, Unit-Tests)
- [ ] Regressions-Test bei Bugfix hinzugefügt  
- [ ] Policies geprüft/neu angelegt & Tests vorhanden
- [ ] Linter & Security-Scanner clean
- [ ] Multi-Tenancy korrekt implementiert
- [ ] Background Jobs verwenden thread-safe Konstanten-Zugriff
- [ ] ViewComponents folgen Neo-Brutalist Design System
- [ ] **i18n**: Alle Strings via `t()`, Keys in DE + EN vorhanden

