# Karte: app/models (Stand: 2026-11-08)

~80 Modelle liegen flach in diesem Verzeichnis; Namespaces existieren nur für `admin/`,
`knowledge/`, `overview/`, `smart_folders/`, `time_sessions/`, `user/`. Die Domänen-Zugehörigkeit ist am
Verzeichnis-Layout nicht ablesbar — diese Karte gruppiert sie:

* **Kern/Tenancy**: `organisation` (= Tenant), `project`, `user` (+ `user/*` — Split-Vertrag
  in den Kommentaren von `user.rb`, **Include-Reihenfolge ist load-bearing!**;
  Namens-Rendering hat EINEN Owner: `user/name_display.rb`; welche E-Mail andere sehen
  (Login-Adresse, Kontakt-Adresse oder keine, `email_visibility`) EINEN Owner:
  `user/email_display.rb` (`#shown_email`, `.matching_shown_email`), Wächter
  `spec/architecture/shown_email_guard_spec.rb` gegen ein rohes Mitglieds-`.email`; Anmeldung,
  Mails und `/admin` behalten `email`), `membership`,
  `role`, `permission`, `project_permission`, `invitation`, `account` (Billing-Ebene ÜBER Orgs),
  `current` (`Current.user` = Audit-Actor der Activity-Kette)
* **Tickets**: `ticket`, `ticket_assignment`, `ticket_attribute_definition`, `ticket_document`,
  `tag`, `tagging`, `ticket_relation` (typisierte Beziehung zweier Tickets einer Organisation,
  `doc/ticket_relations_plan.md`: EINE Zeile je Beziehung, „blockiert von“/„folgt auf“ sind
  dieselbe Zeile vom Ziel aus, `KINDS` bildet sieben Beschriftungen auf vier Arten ab; Enum-Zahlen
  fest, zwei Guards vergleichen sie mit Index und CHECK; kein Trackable, kein Verlauf).
  ⚠️ „Wartet“ und „hält auf“ beantwortet NUR `Tickets::Waiting`, „erledigt“ je eigenem Projekt
  an beiden Enden (`closed_status_values_by_project`, nicht der Topf `closed_status_values_for`);
  Handbauten lehnt `spec/architecture/ticket_waiting_owner_guard_spec.rb` ab. Liste, Kanban und
  Handy zählen je Seite über `Tickets::WaitingCountsCache`. Wie Subs und Zeiten meldet eine Liste
  nur ihre Seite an (`TicketsHelper#register_ticket_count_page`), der erste Lesezugriff lädt sie
  (`Tickets::LazyPagePreload`, per `prepend`). Ein neuer Zähler: Modul voranstellen,
  `answered?` bereitstellen, `preload` beantwortet jedes übergebene Ticket, eine Zeile in
  `register_ticket_count_page`, ein Eintrag in `builders` der Modul-Spec; braucht er einen
  Leser, bekommt er ihn beim Bauen (`new(user:)`). Keine View lädt von Hand vor. Die Spalte
  `waiting` steht bewusst NICHT in `ViewConfiguration::CHILDREN_COLUMN_KEYS` (andere Zeilen
  stimmen erst beim Neuladen). Als Regel einer Ansicht: `smart_folders/filters/waiting_state_filter.rb`
  (IS/IS_NOT × true/false, `wants_state?` liest auch der Dissolver), Felder `waiting`/`blocking`.
  Anlegen/Löschen nur über `Actors::CreateTicketRelation`/`DestroyTicketRelation`
  (Kreis-Prüfung unter Sperre je Org).
  ⚠️ Wer einem Ticket NEU ZUGEWIESEN werden (oder ihm folgen) darf, entscheidet nur
  `Project#assignable_users`: Ticket-Leserecht im Projekt UND aktive Mitgliedschaft. Formular,
  Kopfmenü, Board, Sammelbearbeitung, MCP und die Beobachter-Auswahl lesen es;
  `users_with_access` allein kennt deaktivierte Mitglieder noch (es entscheidet auch
  Benachrichtigungen und was ein Verschieben behält, darum nicht dort). Wer schon zugewiesen
  ist, bleibt es (`Ticket#assignable_user_ids`): sonst entfernt jedes Speichern im Formular
  eine deaktivierte Person still, und das Board lehnt jede weitere Zuweisung ab. „Bleibt" heißt
  nur Behalten: ein erneutes `add` einer nicht mehr zuweisbaren Person ist `value_not_allowed`.
  Entfernen darf eine Änderung jede Person der Organisation und jede, die auf den Tickets der
  Änderung zugewiesen ist oder ein Abo hat, auch nach gelöschter Mitgliedschaft
  (`BulkFields::Field#removable`, erst bei Bedarf gelesen: ein Status-Zug zahlt nichts dafür).
  Ein Rückgängig nimmt die Personen seines Laufs an, legt aber nicht mehr Zuweisbare nicht
  zurück (`AddRemoveBase#restorable`); der Rest des Tickets wird zurückgesetzt.
  Titel: höchstens `Ticket::TITLE_MAX_LENGTH` (255), geprüft nur bei geändertem Titel.
  Unteraufgaben (seit 31.10.2026 in beliebiger Tiefe): die Eltern liegen im selben Projekt und
  stehen nach dem Anlegen fest (`Ticket#parent_unchanged`), darum kein Kreis. Vorfahren liest
  nur `Tickets::Ancestry`. Fortschritt und Spalte „Subs“ zählen nur direkte Kinder; ein
  Ticket in einem Baum lehnt `Tickets::Mover` weiter ab.
  ⚠️ Wer eine Beziehung SEHEN darf, entscheidet nur `TicketRelation.visible_to(user, org, token:)`:
  beide Enden lesbar (`TicketPolicy::Scope`), mit Token zusätzlich in dessen Reichweite. Titel,
  Nummer und Projekt eines Tickets ohne Leserecht erscheinen nirgends (Plan §4).
* **Personen** (seit 26.10.2026): `person` (eine gemeinsame Personenliste je Organisation,
  Tabelle `people`), `person_name` (der EINE Namens-Normalisierer, auch für
  `MeetingParticipant.normalize_name`). Eine Zeile ist ein Kontakt ohne Konto oder die
  Zusatzangaben eines Mitglieds (`user_id`, nur aktive Mitglieder derselben Org, eindeutig
  je Org); `name` ist immer gefüllt. Eigenes Recht (`Permission::CATEGORIES[:people]`,
  `view_people`/`manage_people`, gastrollen-tauglich), Kontoadmins ohne Zeile; die Policy
  prüft die aktive Mitgliedschaft selbst. Lesen über `People::Directory`, Schreiben über
  `Actors::SavePerson`/`DestroyPerson`.
  Sichtbarkeit (Review von S1, 28.10.2026): Die Zeile eines Mitglieds, das der Leser auf der
  Mitgliederseite nicht sieht, bleibt versteckt, auch wenn die Mitgliedschaft nur deaktiviert ist
  (`PersonPolicy::Scope`). Erst nach dem Entfernen ist sie ein Kontakt für alle mit dem Recht.
  Name, E-Mail und Verknüpfung der Zeile eines aktiven Mitglieds gehören dem Konto: `SavePerson`
  nimmt sie aus keiner Anfrage (`ACCOUNT_FIELDS`). Bei einem deaktivierten Mitglied bleibt nur
  die Verknüpfung fest (`LINK_FIELDS`, kein Mitglieder-Select im Formular), Name und E-Mail
  der Zeile bleiben ihre eigenen. Beide fragen `Person#stored_membership`. „Bearbeiten schließt Ansehen ein“ steht einmal
  in `Permission::IMPLIED_BY` (gelesen von `PersonPolicy` und `RolePolicy#change_permission?`).
  ⚠️ `concerns/person_trackable.rb`: Aktivitäten tragen KEINE Personendaten (leere Parameter,
  bei Änderungen nur Feldnamen), `skip_notifications` immer; ein Löschen hinterlässt genau eine
  anonyme `person.deleted`-Zeile. ⚠️ `concerns/person_link_release.rb` steht in `membership`
  UND `admin/membership`: wer eine Mitgliedschaft entfernt, behält die Zeile und verliert nur
  die Verknüpfung. Darum läuft `erase_personal_data!` in beiden Löschwegen VOR
  `memberships.destroy_all`; andersherum findet `erase_person_links!` nichts mehr.
  Seit S2a (26.10.2026) zeigt `meeting_participant.person_id` (FK, nullt beim Löschen der
  Person) auf eine Zeile; `belongs_to :person` steht VOR `acts_as_tenant`, eine Validierung
  hält die Person in derselben Org. Ein Mitglied läuft weiter über `user_id`. Meetings und
  „Letzter Kontakt“ einer Person liest nur `People::Contacts` (`app/services/CLAUDE.md`).
  Seit S2b (27.10.2026) setzt `person_id` nur `Actors::LinkMeetingParticipant` (Dialog an
  den Teilnehmer-Chips, `MeetingParticipantLinksController`): EIN Schlüssel je Teilnehmer,
  ein Mitglied über `user_id`, ein Kontakt (auch die Zeile eines deaktivierten Mitglieds)
  über `person_id`. Die Regel steht dreifach fest: Validierung `one_key`, Check-Constraint
  `meeting_participants_one_key` (fängt auch `update_all`), und jeder Schreiber leert den
  anderen Schlüssel selbst. Der Teilnehmer eines Mitglieds, dessen Mitgliedschaft entfernt
  ist, ist wieder ein Name: der Dialog verknüpft ihn als Kontakt und leert die `user_id`.
  Wer über ein Konto verknüpft ist, entscheidet EINE Stelle (`Meetings::AccountParticipants`):
  Mitglied per `user_id` (aktiv oder nicht) oder Kontakt, dessen Zeile inzwischen einem
  aktiven Mitglied gehört; den lässt der Dialog in Ruhe. Der Actor sperrt das Meeting
  (`lock_in_project!`) und löst Person und Mitglied nur über `People::Directory` des
  Schreibenden auf. Das Meeting-Formular kennt `person_id` nicht; `SaveMeeting` behält die
  Zeile und damit den Link. Macht das Formular eine Kontakt-Zeile zu der eines Mitglieds,
  fällt `person_id` weg, und das Zuordnen (Scope `external`) lässt Kontakt-Zeilen aus.
  Reihenfolge der Chip-Zeile: Scope `in_row_order` (Seite, Panel und Neuzeichnen).
  Seit 28.10.2026 trägt eine Person bis zu 10 **weitere Angaben** (`people.additional_details`,
  JSONB-Liste aus `kind`/`label`/`value`). Die Regel hat EINEN Besitzer: `person_detail`
  (kein AR-Modell): Arten, Grenzen, Normalisierung, Prüfung, Link (`#href`, nur http(s)) und
  Suchwerte (nur Werte, nie Bezeichnungen). Formular (Arten, Eingabetyp, `MAX`), Bahn, Suche und
  Export fragen dort; der Stimulus-Controller bekommt Arten und Grenze als Values. Das Formular
  schickt immer `person[additional_details][sent]` mit (`FORM_MARKER`): ohne ihn ließe das
  Entfernen der letzten Angabe die Liste stehen. Fehlt der Key ganz, bleibt die Liste
  unberührt. Check-Constraint `people_additional_details_shape` hält Liste und Grenze.
* **Glossar** (K4a, 04.11.2026): `glossary_term` (ein Begriff je Organisation, nicht je Projekt;
  eindeutig nach `normalized_term`, Status `proposed`/`confirmed`/`rejected`), `term_correction`
  (eine gehörte Form je Korrektur: Sprecher als Person ODER Mitglied, Check
  `term_corrections_one_speaker`; Projekt als Herkunft; Stelle im Transkript), `glossary_text`
  (der EINE Normalisierer: unsichtbare Zeichen raus, NFC, Leerraum, klein, bewusst OHNE die
  Umlaut-Umschrift von `PersonName`). `glossary_term` hat `lock_version` wie `person`: ein
  Formular über eine fremde Änderung hinweg wird abgelehnt (`:stale_object`). Verweise auf Zeilen
  einer Organisation stehen VOR `acts_as_tenant` und werden zusätzlich ohne Mandanten-Scope
  geprüft (`same_organisation_references`). Eigenes Recht
  (`Permission::CATEGORIES[:glossary]`, `view_glossary`/`manage_glossary`, gastrollen-tauglich),
  Kontoadmins ohne Zeile; `GlossaryPolicy` für beide Modelle (seit K5b auch Lauf und Vorschlag, `policy_class`). Schreiben nur über
  die Glossar-Actors. ⚠️ Ein gelöschtes Meeting lässt seine gehörten Formen samt Stelle stehen, nur
  `meeting_id` wird leer (FK `on_delete: :nullify`, Ausnahme E4, Kommentar an
  `Meeting#purge_fragment_content_embeddings`); nie auf `cascade` stellen. Die Kontolöschung leert
  nur den Sprecher (`erase_term_correction_speakers!`).
  K4b (05.11.2026): JEDE gehörte Form hat einen eigenen Status (`term_corrections.status`,
  `proposed`/`confirmed`, Check `term_corrections_status_known`, Altbestand `confirmed`). Ohne
  `manage_glossary` entsteht sie als Vorschlag, auch an einem bestätigten Begriff. Wirksam ist
  nur `TermCorrection.effective` (bestätigte Form an bestätigtem Begriff): K4c und das Gerät lesen
  dort, nie `term_corrections` direkt. K4c (06.11.2026): dieser Leser ist `Glossary::Lookup`
  (REST `/terms` und MCP `get_glossary`, Karte `app/services/CLAUDE.md`). K4d (08.11.2026):
  `term_application` hält, was ein Gerät beim Senden eines Meetings aus dem Glossar ersetzt hat
  (gehörte Schreibung, Begriff als Text, Zahl; `source` `device`), geschrieben nur von
  `Meetings::Intake` über `TermApplication.record!` (zwei Statements, in der Transaktion des
  Meetings; Feld `meeting[glossary_replacements]`, Fähigkeit `meetings.glossary_replacements`).
  Keine Korrektur: nichts wird gelernt, `.effective` sieht die Zeilen nie. Anders als
  `term_corrections` gehen sie MIT dem Meeting (FK `cascade`, `dependent: :delete_all`); ein
  gelöschter Begriff lässt sie mit seinem Text stehen (`nullify`), ein Merge nimmt sie mit.
  Anzeige: Meetingseite über dem Transkript (`_glossary_applied`), Glossar unter der gehörten
  Form (`_application`), Schreibweise am Kopf des Begriffs. ⚠️ `Meeting#invalidate_stale_summary` hat GENAU EINE
  Ausnahme: `keep_summary_for_next_save!` (eine Speicherung, eine Instanz), gesetzt nur von
  `Actors::SaveMeeting` mit `keep_summary: true`, das nur `Actors::CorrectMeetingTerm` übergibt
  (Wächter `spec/architecture/meeting_summary_exception_guard_spec.rb`). Nicht über
  „`generated_summary` mitschreiben“ lösen: ohne Treffer ändert sie sich nicht und ginge trotzdem.
  K5b (08.11.2026, Extraktion): `GlossaryText.compact` ist der Schlüssel, der die Schreibweisen
  eines Begriffs gruppiert (ohne Leerraum und Bindestriche), nie ein gespeicherter Begriff.
  `glossary_extraction_run`: höchstens EIN aktiver Lauf je Organisation (partieller Unique-Index
  `one_active_glossary_extraction_run`), `stale?` nach `STALE_AFTER`, `mark_failed!` ist EIN
  `update_all` unter der Status-Bedingung; die Formen von `scope` und `stats` stehen im Kopf der
  Datei. `glossary_proposal`: einer je `normalized_term` und Organisation, `variants` als
  JSONB-Liste mit Check-Constraint, Status `open`/`accepted`/`dismissed`. `hint_sources` hält
  unabhängig von den Beispielstellen die Quellarten und IDs aller an den Modellaufruf
  gesendeten Ausschnitte, auch verworfener Kandidaten. Ohne diese Herkunft bleibt der Hinweis
  verborgen; `hint_source_references` lehnt auch teilweise fehlerhafte Herkunft vollständig ab.
  `glossary_proposal_source`: polymorph OHNE Fremdschlüssel; eine gelöschte Quelle lässt die Zeile
  stehen, die Seite fragt beim Rendern, ob sie noch da und für den Leser lesbar ist
  (`GlossaryHelper#glossary_source_access`); beim Schreiben muss die Quelle zur Organisation
  gehören. Die Datenbank löscht: Organisation und Vorschlag kaskadieren, Lauf, Begriff, Projekt und
  Konto leeren nur den Verweis. `GlossaryPolicy` für alle vier Modelle (Begriff, gehörte Form,
  Lauf, Vorschlag). `term_corrections.origin` (`meeting`/`extraction`/`import`, Check-Constraint,
  Altbestand `meeting`); `.effective` liest es nicht.
* **Activity/Notifications**: `activity`, `user_activity`, `outbox_event`, `notification`,
  `notification_preference`, `notification_subscription`, `email_log` — Services dazu unter
  `app/services/notifications/` (eigene Karte dort)
* **Ansichten/SmartFolders**: `smart_folder{,_rule,_rule_group,_share}`, `view_configuration`,
  `view_state`, `dashboard_configuration`, `overview_configuration` (+ `smart_folders/`, `overview/`)
* **Zeiterfassung**: `time_session`, `time_session_group`, `time_session_permission`
  (+ `time_sessions/`: `list_period`, der EINE Besitzer der acht Zeitraum-Keys:
  Reihenfolge, Labels und Fenster für die Filterzeile UND die Statustabelle. Die vier mit
  `overview/time_period` geteilten Fenster werden dorthin delegiert, als `KEYS &
  Overview::TimePeriod::KEYS`, damit ein Widget-Drilldown seine Zahl reproduziert.
  ⚠️ Liste und Tabelle haben verschiedene Voreinstellungen, `this_month` gegen `all`,
  und `custom` gibt es nur in der Liste.) Daneben `list_filters`, die EINE Erklärung der
  Filter der Zeitenliste (Service-Attribute, Entfernen, Zähler, Zurücksetzen, versteckte
  Formularfelder). Ein neuer Filter ist ein Eintrag dort; `list_filters_spec.rb` wird rot,
  wenn `TimeSessionFilterService` ein Attribut kennt, das dort fehlt.
  * ⚠️ `time_session_permission` ist ein zweites Recht AUF der Projekt-Mitgliedschaft: es
    endet mit ihr (`ProjectPermission`-Callbacks, `Actors::RevokeProjectMember` beim Block,
    `Membership#destroy`) und zählt nur mit lebender `ProjectPermission` dahinter
    (`backed_by_project_access`). Ein nacktes Lesen lehnt
    `spec/architecture/time_session_permission_guard_spec.rb` ab (Stand 27.09.2026).
* **Wissen/Kommunikation**: `note`, `note_version`, `post`, `post_document`, `chat`, `chatpost`,
  `prompt_persona`, `chat_style_preference` (+ `knowledge/`)
  * ⚠️ `post` (= Kommentar): Wer einen privaten Kommentar lesen darf, entscheidet EINE Regel,
    `Post.readable_by(user, organisation)` bzw. `#readable_by?` (Adressat, Autor, Kontoadmins;
    `PostPolicy` fragt sie). Was ALLE Leser des Tickets sehen (Aktivitäts-Auszug,
    Zusammenfassung, KI-Antwort), nimmt `public_posts`. Ein nacktes `ticket.posts` beim Lesen
    lehnt `spec/architecture/post_visibility_guard_spec.rb` ab (Stand 27.09.2026). Das ältere
    `visible_to` (nur der Adressat) ist gelöscht.
  * `chat_style_preference` traegt seit 30.08.2026 NEBEN den Stil-Stufen die stehende
    Persona-Wahl einer Person je Org. Welche Persona ueberhaupt angehaengt werden darf,
    entscheidet EIN Ort: `concerns/prompt_persona_selectable.rb`, eingebunden von `chat`
    UND `chat_style_preference`. Die Aufloesungsreihenfolge im Prompt (Thread-Pin, dann
    diese Wahl, dann `PromptPersona.default_for`) steht im `ChatResponseJob`.
  * ⚠️ Zwei Pools, nicht einer, und sie beantworten verschiedene Fragen. `available_for`
    ist die Berechtigungsgrenze (darf diese Org die Zeile ueberhaupt halten) und traegt
    die VALIDIERUNG; sie muss die weitere bleiben, sonst wird eine Zeile mit
    ueberschriebener Persona unspeicherbar. `pickable_for` faltet je Schluessel zusammen,
    die Org-Zeile gewinnt, und beantwortet "welche gilt gerade" -- daran haengen der
    Picker, der Schreibpfad UND `#resolved_persona`. Wer eine gespeicherte Persona gegen
    `available_for` aufloest, zeigt in der Oberflaeche das eine und schickt dem Modell das
    andere, ohne dass irgendetwas es sagt.
  * ⚠️ `chatpost#broadcast_completed` (S3a T4): der Abschluss einer Antwort verzweigt nach
    Thread-Art. Projekt-Threads bekommen wie bisher einen `broadcast_refresh_to`,
    also einen SEITEN-Refresh, der auf der Chat-Seite dank Morph-Meta harmlos ist.
    **Org-Threads dürfen das nicht**: ihr Abonnent ist das Begleit-Panel, und das reitet auf
    einer beliebigen Seite ohne Morph-Meta mit, wo aus dem Refresh ein voller Replace-Visit
    würde. Dort wird stattdessen gezielt die VORHERIGE Antwort ersetzt (Regenerier-Pille).
    Wer diesen Zweig anfasst, prüft beide Seiten.
  ⚠️ **Bilder im Rich-Text**: jedes `has_rich_text :content` (Ticket, Post, Note) bindet
  `concerns/rich_text_embed_guard.rb` ein (Guard-Spec erzwingt das). Der Validator prüft nur das
  **Delta** eines Speicherns (neue Blobs, neue tote `sgid`s), identifiziert den Typ selbst,
  streicht `url`/`href` aus den Attachment-Knoten (war ein unbefristeter Link) und reiht je
  neuem Blob `RichTextEmbedVariantJob` ein. Zahlen und Typliste besitzt allein
  `rich_text_embeds.rb`. Plan: `doc/inline_bilder_spike_plan.md` (E1, D2 bis D10).
  ⚠️ Sein Auslöser `rich_text_content_changing?` antwortet aus dem SPEICHER
  (`association_cached?`), nie per Query: `content.present?` lud den Text bei jedem Save
  jedes Trägers (N+1 bei Massen-Updates), und `association(...)` instanziiert die
  Assoziation, die Rails' Autosave-Validierung dann selbst nachlädt. Pin:
  `spec/models/action_text/rich_text_embed_guard_query_spec.rb`.
  ⚠️ Seit Rails 8.1 hängt der RichText seine `embeds` bei JEDER Validierung im Speicher um.
  Das Delta liest deshalb die **gespeicherten** Anhänge aus der Datenbank
  (`persisted_embed_blob_ids`), nie `content.embeds`: sonst läuft ein Blob, den das erste
  `valid?` abgelehnt hat, beim zweiten durch (PDF, fremde Organisation). Die Prüfung steht mit
  `prepend: true` vor der Autosave-Validierung, weil ein Blob ohne Datei dort schon
  `FileNotFoundError` wirft, und hält dann per `throw :abort` an.
  ⚠️ **Jede Bild- und Erwähnungs-Kennung im Text ist mit `secret_key_base` signiert** (die
  `sgid` im `<action-text-attachment>`, ohne Ablauf). Bekommt eine Instanz einen neuen Schlüssel
  (Umzug auf einen neuen Server oder Klon mit eigenem Schlüssel), geht keine mehr auf: Rails zeigt `☒`, und beim Speichern baut es `embeds` nur aus den Kennungen,
  die aufgehen, hängt also jedes Bild ab und löscht die Datei per Purge-Job.
  `concerns/rich_text_embed_retention.rb` (auf `ActionText::RichText`, eingebunden per
  Initializer) behält deshalb die gespeicherten Anhänge, solange der Text eine tote Kennung
  trägt. **Nach jedem Schlüsselwechsel** einmal `rich_text_embeds:resign_sgids` laufen lassen (zuerst
  `DRY_RUN=1`, braucht keinen alten Schlüssel): er signiert neu, wenn die Daten neben dem Text
  dasselbe Ziel nennen (Bild: `embeds` dieses Textes, Erwähnung: `outgoing_references` der
  Notiz), liest die Kennung nur als JSON, nie Marshal, und listet den Rest. Eine
  Selbst-Erwähnung hat keinen Verweis und bleibt liegen. Specs:
  `spec/models/action_text/rich_text_embed_key_rotation_spec.rb`,
  `spec/services/rich_text_sgid_resign_spec.rb`.
* **Dokumente/Doku/Codebase**: `document`, `document_version`, `documentation_*`
  (`documentation_asset` = ein Bild einer synchronisierten Doku, aus dem Repository kopiert;
  die gecachte Seite zeigt per ID darauf, ausgeliefert nur über `FileDownloadsController`),
  `codebase_*`,
  `code_symbol`, `project_index{,_run}`, `project_repository`, `project_capability`,
  `project_layer4_vision`, `reference`, `fragment`, `imported_object`, `product_knowledge_entry`
  (Lalabases eigene Hilfetexte als Suchtabelle, tenant-frei, siehe Falle 3)
* **Meetings**: `meeting`, `meeting_participant`, `meeting_participant_claim_rejection`,
  `meeting_analysis` (Post-Sichtbarkeitsmuster: `is_private`+`visible_to_user`), `analysis_prompt` (org-weite Prompt-Bibliothek)
  ⚠️ Ein Meeting kann das Projekt wechseln (`Actors::MoveMeeting`). Jeder Schreibweg, der gegen
  ein Projekt geprüft wurde, sperrt über `Meeting#lock_in_project!` und gibt bei `false` auf;
  eine nackte Sperre auf einem Meeting lehnt `spec/architecture/meeting_lock_guard_spec.rb`
  ab (Stand 24.10.2026, Abschnitt in der Wurzel-`CLAUDE.md`).
* **Kein AR-Modell, liegt aber hier**: `acquisition_source` — Value Object über
  `accounts.acquisition` (Herkunft eines Neukunden). Besitzt die Kanal-Priorität
  ref > utm_source > referrer_host > direct an genau EINER Stelle (`doc/akquise_herkunft.md`).
  Ebenso `assistant_panel_state` (S3a T4) — Value Object über das Panel-Cookie des
  Assistenten. Besitzt Format, Breitengrenzen und die Sidebar-Breite an EINER Stelle; der
  Stimulus-Controller bekommt MIN/MAX von dort, statt eigene Zahlen zu führen. ⚠️ Die
  Sidebar-Breite ist der Zwilling von `w-64`/`lg:ms-64` im Application-Layout.
  Ebenso `legal_identity` — Betreiber und Rechtsseiten der Instanz über vier
  `SystemSetting`-Zeilen (`legal_*`). Einziger Leser und Schreiber dieser Zeilen, prüft die
  URLs beim Speichern; `LegalIdentity.current` merkt sich den Stand je Anfrage in `Current`.
  Ebenso `provisioning/request_context` — Wertobjekt in Anfrage-Form für `UserActivity.track!`,
  wenn die getrennte Website ein Konto anlegt: es trägt den BESUCHER (Adresse, Programm), nicht
  den Website-Server. Kein Service, darum hier und nicht unter `app/services`.
* **AI/Billing**: `ai_credential`, `ai_usage`, `system_setting`, `personal_access_token{,_organisation,_project}`
  (`personal_access_token/reach.rb` = der Token-Vertrag als Wertobjekt, gegen `#accessible_project?` gepinnt;
  welche Organisationen ein Token erreicht, beantwortet NUR `#organisation_scopes`, auch für
  `all_organisations`, nie die Verknüpfungszeilen selbst; `#deactivated_member_of?` (K4c) öffnet nichts,
  es sagt einer Tür nur, dass eine genannte Organisation wegen deaktivierter Mitgliedschaft fehlt, damit
  das Glossar sie als fehlendes Recht ablehnt, 403 statt 404),
  `content_embedding` (Sidecar-Vektor je Record je Raum), `embedding_space` (ein von der Org
  GEHALTENER Vektorraum: Tripel + verschlüsselter Credential-Snapshot; welcher davon die Suche
  bedient, sagt `organisations.active_embedding_space_id`),
  `price_list` + `price_tier` (EIN veröffentlichter Preisstand + seine Seat-Staffel: Zeitfenster
  hängt an der Liste, Staffelung an den Stufen), `account_discount` (Prozent-Rabatt je Account,
  ausschließlich im Adminbereich vergeben; genau EINER aktiv, ein laufender ist nur
  BEENDBAR statt änderbar). `EffectiveDating` (Zeitfenster + Überlappungsregel) teilen
  sich `price_list` und `account_discount` — **`price_tier` NICHT**, eine Stufe erbt das
  Fenster ihrer Liste. `founder_signup` ist der **Antrag** auf den Neugründer-Rabatt, nicht
  seine Bewilligung: er entsteht bei der Registrierung, blockiert nichts und wird nach einem
  Telefonat von Hand entschieden — der Rabatt selbst bleibt ein `account_discount`. Von seinen
  Feldern hat nur `phone` eine Frist (gelöscht nach der Entscheidung, spätestens nach 3
  Monaten); Firmenname und Sitz stehen ohnehin am Account.
  S. `doc/billing_preisliste_rabatt_plan.md`,
  `ai_usage_rollup` (ein Monat quota-relevanter KI-Verbrauch je Org, gebucht am ACCOUNT —
  die einzige Kopie, die die Löschung der Org überlebt; `ai_usages` hängt an
  `dependent: :destroy`. Zeilen sind **write-once**, `organisation_id` trägt bewusst
  KEINEN FK, der Name steht als Snapshot daneben. Geschrieben von
  `Subscriptions::AiUsageAggregator` aus zwei Einstiegen: Monatsjob und
  `before_destroy`-Flush. S. `doc/billing_agentur_konto_plan.md` §17.3b),
  `seat_event` + `seat_snapshot` (Grundlage der Platz-Abrechnung,
  `doc/abrechnungsmodell_plan.md`; die vier Dienste darüber stehen in `app/services/CLAUDE.md`
  unter „Die Seat-Kette"). `seat_event` ist **append-only** und erzwingt das (`readonly?` +
  `before_destroy { throw :abort }`); Organisation, User und Rolle sind Herkunftsangaben ohne
  FK, der Organisationsname steht eingefroren daneben, weil das Verschwinden der Org der
  Normalfall ist. `seat_snapshot` ist umgekehrt **abgeleitet und überschreibbar** — die beiden
  Regeln nie aneinander angleichen: die Quelle eines Rollups wird gelöscht, `seat_events` nie.
  ⚠️ Beide sind bewusst **NICHT** `acts_as_tenant` (Falle 3 unten): sie werden von Batch-Läufen
  ohne Tenant gelesen, ein Default-Scope würde dort still jede Zeile wegfiltern statt zu werfen.
* **Sonstiges**: `org_color`, `personal_task`, `user_data_export`, `user_deletion`,
  `mcp_idempotency_key`, `beuser` (Admin-Login, NICHT tenant-gebunden)

Fallen:
1. **Ticket-`status` ist KEINE Spalte** — lebt im `custom_attributes`-JSONB
   (`CustomAttributable` + `TicketAttributeDefinition` + `SystemFunctions`). Schreibpfad ist
   `Actors::SaveTicket`, nicht `ticket.update!(status: …)`.
2. **Updates an Trackable-Modellen lösen implizit die Notification-Kette aus** — vor Änderungen
   an Ticket/Project/Document/Note-Writes: `docs/architektur/seiteneffekt_ketten.md` lesen.
3. **`acts_as_tenant` auf fast allen Modellen** — in Tests den Tenant VOR der Model-Erzeugung
   setzen. Plain `.find` in Jobs ist kein Tenant-Bug (Tenant wird in Jobs serialisiert).
   Bewusst tenant-FREI: `account` + `account_discount` + `price_list`/`price_tier` (Billing liegt
   über den Orgs, und `/pricing` liest ohne Tenant), `ai_usage_rollup` (überlebt die Org, deren
   Verbrauch es zählt — ein Tenant-Scope würde genau die Zeilen wegfiltern, für die es existiert),
   `seat_event` + `seat_snapshot` (dieselbe Begründung, gelesen von Batch-Läufen ohne Tenant),
   `beuser`, `system_setting`, `ai_package*`, `product_knowledge_entry` (Lalabases eigene
   Texte, für jede Org gleich und vom Assistenten aus jedem Tenant gelesen; eine abgeleitete
   Kopie der Hilfedateien, `doc/product_knowledge_plan.md`).
   Dort ein `acts_as_tenant` nachzurüsten filtert still alles weg, ohne einen Fehler zu werfen.
   ⚠️ Umgekehrt gilt: **eine Organisation lässt sich nur MIT gesetztem Tenant zerstören** —
   ihre tenant-gescopten Kaskaden werfen sonst `NoTenantSet` (gemessen beim Bau von T17;
   einen Org-Löschpfad gibt es in der App bis heute nicht).
4. Boy-Scout-Regel: flaches Modell einer Namespace-Domäne wird substanziell angefasst →
   in den Namespace ziehen (`self.table_name` behalten, keine Migration nötig).
5. **`admin/*` sind Zwillinge auf denselben Tabellen ohne gemeinsamen Save-Zyklus** — ein
   Callback oder Concern nur auf der Tenant-Seite wirkt im Adminbereich still nicht
   (`spec/models/admin_twin_concern_parity_guard_spec.rb` prüft die Includes). Die
   Kontolöschung hat deshalb ZWEI Implementierungen (`user/deletion_lifecycle.rb`,
   `admin/user.rb`, Trennung bewusst); was ein Konto an Datensätzen BESITZT (Export-Archive,
   private Analysen und Ticket-Posts, persönliche Aufgaben, eigene Chats, Token-Widerruf),
   löscht allein `concerns/personal_data_erasure.rb` für beide.
   Neue Datensorte → dort ergänzen, nie in einer der Methoden.
   `spec/models/user_erasure_path_parity_spec.rb` pinnt beide Pfade und die Zeile danach.


## Sammeländerung (08.09.2026, `doc/ticket_bulk_edit_plan.md`)

* `ticket_bulk_run.rb`: ein Durchlauf (Änderungen `change_list`, nicht `changes`: das ist
  ActiveRecords eigenes; Ergebnisse je Ticket mit Vorher-Werten; `undone_at`, `undo_of`;
  `UNDO_WINDOW` 24 h; `undoable_by?` = Ausführender oder Account-Admin).
* `Trackable#activity_context`: der EINE generische Haken der Sammeländerung, siehe
  `docs/architektur/seiteneffekt_ketten.md` unten. nil = heutiges Verhalten.
* `Activity.feed`: Feed ohne die Ticket-Aktivitäten eines Durchlaufs; der Ticket-Verlauf liest
  ohne den Scope.
* Scheibe 7: `ticket_bulk_run.kind` (`change`/`move`/`delete`, nur `change` ist rückgängig
  machbar); `Activity.feed` filtert `bulk_run_member` an JEDEM Trackable (Verschieben schreibt
  Projekt-Aktivitäten); `ProjectTrackable#track_tickets_bulk_moved/_moved_in/_deleted`, die
  Lösch-Zeile trägt `follower_ids`, weil die Abos mit den Tickets gehen.
