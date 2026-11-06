# Karte: app/services/lalabase (Stand: 2026-11-06)

AI/RAG-Domäne (Produktname „Lalabase"): alles rund um LLM-Aufrufe, Embeddings und
Codebase-Verständnis.

* `llm/` — **Provider-Factory & gated seams**: `OpenAI::Client`/`Anthropic::Client` dürfen NUR
  in den allowlisteten Seams instanziiert werden (Guard:
  `spec/services/lalabase/llm/direct_client_guard_spec.rb`). Grund: DSGVO-Opt-in-Gate
  (`organisation.ai_enabled`) + BYOK-Routing über `AiCredential` dürfen nicht umgangen werden.
* `tools/` — Tool-Klassen für Chat/MCP; Konvention `Klass.execute(args:, context:)`,
  Sets (`:assistant`, `:assistant_with_code`, `:mcp`; `Registry::SETS` ist die eine Liste aller
  Sets) in `tools/registry.rb`, Guard `spec/services/lalabase/tools/registry_spec.rb`.
  Drei lesen Lalabases EIGENE Hilfe (`search_help`, `help_contents`, `get_help_page`,
  Elternklasse `HelpTool`, nur `:assistant`): ohne Projekt, ohne Abdeckung, Sprache aus
  `language_preference`, Zitationstyp `help_page` ohne Area (die Antwort bleibt ungesperrt),
  Link `/hilfe/<slug>` über `CitationLink`. Links im Seitentext werden zu „(help page <slug>)",
  nie zu `/hilfe`-Links: ein vom Modell kopierter Link öffnete sich im Chat-Frame. Leere
  Tabelle = Fehler „nicht verfügbar", nie „keine Seite". `help_contents` hat keine Argumente:
  `GoogleVertexProvider` schickt so ein Werkzeug ohne `parameters`, weil Gemini ein OBJECT mit
  leeren `properties` ablehnt (Spec prüft jedes Chat-Werkzeug). Plan `doc/product_knowledge_plan.md`.
  Two read the people directory (`find_people`, `get_person`, parent class `PeopleTool`,
  `:assistant` and `:assistant_with_code`, People S3): no project and no coverage like
  the help, but a right of their own. `PersonPolicy.view_allowed?` is asked inside the tool
  BEFORE anything is read, else `refused` (a deactivated member too). They read through
  `People::Lookup` only (over `People::Directory`), never `Person.where`/`find`. The id is the
  format of `Meetings::ParticipantLinkChoice` (`person:<uuid>` for a contact, `member:<uuid>`
  for a member); unknown, foreign and invisible ids give the same `not_found`. Which fields
  reach the provider is decided only in `People::Lookup.row`/`.card` (never `notes`, E2; the
  last contact as date and kind, E3). Both cite type `person` (area `people`, no project, a content
  type): a contact by its row, a member by the account (`member_id`, the page sends it on to
  the row). `find_people` cites its first five rows, or an answer drawn on the list alone
  would carry no area and stay unredacted for others.
  `get_meeting` on `:mcp` is a twin as well (`McpGetMeeting`, R9, MCP 0.17.0), for a program
  behind a token such as Claude Code beside a meeting in the terminal client. Its gate is
  `Meetings::Readable`, the one `GET /api/v1/meetings/:id` asks (moved there from the REST
  controller when this second door came): missing, malformed, beyond the token, foreign or
  unreadable all answer `kind: empty` with one text, word for word. Unlike the assistant's
  capped read it carries the generated summary and gives summary, notes and transcript whole,
  in pages (`Meetings::TextPage`, 40,000 characters, cut at a line break near the end):
  Claude Code cuts a tool answer above about 25,000 tokens without saying so. Without `part`
  each part's first page is a third of a page, so the three stay within one; `part` and
  `offset` read on, `next_offset` is null at the end. Offsets count code points, as Ruby's
  String does; a page may end inside a grapheme cluster, which the next one continues.
  `get_glossary` (K4c, MCP 0.18.0, `:mcp` only, the last tool, no assistant twin) reads an
  organisation's glossary through `Glossary::Lookup`, the reader of
  `GET /api/v1/organisations/:id/terms`. `scope_mode :token`; `Glossary::Lookup.for_token` is its
  gate: an organisation outside the token, a foreign, a missing and a malformed id are all
  `not_found`, as REST's one 404 (not `invalid_input` like the people twins: one reader, one
  reading of the id); a member deactivated in an organisation the token names is `refused`
  (`glossary_forbidden`), REST's 403. Then the tenant, the glossary right (`refused`, the same reason,
  REST's text) and `authorize!`. `project_id` is its own argument (it reorders, it does not narrow),
  so `project_filter?` stays false; an unknown argument is `invalid_input`. The bounds of `page` and
  `per_page` are the reader's, not the schema's (no `minimum`/`maximum`): the SDK would refuse a value
  ahead of the right and in its own English, where REST answers after the right in the owner's language.
  The types stay the schema's: a value of another type (`null` included) the SDK refuses before the
  tool, as it does for every tool; `2.0` passes as an integer, and the reader takes it as 2.
  On `:mcp` the same two names are twins (`McpFindPeople`, `McpGetPerson`, People S3b, MCP
  0.13.0), own classes because their schema requires `organisation_id` (E3). `scope_mode
  :token`; `PeopleTool.with_token_lookup` is their gate: only an organisation whose every
  project the token reaches (`People::Lookup.for_token`, `Reach#project_ids_for(id).nil?`, E1),
  else `not_found` with `list_notifications`' wording, for a project-limited token, an
  organisation outside the token and a deactivated member alike (the token no longer reaches
  it); then the call runs under that organisation's tenant, asks the people right (`refused`)
  and marks `authorize!(context, Person, :index?)`, which reads the tenant: a twin run without
  it is refused, not served. Same JSON as the assistant (`FindPeople.list`, `GetPerson.read`),
  no citations, never the notes (E2: only the REST card carries them). A person that is not
  there is `kind: empty` (the MCP rule for one record, like `get_ticket`); the assistant keeps
  its `not_found`. The SDK refuses an unknown `kind` before the tool runs (schema enum).
  Reichweite je Werkzeug (`Base.scope_mode`): `:project` (Default, Dispatcher injiziert
  `project_id` als Pflicht, ToolCall gated das Projekt) oder `:token` (Inbox-Arbeitsfluss:
  kein Projekt-Gate, `Context#reach` = `PersonalAccessToken::Reach`, läuft OHNE Tenant, nur
  im `:mcp`-Set, record-mode; `list_notifications`, `mark_notification_read`,
  `list_organisations`, `list_projects`, die Personen-Zwillinge, `get_meeting` und `get_glossary`,
  die sich den Tenant ihrer Organisation selbst setzen). Die Inbox-
  Zeilen kommen aus `Notifications::InboxQuery` + `Serializer`, geteilt mit der HTTP-API.
  Schreibende Werkzeuge gibt es nur im `:mcp`-Set: `create_ticket`, `post_comment`,
  `create_time_session`, `mark_notification_read`, `update_ticket`, `create_meeting`
  (token-scoped, setzt den Tenant selbst; Regel `Meetings::Intake`, dieselbe wie
  `POST /api/v1/organisations/:id/meetings`). `create_time_session`
  bucht über `TimeSessions::Booking`, dieselbe Regel wie die HTTP-API (seit 29.10.2026,
  REST R6); im Werkzeug bleiben nur Argumente, Rechte und die Texte. `post_comment` schreibt
  über `Actors::SavePost` wie das Web-Formular (Activity `post_added`, Benachrichtigungen,
  Embedding); ein nacktes `Post#save` löste bis zum 10.10.2026 nichts davon aus, in
  `Api::V1::PostsController` ebenso. `update_ticket`
  (Terminal-Client S2) ändert je Aufruf genau EINE Art (Titel, Status oder Zuweisung,
  entschieden nach vorhandenem Schlüssel) und baut keinen eigenen Schreibweg: Status und
  Zuweisung über `Actors::ApplyTicketChanges` wie Board und Kopfmenü, Titel über
  `Actors::SaveTicket` ohne `assignee_ids` (das ersetzt die Liste), unter Zeilensperre im
  Projekt (`SaveTicket` sucht organisationsweit und baut für eine fehlende ID ein NEUES
  Ticket). Unbekannte Argumente sind `invalid_input`. Die Regel, die Schreibwege und das
  Einordnen der Ergebnisse liegen seit REST R3b in `Tickets::Change`, geteilt mit
  `POST /api/v1/tickets/:id/changes`; im Werkzeug bleiben Argumente, Rechte, die Texte
  (`REFUSAL_TEXT`, `FAILURE_TEXT`) und die Reihenfolge der Antworten: erst Schlüssel und
  Kodierung (`unreadable?`), dann die eigene `ticket_id`, dann die Änderung
  (`update_ticket_order_spec.rb`). Schema bewusst flach, ohne `oneOf`:
  der Go-Client erkennt Funktionen nur an den obersten `properties`. Den Titel prüfen
  `create_ticket` und `Tickets::Change` gemeinsam (`tools/ticket_title.rb`): eine Zeile, höchstens
  255 Zeichen, unsichtbare und Steuerzeichen abgelehnt, nicht bereinigt.
  `post_comment` (MCP 0.11.0, terminal client S2b) takes optional `format`: `html`
  (default, unchanged ActionText input) or `plain`. `Posts::PlainTextBody` escapes
  literal text, normalizes CR and CRLF, drops blank lines at the edges, turns blank
  lines into paragraphs and single line breaks into `<br>`. Repeated spaces and
  indentation are stored but collapse in the web view; no Markdown. The rule is
  `Posts::Comment`'s since REST R3a, shared with `POST /api/v1/tickets/:ticket_id/posts`:
  invalid UTF-8 in either format and NUL in plain bodies are `invalid_input`, emptiness
  is decided on the converted text (a body of Unicode whitespace only is `body is
  required`). The tool keeps its own texts (`REFUSAL_TEXT`) and checks before the ticket
  lookup; model save failures stay `refused`, an unexpected one (`internal_error`) is
  `comment failed: unexpected error`, never the exception's text, unless it came after
  the commit: then the comment is written and the tool returns it.
  Zwei Formen: `record`-Werkzeuge liefern
  Zeilen und zitieren jede (Ticket-Werkzeuge), `report`-Werkzeuge liefern nur Zahlen und
  zitieren die Auswertung (`summarize_time_sessions`, Zitationstyp `time_report`). Ein
  Report prüft seine Rechte SELBST, wo die Area zu grob ist: Zeiten gehen durch
  `TimeSessions::ViewingScope` (eigene/alle), die Area `time_sessions` bleibt nur für den
  Riegel gesetzt (Plan `doc/persoenlicher_assistent_plan.md` §6.4, §13-9).
  `summarize_time_sessions` ist seit MCP 0.12.0 (Terminal-Client S6) auch im `:mcp`-Set,
  als letztes Werkzeug: Projektmodus (`project_id` Pflicht, die Naht prüft Projekt und
  Token-Reichweite), Rechte über `ViewingScope` im Werkzeug, Lesewerkzeug (auch für
  Nur-Lese-Token), keine Zitationen in der MCP-Antwort. Das org-weite Feld `project` steht
  dort mit im Schema, wird auf dem Projektpfad aber ignoriert. Spec:
  `spec/requests/api/mcp_time_report_spec.rb`. Org-weite
  Reichweite (S3a T3): `Context#scope` (`tools/scope.rb`, je Area über
  `accessible_project_ids`) ADDITIV zu `project` (R-M5, MCP unberührt), `Result#coverage`
  ist das L7-Deckungs-Vertragsfeld, mehrdeutige Ticketnummern antworten mit der geteilten
  Kandidatenliste (`tools/ticket_candidates.rb`, §9.2).
  `get_ticket` liest Seiten-Optionen und baut Kommentar-, Anhang- und Einzelseiten über
  `Tickets::Reading` (`app/services/tickets/reading.rb`, REST R1), denselben Service wie die
  REST-Ticketansicht. Im Werkzeug bleiben nur die MCP-Eigenheiten: Kappungen
  (`MAX_BODY_CHARS`, `MAX_FULL_TEXT_CHARS`, `MAX_ATTACHMENT_TEXT_CHARS`, Assistenten-Grenze),
  `full_text`, `post_id`, Zitationen. `posts_per_page` über 50 klemmt MCP auf 50
  (`over_max: :clamp`), REST lehnt mit 422 ab. Eine neue Seiten-Regel gehört in den Service,
  nicht in eine der beiden Hüllen.
  `search_knowledge` liest über `Knowledge::Lookup` (`app/services/knowledge/lookup.rb`,
  REST R2), denselben Service wie `GET /api/v1/projects/:project_id/knowledge`. Im Werkzeug
  bleiben `q` als Pflicht, die nachsichtigen Seiten-Optionen und die Zitationen.
  `list_organisations` and `list_projects` (MCP 0.15.0, `:mcp` only, the last two tools) name
  the ids the other tools take. `scope_mode :token`, reads for a read-only token as well. Both
  read through `PersonalAccessTokens::ReachListing`, the reader of `GET /api/v1/organisations`
  and `/projects`, so a new rule of the reach belongs there. `list_projects` keeps what is the
  tool's: archived projects only with `include_archived`, `not_found` for an organisation out
  of reach (REST answers 200 with `[]`), `per_page` of at most 100 clamped, a description cut
  after 500 characters. Not `ProjectPolicy#index?`: it refuses an active member without a
  project, who gets an empty list, so `Base.scoped_by_policy!` marks the decision of the policy
  scope. Every listed id passes the gate of `Mcp::ToolCall`: `openable_only`, which reads
  `ProjectAccessService.openable_project_ids`, because the policy scope alone is wider (a role
  holding nothing but time tracking sees projects there and opens none). Held over every role
  key in `spec/services/personal_access_tokens/reach_listing_spec.rb`, walked through the real
  gate in `spec/requests/api/mcp_list_projects_spec.rb`.
  Fehler eines Werkzeugs tragen eine Klasse: `Result.invalid_input(msg)` oder
  `Result.refused(msg, reason:)`; ohne Code gilt `refused`, auch für ein abgelehntes Speichern
  (Modellvalidierung, Actor-Fehler): das beweist keine falsche Eingabe. Spec je Fehlerstelle:
  `spec/requests/api/mcp_result_codes_spec.rb`. `Mcp::ToolCall` legt sie als
  Maschinenfeld in `_meta` (`lalabase/kind` bzw. `lalabase/code` + `lalabase/reason`), für
  „fehlt“ und „fremd“ gleich (`not_found`). `kind: empty` heißt „der Aufruf fand nichts“:
  bei Werkzeugen für einen Datensatz „nicht gefunden“, bei den Code-Suchen „keine Treffer“;
  Listen (`list_tickets`, `search_knowledge`, `list_notifications`) antworten leer mit `ok`
  und `data: []`. Wer das `:mcp`-Set ändert, erneuert den Vertrag
  `spec/fixtures/mcp_contract.json` mit `RAILS_ENV=test bin/rails mcp:contract` und hebt
  `Mcp::Dispatcher::SERVER_VERSION` (Minor); die Vertrags-Spec vergleicht nur.
  The seam answers some errors itself, before any tool runs, in this order: `project_id`
  missing (`invalid_input`), a project out of reach (`not_found`), a write over a read-only
  token (`read_only`), then (MCP 0.13.1) an `idempotency_key` the store cannot hold: more
  than 255 bytes, no valid UTF-8 or a NUL (`invalid_input`). The key is remembered only
  after the write, so such a key used to write, fail with -32603 and write again on the
  retry. The rule is `Mcp::IdempotencyStore`'s, shared with the REST header; a read tool is
  not offered the key and ignores it. Guard: `spec/requests/api/mcp_idempotency_key_bound_spec.rb`.
* `indexer/` — Codebase-Indizierung (befüllt `project_index`, `code_symbol`, `fragment`)
* `project_rag/` — Retrieval für projektbezogene Chats; org-Threads (S3a T3) nur
  Content-Schicht über `Fragment.for_context_map` (je Area verengte Projektmenge)
* `github/` — Repo-Anbindung (Import-only, kein laufender Sync)
* `fence_guard.rb` — Markdown-Fence-Breakout-Neutralisierung (Prompt-Injection-Schutz;
  Spec: `spec/services/lalabase/fence_guard_spec.rb`)
* `llm/vertex_availability_probe.rb` — Admin-Diagnose: Vertex-Modell-Verfügbarkeit
  (Region×Modell) via kostenlosem `:countTokens`; teilt Auth/Endpoint-Klassenmethoden mit
  `GoogleVertexProvider`. Bewusst KEIN Quota-Seam (keine Inferenz, keine Org, keine
  Tenant-Inhalte) und KEIN Actor (reiner Read); `Rails.cache` statt Migration.
* `query_embedding.rb`, `repo_scope.rb`, `language_detector.rb`, `languages.rb`, `citations.rb`

Wichtig:
1. **Neue KI-Aufrufer müssen durch den Kontingent-Seam** (Metering/Quota) — Vertrag in
   `doc/ki_sourcing_kontingent_plan.md`. Ohne Metering läuft der Verbrauch an der Abrechnung vorbei.
2. Embedding-Modell nie hardcoden — Provider über die Factory auflösen (Guard:
   `spec/services/embedding_provider_hardcode_guard_spec.rb`).
3. **Chat-Provider nie pinnen** — die Auflösung folgt der Anbieter-Wahl der Organisation,
   und neuer Code fragt sie über `Factory.for_feature(:key, org)` (seit R6 der Weg JEDES
   registrierten Seams; das rohe `for_chat` gehört allein dem Verbindungstest, s. u.);
   `Factory.build(provider_name: …)` überschreibt die Wahl. Die Wahl ist eine
   DSGVO-Aussage (welcher Rechtsraum sieht die Daten?), keine Vorliebe. Guard:
   `spec/services/lalabase/llm/provider_pin_guard_spec.rb` mit shrink-only-Allowlist —
   die **seit R3 (2026-08-02) LEER** ist. Er kennt drei
   Türen: `Factory.build`, `PROVIDER_CLASSES` und `<X>Provider.new` (Allowlist von
   Tür 1 und 3 leer, Tür 2 nur die Factory selbst + zwei Credential-Concerns).
   Der eine verbliebene Pin (P5, `gpt-5-nano` ist ein Reasoning-Modell mit eigenem
   Wire-Dialekt) steht nicht mehr im Service, sondern als `pin:`/`pin_reason:` in der
   Registry-Zeile `:customer_description`; der Seam baut ihn über sein eigenes,
   nacktes `build(...)`, das Tür 1 nicht trifft. Wer wirklich pinnen muss, schreibt
   ihn dorthin — **der Pin ist damit automatisch mit einer Absage gepaart**, weil das
   Gate dieselbe Zeile liest. Vorher war das Disziplin und ging dreimal in einer Woche
   schief. Plan: `doc/ki_provider_reichweite_plan.md`.
   **Gate und Routing lesen dieselbe Registry-Zeile** (`llm/feature_registry.rb`,
   12 Einträge — je eine Routing-Entscheidung, Plan `doc/ai_feature_registry_plan.md`).
   Seit R3 gilt das nicht mehr nur theoretisch (erster Produktivaufrufer:
   `CustomerDescriptionGenerator`), und seit **KI-Pakete P3 (2026-08-02) routen
   sechs weitere Seams über `Factory.for_feature`**: `TicketSummaryService`,
   `SummaryProcessingService`, `Meetings::ParticipantDetectionService`,
   `ProjectIndexerJob` (Chat-Hälfte, `lane: :chat`) und — über EINE Zeile in
   `Meetings::BaseLlmService` — die drei Meetings-Unterklassen, die dafür je einen
   `#feature_key` deklarieren. **Seit R6 routet JEDER registrierte Seam über seinen
   Key** — auch `ChatResponseJob` (`:chat`), `Actors::CreateAiPost` (`:ask_ai_post`),
   `EmbeddingProcessingService` (`:content_indexing`), `Lalabase::QueryEmbedding`
   (`:semantic_search`) und die Embedding-Hälfte in `Indexer::JobSupport`
   (`:repository_indexing, lane: :embedding`). Die rohen Lanes bleiben genau zwei
   Aufrufern: dem Verbindungstest (`for_chat`, kein Feature) und dem
   `OrganisationReindexer` (`for_embeddings`, muss laufen, wenn Feature-Gates nein
   sagen). Ein neuer Pin gehört in die Registry, nie in einen Service.
   * **`utility: true` an einer Registry-Zeile** (P3, `doc/ki_pakete_plan.md` §2.1):
     Hilfspfade nehmen die UNTERSTE Paketstufe statt der von der Org gewählten —
     eine Code-Eigenschaft des Pfads, keine Kundeneinstellung, und **keine
     Provider-Aussage** (E7): das Paket und damit der Rechtsraum bleiben, nur das
     Modell darin wird billiger. Fünf Zeilen tragen sie (`ticket_summary`,
     `document_summary`, `meeting_participant_detection`,
     `meeting_ticket_suggestions`, `repository_indexing`). Bei `kind: custom` /
     `ai_package_id IS NULL` gibt es keine Staffel — dort ändert das Flag nichts.
     Die Stufe reist als `utility:`-Kwarg durch `chat_provider_name` /
     `curated_chat_credential` / `resolve_credentials` **und durch
     `has_valid_ai_configuration?`**: zwei Stufen können auf verschiedenen Providern
     liegen, ein Gate ohne den Kwarg beurteilt also eine andere Zeile als die
     Anfrage nutzt. `pin:` + `utility:` an derselben Zeile wirft beim LADEN
     (widersprüchlich, keine definierte Vorrangregel).
   * **`organisation.ai_available_for?(:feature_key)` ist DER Weg für ein Gate** und der
     einzige, der auch den Grund benennen kann (`Availability`: `available?`, `reason`,
     `required_provider`, `lane`). Gegenstück beim Routing:
     `Factory.for_feature(:feature_key, org)`. Ein Tippfehler im Key wirft `KeyError` —
     ein Gate darf nie „nicht verfügbar" antworten, weil der Key falsch war.
   * **Der Absage-TEXT hat genau eine Quelle**: `FeatureRegistry.unavailable_hint(availability, org)`
     (R3). Mappt `reason` → `shared.ai.unavailable.<reason>`, interpoliert Anzeigenamen
     statt Routing-Keys, und beantwortet `:ai_disabled` mit der kanonischen
     `shared.ai.disabled_member_hint` (E4: wiederverwenden, nicht forken). Aufrufer
     entscheiden nur, WELCHE Gründe sie erklären — die View bei `:customer_description`
     z. B. nur `:pinned_elsewhere`, weil der Pin-Text einen Admin mit bloß fehlendem
     Credential auf die falsche Seite schicken würde. Kein `t('shared.ai.unavailable.…')`
     von Hand.
   * `ai_configured_for_chat?` (nur Konfiguration) **gibt es nicht mehr** (P3): das
     Prädikat leitete die Stufe der ORG ab, seine vier Aufrufer
     (`TicketSummaryService` + die drei Zusammenfassungs-Einstiege in
     `tickets/_ticket_content_for_frame`) routen aber auf der UTILITY-Stufe — bei
     zwei Stufen auf zwei Credentials antwortete es also über ein Credential, das
     die Anfrage nie anfasst (in beide Richtungen falsch). Alle vier fragen jetzt
     `ai_available_for?(:ticket_summary)`. Wer wie dieser Service **zwei Zustände
     auseinanderhalten** muss, mappt sie aus `availability.reason` (dort:
     `TicketSummaryService#unavailable_status` — `:ai_disabled` behält seine eigene
     Oberfläche, jeder andere Grund teilt sich das Setup-Modal). Die Regel dahinter:
     wie viele Zustände eine Oberfläche darstellen kann, weiß nur sie selbst.
   * `ai_available_pinned?`/`ai_pinned_elsewhere?` (S4-Paar) **gibt es nicht mehr** (R3):
     beide Fragen sind der Grund `:pinned_elsewhere` bzw. `:no_credential` an EINER
     Antwort. Die Registry fragt den Pin VOR dem Credential — genau die Unterscheidung,
     für die das Paar zwei Prädikate brauchte.
   * `ai_available?(provider)` hat seit R3 **keinen Produktivaufrufer mehr** (der letzte
     war das S4-Paar). Bleibt als Low-Level-API und Vergleichsseite der Äquivalenz-Matrix
     (`spec/models/organisation_ai_availability_spec.rb`) — E3. Kein Gate baut mehr darauf.
   * **R5-Guards (2026-08-03, `feature_registry_guard_spec.rb`)**: Guard A —
     `Factory.for_chat`/`for_embeddings` nur in der Datei-Allowlist (die Factory selbst
     ruft nackt, braucht keinen Eintrag); Guard B — jede `seam:`-Zeile existiert und routet
     wirklich; Routing außerhalb der eigenen Seam-Datei zählt NUR über die begründete
     Ancestor-Liste (`BaseLlmService`, `JobSupport`) — pauschale Vererbung wäre ein
     Freifahrtschein für Basisklassen wie `application_job`; jede routende Datei ist Seam
     oder steht mit Begründung in `FeatureRegistry::EXCLUDED_CALLERS`
     (`embedding_space_for` in `UNGATED_RESOLUTIONS`, Plan §7.5); Guard C — nichts
     außerhalb seiner zwei Besitzer (`organisation.rb` definiert, `feature_registry.rb`
     konsumiert) ruft die Low-Level-Prädikate; die Oberflächen-Allowlist bleibt zusätzlich
     leer per Plan E3 (die zwei lokalen Controller-Methoden heißen deshalb
     `ai_feature_available?`). Alle drei + `provider_pin_guard` + `action_registry_guard`
     laufen seit R5 in der CI (`guards.yml`).
     **Vier Dinge, die ein Anwesenheits-Guard NICHT sieht** und die deshalb eigene
     Prüfungen haben (Review-Nachzug 2026-08-03): Guards A und B scannen **auch
     Templates** — mit `.rb`-only-Glob blieb ein `Factory.for_chat` in einer View grün;
     die Muster kennen **`Factory::for_chat`** (legales Ruby, heute null Aufrufstellen —
     also ein stilles Loch); Guard B prüft nicht nur DASS eine Seam routet, sondern
     **auf WELCHER Zeile**: der literale Key an der Aufrufstelle bzw. das `#feature_key`,
     das die geerbte Aufrufstelle in `BaseLlmService` liest, muss die eigene Registry-Zeile
     sein (ohne das durfte eine Meetings-Unterklasse auf einer fremden Zeile routen,
     während ihr Gate die richtige fragte); und **alle vier Ausnahmelisten tragen
     `calls:`** (die zwei Lane-Allowlists, `EXCLUDED_CALLERS`, `seam_routing_ancestors`) —
     eine Ausnahme entschuldigt eine DATEI, ohne Zahl sammelt diese Datei beliebig viele
     weitere Aufrufe unter derselben Begründung. Alle Zähler stehen heute auf 1; eine
     Änderung ist ein Diff, den jemand liest.
   * `ai_available_for_chat?` **gibt es nicht mehr** (R2, 2026-08-02): seine 11 Aufrufer
     fragen jetzt ihren eigenen Feature-Key. Heute antworten alle ungepinnten Chat-Features
     identisch — der Key ist also Semantik-Dokumentation, bis Pakete/R3 sie auseinander
     laufen lassen. **Ein falscher Key ist damit in Produktion unsichtbar**, weshalb jede
     der 11 Stellen einen eigenen Mutations-Guard trägt: ein Spec, das genau EINE
     Registry-Zeile absagt und eine zweite unberührt lässt. Vollständig gemessen —
     jede der 11 Stellen auf einen fremden Key verstellt bricht mindestens ein Beispiel:
     `meetings_spec` („feature keys (R2)"), `meeting_analyses_spec` /
     `meeting_ticket_suggestions_spec` (key-scoped `stub_ai_availability` —
     **niemals ohne `with`**, ein Blanket-Stub antwortet für jeden Key und macht die
     Datei blind), `meeting_detect_participants_spec` („feature key (R2)"),
     `ai_surface_gating_spec`, `user_preferences_spec`.
4. Das `ai_enabled`-Gate der Organisation gilt für JEDEN LLM-Call — kein Aufruf ohne Opt-in.
   **Eine bewusste Ausnahme, nicht „vergessen":** `Llm::Factory.embedding_space_for(org)`
   (embedding v2 PR 4b) löst NUR das Vektorraum-Tripel für einen LOKALEN DB-Read auf
   (`Embeddings::NearestNeighbors`) — kein Daten-Egress, keine API-Kosten. Deshalb ohne
   `ai_enabled`- und Quota-Gate: eine erschöpfte Quota darf die Suche nicht abschalten.
   Gepinnt in `spec/services/lalabase/llm/factory_spec.rb`; `for_embeddings` (Schreibpfad)
   bleibt unverändert gated.
4. **`space:` ist Pflicht-Kwarg** an `for_embeddings` und `embedding_space_for` (v2 PR 6a):
   `:configured` = wohin NEUE Embeddings gehen, `:active` = welcher Raum die Suche bedient.
   Bewusst ohne Default — beide möglichen Defaults hätten einen STILLEN Fehlmodus, der
   `ArgumentError` hat keinen. Reads (`QueryEmbedding`, `NearestNeighbors`,
   `PowerSearchService`, `SpaceAlignment`) nehmen `:active`, Schreib-/Build-Pfade
   `:configured`.
5. **`model:` beim Embed-Call ist tragend, nicht Deko** (v2 PR 6a): `OpenAiProvider` und
   `GoogleVertexProvider` beantworten `#default_embedding_model` aus einer KONSTANTEN und
   ignorieren das konfigurierte Modell (bei Vertex Absicht — dort ist `default_model` das
   CHAT-Modell). Wer einen Raum bedient, dessen Modell ≠ Konstante ist, MUSS das Modell
   explizit durchreichen, sonst kommen die Vektoren still aus dem falschen Modell.
   Betrifft `QueryEmbedding.embed` und `OrganisationReindexer#reembed_batch`.
6. **Der gemessene Embed-Pfad ist der einzige** (KI-Pakete P4a+): `#embed` delegiert an
   `#embed_with_usage`, `#embed_batch` an `#embed_batch_with_usage` — je EIN Call-Site pro
   Form, damit ein ungemessener Aufrufer nicht am Zähler vorbeirouten kann. `OpenAiProvider`
   implementiert die Batch-Variante echt (liest `response['usage']`), die Basisklasse fällt
   auf `texts.map { embed_with_usage }` zurück — der Vertex-Pfad (ein `:predict` pro Text).
   Gebucht wird EINE `AiUsage`-Zeile pro Lauf, nicht pro Batch (`UsageTracking`).
   ⚠️ `Indexer::SymbolPersistence` nutzt weiterhin `embed_batch` und bucht NICHTS — bekannte
   Altlast, nicht von P4a berührt.
7. **`max_tokens` ist das Budget der ANTWORT** (seit 2026-10-26). Ein Modell, das vorher
   denkt, bekommt die Reserve im Provider obendrauf: `GoogleVertexProvider::THINKING_BUDGET`
   für Gemini 2.5 Flash und Pro (`thinkingConfig` + `maxOutputTokens`),
   `OpenAiProvider::REASONING_RESERVE` für gpt-5 und die o-Reihe (`max_completion_tokens`).
   Ohne Reserve zählten die Denk-Tokens gegen das Limit, und von einer kurzen Antwort blieb
   fast nichts übrig. Ein Aufrufer rechnet nie selbst eine Reserve ein; Anbieter-Felder
   (etwa `reasoning_effort`) schickt nur ein Seam mit Registry-Pin (`:customer_description`).
   Endet eine Antwort am Limit (`stop_reason 'length'`), ist sie abgeschnitten:
   `Meetings::BaseLlmService` meldet dann den Fehler `truncated` statt den Teiltext zu
   speichern. Kam vor dem Limit gar kein Text, werfen OpenAI, Vertex und Anthropic
   `Provider::TruncatedError` (eine Unterklasse von `Provider::Error`, mit dem Ergebnis samt
   Verbrauch); `BaseLlmService` bucht ihn und meldet ebenfalls `truncated`. Lehnt der
   Anbieter die Anfrage ab (400, etwa ein Modell mit kleinerem Ausgabe-Limit als die
   8.000 Tokens der Analyse oder ein zu kleines Kontextfenster), werfen OpenAI, Vertex und
   Anthropic `Provider::RequestRefusedError`; `BaseLlmService` meldet `request_refused`
   bzw. bei eigenem Zugang `request_refused_own_access`, nie „später erneut versuchen“. ⚠️ Der Assistent
   (`Tools::Runner`) und die Teilnehmer-Erkennung werten `'length'` noch nicht aus.
