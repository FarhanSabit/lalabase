# Karte: app/services (Stand: 2026-11-01)

**Entry-Point-Konvention für NEUE Services: `Klass.call(**kwargs)`** (Klassenmethode; eine
Instanz-`#call`-Implementierung dahinter ist erlaubt). Pflicht: mindestens 1 Kommentarzeile
über der Klasse (was tut der Service). Read-/Query-Objekte mit Domänen-Verben (`can?`,
`fetch_results`) sind als Ausnahme erlaubt, wenn der Header den Entry-Point deklariert —
Marker exakt: `# Entry point: <methode>`. `#initialize` nimmt nur Keyword-Args.
Guard: `spec/services/service_convention_guard_spec.rb` (Bestand steht auf Legacy-Allowlist,
shrink-only; wer eine Allowlist-Datei substanziell ändert, migriert sie und streicht sie dort.
Ausgenommene Subtrees mit eigenem Vertrag: `actors/`, `lalabase/tools/`).

**Writes**: nicht-trivialer Write → Command-Objekt unter `actors/` (Vertrag: Root-`CLAUDE.md`
„Actor-Pattern", Guard: `spec/services/actors/actor_contract_guard_spec.rb`). Triviales
Einzel-`update!` ohne Side-Effects bleibt im Controller.

* An actor writes and checks no rights. Exceptions lock first and authorize again under the lock (`AcceptTicketSuggestion`, `StartTicketSuggestionRun`).
* Finding belongs to one object per domain (`Tickets::ReadableForToken`, `Tickets::RelationAccess`, `People::Lookup`); they share the question, not code. Where `nil` would drop a limit, the keyword is required.
* The policy decides yes or no.
* The caller words the answer (status, text, 404 form).
* A guard holds where a mistake discloses data (`ticket_token_lookup_guard_spec.rb`, `ticket_relation_actor_callers_guard_spec.rb`).

Verzeichnis-Übersicht (Auswahl):
* `knowledge/` — `lookup.rb` (`Knowledge::Lookup`, REST R2, 29.10.2026) ist das EINE Lesen
  des Wissens eines Projekts (Notizen, Dokumente) nach Titel, für das MCP-Werkzeug
  `search_knowledge` und `GET /api/v1/projects/:project_id/knowledge`: Rechte je Typ über
  `Pundit.policy_scope!` (kein Titel und keine Zählung eines Typs ohne Leserecht), Merge-Seite
  über zwei Tabellen (`updated_at DESC, id ASC`, derselbe Tiebreak in SQL und Ruby), Gesamtzahl,
  Serialisierung mit dem Link aus `Documentation::KnowledgeLink`. Ohne Suchwort listet es
  alles Lesbare (nur REST nutzt das, MCP verlangt `q`). `.options(args, strict:)`: MCP liest
  Unlesbares als Standard und klemmt `per_page`, REST (`strict: true`) lehnt ab
  (`InvalidOption`, 422). Eine neue Such- oder Seitenregel gehört hierher, nicht in eine Hülle.
* `time_sessions/` — Lese-Objekte der Zeitdomäne. `viewing_scope.rb` ist der EINE Besitzer der
  Regel „eigene oder alle Zeiten" (`:all`/`:own`/`:none` plus `#apply(relation)`), die
  `ProjectPolicy#area_access?(:time_sessions)` nicht ausdrücken kann (`can_view_own ||
  can_view_all`). Fail-closed: nur eine PERSISTIERTE `TimeSessionPermission` zählt, die
  unsaved Default-Zeile aus `User#time_session_permission_for` nicht, und seit 27.09.2026 nur
  mit lebender `ProjectPermission` dahinter (`TimeSessionPermission.backed_by_project_access`,
  Wächter `spec/architecture/time_session_permission_guard_spec.rb`). Zwei Einstiege, EINE
  Regel: `.call(user:, project:)` für ein Projekt, `.for_organisation(user:, organisation:)`
  für alle Projekte einer Organisation aus EINEM Lesen der Rechtezeilen (`#apply`,
  `#tier_for`, seit 01.09.2026 auch `#projects` und `#sees_anything?`: welche Projekte und ob
  überhaupt; `time_session_navigation_service.rb` ist nur noch die dünne Tür davor, plus
  `#bookable_projects` für die Schreibfrage `can_create_own`). Nutzer:
  `TimeSessionPolicy::Scope`, die org-weite Tür jeder Liste und jeder
  Dashboard-Kachel (seit 30.08.2026; davor eine zweite, handgeschriebene Kopie der Regel, die
  abgeschaltete Mitgliedschaften nicht kannte), das Werkzeug
  `lalabase/tools/summarize_time_sessions.rb` (Assistent und seit MCP 0.12.0 auch
  `/api/mcp` im Projektmodus, also eine Tür für jeden Token), `subject_time_summary_service.rb`
  (Stunden-Chip) und `time_sessions/open_hours.rb` (`GET /api/v1/time_sessions/open`, seit
  08.10.2026; davor sah die API auch Buchungen, die die Zeitliste im Web verbirgt). Wer eine
  weitere Auswertung über gebuchte Zeit baut, geht hier durch, statt die Rangfolge ein
  sechstes Mal von Hand zu schreiben. `bucket_totals.rb` ist der
  zweite Besitzer daneben: die Aggregation in die drei Abrechnungs-Töpfe, in EINER Query,
  geteilt von `SummarizeTimeSessions` und dem Report-Panel des Assistenten — die
  Einordnung selbst bleibt `TimeSession.billing_bucket_for`. `booking.rb` (seit 29.10.2026,
  REST R6) ist die EINE Regel einer Zeitbuchung per Token: das MCP-Werkzeug
  `create_time_session` und `POST /api/v1/tickets/:ticket_id/time_sessions` buchen beide
  hier durch (Dauer Pflicht und nur eine, `occurred_on` als Kalendertag in der Profilzone,
  Schreiben über `Actors::SaveTimeSession`); Rechte prüfen die Hüllen zwischen `parse`,
  `build` und `save`, die Texte der Ablehnungen auch. `date_bound.rb` ist der
  dritte: die EINE Antwort auf „ist das eine Datumsgrenze, die ich der Datenbank geben
  darf". `empty_reason.rb` ist der vierte: WARUM die Zeitenliste leer ist. Drop-one, ein
  `EXISTS` je aktivem Filter und nur, wenn die Liste schon leer ist; „aktiv" fragt es am
  gebauten SQL ab (`to_sql`-Vergleich) statt an den Parametern, damit die Regel nicht neben
  `TimeSessionFilterService` ein zweites Mal geschrieben steht. Alle Filter sind UND-Bedingungen,
  also kann Weglassen nur mehr Zeilen liefern: was es nennt, darf die Seite versprechen.
  ⚠️ `Date.strptime` allein reicht NICHT — `%Y` nimmt beliebig viele Ziffern und
  ein Vorzeichen, `999999999-01-01` ist ein gültiges Ruby-Date und ein
  `PG::DatetimeFieldOverflow` in der nächsten Query. Die Vierstelligkeitsprüfung muss VOR
  dem Parsen laufen; genau diese Hälfte ging beim Abschreiben der Regel ins Report-Panel
  verloren. Drei weitere gehören zu den Zeit-Spalten der Ticket-Tabelle:
  `subject_billing_status.rb` faltet die Töpfe EINES Bezugs zu einem Wort
  (`:billed`/`:in_billing`/`:open`/`:mixed`/`:no_sessions`) — geteilt vom Stunden-Chip und
  von der Abrechnungsstand-Spalte, damit beide dasselbe Ticket nicht verschieden nennen;
  `subject_totals.rb` ist das Stapel-Gegenstück zu `subject_time_summary_service.rb`
  (Minuten + Status je Ticket für eine ganze Seite in EINER Query);
  `subject_totals_cache.rb` hält die Antworten EINES Lesers (`new(user:)`) in EINEM Request
  (Seite angemeldet über `Tickets::LazyPagePreload`, geladen beim ersten Lesen je Projekt der
  Tickets, wie die Subs- und Wartet-Caches). ⚠️ Dessen Fallback ist der Punkt: eine Zeile, die
  der Vorablauf nie gesehen hat (Einzelzeilen-Rerender per Turbo-Stream nach einem Save), wird
  EINZELN nachgeschlagen statt genullt — eine leere Zelle ist eine falsche Zahl, keine
  fehlende, und nichts daran sieht kaputt aus.
  ⚠️ Vokabular (seit S1, 01.09.2026): EIN Satz Namen. Die Bezugs-Antwort ist ein Topf aus
  `TimeSession::BILLING_STATUS_FILTERS` als Symbol, dazu `:mixed` und `:no_sessions`. Die
  frühere Übersetzung `without_billing` -> `:open` (`BUCKET_TO_STATUS`) ist weg. Das Wort
  liefert AUSSCHLIESSLICH `time_billing_state_label`, den Anteil
  `SubjectBillingStatus.percent_billed`. Die Wörter selbst wohnen einmal unter
  `views.time_sessions.billing_status.*`; Wächter:
  `spec/locales/time_list_billing_words_spec.rb` und
  `spec/architecture/billing_state_vocabulary_guard_spec.rb`. Keinen zweiten Namen
  dazustellen — vor S1 waren es neun Stellen und fünf verschiedene deutsche Wörter.
* `activities/` — der Riegel des Aktivitätsverlaufs (S3b, §13-11). ⚠️ `area_registry.rb`
  kartiert über **`key`**, nicht über `trackable_type`: es gibt nur vier Trackable-Typen,
  und `Project` traegt Notiz-, Dokument-, Meeting-, Mitglieder- und Rechte-Ereignisse
  gleichzeitig. `visible_to.rb` haengt jede Zeile an ihr Projekt (Ticket-Zeilen ueber
  Subquery, Project-Zeilen ueber `trackable_id`) und filtert ueber die Area-Reichweite;
  `project_reach.rb` ist der Ein-Projekt-Adapter, damit die Aktivitaeten-SEITE und das
  Chat-Werkzeug denselben Riegel benutzen. Fail-closed auf jeder Achse: unbekannter
  Schluessel, leere Reichweite und keine Klausel liefern nichts, nie alles.
  ⚠️ `visible_to.rb` hat einen ZWEITEN Ausgang: `reached_project_ids` ist der Besitzer der
  L7-Deckungszahl. Wer die Deckung eines Verlaufs aus EINER Area zieht
  (`coverage(area: :tickets)`), beschreibt die falsche Reichweite; gemessen: Antwort aus
  drei Projekten unter „Durchsucht: 0 von 3 Projekten".
* `assistant/` — die Bewohner der Artefakt-Lane (S3c T3, Plan §8.1). `panel_registry.rb`
  bildet Panel-Art auf Panel-Klasse ab, **fail-closed** wie `ContentAreaRegistry`: die Art
  kommt aus einer tippbaren Adresse, „unbekannt" ist also ein Produktionsfall. Der
  Controller rendert das Template nach der Schreibweise der REGISTRY (`canonical_kind`),
  nie nach dem Parameter. `panels/time_report.rb` prüft seine Rechte selbst — die
  Area-Tabelle kann bei Zeiten „eigene" nicht von „alle" trennen (§13-9), deshalb trägt
  jede `report`-Art ihre eigene Prüfung.
  Meeting-Analysen im Assistenten: `analysis_context.rb` hält je Antwort die expliziten
  Meeting-Bezüge, Arbeitsanweisungen und Quellenherkunft einschließlich Gesprächsverlauf
  fest; `analysis_sources.rb` prüft die Quellenrechte beim Speichern und ob eine Analyse
  am Zielmeeting veröffentlicht werden darf. Unvollständige Quellenherkunft sperrt das
  Speichern. `analysis_eligibility.rb` teilt die Speicherregeln zwischen Oberfläche und Actor
  und lädt Speicherzustände im Gespräch gesammelt. `analysis_revision.rb` prüft den
  ausdrücklich gewählten Antwortbezug; Wortanfänge lösen keine Überarbeitung aus.
  `coverage_notice.rb` liefert den Reichweitenhinweis für Chat und private Analyse.
  Ticket-Vorschläge: `Actors::StartTicketSuggestionRun` bindet Auftrag, Meeting, Projekt
  und Prüfsummen getrennt begrenzter Notizen/Mitschrift an einen `MeetingTicketSuggestionRun`.
  Quellen werden vor KI-Aufruf und Veröffentlichung erneut geprüft; Chat-Löschen entfernt
  den persönlichen Lauf, erhält aber gemeinsame Vorschläge. `retried_at` erlaubt nur einen
  Neuversuch je altem Auftrag. Advisory-Sperren verhindern parallele Job-Ausführung.
  `MeetingTicketSuggestionRun#mark_failed!` hält Fehlerzustand und Flag-Freigabe
  zusammen; nur Meeting-Seiten-Läufe schreiben ihren Fehler auch an das Meeting.
  Kein persönlicher Verlauf gelangt in diese meetingweit sichtbaren Vorschläge.
  Start und Ersetzung sperren zuerst das Meeting, wie `AcceptTicketSuggestion`;
  Verwerfen ist ein bedingtes UPDATE auf `open`. Ergebnis-Snapshots behalten die IDs
  gelöschter offener Vorschläge als überholte Historie. Assistenten-Ergebnisse werden
  nur über berechtigungsgeprüftes HTTP aktualisiert, nie als Inhalts-Broadcast.
  Neue Läufe nutzen `Meetings::TicketSuggestionRunJob`; die Argumente alter
  `TicketSuggestionJob`- und `ChatResponseJob`-Jobs bleiben kompatibel.
* `actors/` — Command-Objekte für Writes (Tier-1/Tier-2-Vertrag, guard-erzwungen). Vollständig
  auf der Seam: Dokumente (`save_document`, `save_document_version`, `destroy_document`,
  `destroy_document_version`); Zeiterfassung/Abrechnung (Phase 4 T1–T3, Pläne
  `doc/actors_phase4_plan.md` §9 + `doc/actors_t3_save_time_session_plan.md`): T1-Assigner-Paar
  mit geteiltem Write-PORO `time_session_group_assigner.rb`, T2 Billing/Descriptions,
  T3 `save_time_session` (create+update inkl. Gruppen-Wechsel in EINER Txn); Chat (C1, Plan
  `doc/actors_c1_chat_plan.md`): `save_chat`, `destroy_chat`, `create_chatpost`,
  `regenerate_chatpost`, `set_chat_style`; `save_assistant_analysis` kopiert eine fertige
  eigene Antwort unter Zeilensperre als private Meeting-Analyse ohne Suchfreigabe, mit
  Quellen-Snapshot und eindeutigem Antwortschlüssel gegen doppeltes Speichern; keine neue
  KI-Generierung. Preisstände (`publish_price_list` hier, `withdraw_price_list` seit S3.2 in der
  Engine `gboyke/lalabase-operator`; `publish_price_list` bleibt, weil der Kern die Regel besitzt und
  die Konsole ihn ruft) —
  **beide OHNE `current_user`**, weil der Admin-Operator ein `Beuser` ist und `Current.user`
  einen `User` erwartet; Audit läuft über einen E-Mail-Snapshot auf der Zeile. In beiden ist
  die REIHENFOLGE tragend (Vorgänger clippen VOR dem Anlegen, Ankündigung löschen VOR dem
  Wiederöffnen) — andersherum weist die Überlappungsregel den eigenen Schreibvorgang ab.
  KI-Zugang: `save_ai_configuration` **und** `remove_ai_configuration` (KI-Bereich S7,
  vollständig). Beide hängen an `Organisations::AiConfigurationsController` — dem eigenen
  Einrichtungs-Screen, nicht mehr an `AiSettingsController#update`, dessen Schreibroute
  ersatzlos weg ist. ⚠️ Drei nicht offensichtliche Regeln: Spalten unterscheiden
  **abwesend = behalten / leer = löschen**, nur `ai_access_token`
  behält auch bei leer (E2-A, der Schlüssel wird nie zurückgespielt); ein Wechsel von
  **Anbieter oder Endpunkt** verlangt seine erneute Eingabe, weil ein behaltener Schlüssel plus
  ein beschreibbares `ai_api_base` sonst ein Lesezugriff auf ihn ist (Begründung:
  `doc/ki_bereich_navigation_plan.md` §E2a); und der Endpunkt-Riegel gehört `Lalabase::PublicAddress`: er löst den Namen
  auf und beurteilt die **Zieladressen**, nie die Schreibweise. Er ging dreimal an genau dieser
  Verwechslung kaputt (IPv4-gemappte IPv6-Literale, numerische Notationen wie `127.1`, dann
  Namen: `localhost.`, `redis.`, öffentliche Namen mit Eintrag nach innen). Beim Speichern ist
  er nur Komfort; der Schutz ist `Lalabase::Llm::PublicEndpointAdapter`, der bei jeder
  Verbindung neu prüft und den Socket an die geprüfte Adresse bindet. Vertraut wird nur dem
  Endpunkt, den eine `AiCredential` nennt (`Factory#operator_endpoint?`).
  Registrierung (Website-Schnitt W2, 15.09.2026): `create_signup` ist die EINE
  Selbst-Registrierung für das Formular und später den Provisioning-Endpunkt. Tier 2: Sprache
  und tenant-freier Rahmen umschließen den ganzen Lauf (die Bestätigungsmail rendert beim
  Commit), Nutzer und eigene Organisation committen **zusammen oder gar nicht** (Entscheidung
  D2). Die Schritte danach, die eine Registrierung nie rückgängig machen dürfen (Tutorial,
  Herkunft, Neugründer-Antrag, Audit), liegen in `signups/follow_ups.rb`, weil ihr
  `rescue StandardError` im Actor verboten ist. Einladungen laufen NICHT hier durch.
  `signups/handoff.rb` besitzt den Einmal-Anmeldelink, den der Provisioning-Endpunkt
  ausgibt: Zweck, Frist (2 Min) und Einmaligkeit an EINER Stelle, weil ein Erzeuger und
  ein Verbraucher, die sich darüber uneinig sind, einzeln beide richtig aussehen. Riegel
  ist `User#claim_first_visit!` (`UPDATE ... WHERE last_seen_at IS NULL`); die App führt
  kein Devise `trackable`. ⚠️ Host aus `ActionMailer::Base.default_url_options`, nicht
  aus dem Config-Objekt: das ist unter RSpec leer.
* `people/` — `directory.rb`, das Lese-Objekt der Personenliste (seit 26.10.2026): Mitglieder
  über `MembershipPolicy::Scope` (dieselbe Reichweite wie die Mitgliederseite), dazu die
  Zeilen ohne aktives Mitglied als Kontakte; Suche in Ruby über `PersonName.normalize`.
  Rechte nur über `PersonPolicy`, keine eigene Regel daneben. Die E-Mail eines Mitglieds
  (Zeile unter dem Namen, Suche, Karte in `lookup.rb`) ist immer `User#shown_email`: eine
  verborgene Login-Adresse wird weder gezeigt noch gesucht (29.10.2026).
  `contacts.rb` (S2a, 26.10.2026): Meetings einer Person (`person_id` ODER `user_id` des
  Mitglieds) und „Letzter Kontakt“ einer ganzen Liste in fester Abfragezahl. Lesbar nur über
  `MeetingPolicy::Scope`, `TicketPolicy::Scope`, `Post.readable_by` und `Activity.feed`; bei
  aktiven Mitgliedern zählt eigene Ticket-Arbeit (`TICKET_ACTIONS`: angelegt, geändert,
  kommentiert), bei Kontakten nur Meetings. `Directory#entries` hängt den Kontakt an und
  sortiert nach `name` oder `last`.
  S2b (27.10.2026): `Directory#person_entry`, `#entry_for_participant`, `#candidates`
  (Suche ohne Kontakt) und `#suggestions_for` (gleicher Name vor gleichem Nachnamen, E6)
  speisen den Dialog „Mit Person verknüpfen“. Seine Regeln liegen außerhalb des Helfers,
  einzeln testbar: `meetings/participant_link_options.rb` (Zeilen des Dialogs),
  `meetings/participant_link_choice.rb` (das Format `person:`/`member:`/`new`, einmal),
  `meetings/account_participants.rb` (wen der Dialog in Ruhe lässt). Die Zeile unter einem
  Namen ist `Directory::Entry#detail` (Liste und Dialog). Geschrieben wird über
  `Actors::LinkMeetingParticipant`, der jede ID über das gesperrte Meeting und das
  Directory des Schreibenden auflöst.
  S3 (28.10.2026): the assistant's `find_people`/`get_person` read only through this
  directory (`#entries`, `#person_entry`, `#member_entry`); `#last_contacts_for` gives the
  card of one entry the last contact the list attaches to every row. Map:
  `lalabase/CLAUDE.md`.
  S3b (29.10.2026): `lookup.rb` (`People::Lookup`) is the ONE read of the directory outside
  the page, for three adapters: the assistant's two tools, their MCP twins and
  `Api::V1::PeopleController`. It owns the rights question (`#allowed?`, asked again by
  `#find` and `#entry` before anything is read: `Refused`), the search (the Directory's, with
  `kind` checked instead of read as `all`: `InvalidArgument`), the id format and the ONE field
  selection (`.row`, `.card(entry, notes:)`; `notes: true` only on the REST card, S3b E2), and
  `.for_token` (E1: only an organisation whose every project the token reaches,
  `Reach#project_ids_for(id).nil?`; else nil, so a project-limited token, an organisation
  outside the token and a missing one look alike). The caller sets the tenant (the MCP twins
  and the controller do, before `authorize Person, :index?`); paging is the REST
  controller's (50, at most 100, a value outside refused).
* `notifications/` — Empfänger-Fanout, Broadcast, Scoring (eigene Karte im Ordner); dazu
  `inbox_query.rb` + `serializer.rb`, der EINE Besitzer der Token-Inbox (Reichweite,
  Argument-Vertrag, Zeilen-JSON), geteilt von `GET /api/v1/notifications` und dem
  MCP-Werkzeug `list_notifications`
* `posts/` — `comment.rb` (REST R3a, 29.10.2026) is the ONE rule of a comment written through
  a token: the MCP tool `post_comment` and `POST /api/v1/tickets/:ticket_id/posts` call it.
  `parse` (format `html`/`plain`, valid UTF-8, no NUL in plain, `plain_text_body.rb`, empty
  after conversion), `build` (the unsaved post through `Actors::SavePost`, for the caller's
  `:create?`), `save` (a comment written before a failure after the commit counts as saved,
  else a retry with the same Idempotency-Key writes it twice); rights and wording stay with
  the callers. The refusals (`REFUSALS`), the tool's `REFUSAL_TEXT` and the
  `services.post_comment` keys in de and en are held together by
  `spec/locales/token_rule_refusal_texts_spec.rb`. ⚠️ An empty html body is
  answered differently on purpose: MCP refuses it before the ticket lookup (`body is
  required`, as always), REST leaves it to the model after the write check (its answer
  without `format` stays byte for byte). Not a second rule: do not align them in one hull.
  Encodings: JSON and forms always give UTF-8; a multipart part may name its own charset,
  which an html body keeps (ActionText reads it, as before) and a plain body transcodes.
* `personal_access_tokens/` — `reach_listing.rb` (31.10.2026) is the ONE read of a token's
  organisations and projects as rows, for `GET /api/v1/organisations`, `GET /api/v1/projects` and
  the MCP tools `list_organisations` and `list_projects`. Reach (`PersonalAccessToken::Reach`) AND
  the policy scope decide; `openable_only` narrows to what the project gate opens
  (`ProjectAccessService.openable_project_ids`), for the MCP tool. It asks `Pundit.policy_scope!`
  per organisation, not the controller helper. The method `projects_in_organisation` keeps its
  name: `spec/support/prosopite.rb` allow-lists it by that name.
* `lalabase/` — AI/RAG-Domäne (eigene Karte im Ordner)
* `access_check/` — Projekt-Zugriffslogik, 5 Objekte mit überlappenden Prädikaten —
  **vor Neubau erst hier prüfen**. `project_access_service.rb` ist der EINE Besitzer der
  Regel „aktive Mitgliedschaft" (`.active_member?`, #603): alle fünf Einstiegspunkte
  fragen sie zuerst, **vor** dem Admin-Kurzschluss, in derselben Reihenfolge wie
  `ProjectPolicy#area_access?`. Vier Stellen hatten sie zuvor von Hand gehalten. Wer eine
  neue Reichweiten-Frage baut, geht hier durch und schreibt die Prüfung NICHT noch einmal
  hin. ⚠️ Zwei Fragen bleiben getrennt: `User#account_admin_in?` ist die
  Berechtigungsfrage (verlangt aktiv), `role_in_organisation` die Stammdatenfrage (tut es
  nicht, die Mitgliederliste zeigt die Rolle eines deaktivierten Mitglieds weiter).
  Ausnahme mit eigener Begründung im Code: `ChatPolicy::Scope` prüft selbst, weil der
  org-weite Verlauf gar kein Projekt hat. Guard:
  `spec/policies/inactive_membership_scope_guard_spec.rb`. Ebenso der Regel „archiviertes
  Projekt": für Nicht-Admins in allen Einstiegen geschlossen (seit 27.09.2026), einzige
  Ausnahme sind die eigenen Stunden (lesbar über `time_sessions/viewing_scope.rb`). Guard:
  `spec/requests/organisations/archived_project_access_spec.rb`
* `subscriptions/` — Abo-/Preis-Domäne auf Account-Ebene (ÜBER den Orgs, tenant-frei):
  `seat_counter` (Dedup billable User je Account, wirft bei Zählfehlern laut statt still
  zu unterzählen), `guest_ceiling` (reine Erkennung, blockiert nie einen Write),
  `price_lookup` (**DER Seam für „welcher Preisstand gilt" und „welche Staffelstufe trifft
  diese Seat-Zahl"** — Datums- und Seat-Vergleiche gehören ausschließlich hierhin, damit die
  inklusive `ends_on`-Semantik genau einmal existiert), `public_price_list_payload` (stabiler
  v1-Vertrag für `GET /api/public/v1/price_list`: immer im Envelope `data.price_list`, darin
  Plan, Währung, Intervall-Längen und rohe Staffelwerte mit `billing_interval`, aber keine IDs,
  Notizen, Audit- oder Datumsfelder; ohne gültigen Preisstand ist `data.price_list` JSON-`null`),
  `amount_preview` (Seats × Stufe −
  Rabatt, alle Beträge NETTO; ausdrücklich **keine** Abrechnungsvorhersage, weil eine
  Seat-Reduktion erst zum Periodenende wirkt), `ladder_validator`
  (die zwei Staffel-Invarianten
  lückenlos/überschneidungsfrei — gelten für den Preisstand als GANZES, deshalb kein
  Model-Validator), `price_list_gaps` (findet **künftige** Preislücken; ein „gilt heute ein
  Preis"-Check sieht sie nicht, und genau daran stirbt die öffentliche Preis-API am Stichtag;
  Aufrufer sind seit S3.2 nur noch die Engine: Preisstand-Seite und `subscription_prices:check`),
  `public_ladder` ist seit W6 **weg**: die Preisseite lebt in
    gboyke/lalabase-website und bringt ihre eigene Leiter mit.
  ⚠️ **Seit S3.2 in der Engine `gboyke/lalabase-operator`, nicht mehr hier:** `billing_period`
  (die einzige Monatsarithmetik, vom Startdatum aus GEMESSEN), `billing_list` (W4, fünf
  erschöpfende Abschnitte), `price_list_seed` (Erstbefüllung, nur mit
  `BUNDLE_GEMFILE=Gemfile.operator rake subscription_prices:seed`), `admin/acquisition_report`,
  `actors/withdraw_price_list`. Ihre Regeln stehen in ihren Dateien drüben.
  ⚠️ **Drei Beträge, die auf einer öffentlichen Seite falsch werden können — alle drei sind
  Prädikate auf `Cell`, keine Stufenindizes** (§7.5, §7.5.1): `per_seat?` (nur Sitzanteil →
  „X € je Person"; die offene Stufe hat KEINEN Gesamtbetrag, „ab 11 | 110 €" war für jedes
  größere Team falsch), `total_from?` (Grund- UND Sitzanteil über mehrere Sitze → nur die
  Untergrenze „ab X €" ist wahr), sonst exakter Gesamtbetrag. Und `rung_for` paart die
  Intervalle über die Deckung der **ganzen Zeile**, nicht ihres ersten Sitzes: eine Stufe, die
  mitten in der Zeile endet, wurde sonst über ihre Obergrenze hinaus hochgerechnet (gemessen:
  doppelter Pro-Kopf-Preis). Teilabdeckung → „—"-Zelle, nie eine Paarung.
  ⚠️ Die Seite baut je Intervall zwei I18n-Schlüssel **dynamisch** aus
  `Constants::BILLING_INTERVAL_KEYS` — `i18n-tasks` sieht das nicht, deshalb der Guard
  `spec/locales/billing_interval_keys_spec.rb`. „Drittes Intervall = reine Datenänderung" gilt
  für Ruby und JS, NICHT für die Locales.
  **Die Seat-Kette (M0 bis M2, `doc/abrechnungsmodell_plan.md`)** — vier Dienste, die
  aufeinander aufbauen. Sie beantworten NICHT dieselbe Frage wie `seat_counter`: der zählt
  **jetzt** aus den Mitgliedschaften, diese Kette rekonstruiert **damals** aus `seat_events`.
  1. `seat_opening_backfill` (M0b, `rake seat_events:backfill_openings`) — schreibt den
     Eröffnungsstand, den ein Ereignisstrom auf einem laufenden System nie hatte. Ohne ihn
     rekonstruiert ein ruhiges Bestandskonto zu NULL Plätzen. Idempotent, setzt den Marker
     `SystemSetting#seat_stream_opened_at`.
     ⚠️ Rekonstruierbarkeit hängt an diesem **Marker**, nicht an den `opening`-Zeilen: eine
     paargebundene Zeile kann die System-Frage „ab wann überhaupt" nicht beantworten, und auf
     einer Tag-eins-Installation gibt es sie zu Recht gar nicht.
  2. `seat_stream_drift` (M0b/M0c) — Strom gegen `seat_counter`, je Konto, nachts um 06:20
     (`SeatStreamDriftCheckJob`, nur production). Meldet, repariert NIE: eine Reparatur müsste
     einen Zeitpunkt erfinden, und erfundene Zeitstempel in einem append-only-Buch werden zu
     amtlichen Zahlen.
  3. `seat_snapshot_writer` (M1a/M1b) — eine `seat_snapshots`-Zeile je Konto und Monatsanfang.
     **Überschreibt** beim erneuten Lauf, das GEGENTEIL von `ai_usage_aggregator`; §9 hängt
     daran (rückdatiertes Ereignis nachtragen, dann neu rechnen).
     ⚠️ **Zwei Einstiege, kein Schalter:** `.call` rechnet neu (Korrektur,
     `rake seat_snapshots:rebuild`), `.fill` schreibt nur, was noch KEINE Antwort hat. Der
     Monatslauf nimmt `.fill` — überschriebe er beantwortete Zeilen, wäre jede §9-Korrektur
     beim nächsten Monatstick still wieder weg.
     Betrieb (M1b): `SeatSnapshotJob` am 1. um 06:40 (nur production, direkt nach der
     Driftprüfung), Lückenwächter über `.gaps`/`.unanswered_accounts` — Wächter und Schreiber
     fragen durch DIESELBE Methode, zwei Vorstellungen von „fehlt noch" würden sich
     widersprechen. Dazu `rake seat_snapshots:backfill|gaps|rebuild`.
  4. `seat_peak` (M2/M3, `rake seat_peaks:month|show`, plus der Block auf der Konto-Adminseite) —
     der Höchststand eines Messmonats, dazu wann und mit welchen Organisationen (§5). Liest
     nur: fehlender Schnappschuss ⇒ `unavailable`, kein Nachrechnen, sonst macht ein kaputter
     Monatsjob sich unsichtbar.
     ⚠️ **Das Ergebnis hat KEINEN Monatshöchststand, sondern `sections`** (M3/A3/A9). Zwei
     Zugehörigkeitsgrenzen, und sie wirken VERSCHIEDEN: ein Org-Umzug
     (`moved_in`/`moved_out`, NICHT `opening`) **teilt** den Monat in mehrere Abschnitte, ein
     `billing_starts_on` mitten im Monat **kürzt** ihn (weiter EIN Abschnitt, aber nur über
     einen Teil der Tage). Wer Spanne und Anteil an der Abschnittszahl aufhängt statt an
     `Result#detailed?`, zeigt den ersten Monat jedes Kunden als vollen Monat an.
     ⚠️ **Zwei verschiedene Schnitte je Abschnitt, und sie fallen absichtlich auseinander:**
     `measured_from/to` sind die echten Messmomente, `first_day/last_day` die berechneten
     Kalendertage, und der Umzugstag gehört ganz dem neuen Abschnitt (A6). Gemessen ab
     Mitternacht statt ab dem Umzugsmoment trüge das abgebende Konto seine Leute noch bis
     mittags, und beide Konten zahlten den Umzugstag doppelt. Belegt am Rechenbeispiel in A3.
     ⚠️ Ereignisse GENAU auf einem Schnitt werden angewandt, BEVOR der Abschnitt zum ersten
     Mal gemessen wird. Andersherum ist der Eröffnungswert der Stand, den der Schnitt beendet
     hat, und der Höchststand des zweiten Abschnitts sinkt nie darunter (gemessen: [2, 2] statt
     [2, 0]).
     Ein Monat vor `billing_starts_on` ist `not_billable`, nicht „ohne Antwort" — ob ein Konto
     überhaupt berechnet werden darf, entscheidet weiterhin `billing_list`, nicht dieser Dienst.
  ⚠️ **Nie ein Plus-Minus-Zähler** (§4). Weil über die Organisationen eines Kontos
  dedupliziert wird (D4.1), macht das Entfernen aus Organisation 1 keinen Platz frei, solange
  die Person in Organisation 2 sitzt. Deshalb trägt der Schnappschuss die **Paare** und die
  Wiedergabe eine Karte, nicht eine Zahl.
  ⚠️ **Monatsgrenze `Europe/Berlin` an EINER Stelle:** `SeatSnapshot.boundary_moment` (A6, die
  App läuft auf UTC). Daneben `SeatSnapshot.normalise_period` (Date/Time → Monatsanfang) und
  `.current_period` (welcher Messmonat läuft) — `SeatSnapshotWriter.current_boundary_month`
  zeigt nur noch dorthin. Wer eine zweite Umrechnung schreibt, misst still einen UTC-Monat,
  und zwar genau in den zwei Stunden nach Mitternacht am Monatsersten.
  Ereignisse GENAU auf der Grenze gehören in den Schnappschuss, die Wiedergabe beginnt strikt
  danach; die Fenster-Endgrenze ist deshalb ausschließend (`SeatEvent.strictly_between`).
  **Die Konto-Übersicht (K-S1):** `visible_accounts` (welche Konten gehen einen Nutzer etwas
  an) und `account_summaries` (eine Zeile je Konto für `/billing`; der Cockpit-Block ist
  entfallen, Einstieg ist jetzt der Navigationspunkt „Rechnungskonten" in
  `common/_navigation_account`, der EINZIGEN Navigation ohne Tenant).
  ⚠️ `account_summaries` blendet Konten OHNE Organisation aus. Absichtlich dort und nicht in
  `visible_accounts`: das eine beantwortet „darf sehen" (mit gepinnter Policy-Übereinstimmung),
  das andere „gibt es etwas zu zeigen". Per URL bleibt so ein Konto erreichbar, im Adminbereich
  ist es weiter gelistet.
  ⚠️ `visible_accounts` ist eine ZWEITE Fassung von `AccountPolicy#show_overview?`, absichtlich
  **umgekehrt** gefragt: die Policy läuft über die Organisationen des KONTOS und fächert je Zeile
  auf, dieses Objekt läuft über die Organisationen des NUTZERS und wächst deshalb nicht, wenn ein
  fremdes Konto mehr Orgs bündelt. Zwei Fassungen einer Berechtigungsregel driften — die
  Übereinstimmung ist deshalb selbst gepinnt (`spec/services/subscriptions/visible_accounts_spec.rb`,
  Gruppe „agreement with AccountPolicy"). Wer die Policy ändert, ändert beide.
  ⚠️ Die Zeile baut ihren Zustands-Schlüssel **dynamisch** aus
  `AccountSummaries::LABELLED_ROW_STATES` — dafür der Guard
  `spec/locales/billing_account_row_states_spec.rb`, gleiche Bauart wie der Intervall-Guard oben.
  **Der Umzug (K-S2):** `organisation_move`, Einstieg `rake billing:move_org`, bewusst ohne UI.
  ⚠️ **Eine Organisation NIE per `update!(account:)` umhängen.** Dieser Write fasst keine
  Mitgliedschaft an, also feuert kein Callback und der Seat-Strom bekommt nichts mit; beide
  Konten rekonstruieren danach plausible, aber falsche Zahlen. Der Service schreibt die
  `moved_out`/`moved_in`-Paare selbst, mit EINEM Zeitstempel für beide Hälften. Verweigert bei
  gesetztem `billing_starts_on` (`FORCE=1` übersteuert), zeigt Zugänge und Betrag beider Konten
  vorher/nachher, `DRY_RUN=1` läuft durch dieselbe Transaktion und rollt am Ende zurück — deshalb
  sind die Vorschauzahlen die echten und keine Nebenrechnung. Leerlaufendes Konto bleibt
  stehen (K7).
  ⚠️ **K6 gilt nur fuer bereits GESCHRIEBENE Zeilen.** Rollups, Seat-Ereignisse, Rabatte und
  Antraege behalten ihr `account_id`. Noch nicht aufgerollter Verbrauch folgt dagegen der
  Organisation: `AiUsageAggregator#record_for` liest `organisation.account_id` erst beim
  Aufrollen, und `ai_usage_rollups` haelt EINE Zeile je Organisation und Monat (Unique-Index,
  Einfuegen mit `ON CONFLICT DO NOTHING`). Ein Teil-Abschluss beim Umzug wuerde den Rest des
  Monats deshalb nicht verschieben, sondern VERLIEREN. Der Task misst und benennt die Kante
  stattdessen; einen Monat zu teilen braucht eine Datenmodell-Aenderung.
  ⚠️ **Buendeln reisst die Gastgrenze.** `guest_max_organisations` steht per Default auf 1 und
  zaehlt die Organisationen EINES Kontos, in denen jemand ausschliesslich Gast ist
  (`guest_ceiling.rb`). Genau diesen Zustand stellt K5 her, der Umzug erzeugt also Verstoesse,
  die es bei zwei getrennten Konten nicht geben konnte. Das ist die einzige Umzugsfolge, die
  beim KUNDEN ankommt: `Organisations::BaseController#warn_if_guest_ceiling_exceeded` setzt beim
  naechsten Mitgliedschafts-Write ein `flash[:warning]`. Deshalb misst `#snapshot` die Zahl fuer
  BEIDE Konten und der Task meldet sie dort, wo sie GESTIEGEN ist; Abhilfe ist das Limit am
  aufnehmenden Konto.
  Pläne: `doc/billing_preisliste_rabatt_plan.md`, `doc/konto_ebene_plan.md`.
* `documents/` — die Dokumentversionen (`doc/dokumentansicht_plan.md`, S1): `number_versions.rb`
  zählt den Bestand je Dokument chronologisch von 1 (Task `documents:number_versions`, nach dem
  Deploy, VOR der NOT-NULL-Migration). ⚠️ Nimmt die Zeilensperre des Dokuments, dieselbe wie
  `Actors::SaveDocumentVersion`: die Transaktion allein hält keinen gleichzeitigen Upload auf.
* `indexing/` — `index_everything.rb`, der gemessene Nachholer, seit Notizen immer indexiert
  sind (`doc/notizen_immer_indexiert_plan.md`; Task `indexing:everything[ORG]`).
* `embeddings/` — Embedding-v2-Domäne. **`nearest_neighbors.rb` ist DER EINE Vektor-Read-Seam**
  (PR 4b, `doc/embedding_v2_pr4b_read_switch_plan.md`): alle Retrieval-Call-Sites laufen darüber,
  `nearest_neighbors` auf den Inline-Spalten gibt es im App-Code nicht mehr. Der Seam besitzt
  Metrik pro Record-Typ, den Pflicht-INNER-JOIN (M1) und die 4a-Index-Prädikate — neue
  Vektor-Suchen NIEMALS daneben bauen. Rest: GC-/Reindex-Ops-Helfer.
  **Staged Switch (PR 6a):** Welchen Raum der Seam liest, entscheidet der Pointer
  `organisations.active_embedding_space_id` → `embedding_spaces` (Tripel + Credential-Snapshot),
  NICHT die Org-Konfiguration. `ensure_space.rb` legt Räume an, `Actors::FlipEmbeddingModel`
  schaltet um (Vollständigkeit als ANTI-JOIN via `OrganisationReindexer.missing_in_space` —
  eine Zählung tricksen Orphans aus), `space_index_flag.rb` nimmt Räume aus dem Index
  (Retirement) und zurück hinein (Reaktivierung — **muss VOR einem Rück-Flip laufen**, sonst
  liefert der Rollback still null Treffer). Reindexer-Modi: build (fehlende Zeilen) /
  `delta:` (zusätzlich `source_hash`-Drift) / `force:` (alles).
  **Die Typenliste besitzt allein `content_types.rb` (seit 04.09.2026):** neun Einträge mit
  Tabelle, Modell, Opt-in-SQL, Pflicht-Join, Projekt-Join und Projektspalte, dazu die
  Zustandsprädikate (`flag_pending`, `processed`, `failed`, `text_present`). Keine Relation
  wird dort gebaut (zwei Tenant-Kontexte). Drei Leser leiten ab und bauen ihre eigene
  Abfrageform: `pending_embeddings.rb` (lazy Relationen für Knopf und monatliche Nachlese),
  `index_health.rb` (EINE UNION) und `ai_sync_status_service.rb` (je Projekt, `.call(organisation:)`).
  Wächter: `content_types_spec.rb` (Liste ⟺ Modelle mit `as: :fragmentable`, abgeleitet) und
  `index_health_pending_parity_spec.rb` (stubbt die Liste ohne einen Typ; jeder Leser muss ihn
  verlieren, sonst hat er eine private Kopie). Ein zehnter Typ = ein Eintrag + Builder in
  `spec/support/embeddable_content_types_helpers.rb` + Zeile in `AiSyncStatusHelper::TYPE_PRESENTATION`
  + Label DE/EN + die Aufzählung in der In-App-Hilfe `05-sync-status.md` (DE **und** EN).
  NICHT die Abruf-Seite: `ContentAreaRegistry` gattert, was ZURÜCKKOMMT.
  **Drei Leser derselben Spalten, nicht einer (KI-Bereich S2):** `index_health.rb` beantwortet
  „wie viel steht aus, wie viel ist fehlgeschlagen" org-weit in EINER Query (UNION über alle
  registrierten Typen) — für den KI-Hub, dessen Budget bei ≤ 9 eigenen Queries
  für die GANZE Seite liegt (§3.3 nennt oben 5, der Nachtrag vom 05.08. begründet die 9). `AiSyncStatusService` bleibt der Leser der Detailseite (alle Projekte ×
  alle registrierten Typen, Übersicht = Summe der Projektzeilen) und darf auf dem Hub NIE aufgerufen werden. ⚠️ Der Preis des rohen SQL:
  `acts_as_tenant` greift nicht, jeder UNION-Zweig bindet `organisation_id` selbst — ein
  vergessener Filter ist ein stiller mandantenübergreifender Leak, den Request-Specs mit nur
  einer Organisation nicht sehen (gemessen). Deckung dafür: `spec/services/embeddings/index_health_spec.rb`.
  **Statusanzeige ≠ Diagnose (KI-Pakete P4c):** `switch_progress.rb` beantwortet „läuft ein
  Wechsel und wie weit" für die KUNDENSEITE, `space_alignment.rb` ist die Betreiber-Diagnose.
  Nicht verwechseln — der volle `SpaceAlignment.call` macht vier Aggregat-Scans mit
  korrelierten Subqueries; auf einer Seite, die der Kunde von Hand öffnet, ist das die
  N+1-Lehre aus #368. `SwitchProgress` staffelt stattdessen: Opt-in und Pointer sind
  Spaltenlesungen, `configured != active` fasst `content_embeddings` nicht an, und die
  Anti-Joins laufen nur, wenn ein Wechsel wirklich aussteht.
  ⚠️ **Ohne Pointer ist die Wechsel-Frage nicht beantwortbar** — `embedding_space_for(:active)`
  fällt auf das konfigurierte Tripel zurück, beide Seiten des Prädikats werden identisch, und
  ein laufender Wechsel meldet sich als „keiner". `SwitchProgress` gibt dafür den eigenen
  Zustand `:pointer_missing` zurück statt `:none`; wer das Prädikat woanders nachbaut (der
  Watcher tut es), erbt die Blindheit ohne den Hinweis. Reparatur: `embeddings:backfill_spaces`.
  ⚠️ **`ensure_space.rb` refresht ALLE Snapshot-Spalten — außer einer.** `ai_credential_id`
  (der P0-Pin) wird nur geschrieben, wenn die Zeile keinen Pin hat, und geleert, wenn sie auf
  BYOK wechselt; ein bestehender Pin bleibt stehen (Log-Warnung bei Abweichung). Der Grund ist
  der Zweck der Spalte: mitrefresht würde `flip`/`build_target` einen gehaltenen Raum still auf
  den heutigen Provider-Standard umhängen — exakt der Swap, gegen den der Pin gebaut ist, nur
  über den Schreib- statt den Lesepfad. Wer eine Pin-Spalte in einen Refresh-Hash aufnimmt,
  braucht diese Ausnahme im Code, nicht bloß einen Kommentar am Modell.
  **Retention (PR 6b):** `orphan_gc.rb` hat einen dritten, **org-gebundenen** Sweep: Räume
  jenseits von `organisations.embedding_retention_limit` werden gelöscht (Sidecar-Zeilen +
  `embedding_spaces`-Zeile). Zwei Schutzregeln, deren REIHENFOLGE zählt — der aktive Raum ist
  nie Kandidat, und der Raum im Aufbau (= konfiguriertes Tripel, aber nicht aktiv) fliegt
  **vor** der Behalten-Auswahl raus, damit er keinen Slot belegt. Behalten-Ordnung ist
  `retired_at DESC NULLS LAST` (der Flip stempelt sie unter Sperre), NICHT `created_at`: nach
  einem Rollback zeigen die beiden in verschiedene Richtungen. Eigener Kill-Switch
  `EMBEDDINGS_RETENTION_ENFORCE`, getrennt von `EMBEDDINGS_GC_ENFORCE` (anderer Blast-Radius:
  Orphans sind wertlos, ein Raum ist das Rollback-Netz).
  ⚠️ **Zeilen in einem Tripel OHNE `embedding_spaces`-Zeile sieht KEIN Sweep** — Record lebt
  (kein Orphan), kein Raum hält das Tripel (kein Retention-Kandidat). Der GC zählt und warnt
  sie als `UNREGISTERED`, löscht sie nie (dasselbe Tripel ist auch ein frisch konfiguriertes
  Ziel vor `build_target`). Das ist der Prod-Altbestand aus Wechseln vor PR 6a — wer erwartet,
  dass der GC ihn abräumt, hat den Sweep falsch verstanden.
  **Die Inline-Lane ist weg (PR 7).** Die vier Inline-Vektorspalten und ihre acht
  Provenienz-Spalten sind gedroppt; `content_embeddings` ist die einzige Vektor-Quelle für
  Lesen UND Schreiben. Damit entfällt der Dimensions-Sonderfall: die fünf Schreibpfade
  (`embedding_processing_service`, `project_indexer_job` ×2, `indexer/symbol_persistence`,
  `embeddings/organisation_reindexer`) schreiben jede Dim auf demselben Weg.
  `Indexer::EmbeddingColumns` liefert nur noch das TRIPEL (`.from`) — `inline_pair`,
  `INLINE_DIMS` und `inline_writable?` gibt es nicht mehr, ebenso wenig `SidecarBackfill`
  und `normalize_legacy_labels`. Wer „hat ein Embedding?" fragt, fragt die Sidecar
  (`Fragment.with_sidecar_embedding`). Guard: `spec/models/no_inline_embedding_columns_guard_spec.rb`
  hält die Spalten draußen — die geteilte Dev-DB schreibt sie sonst über `schema.rb` zurück.
  **`space_alignment.rb` ist das Gate zu diesem Seam** (`rake "embeddings:check_alignment[ORG]"`,
  Exit ≠ 0): Der Seam filtert strikt auf das Tripel, das `Factory.embedding_space_for` auflöst —
  passt das nicht zum gestempelten Tripel der Sidecar-Zeilen, liefert JEDE Suche still null
  Treffer (so geschehen 2026-07-30 auf Prod). Ein Vollständigkeits-Anti-Join sieht das
  prinzipiell nicht — er fragt nur, OB eine Zeile existiert, nicht in welchem Raum
  (`OrganisationReindexer.missing_in_space` ist der verbliebene, er trägt das Tripel
  deshalb selbst). Vor/nach jedem Modellwechsel laufen lassen. Vier Eimer, nur
  einer ist der Befund (seit PR 6a fünf, siehe `pending_flip`): `stranded` (Record hat KEINE
  **lesbare** Zeile — Tripel UND `indexed` —
  → unerreichbar) ist der Fehlerfall; `stale` (Alt-Zeile neben einer lesbaren) der Normalzustand
  nach jedem Reindex — seit PR 6a nimmt das Retirement solche Zeilen aus dem INDEX
  (`indexed → false`), GELÖSCHT werden sie vom Retention-GC (PR 6b) NUR, wenn eine
  `embedding_spaces`-Zeile ihr Tripel noch hält (sonst `UNREGISTERED`, siehe Retention-Block
  oben); der `stale_count` sinkt am Retirement also nicht; `aligned` der gesunde Rest; `orphan`
  `pending_flip` (nicht lesbar im aktiven, aber lesbar im KONFIGURIERTEN Raum — Inhalt, der
  während eines laufenden Staged Switch entstand; der Flip löst ihn auf, ein Reindex nicht,
  deshalb außerhalb des Urteils); `orphan`
  (Record per `delete_all` weg) steht **außerhalb** des Urteils — kein Reindex erreicht sie, das
  Mittel ist `embeddings:gc`. Der Exit-Code liest zusätzlich `ai_enabled`: KI aus → Warnung
  statt Rot (der empfohlene Reindex würde `AiDisabledError` werfen), KI an + Raum NICHT
  auflösbar → rot (`NearestNeighbors` wirft dann bei jeder Query, `PromptBuildingService`
  antwortet still kontextfrei). **Kein Raum auflösbar ≠ „Org hat KI aus"**:
  `Factory.embedding_space_for` ist gate-frei und löst mit aktivem System-Credential für JEDE
  Org auf — der Zustand heißt „gar kein Credential" (oder Fehlkonfiguration, dann immer rot).
  **Zweite, unabhängige Hälfte des Urteils (KI-Pakete P0):** die Eimer oben vergleichen nur
  TRIPEL, und `embedding_space_for(:active)` antwortet aus der Snapshot-Zeile, ohne je ein
  Credential anzufassen. Ein Raum, dessen Pin (`embedding_spaces.ai_credential_id`) auf ein
  gelöschtes, deaktiviertes oder fremdes Provider-Credential zeigt, wäre damit `aligned/ok` —
  während JEDE Query `MissingCredentialError` wirft. Deshalb fragt `SpaceAlignment` zusätzlich
  `Factory.active_space_credential_error` (gate-frei, nil bei BYOK und ohne Pointer), und
  `severity` ist das SCHLECHTERE aus `space_severity` und `credential_severity`. `status`
  bleibt bewusst tripel-only: „misaligned" bei korrekt liegenden Zeilen schickte den Operator
  in einen Reindex, der nichts repariert — der Rake-Text nennt stattdessen „Credential
  reaktivieren ODER Raum umhängen".
* `admin/` — Lese-Objekte NUR für den Adminbereich. `acquisition_report` (woher ein Kunde kam,
  `doc/akquise_herkunft.md`) liegt seit S3.2 in der Engine. `ai_routing_summary` beantwortet „welche KI
  nutzt diese Org", indem es die Reihenfolge **Paket-Rung > BYOK > System-Credential** durch
  `Lalabase::Llm::Factory` erfragt (`curated_chat_tier`) statt sie nachzubauen — die alte
  Anzeige las `has_own_ai_credentials?` („brachte kein Token") und beschriftete damit jede
  Paket-Org als „System-Credentials", also mit einem Credential, das sie nie anfasst.
  ⚠️ Dafür braucht `Admin::Organisation` sein `belongs_to :ai_package`: die Factory fragt
  `organisation.try(:ai_package)`, und ohne die Assoziation antwortet **jede** Admin-Org
  „kein Paket" — still und plausibel.
* `codebase_import/`, `user_data_exports/`, `subscriptions/`, `overview/`, `dashboard/`
* **Achtung, zwei ähnlich benannte Domänen:** `documentation/` = aus Repos synchronisierte
  `.md`-Doku (eigener `MarkdownRenderer`, eigene `Navigation`; `asset_collector.rb` kopiert
  beim Sync die Bilder aus dem Klon und ist die EINE Stelle, die entscheidet, was davon
  ausgeliefert wird: innerhalb des Klons nach Auflösen der Symlinks, Typ aus den Bytes, eine
  Typliste `RichTextEmbeds::IMAGE_CONTENT_TYPES`; ⚠️ nach einer Änderung am Renderer
  `bin/rails documentation:resync_all`, ein Poll überspringt unveränderte Repos),
  `product_knowledge/` =
  Lalabases eigene Texte als Tabelle für die Suche. Die dritte, `docs/`, rendert seit **D5
  (21.09.2026) kein Markdown mehr** und ist nur noch die LESESCHICHT auf eine fremde Datei
  (`doc/docs_delivery_plan.md`).
* `docs/` — acht Dateien, und alle antworten auf dieselbe Frage: was die Hilfe (`/hilfe`) und
  der Assistent von der Dokumentation wissen, die in `gboyke/lalabase-documentation` lebt.
  `catalogue.rb` liest eine JSON-Datei je Sprache, die jenes Programm schreibt und sein Deploy
  hierher legt (`DOCS_CATALOGUE_PATH`; Vertrag: `docs/api/katalog_v1.md`).
  ⚠️ **Keine Datei ist der NORMALFALL** (Selbsthosting, Entwicklungsrechner): jeder Leser
  antwortet, keiner wirft. `contract.rb` hält, was beide Seiten teilen (Sprachen,
  Sanitize-Allowlist, die kanonische `/docs/<sprache>/<slug>`-Form) — **eine** Konstante je
  Sache, und `page_links.rb` liest die Form von dort statt eine zweite zu halten.
  `contextual_help.rb` ist die Karte Seite → Frage → Anker; sie gehört dem Kern, ob die Anker
  noch antworten prüft `rake anchors:check` drüben. Dazu `help_link*.rb` (wohin ein Link
  zeigt: org-gebundene Hilfe, sonst die öffentliche Doku), `public_docs.rb` (deren Adresse)
  und `plain_text.rb` (Schnipsel um einen Treffer).
  ⚠️ **Nichts hier rendert Markdown, und nichts liest `app/docs/`** — das Verzeichnis gibt
  es nicht mehr. Wer eine Doku-Seite ändern will, ändert sie im anderen Repo. Redcarpet und
  Rouge bleiben im Gemfile: Changelog, `documentation/` und `Lalabase::SafeMarkdown` nutzen
  sie weiter.
* `product_knowledge/`: Lalabases EIGENE Texte (die In-App-Hilfe, später die Neuigkeiten)
  als durchsuchbare Tabelle ohne Organisation (`doc/product_knowledge_plan.md`). Quelle ist
  seit D4 der **Katalog** (`Docs::Catalogue`), nicht mehr `app/docs/`; die Tabelle ist eine
  Kopie davon. `sources.rb` entscheidet fail-closed, was
  hineinkommt (die Self-Hosting-Doku bewusst nicht, sie steht gar nicht im Katalog), und berechnet
  als EINZIGE Stelle den Inhalts-Hash (`build_row`). `sync.rb` gleicht ab (`rewrite:` für die
  Reparatur). `ensure_fresh.rb` läuft vor jedem Lesen, in dieser Reihenfolge: Merker je
  Prozess (5 Minuten oder bis sich der Katalog ändert, sonst kostet jedes Lesen rund 100 ms),
  Fingerabdruck der TABELLE gegen den Katalog, nie rückwärts (`SystemSetting`
  `product_knowledge_generation`, sonst setzt ein Prozess des alten Releases während des
  Deploys die Tabelle zurück; Maßstab ist die Änderungszeit der Katalogdateien, und eine
  Sprache OHNE Datei trägt nichts bei statt einer Null, die die Generation zurückzoge),
  Sperre ohne Warten. Alles ohne Query-Cache (unter ihm sah die
  Prüfung nach der Sperre den alten Stand). `search.rb` ist der EINE Leser: Suchbegriffe
  normalisiert Postgres EINMAL (Stoppwörter raus, Stämme, Präfixe), danach gehen sie als
  fertige `tsquery` hinein und nicht noch einmal durchs Wörterbuch; erst Seiten mit allen Begriffen,
  dann mit einigen, dann wörtliche Treffer; eine Sprache je Antwort, standardmäßig nur die
  Hilfe. `contents` gibt alle Seiten einer Sprache ohne Text zurück (das Inhaltsverzeichnis
  für `help_contents`). Leser sind die drei Hilfe-Werkzeuge des Assistenten (Karte
  `lalabase/CLAUDE.md`). ⚠️ Nie an `Search` vorbei auf die Tabelle lesen, dort sitzt der Abgleich.
  ⚠️ Specs, die Zeilen per Factory bauen, brauchen `:product_knowledge_table_as_given`, sonst
  löscht der echte Abgleich sie (`spec/support/product_knowledge.rb`). Aus `docs/` liest es
  `sections.rb` (der eine Besitzer der Abschnittsbeschriftung) und `plain_text.rb`
  (dekodiert Entitäten, für Suchindex, Schnipsel und Modell); `page_links.rb` entscheidet für
  den Renderer und für `get_help_page`, welche Seite ein Link in einer Seite meint.

Bekannte Doppel-Verortungen (Altbestand; Boy-Scout-Regel: bei Berührung konsolidieren):
* Ticket-Logik an 4 Orten: `ticket_*_service.rb` (flach), `tickets/`, `actors/*`,
  `codebase_import/ticket_*`. Alle nicht-trivialen Ticket-Writes laufen über die Actor-Seam
  (`save_ticket`/`move_ticket` [Tier 2], `apply_ticket_changes`, `merge_ticket_attribute_option`,
  `sort_ticket_attribute_definitions`, `create_ai_post` [Tier 2]) — Plan `doc/tickets_seam_umbau_plan.md`.
  Seit 08.09.2026 (`doc/ticket_bulk_edit_plan.md`): `tickets/bulk_selection.rb` löst die Auswahl
  einer Sammeländerung in Ids auf (Modus `ids`/`all`, Deckel `MAX_TICKETS`, `expected_count`);
  Dazu `tickets/bulk_fields.rb` (der eine Katalog der änderbaren Felder, Scheibe 4),
  `tickets/bulk_summary.rb` (Bestand je Feld über die Auswahl, Digest je Feld),
  `tickets/changes.rb` + `tickets/changes/*` (Register: eine Klasse je Änderungsart mit
  `apply`/`restore`/`still_applied?`/`describe`; Fehler über `Invalid.with(code)`, weil die
  Konvention Initializer ohne Positionsargumente will), `tickets/change_applier.rb` (EIN Ticket
  im eigenen Sicherungspunkt, trägt das Rescue je Ticket, damit die Actors den Vertrag halten),
  `tickets/change.rb` (REST R3b, 30.10.2026, nicht zu verwechseln mit dem Register
  `tickets/changes*`) ist die EINE Regel einer Änderung über einen Token: das MCP-Werkzeug
  `update_ticket` und `POST /api/v1/tickets/:id/changes` rufen sie. `parse` (Art nach
  vorhandenem Schlüssel, Schlüssel, UTF-8, Titelregel, Listen, `"me"`), `write` (Status und
  Personen über den Actor unten, Titel über `SaveTicket` unter Zeilensperre im Projekt) und
  `Outcome` (geschrieben, Ticket weg, `FAILURES`, Unerwartetes). Rechte und Wortlaut bleiben in
  den Hüllen; `REFUSALS`, `FAILURES`, die Tabellen des Werkzeugs und die `services.ticket_change*`-Schlüssel
  in de und en hält `spec/locales/token_rule_refusal_texts_spec.rb` zusammen.
  `actors/apply_ticket_changes.rb` (EIN Actor für eins und viele, D13; sperrt die Zeilen,
  vergleicht den Bestand, schreibt den Durchlauf `TicketBulkRun`) und `actors/undo_ticket_bulk_run.rb`.
  Seit 6b bedient `apply_ticket_changes` auch Board-Drag und Kommentar-Status mit einer Menge
  von einem Ticket (`set_ticket_attribute` ist gelöscht); ein Ticket, das nicht speichert, ist
  dort der Fehlschlag des Aufrufs, bei mehreren ein benanntes Teilergebnis. Scheibe 7:
  `tickets/mover.rb` besitzt den Umzug EINES Tickets (Nummer mit Retry im Savepoint, verlorene
  Zuweisungen/Abos, Zeiten, drei Aktivitäten; Kontext auf Ticket und beide Projekte) und bedient
  `actors/move_ticket.rb` (jetzt Tier 1) wie `actors/move_tickets.rb`; `tickets/move_applier.rb`
  und `tickets/destroy_applier.rb` sind die Geschwister von `change_applier.rb`;
  `actors/destroy_tickets.rb` liest die Beobachter vor dem Löschen; `tickets/bulk_impact.rb`
  zählt für die Dialoge (Kommentare, Anhänge, Zeiten, Unteraufgaben, verlorene Zuweisungen).
  Ticket-Beziehungen (30.09.2026, `doc/ticket_relations_plan.md`): `tickets/waiting.rb` ist der
  EINE Besitzer von „wartet“/„hält auf“ (`waiting`, `blocking`, `counts_for` mit fester
  Abfragezahl, `for`), `tickets/cycle_check.rb` die Erreichbarkeit über eine feste Kantenliste
  (rekursive CTE, gibt nur IDs aus, endet auch bei Altbestand-Kreisen), und zwar NUR für
  Warte-Kanten: die Hierarchie braucht keine, weil die Eltern nach dem Anlegen feststehen.
  `tickets/ancestry.rb` ist der EINE Leser der Vorfahren eines Tickets (Brotkrumen): eine
  Abfrage, endet bei Kreisen in den Daten, bleibt in Projekt und Organisation. Geschrieben wird über
  `actors/create_ticket_relation.rb` (Advisory-Lock je Organisation, dann Kreis-Prüfung, dann
  `save!`) und `actors/destroy_ticket_relation.rb`; beide prüfen keine Rechte, das tut der Aufrufer
  (`Organisations::Tickets::RelationsController`). Seit PR 2 (Ticketseite): `tickets/waiting.rb`
  hat dazu `open_ids` (dieselbe Erledigt-Regel für die graue Anzeige), `tickets/relation_section.rb`
  liest Abschnitt und Kopf-Hinweis EINES Tickets in fester Abfragezahl (nur sichtbare Beziehungen,
  der Hinweis zählt trotzdem alle Blocker), `tickets/lookup.rb` ist die Suche des Pickers (Nummer
  oder Titel über `Ticket.search_title`, NIE `search_full_text`: das trifft auch private Kommentare).
  Seit PR 4 (Filter): `tickets/waiting_state_filter.rb` macht aus „wartet“/„hält auf“ eine
  Ja/Nein-Bedingung („ist nicht“ = der Rest der Liste, erledigte Tickets eingeschlossen); Leiste
  (`AdHocFilterService`) und Ansicht (`SmartFolders::Filters::WaitingFilter`/`BlockingFilter`)
  fragen beide dort, nie `Tickets::Waiting` mit eigener Verneinung.
* Embeddings: `embedding_processing_service.rb`/`embedding_reprocessing_service.rb` (flach) + `embeddings/`
* SmartFolders: Reads = 5 flache `smart_folder_*`-Dateien + `projects/default_smart_folder_service.rb`;
  Writes unter `actors/` (`clone_smart_folder`, `save_smart_folder_from_filters`, `share_smart_folder`);
  `ad_hoc_to_smart_folder_service` ist ein reiner Converter (kein Write mehr).
  Eine neue Sonder-Kategorie der Leiste kommt NUR in `AdHocFilterService::SPECIAL_FIELDS`: der
  Converter und `SmartFoldersController#sanitized_filter_params` lesen dieselbe Liste. Was der
  Converter schreibt, liest `smart_folder_dissolver.rb` 1:1 zurück (Spec:
  `spec/services/smart_folder_round_trip_spec.rb`); ohne Rückweg öffnet die Ansicht als Expertenregel.
* Objekt-Art ≠ Verzeichnis: `kanban_board_presenter.rb` liegt hier statt in `app/presenters/`;
  Query-artige Objekte teils hier statt in `app/queries/`

## Geltungsbereich des Assistenten (S3a T5, 2026-08-25)

Wer die org-weite Reichweite anfasst, fasst DREI Besitzer an, nicht mehr:

* `lalabase/tools/scope.rb` — **`Scope.for(chat:, actor:)` ist der einzige Weg**, einen
  org-Scope zu bauen. Runner und Retriever gingen vorher je eigene Wege; ein Guard
  (`spec/services/lalabase/tools/scope_factory_guard_spec.rb`) hält sie jetzt auf der
  Fabrik. ⚠️ Der Chip verengt durch INTERSEKTION mit den Rechten, nie durch Ersetzen.
  Eine Wahl, die nicht mehr auflöst, ist keine Wahl: der Thread fällt auf die volle
  Reichweite zurück, und `#selection` sagt das, damit der Chip nicht eine Einschränkung
  behauptet, die es nicht mehr gibt. ⚠️ „Löst nicht mehr auf" heißt archiviert, gelöscht
  **oder für DIESEN Fragenden nicht mehr lesbar**: `#selection` geht über
  `Chats::AssistantScopeOptions`, denselben Besitzer wie der Schreibpfad. Der prüft die
  Rechte genau einmal, beim Speichern — ohne die Prüfung beim Lesen trüge ein verlorenes
  Recht den Projektnamen weiter in Systemprompt und Deckungssatz, während der Chip
  „Alle Projekte" zeigt.
* `lalabase/tools/base.rb` — `PROJECT_FILTER_SCHEMA` und `resolve_project_filter` gehören
  allen drei org-fähigen Werkzeugen gemeinsam. ⚠️ Auf dem Ein-Projekt-Pfad (nur noch
  MCP) wird der Filter ABGELEHNT, nicht ignoriert: stilles Schlucken ließe ein Modell
  glauben, es habe verengt. Ebenso `coverage_for(..., only_project:)` — eine auf ein
  Projekt verengte Antwort darf nicht die org-weite Deckung tragen. ⚠️ `only_project:`
  nimmt das **Projekt**, nicht seine id, und `resolve_project_filter` gibt es deshalb
  auch so zurück: der Deckungssatz nennt den Namen, und mit der id allein hätte ihn
  jeder Aufrufer erneut nachschlagen müssen.
* `lalabase/tools/base.rb#referenced_record` (10.09.2026, `doc/assistent_wissen_kontext_plan.md`)
  — der E3-Rückfall „was der Faden benennt, darf gelesen werden, auch wenn der Chip
  woanders sucht; nur per UUID" gehört den Lese-Werkzeugen `GetTicket`, `GetNote`,
  `GetDocument` und `GetMeeting` gemeinsam, ebenso `outside_coverage` und `cap_text`/`TRUNCATION_MARKER`.
  Meeting-Bezüge laden nur ID, Organisation, Projekt, Titel und Zeitpunkt; der
  Titel trägt das Datum. `GetMeeting` lädt beim Rückfall die aktuellen Inhalte neu
  aus den aktiven Projekten der Organisation und prüft danach das Datensatzrecht.
  Kein zweiter Rechte-Riegel: der Bezug hat `Scope#resolve_reference` beim Speichern
  passiert, `authorize!` je Datensatz bleibt. Die vier Wörter des Textstatus (`available`,
  `unsupported`, `unavailable`, `empty`) besitzt `ExtractPlainTextProcessingService
  .text_status` neben seiner Allowlist; `Tickets::Serializer` und `GetDocument` rufen ihn.
  Ein neuer referenzierbarer Typ = Registry-Eintrag (`assistant/reference_registry.rb`),
  Marker + Knopf über `AssistantContextHelper`, und ein `Get*`-Werkzeug nach diesem Muster.
  ⚠️ **`area:` ist NICHT für jedes Werkzeug die richtige Quelle der Kandidaten.**
  `ProjectPermission.access_areas` kennt `tickets, notes, chats, documents, members,
  documentation, meetings` — **kein `time_sessions`**. Die all/own/none-Regel
  der Zeiten lebt in `TimeSessions::ViewingScope` (§2.4). `resolve_project_filter` nimmt
  deshalb wahlweise `area:` ODER `candidates:`; `SummarizeTimeSessions` reicht seine
  ViewingScope-Liste als `candidates:` ein. Ein `area: :time_sessions` hier ist ein
  `NoMethodError`, den der Runner zu „tool crashed" auffängt: still, nicht laut.
* `lalabase/tools/scope.rb#code_project_ids` — die Reichweite der fünf CODE-Werkzeuge
  (`doc/assistent_code_werkzeuge_plan.md`). ⚠️ **Keine Area.** Repositories sieht, wer
  `chats:read` ODER `documentation:write` hat — eine Zwei-Area-Vereinigung, für die
  `ProjectPermission` gar kein Feld hat. Besitzer der Regel ist
  `ProjectRepositoryPolicy::Scope`, und diese Methode ist ihr einziger Aufrufer; ein
  handgeschriebenes `area: :chats` ließe den Dokumentations-Zweig still fallen. Dieselbe
  Bauart wie `SummarizeTimeSessions` mit `TimeSessions::ViewingScope`, aus demselben
  Grund. Der Chip verengt auch hier durch Intersektion, nie durch Ersetzen.
* `lalabase/tools/base.rb#resolve_code_project` — die Leiter, mit der aus dieser
  Reichweite EIN Projekt wird: genanntes Projekt, sonst der Chip beziehungsweise das
  einzige erreichbare, sonst eine Kandidatenliste. Fünf Werkzeuge, EINE Leiter. Vision
  und Fähigkeiten sind 1:1 je Projekt, „alle Projekte" gibt es hier also nicht, und
  raten ist schlechter als fragen. ⚠️ Die fünf melden seither `requires_actor?` — die
  einzige Stelle, an der auch der Ein-Projekt-Pfad sich ändert: ohne Fragenden lehnt der
  Runner sie ab, statt Pundit ein `nil` zu reichen.
* `chats/assistant_scope_options.rb` — die anwählbaren Projekte, geteilt von Chip und
  Schreibpfad. Driften die auseinander, entsteht entweder eine tote Option oder ein Weg,
  einen Verlauf an ein Projekt zu heften, das man nicht sehen darf.
* `assistant/reference_registry.rb` — welche Objekttypen der Bezug des Assistenten kennt
  (Bezugs-Sammlung S1, `doc/assistent_bezug_sammlung_plan.md` §5), fail-closed wie
  `PanelRegistry`. Je Typ: Rechte-Area, Zitationstyp, `reachable`-Lambda (die POLICY des
  Typs, nicht bloß sein Projektfilter) und `title`-Lambda. ⚠️ Sie doppelt KEINE der drei
  bestehenden Karten (`AREA_BY_TYPE`, `Citations::TYPES`, `CitationTargets::MODEL_NAMES`),
  sondern deklariert und wird gegen sie geprüft
  (`spec/architecture/assistant_reference_registry_guard_spec.rb`). Hier wohnt auch die
  Schlüsselvokabel `Ticket:<uuid>` samt `parse_key` — ⚠️ **nie `constantize`**, der Typ
  wird ausschließlich in der Registry NACHGESCHLAGEN.
* `chats/reference_normalizer.rb` — die geteilte Normalisierung, die beide Bezugs-Actors
  unter dem Zeilenschloss fahren (§7.2). Wirft alles weg, was für den Besitzer des Fadens
  nicht auflöst: gelöscht, außer Reichweite, abgemeldeter Typ — drei Gründe, EIN Wort,
  tragfähig nur weil ein Org-Faden genau einen Besitzer hat. Der Schreibpfad hält die
  Liste sauber, das Modell prüft nur Form.

Der Vertrag `chatposts.source_coverage` trägt seit T5 zusätzlich `chosen` (Name des
gewählten Projekts). ⚠️ **ZWEI Wege setzen ihn**, nicht nur der Chip: der Chip über
`Scope#selection`, der Werkzeug-Filter über `coverage_with(chosen:)`. Beide sind die
Wahl des Fragenden und bekommen denselben Satz; nur eine Grenze aus den RECHTEN wird
gezählt. ⚠️ Wer diese Deckung erzeugt, baut sie NIE von Hand: `Scope#coverage`
bzw. `#coverage_with` sind die einzigen Bauer, auch im `ProjectRag::Retriever`.
`ChatResponseJob#narrowest_coverage` wählt einen der Hashes ganz aus, und bei
Gleichstand den ERSTEN (den des Retrievers) — ein handgebauter Hash dort überstimmt
also lautlos den, der den Chip trägt. Er unterscheidet die selbst gewählte Verengung von der, die aus den
Rechten folgt — beide bekommen einen anderen Satz unter der Antwort, weil eine Antwort
wandert und der Chip dort nicht mitkommt.
