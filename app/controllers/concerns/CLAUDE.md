# Karte: app/controllers/concerns (Stand: 2026-11-04)

> Für die Ticket-**Domäne** (Attributsystem, Kanban, Actors, Fallen) gilt zusätzlich
> `docs/architektur/tickets_lesepfad.md`. Diese Karte hier beschreibt nur den **Stack**.

Hier liegt der **ObjectListController-Stack**, der Listen-Features treibt (v. a. Tickets).
Lese-Reihenfolge, um eine Listen-Seite wirklich zu verstehen:

1. `object_list_controller.rb` (~470 LOC) — definiert eigene Default-`index`/`show`, zieht via
   `included do` transitiv `Sortable`, `Pageable`, `Searchable`, `AdHocFilterable` herein und
   registriert 5 before_actions (`set_project`, `set_objects`, `set_object`,
   `authorize_project_access`, `set_smart_folders`), die am einbindenden Controller NICHT
   sichtbar sind. Seit 08.09.2026 ist `filtered_objects` (Ordner, dann Ad-hoc, Suche,
   Sortierung) der EINE Besitzer der gefilterten Liste: `index` paginiert ihn, die
   Sammeländerung (`doc/ticket_bulk_edit_plan.md`, S0) löst „alle Treffer" daraus. Kanban,
   `show` und die Seitenberechnung spielen die Pipeline noch von Hand nach (Befund im
   Lesepfad, eigener Strang).
2. **Der einbindende Controller darf `index`/`show` überschreiben — TicketsController tut das.**
   Immer BEIDE Versionen lesen (Concern-Default + Controller-Override), sonst falsches Bild.
3. Frame-IDs und Partial-Pfade werden per String-Interpolation gebaut (`results_partial_path`,
   `object_show_partial`, `results_frame_id` — inkl. hartkodiertem Ticket-Sonderfall
   `tickets_list_frame`). Frames/Partials NICHT per Literal-grep suchen — diese Methoden auswerten.
4. `sortable.rb` (~390 LOC) — Whitelist-Sort-DSL (`setup_sortable`, `add_sortable_columns`),
   ORDER BY via `Arel.sql`, hartkodierte DISTINCT-JOIN-Sonderfälle pro Tabelle.
5. `ad_hoc_filterable.rb` — liest `filter[]`, `filter_op[]`, `filter_drop[]`. Seit der
   Filterleisten-Umbau (S3a, `doc/filterleiste_s1_s4_plan.md`) gilt: trägt die Adresse eine
   auflösbare gespeicherte Ansicht UND Änderungen daran (`edited_saved_view?`), wendet die
   Liste den EFFEKTIVEN Satz an (`list_filter_params`) statt Ordner-Query ∩ Adresse. Dieselbe
   Regel liegt clientseitig in `lib/filter_bar/change_set.js`; wer eine Seite ändert, ändert
   beide. Ordner-Query-Aufrufer prüfen `edited_saved_view?` (`apply_smart_folder_filter`,
   `TicketsController#find_objects`, `KnowledgeController#index` über `apply_folder_query`).
6. `ticket_list_columns.rb` (07.09.2026, `doc/spaltenwahl_plan.md` S1): EINE Methode
   `ticket_list_columns(project)` für jeden Stream, der eine Ticketzeile oder die Liste außerhalb
   von `index` neu rendert (Tickets + Posts). Ruft `Tickets::ResolveColumns` (Adresse `cols[]` vor
   Ordner vor Grundansicht). Vorher rechneten die beiden Controller das sechsmal von Hand.
   Seit 08.09.2026 auch `ticket_list_selectable?` (helper_method, Memo je Request): ob die
   Zeile ein Auswahlkästchen trägt (`doc/ticket_bulk_edit_plan.md`, Scheibe 1).
   Seit 29.09.2026 auch der Zeilen-Stream selbst: `ticket_list_row_streams(ticket, selected_ticket:)`
   (Desktop- und Mobilzeile, je mit eigenem Partial). Wer eine Ticketzeile streamt, nimmt diese
   Methode. Seit 30.09.2026 auch `Tickets::RelationsController` (Spalte „Wartet“, Karte und
   Handy-Zeile des OFFENEN Tickets nach Anlegen/Entfernen einer Beziehung). Die Zeile eines
   ANDEREN Tickets streamt dort niemand, auch nicht die eines wartenden Tickets, wenn sein
   Blocker erledigt wird (`doc/ticket_relations_plan.md` §4, `ticket_waiting_visibility_spec.rb`).
   Sie hängt `ticket_list_parent_streams` an (allein bei Quick-Add und Löschen): für jede
   Spalte aus `ViewConfiguration::CHILDREN_COLUMN_KEYS` (heute `subtask_count`) NUR Zelle und
   Eintrag unter dem Titel des Haupttickets (bei Umzug auch des alten), nie dessen ganze Zeile.
   Eine ganze Zeile braucht, was nur `index` kennt (Spalten des aktiven Ordners, den kein Formular
   mitschickt; ungelesene Benachrichtigungen) und verlor beides. Deshalb heißt „kein Wert“ am
   Eintrag unter dem Titel `:empty` (CSS), `hidden` nur „nicht angepinnt“.
7. Rest: `pageable.rb`, `searchable.rb`, `performance_optimized.rb`,
   `viewport_switchable.rb` (Mobile/Desktop-Umschaltung), `project_controller.rb`
   (Projekt-Scope-Basis, nutzt z. B. der MeetingsController), `ai_feature_gate.rb`
   (`ensure_ai_enabled`, org-Ebene; aus `project_controller.rb` extrahiert in S3a T2,
   damit die projektlosen Assistant-Controller dasselbe Gate nutzen),
   `meeting_in_project.rb` (24.10.2026: `with_meeting_in_project { ... }`, die Sperre eines
   Meeting-Schreibwegs im Controller, Abschnitt zu `Meeting#lock_in_project!` in der
   Wurzel-`CLAUDE.md`; der Wächter fragt jede schreibende Aktion der Meeting-Controller).

Daneben liegen **Patches in Rails-eigene Controller**, die nicht per `include` im App-Controller,
sondern über einen `to_prepare`-Initializer eingehängt werden: `direct_uploads_guard.rb` →
`ActiveStorage::DirectUploadsController` (Initializer `config/initializers/direct_uploads_guard.rb`,
Muster: `active_storage_tenant_patch.rb`). Diese Controller erben von `ActionController::Base`,
nicht von `ApplicationController`; kein `before_action` der App gilt dort, jede Regel muss
explizit hinein.

Ist-Zustand (bewusst dokumentiert): Die fünf Master-Detail-Features nutzen fünf verschiedene
Fundamente — Tickets = dieser Stack, Knowledge = `Pageable`+`AdHocFilterable`+
`ViewportSwitchable`+`ProjectController` mit `KnowledgeSearchQuery` (UNION über
`Knowledge::TypeRegistry`, kein `ObjectListController`), TimeSessions = `Sortable`+`Pageable`
direkt, Notifications = bespoke + `MasterListPresenter`, Meetings =
`ProjectController`+`ViewportSwitchable`+`meeting_list.rb`.
`meeting_list.rb` (17.10.2026) ist der EINE Besitzer der Meeting-Liste: Projektseite
(`meeting_list_project` = `@project`) und „Alle Meetings“ (`nil`). Seit PR 3 öffnet auch die
Übersicht das Meeting in der Bahn; Detail und Schreibwege bleiben projektverschachtelt
(`MeetingsController`), und die Bahn trägt `list_context=organisation`
(`Meetings::ListState`, ein erlaubter Wert, nur verglichen). Getragen wird er zweimal: der
Server schreibt ihn in die Links und Formulare, die er für eine Anfrage MIT Kontext rendert
(`meeting_lane_state`), und `layout-toggle` hängt ihn bei Klick und Absenden an jede Anfrage
der Bahn (`laneContext`, aus `meeting_list_page_data`). Das Zweite fängt, was ohne Kontext
gerendert wurde: Broadcasts, Abschnitts-Aktualisierungen, Controller-Ersetzungen. `meeting_organisation_list?`
ist die EINE Frage „welche Liste?“ für Stream, Weiterleitung und Rückweg (das frühere
`context=overview_modal` ist darin aufgegangen). Seit PR 4 öffnet auch das „+“ der Übersicht in
der Bahn: `?new=meeting` auf ihrer eigenen Adresse liefert eine Projektauswahl
(`meetings_overview/_new_meeting_lane`), darunter lädt ein eigener Frame das Formular des
gewählten Projekts aus `MeetingsController#new`; eine Meeting-Route ohne Projekt gibt es nicht. Der Kontext wählt nur die
Liste, die Rechte bleiben die des Projekts (`set_meeting`, Bereichs-Tor). Eine
Meeting-Ansicht gehört der Liste ihres Projekts, ohne Projekt der Übersicht. Die Filterleiste, das Speichern von Ansichten und die Spaltenwahl
nehmen `project: nil` als „organisationsweit“; Tickets und Wissen geben weiter ein Projekt mit.
Die Grundansicht der Spalten wählt `ViewConfiguration.for_list` (ohne Projekt nur `meetings`,
Route `meetings_view_configuration`, derselbe Controller wie die Projekt-Route).
Die Personenliste (`Organisations::PeopleController`, 26.10.2026) ist die sechste Bahn:
`ViewportSwitchable` + `People::Directory`, ohne Filterleiste und Spaltenwahl, dieselben
Stimulus-Controller (`layout-toggle`, `index-page`, `list-row`, `lane-link`); Speichern und
Löschen verlassen die Bahn (`_top`) und landen mit `?person_id=` wieder auf der Liste. Zwei
Auswahlparameter schließen sich aus: `person_id` (eine Zeile) und `member_id` (ein Mitglied ohne
eigene Zeile, `PeopleController#member`); `user_id` gehört zur Formular-Gruppe.
Das Glossar (`Organisations::GlossaryController`, K4a, 04.11.2026) ist die siebte Bahn, gebaut
wie die Personenliste (dieselben Stimulus-Controller und `people-*`-Klassen), mit `term_id` als
einziger Auswahl und den Filtern `project_id`, `category`, `status` (`LIST_PARAMS`, unbekannte
Werte fallen weg). Meeting-Titel nur über `policy_scope(Meeting)`, nie vorgeladen. Ein Sprecher
hat einen Namen nur, wenn der Leser ihn auf der Mitglieder- oder Personenseite sehen darf
(`MembershipPolicy::Scope`, `PersonPolicy::Scope`), sonst steht ein neutrales Wort; verlinkt nur
mit `view_people` und nur auf aktive Mitglieder (die Personenseite listet nur sie).
Der Entscheid für EINE kanonische Listen-Architektur steht aus; bis dahin gilt für neue
Listen-Features: am ähnlichsten Bestands-Feature orientieren und die Wahl im PR begründen.
Seit 10.09.2026 teilen Tickets und Knowledge immerhin die OBERFLÄCHE der Liste-mit-Bahn
(`doc/wissen_als_bahn_plan.md`): `NeoTwoColumnGridComponent` mit `lane: true`, den einen
Öffner `list_row` (Adressregeln in `lib/list_row/address.js`), die Markierung `.selected-row`
und die Kopfzeile der Bahn. Das Listen-Fundament dahinter bleibt je Bereich verschieden.

## Mobile Ticketdarstellung (PR #807)

`ViewportSwitchable` akzeptiert den expliziten Parameter `viewport`. Den Header
`X-Viewport` wertet ausschließlich `TicketsController#set_viewport_mode` aus.
Andere Listen dürfen dadurch nicht auf die breitere Ticket-Grenze umgeschaltet werden.
Die mobile Liste verwendet `tickets_list_frame`, das Detail `ticket_display_frame`
wie am Desktop. `ticket_display_frame_mobile` existiert nicht mehr.
Mobile vollständige Listenaufrufe behalten ihre Seitenzahl; der bisherige
Desktop-Seite-1-Redirect bleibt bestehen. Ticket- und Post-Streams müssen mobile
Listenzeilen ebenso berücksichtigen wie Tabellenzeilen.
