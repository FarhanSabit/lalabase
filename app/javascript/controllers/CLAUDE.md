# Karte: app/javascript/controllers (Stand: 2026-11-08)

~109 Stimulus-Controller, bewusst FLACH gehalten: Unterordner würden via
`eagerLoadControllersFrom` alle Identifier ändern (`meetings/row_controller.js` →
`data-controller="meetings--row"`) — bei ~145 `data-controller`-Stellen in ERB zu viel Churn.
Die Domäne steckt im Dateinamen-Präfix (`ticket_*`, `time_session_*`, `meeting*`, `neo_*`).

Konventionen:
* `neo_*` (~20 Stück) = Design-System-Controller (Pendants zu den Neo-ViewComponents).
  Unpräfixierte Controller sind Legacy bzw. feature-spezifisch.
* Wiring läuft NUR über `data-controller`-Attribute in ERB. Controller→View finden: nach dem
  Identifier grepen (Dateiname ohne `_controller`, Unterstriche → Bindestriche). Achtung:
  manche Mounts entstehen per Ruby-Array-Join — ein Literal-grep kann fälschlich „unused" melden.
* **Nach jedem Anlegen/Löschen/Umbenennen: `rails importmap:auto_pin` ausführen und committen**
  (sonst bricht das Prod-Precompile). NIEMALS `rails stimulus:manifest:update` direkt —
  siehe Root-`CLAUDE.md`, „Critical Bug Fixes".
* Guard: `spec/architecture/stimulus_controller_wiring_spec.rb` (kein Mount ohne Controller-Datei).
* Modals: IMMER zuerst `docs/dokumentation/modal_pattern.md` und `README_MODAL_PATTERN.md`
  (hier im Ordner) lesen. Referenz-Implementierung ist `ticket_relation_modal_controller.js`
  (Fokusfalle über `dialog_a11y`, Schließen über Hintergrund und Escape, Fokus zurück an den
  Auslöser). `meeting_modal_controller.js` ist seit 17.10.2026 gelöscht („Neues Meeting“ auf
  „Alle Meetings“ öffnet in der Bahn), `time_session_modal_controller.js` seit 16.09.2026.
  Seine Form hat KEINEN gemeinsamen Scope mit dem Auslöser: das Modal ist der Inhalt eines
  Frames neben dem Abschnitt, beide Auslöser sind Links mit `data-turbo-frame`, Verbinden heißt
  Öffnen, Schließen leert den Frame. Jede Öffnung trägt eine eigene ID (Token): Ablehnung und
  Speichern treffen nur sie, eine späte Antwort an ein geschlossenes Modal findet nichts. Das
  Fokus-Rücksprungziel liegt am Frame, nicht an der Instanz.
  Ein weiteres Modal derselben Form erbt den Controller statt ihn zu kopieren
  (`participant_link_modal_controller.js`, seit 27.10.2026: nur das erste Feld ist anders;
  `term_correction_modal_controller.js`, seit 05.11.2026: Fokus aufs Feld „Richtig“, die Zahl
  lädt in ihren eigenen Frame nach).
* `transcript_selection` (K4b, 05.11.2026): eine Markierung im Transkript zeigt „Korrigieren“
  (über der Markierung, auf dem Telefon darunter, wo sonst das Systemmenü steht). Der Knopf ist
  ein Link in den Frame des Dialogs; der Controller hält nur seine Adresse aktuell:
  Markierung, Kontext und Versatz in CODEPUNKTEN über den sichtbaren Text
  (`lib/transcript_mark.js`, Pin `transcript_mark`, node-Tests). ⚠️ Nie Positionen aus dem HTML
  an den Server: die Seite zeigt Markdown, die Stelle findet `Meetings::TranscriptMark`. Im Panel
  neben einem Ticket nicht eingebunden.
* **Escape gehört dem Obersten** (`lib/escape_owner.js`, seit 17.10.2026): Jeder Controller, der
  auf Escape reagiert, beantwortet `ownsEscape()` (wahr, solange sein nächstes Escape etwas
  Eigenes schließt). Ein Overlay, das ein Skript außerhalb eines Controllers baut, trägt
  `data-owns-escape`. Die Bahn (`layout-toggle`) fragt das in der Capture-Phase auf `window`,
  bevor irgendein Listener lief, und schließt nur, wenn niemand antwortet. Bis dahin stand
  eine Selektor-Liste in `layout-toggle`, und jedes vergessene Overlay schloss die Bahn
  DAHINTER. Wächter: `spec/architecture/escape_owner_guard_spec.rb` (auch `keydown.esc->` in
  Templates; geschlossene Liste `NOT_OWNERS` mit Grund). ⚠️ Ein `ownsEscape()`, das wahr
  bleibt, obwohl nichts offen ist, hält die Bahn für immer offen: an den Zustand binden, den
  der eigene Escape-Handler prüft.
* `neo_autosuggest` hat zwei Modi: ohne `url` filtert er vorgeladene Optionen im Browser, mit `url`
  fragt er den Server; bestätigte Auswahl, Anfragenummer, Entprellen und Abbruch liegen in
  `lib/autosuggest_search.js` (Pin `autosuggest_search`, node-Tests).
* ⚠️ Kein `#anker`-Link auf einer Bahn-Seite: er legt einen History-Eintrag an, „Zurück" gilt dann
  als Bahn-Wechsel und lädt die Bahn neu (Kommentarentwurf weg), und der Hash wandert in Adressen,
  die aus `window.location` gebaut werden. Für Sprünge `scroll_into_view` (Knopf, scrollt und
  fokussiert, Adresse bleibt).
* Bahn-Historie (`index_page` + `lib/lane/history.js`): ein Eintrag mit ANDEREM Pfad gehört einer
  anderen Seite; Turbos eigenen stellt Turbo wieder her. Sonst brach „Link in Projekt B, Zurück"
  Turbos Besuch ab und lief in den 500-ms-Doppelklick-Schutz von `application.js`.

Ähnlich benannte Controller — Analyse 2026-07-13 (KI-DX Slice 5), KEINE Duplikate:
* `toggle` (generisches, umkehrbares Ein-/Ausblenden, Targets `content`/`icon`, 13+ Mounts) vs.
  `neo_toggle` (Form-Switch mit Visuals + `relatedSelect`/`relatedInput`) vs. `reveal_more`
  (EINWEG-Reveal: zeigt `[data-more-item]` unter seinem Element + blendet den Trigger aus, kein
  Zurückklappen) — drei verschiedene Zwecke. `reveal_more` speist aus EINER Quelle das
  Projekt-„mehr …" der Sidebar (`neo_sidebar_project_item_component`) UND seit S5b (02.09.2026)
  die Stand-Tabelle der Zeitenliste, die Projekte ohne Zeiten faltet
  (`time_sessions/_billing_overview_panel`). Die Org-Nav (`_navigation_application`) nutzt ihn
  nicht mehr.
* `clamp_toggle` ist der VIERTE aus dieser Familie und der einzige mit einer Vorschau:
  er kürzt einen langen Block auf eine Vorschauhöhe und klappt ihn wieder auf. Die
  Kürzungsklasse kommt über die Stimulus-Classes-API von außen, er ist also inhaltsneutral.
  ⚠️ **Sein Markup nicht mehr von Hand verdrahten** — seit 04.09.2026 gehört es
  `Neo::MarkdownPreviewComponent` (Transkript, Analyse-Vorschau, Ticket-Zusammenfassung).
  Er blendet den Knopf nur ein, wenn der Text die Kürzung wirklich überläuft; ein Block,
  der beim `connect()` nicht messbar ist (`clientHeight === 0`, verstecktes Lane),
  behält Kürzung und Knopf.
* `neo_price_interval` (öffentliche Preisseite, `doc/billing_preisliste_rabatt_plan.md` §7.4)
  ist KEIN weiterer `toggle`: er blendet nicht ein Element auf/zu, sondern wählt **eine von n**
  Varianten anhand `data-interval` — alle serverseitig gerendert, er flippt nur `hidden`. Die
  Seite ist ohne JavaScript vollständig; wer das als Ein/Aus nachbaut, verliert genau diese
  Eigenschaft.
* `billing_form` (Rechnungsformular, `doc/billing_stammdaten_plan.md` §9) ist ebenfalls KEIN
  weiterer `toggle`: er blendet nicht auf Knopfdruck etwas auf/zu, sondern leitet aus dem
  gewählten Land ab, welche Felder überhaupt gelten. Alle Listen und Subdivisionen kommen als
  `data-*`-Werte aus `Accounts::BillingRules` und dem `countries`-Gem, nie als Kopie im JS.
  Setzt bewusst KEIN `required`: das Formular muss vollständig leerbar bleiben (E3),
  verbindlich ist die Server-Validierung im `:billing`-Kontext.
* `dropdown` (Targets `menu`/`button`) vs. `neo_dropdown` (Target `trigger`, auto-close-Value,
  Keyboard-Nav) — beide live. **Für neuen Code `neo_dropdown` bevorzugen**; `dropdown`-Mounts
  opportunistisch migrieren (Boy-Scout). ⚠️ **Ausnahme: eine Fläche, die ohne JavaScript
  vollständig bleiben muss.** `neo_dropdown` blendet sein Menü per JS ein, ohne JS gibt es also
  gar kein Menü. Die Filterzeile der Zeitenliste (S7, `time_sessions/_filter_pill`) nimmt darum
  `<details>` + `details_autoclose`: der Zeitraumfilter war vorher neun Links und hätte sein
  Ohne-JS-Verhalten sonst verloren.
* `details_autoclose` hat seit S7 **zwei** Verbraucher: den Org-Umschalter der Navigation und
  jede Pille der Zeitenliste. Sein `panel`-Target und `reposition` gehören nur dem ersten (sie
  ankern an `#sidebar`); die Pillen mounten ihn ohne Target und nutzen nur „außen klicken" und
  Escape. Alles im `reposition`-Pfad prüft `hasPanelTarget`, das muss so bleiben.
* `filter_menu_search` (S7) filtert die bereits gerenderten Links EINES Pillen-Menüs nach
  getipptem Text. Reine Verbesserung: ohne JS listet das Menü einfach alle. Mount sitzt
  literal an jedem Menü, auch ohne Suchfeld — der Verdrahtungs-Zensus liest Mounts als
  Literale und sieht eine aus Ruby gebaute Bedingung nicht.
* `project_cascade` ist mit S7 **gelöscht**: sein einziger Mount war das Projekt-Auswahlfeld
  der Zeitenliste. Was er tat (Projektwechsel räumt beide Bezugs-Ids weg) steht jetzt in der
  Adresse jeder Menü-Option und gilt damit auch ohne JavaScript.
* `slim_select` (Wrapper um die SlimSelect-Lib) vs. `neo_select` — getrennte Zwecke.
* `ticket_selection` (08.09.2026, `doc/ticket_bulk_edit_plan.md` Scheibe 1): die Auswahl der
  Ticketliste. Zustand in `lib/ticket_selection.js` (Pin `ticket_selection`, node-Tests), Mount
  UM Kopf und Listenrahmen in `_index_desktop`, rendert nach jedem Nachladen neu.
  ⚠️ Hört `turbo:frame-load` in der CAPTURE-Phase am Mount: auf der Ticketseite erreicht das
  Ereignis das `document` NICHT (gemessen 08.09.2026; jedes andere Frame-Ereignis schon). Damit
  sind auch die `document`-Listener von `filter_bar` (`_hits` bleibt nach einem Nachladen auf
  dem alten Wert), `column_picker` und `keyboard_navigation` blind. Ursache ungeklärt, offener
  Befund, eigener Strang.
* `ticket_bulk_panel` (Scheiben 3 und 4): das Panel in der Bahn, Gerüst vom Server, fügt die
  Änderungszeilen aus `<template>`s hinzu, holt den Bestand (`bulk_summary.json`) nach jeder
  Änderung der Auswahl und spricht mit `ticket_selection` über Window-Ereignisse (`:ready`,
  `:close`, `:draft`, `ticket-selection:change`), weil Panel (Bahn-Rahmen) und Auswahl
  (Listenspalte) in verschiedenen Rahmen leben. Der Entwurf (`lib/ticket_bulk_draft.js`, Pin
  `ticket_bulk_draft`, node-Tests) wird von `ticket_selection` über den Wechsel mit dem Ticket
  bewahrt. `ticket_selection` fängt den Schließen-Knopf der Bahn in der
  Capture-Phase am `document` ab, solange eine Auswahl steht. `execute` (Scheibe 6) schickt Auswahl, Entwurf und Bestands-Digests als JSON an
  `bulk_update` (Adresse in der Query), rendert die Turbo-Stream-Antwort selbst
  (`Turbo.renderStreamMessage`) und meldet die geänderten Ids als `ticket-bulk-panel:done`;
  `ticket_selection#afterRun` macht daraus die neue Auswahl. ⚠️ Turbo wendet einen Stream
  erst beim nächsten Repaint an: die Ids kommen aus dem Antworttext (`runTicketIds`), und die
  Häkchen der neuen Zeilen setzt `ticket_selection#onStreamRender` über den `render`-Haken
  von `turbo:before-stream-render`, nicht über ein `setTimeout`. Scheibe 7: die anderen
  Aktionen unter dem Knopf öffnen native `<dialog>`s im Panel (`openMove`/`openDelete`), holen
  die Zahlen per `POST bulk_impact` (JSON-Body, wie seit Scheibe 7 auch `bulk_summary`: 200 Ids
  passen in keine Request-Zeile) und antworten wie ein Durchlauf; `done` mit `clear: true` leert
  die Auswahl, `ticket_selection` hält die Ergebniszeile ohne Auswahl bis zum ✕ (`dismissResult`).
* `filter_bar` ist die EINE Filterleiste (Reiter, Pillen, Speicherzeile; Zustand kommt aus der
  Adresse, Logik in `lib/filter_bar/change_set.js`). Die eingefrorene Kopie `filter_bar_legacy`
  samt `lib/filter_bar_legacy/` und dem Nutzer-Flag ist am 07.09.2026 gelöscht.
* Echte Duplikate/Leichen wurden 2026-07-13 gelöscht (`sort`, `search_clear`, `search_input`,
  `permission_radio`, `neo_grouped_notification`, `.disabled`-Dateien) — der Census-Guard
  meldet neue.

## Rich-Text (seit Paket 2 Inline-Bilder, 2026-08-23)

Lexxy ist der einzige Editor; Trix ist aus Importmap, JS und CSS verschwunden
(Guard: `spec/views/no_trix_guard_spec.rb`). Zwei Controller gehören dazu:

* `neo_rich_text_embeds` sitzt am `<lexxy-editor>` (Attribute aus
  `RichTextEmbedsHelper#lexxy_embed_editor_options`), hört `lexxy:file-accept` und prüft NUR
  neue Dateien gegen Typ und Größe aus `RichTextEmbeds` (`lib/rich_text_embed_accept.js`,
  `node:test`). Abgelehnte Dateien wandern in das Anhang-Feld des Formulars, das er über
  einen Selektor im umschließenden `form` findet. ⚠️ Nie Lexxys eigenes
  `permitted-attachment-types` setzen: Lexxy filtert damit auch beim LADEN und wirft
  Bestands-Attachments weg.
* `neo_rich_text_zoom` sitzt am Wrapper jedes gerenderten Rich-Texts
  (`layouts/action_text/contents/_content.html.erb`), nie am Bild: ActionText streicht
  `data-*` aus den Attachment-Partials. Delegierter Klick auf `a.attachment__zoom`
  (`lib/rich_text_zoom.js`) öffnet ein natives `<dialog>`; ohne JS öffnet der Link die
  große Variante. Funktioniert in Turbo-Streams, weil der Listener am Wrapper hängt.
* `neo_writing_surface` (Paket 3) sitzt an der großen Ticket-Schreibfläche
  (`tickets/_writing_surface.html.erb`, gerendert in `turbo-frame#writing_surface` von
  `tickets#new` und `#edit`; der leere Frame gehört dem Application-Layout, damit Liste,
  Dashboard UND Inbox-Pane ihn erreichen). ⚠️ Bewusst NICHT `turbo-frame#modal`:
  `filter_bar_controller` besucht die Seite nach jedem erfolgreichen Submit in `#modal`
  neu, und die URL trägt noch das vorher gewählte Ticket. Er kennt nur den Weg HINAUS ohne Speichern: Escape und Abbrechen schließen
  ein unverändertes Formular sofort, sonst `window.confirm`; Klick daneben schließt nie.
  „Verändert" ist ein Vergleich von FormData-Snapshots (`lib/form_snapshot.js`,
  `node:test`), flüchtige Felder wie `authenticity_token` ausgenommen. Speichern schließt
  nicht er, sondern der Turbo-Stream `update('writing_surface', '')` der Controller-Antwort.

## Begleit-Panel des Assistenten (S3a T4, 2026-08-24)

Zwei Controller, ein Grund für die Trennung: das Panel liegt auf Body-Ebene (es muss, um
`data-turbo-permanent` zu sein und dem `transform`/`overflow` der Sidebar zu entkommen),
die Sidebar-Zeile liegt in der Navigation. Damit sind sie NICHT im selben Stimulus-Scope.

* `assistant_panel` sitzt am permanenten Knoten `#assistant_panel`
  (`layouts/_assistant_panel.html.erb`). Turbo VERPFLANZT diesen Knoten bei jedem
  Drive-Besuch, deshalb gilt hier durchgehend: Zustand gehört auf den Knoten, nicht in die
  Instanz — die Stimulus-Values (`open`, `width`) tun genau das, weil sie Attribute sind.
  ⚠️ `disconnect()` feuert bei JEDER Verpflanzung, nicht nur beim Abbau: dort nichts
  abräumen und vor allem nichts MESSEN (`scrollTop` liest dort 0, der Knoten hängt schon
  aus). ⚠️ Ein permanenter Knoten sieht die frisch gerenderte Fassung nie — serverseitige
  Änderungen an seinen Attributen kommen nicht an; der Weg vom Server dorthin ist die URL
  (`?assistant_chat_id=`, `honourRequestedChat`; ebenso `?assistant=full`,
  `honourRequestedMode`). Umgekehrt gilt dasselbe für den KOPF des
  Panels: er weiß nie, welchen Verlauf der Frame gerade zeigt. Deshalb ist „Frühere
  Verläufe" ein Knopf und kein Link — `showHistory` liest die offene Id am Chat-Frame ab
  (`#assistant-panel-chat[data-chat-id]`, gesetzt von `ChatContainerComponent`) und baut
  die Adresse selbst.
  ⚠️ Wer Zustand aus der URL übernimmt, MARKIERT die Adresse (`dataset.honouredChat`,
  `dataset.honouredMode`, `dataset.honouredArtefact`) — der Morph-Refresh besucht dieselbe
  URL erneut und macht sonst eine Nutzerentscheidung rückgängig. Wer sie SCHREIBT
  (`publishArtefactAddress`, `replaceState`), markiert sie im selben Zug.
* **Drei Zustände, EIN Knoten** (S3c T2): Die Vollansicht ist eine KLASSE am selben Knoten
  plus ein Grid darin, nie eine Seite — eine Seite nähme Entwurf, Bildlauf und laufenden
  Stream mit. Das Raster aus `layout.css` ist dafür unbrauchbar (lebt in `<main>`); Regeln
  in `components/assistant_panel.css`.
* ⚠️ **Ein Marker im Panel-Knoten ist NICHT eindeutig.** `showHistory` fragt, ob die
  Verlaufsliste schon offen ist, und muss dafür den CHAT-FRAME fragen, nicht
  `this.element`: seit T2 rendert die Verlaufs-Lane dieselbe Komponente mit demselben
  `data-assistant-history` im selben Knoten. Ein Ausflug in die Vollansicht lud die Lane,
  der Marker blieb danach im DOM (die Lane ist nur `display:none`), und der Uhr-Knopf tat
  bis zum nächsten Neuladen nichts mehr. In PRODUKTION gefunden, nicht im Test. Wer hier
  einen Marker oder eine Id sucht, fragt die Fläche, die ihn besitzt.
* **`showSettings`** (Zahnrad, 30.08.2026) ist derselbe Bau wie `showHistory`: dritter
  Zustand des Chat-Frames (`?settings=1`), `data-assistant-settings` als Marker, und der
  offene Verlauf reist als `?current=` mit, damit der Rückweg dort landet, wo das Zahnrad
  gedrückt wurde. Ohne diesen Parameter fällt der Rückweg auf die Panel-Vorgabe, also den
  NEUESTEN Verlauf. ⚠️ Ein Test dagegen ist nur dann echt, wenn der Ziel-Verlauf nicht
  selbst der neueste ist: sonst ist der Rückfall vom Rückweg nicht zu unterscheiden
  (gemessen, `spec/system/assistant_panel_spec.rb`).
* **Die Artefakt-Lane** (S3c T3) ist die dritte Spur, sichtbar nur wenn BEIDE Klassen
  stehen (`assistant-panel--full` + `assistant-panel--artefact`). Ein einziger delegierter
  Klick-Handler (`handleClick`) entscheidet beides: ein Link mit `data-assistant-artefact`
  öffnet in der Vollansicht die Lane statt zu navigieren, und jeder Link, der das Panel
  VERLÄSST, klappt vorher auf die Begleitspur zurück — sonst lädt die Seite hinter einem
  bildschirmfüllenden Panel und der Klick sieht folgenlos aus (der Defekt, mit dem T2 lief).
  Links, die einen Frame IM Panel adressieren (`data-turbo-frame="assistant_panel_body"`),
  sind davon ausgenommen. ⚠️ Der Frame-`src` wird IMMER aus dem eigenen Endpunkt
  (`artefactSrcValue`) plus Query gebaut, nie aus einem Adress-Wert als Ganzem.
  ⚠️ `handleClick` steigt bei ⌘/Strg/Shift/Alt und `button !== 0` sofort aus. Beide
  Zweige lägen sonst falsch: `preventDefault()` verschluckt den neuen Tab, und die
  Rückklappe faltet das Panel weg, obwohl Turbo modifizierte Klicks selbst ignoriert
  und die Seite gar nicht navigiert. Dasselbe für `#`-Anker und `mailto:`/`tel:`.
* ⚠️ **`turbo_stream.update` feuert KEIN `turbo:frame-load`.** Das Kontext-Angebot
  (S4 T2 Schritt 5b) muss wissen, welchen Gegenstand die Seite gerade zeigt, und ein
  Frame-Load-Listener beantwortet das fast nie: `#ticket_display_frame` hat ACHT
  Schreiber, und genau einer davon (`list_row_controller`, setzt eine `src`) ist ein
  Load. Der Rest sind Streams, dazu zwei Stellen, die `innerHTML` direkt zuweisen
  (`turbo_cache_controller`, und der Kanban-Ausklapper beim Schliessen) und damit gar
  nichts feuern. Drei Defekte im Review liefen auf diese eine Tatsache hinaus. Deshalb
  ein `MutationObserver` — **auf `<main>`, nicht auf `document.body`**: das Panel ist ein
  Geschwister von `<main>`, und eine laufende Antwort schreibt den Verlauf pro Token neu,
  ein body-weiter Beobachter liefe also während jeder Antwort sechzigmal pro Sekunde.
* **Das Angebot liegt im FRAME, nicht mehr in der Hülle** (27.08.2026). Sein Markup ist
  `Neo::Chat::ContextOfferComponent`, gerendert von `ChatContainerComponent`, und zwar NUR
  für `PANEL_FRAME_ID`: es steht jetzt direkt über der Zeile, deren Bezug es setzen will,
  weil es unten am Panelrand niemand ansah. Der Preis dafür steht oben: was der Client in
  `assistant_panel_body` schreibt, ist beim nächsten Frame-Load weg. Beantwortet wird das
  am Ladeereignis selbst, `handleChatFrameLoad` fragt danach erneut, und zwar ZWEIMAL:
  sofort und im nächsten `requestAnimationFrame`. Stimulus findet die Targets eines frisch
  getauschten Teilbaums über einen `MutationObserver`, also einen Microtask NACH
  `turbo:frame-load`; der erste Aufruf redet unter Umständen noch mit dem abgehängten
  Knoten. Seit 10.09.2026 rendert auch der Empty State das Angebot. Ohne gespeicherten
  Verlauf landen angenommene Bezüge in `DraftReferencesComponent` als sichtbare Chips
  und versteckte Formularfelder (`chat[reference_keys][]`). Der permanente Panel-Knoten
  erhält diese Auswahl bei Navigation; „Neuer Chat“ tauscht das Formular aus und leert sie.
  `Actors::SaveChat` prüft die Sammlung über `Tools::Scope#references` und speichert sie
  mit der ersten Nachricht, bevor der Antwort-Job startet. Fehler rendern die Nachricht
  samt weiterhin lesbaren Bezügen erneut. Während des Sendens sperrt der Controller die
  Auswahl und weitere Submits. Bei einer Turbo-Stream-Antwort bleibt das alte Formular
  bis zum Austausch gesperrt: `submit-end` kann vor dem Lesen des Antworttexts feuern.
  `offerTargetConnected` erneuert das Angebot auch nach einem Stream-Austausch.
  Verlaufsliste und Einstellungen rendern weiterhin kein Angebot.
* **`chat_scroll_controller` hat zwei Akte, und der zweite ist neu** (27.08.2026): der
  Sprung (die eigene Frage an den oberen Rand) und danach das FOLGEN, das das Ende des
  Verlaufs sichtbar hält, während die Antwort Token für Token hereinkommt. Beide sind nur
  durch das `turbo:submit-end` des eigenen Composers scharf, nie durch einen Broadcast.
  ⚠️ Dass der Leser selbst gescrollt hat, wird OHNE Scroll-Listener erkannt: ein
  programmatischer Bildlauf feuert dieselben Ereignisse wie ein echter, eine gemerkte
  Position unterscheidet die beiden. Der Sprung ist darum bewusst NICHT smooth: ein
  laufender Smooth-Scroll hätte keine verlässliche Bezugsposition, und das Folgen
  würde ihn überschreiben (eine frühere Schonfrist `JUMP_SETTLE_MS` gibt es nicht mehr).
* **Das Ende beim Öffnen** (10.09.2026) gehört dem PANEL-Controller, nicht dem
  Scroll-Controller: `showTranscriptEnd` läuft in `open()` und bei `turbo:frame-load` des
  Chat-Frames. ⚠️ Nicht in `connect()` des Scroll-Controllers: der feuert bei jeder
  Verpflanzung und würde die Leseposition überschreiben, die `restoreTranscriptScroll`
  gerade zurückgeholt hat. Ein Seitenwechsel bei offenem Panel behält die Position,
  jedes Öffnen und jeder Verlaufswechsel zeigt das Ende. Steht eine Antwort noch aus,
  lädt der Resync den Frame beim Seitenwechsel ohnehin neu, und der frische Verlauf
  zeigt dann ebenfalls das Ende (gemessen: ein Verlauf, dessen letzte Blase
  `data-answer-pending="true"` trägt, wird bei jedem Besuch neu geholt).
* ⚠️ **Der permanente Knoten stirbt auf jeder Seite OHNE Organisation** (Org-Wechsler,
  Kontoseiten, Admin, `/hilfe`): `assistant_available?` verlangt `current_organisation`,
  also rendert das Layout das Panel dort nicht und Turbo verpflanzt nichts. Die Listener
  auf `document`/`window` sterben aber nicht mit, sie halten die tote Instanz samt
  abgehängtem Teilbaum am Leben, einer mehr pro Rundreise. `disconnect()` kann das nicht
  aufräumen (eine Verpflanzung feuert es auch), deshalb melden sich die Listener selbst ab
  (`releaseIfGone`) — und erst nach einer ZWEITEN Frage in einer späteren Task, weil eine
  Verpflanzung den Knoten kurz aus dem Dokument nimmt.
* ⚠️ **Für das Ergebnis eines Chip-Schreibens gibt es kein Ereignis.** `turbo:submit-end`
  feuert, bevor der Stream die Chip-Zeile ersetzt hat, und ein Div-Tausch ist kein
  Frame-Load. Wer dort zu früh aufräumt, bietet das gerade gesetzte Ticket erneut an; wer
  nie aufräumt, lässt das Ticket für die Lebensdauer des Tabs verstummen. `settleAfterScopeWrite`
  wartet deshalb, bis die Zeile sich WIRKLICH ändert, mit einem Frame-Budget als Rückfall
  für den Fall, dass sie unverändert zurückkommt — was genau die Form einer Ablehnung ist.
* **Der Bezug ist eine SAMMLUNG, und ihre Vokabel ist der Schlüssel `<Typ>:<uuid>`**
  (Bezugs-Sammlung S1, 27.08.2026, `doc/assistent_bezug_sammlung_plan.md` §7.1/§8.3).
  Derselbe Wert im URL-Segment, im Formularfeld, in `data-reference-keys` am Chip und in
  `dismissedContexts`/`refusedContexts`/`pendingContext`; Meeting-Einstiege führen daneben
  ihre noch nicht erfüllte Absicht in `pendingMeetingIntents`. Zusammengesetzt wird der
  Schlüssel an genau zwei Stellen:
  `assistant_trigger#adopt` aus seinen beiden Values, und `pageContext()` aus
  `data-assistant-context` plus `data-assistant-context-type`. Beide Attributsätze
  schreibt auf der Server-Seite EIN Besitzer, `AssistantContextHelper`
  (`assistant_context_attributes` für den Marker, `assistant_trigger_attributes` für den
  Knopf), seit Wissen sie neben den Tickets rendert (10.09.2026,
  `doc/assistent_wissen_kontext_plan.md`). ⚠️ `pageContext()` überspringt Marker in einer
  GESCHLOSSENEN Bahn (`.layout.hide-content`): das ✕ blendet die Spalte per Klasse aus und
  lässt den Inhalt stehen, sonst bliebe die eben geschlossene Notiz im Angebot. Deshalb
  beobachtet `observePageContent` neben der Kinderliste von `<main>` das `class`-Attribut
  des `.layout`-Knotens, und nur dieses. `standingReferenceKeys()`
  liest die ganze Zeichenkette (das ist es, was `settleAfterScopeWrite` vergleicht),
  `standingKeySet()` beantwortet die Mitgliedschaftsfrage. Geschrieben wird per POST auf
  `.../assistant_chats/:id/references`, entfernt per DELETE auf den Schlüssel.
  Eine Server-ABLEHNUNG landet in `refusedContexts` (S2, §8.3), sonst entsteht mit der
  Obergrenze 10 eine Schleife: Klick, 422 „höchstens zehn", Angebot wieder da. Sie wird
  nicht aus einer unveränderten Zeile geraten, sondern nur aus `success:false` MIT
  `fetchResponse` des eigenen Kontextformulars gelesen; ein Netzfehler darf den Bezug
  nicht für den Tab verstummen lassen. `settleAfterScopeWrite` wartet trotzdem auf die
  wirklich gerenderte Chip-Zeile, bevor Angebot und Meeting-Absicht neu bewertet werden.
  ⚠️ Mehrere Scope-Schreiben können einander in Turbo abbrechen. Deshalb zählt
  `contextSubmissionsInFlight` pro Schlüssel bereits VOR `requestSubmit()`: nur der letzte
  Settle darf `pendingContext` und `pendingMeetingIntents` löschen oder den Modus aktivieren.
* `assistant_trigger` wirft ein Custom-Event auf `window`: neben dem Bezug trägt ein
  Meeting-Einstieg optional `analysis` oder `ticket-suggestions` als Absicht. Der Panel-
  Controller erfüllt sie erst, wenn `Meeting:<uuid>` sichtbar in der aktuellen Sammlung
  steht. Ein zweiter Klick auf denselben fliegenden Bezug ersetzt nur die Absicht; ein
  erneutes `requestSubmit()` würde Turbos erste Übernahme abbrechen.
* ⚠️ Solange eine solche Meeting-Absicht auf die Bezugsübernahme wartet, hält
  `guardPendingMeetingIntentSubmit` ausschließlich das Nachrichtenformular an. Andere
  Formulare im Panel — Vorschläge übernehmen/verwerfen, Lauf wiederholen, Chip oder Chat
  löschen — bleiben bedienbar. Der Guard lauscht in der Capture-Phase, zeigt seinen
  `role="alert"`-Status aus `ComposerComponent` in neuem UND bestehendem Chat und verhindert
  so, dass ein sichtbarer alter Aufgabenmodus versehentlich für Meeting A absendet,
  während der Einstieg für Meeting B noch geprüft wird.
* `assistant_suggestion_composer` (Meeting-Migration Schritt 3) ergänzt das vorhandene
  Nachrichtenfeld um einen sichtbaren, aufhebbaren Aufgabenmodus. Das versteckte Feld
  `ticket_suggestion_meeting_id` trägt dessen Absicht; `assistant_panel` erhält es beim
  Frame-Abgleich zusammen mit dem Entwurf. Ziele kommen aus den übernommenen Meeting-Bezügen
  und einem berechtigungsgeprüften Endpunkt, nie aus der gerade geöffneten Seite. Ein
  ausdrücklicher Meeting-Einstieg wartet nur, solange genau der Fetch läuft, der dieses
  Meeting entscheiden kann. Nach einem Fehler fällt die Absicht weg, normale Nachrichten
  lassen sich wieder senden; der sichtbare Wiederholen-Knopf oder derselbe Einstieg lädt
  die Auswahl erneut.
* `meeting_section_sync` hält gespeicherte Analysen und die gemeinsame Vorschlagsliste am
  geöffneten Meeting mit den Assistenten-Karten synchron. `assistant:analyses-changed` und
  `assistant:suggestions-changed` sind nur Hinweise: die Meeting-Seite lädt ihre eigene,
  berechtigungsgeprüfte Darstellung mit `Turbo-Frame: meeting_display_frame`, bündelt
  Ereignisse während eines laufenden Abrufs und versucht einen flüchtigen Fehler einmal
  erneut. Nur eine erfolgreiche Ticket-Übernahme trägt `refreshLinks` und ersetzt im selben
  Abruf auch die Verknüpfungsliste; Start, Abschluss und Verwerfen lassen einen dort noch
  nicht abgesendeten Autosuggest-Entwurf stehen. Ein eingereihtes Ereignis darf dieses Flag
  auch dann nicht verlieren, wenn der erste Abruf fehlschlägt.
* `assistant_suggestion_result` aktualisiert genau einen gespeicherten Lauf per HTTP,
  solange Panel, Dokument und Karte sichtbar sind und der Lauf aktiv ist (Backoff bis
  30 Sekunden, bei 429 mindestens 60 Sekunden). Fertige Karten aktualisieren ausdrücklich
  oder beim Zurückkehren mit mindestens 60 Sekunden Abstand zum letzten Abruf.
  Wiederandocken setzt die Observer-Markierung zurück und löst keinen Abruf aus.
  Ein Server-Digest berücksichtigt Aktionsfehler, ignoriert aber wechselnde CSRF-Tokens. Vor dem Einsetzen einer Antwort prüft er die Sichtbarkeit erneut; wird die Karte während
  des Abrufs versteckt, bleibt sie `stale` und holt beim nächsten Anzeigen sofort nach.
  `disconnect` bricht den Request ab und entwertet über eine Generation alte Timer.
  Geschlossene Ergebnisflächen erhalten keine Inhalte. Der allgemeine Chat-Resync
  überspringt diese Ergebnisse, damit nicht zwei Polling-Wege denselben Auftrag aktualisieren.
* `glossary_run_poll` (K5b, 08.11.2026) lädt den Listen-Frame der Prüfliste des Glossars alle 5 s
  neu (Value `interval`), solange ein Lauf der Extraktion aktiv ist. Sitzt an der Lauf-Leiste IM
  Frame: die frische Leiste entscheidet, ob es weitergeht (`active`), eine Antwort ohne Liste
  beendet das Fragen. Kein Broadcast, die Rechte bleiben in der View (Form von
  `meeting_section_sync`, node-Tests).
* Die Grenzen des lebenden Knotens stehen in `doc/persoenlicher_assistent_plan.md` §7.7.
  Kurzform: Org-Wechsel und globale Suche sind `turbo: false`, und
  `knowledge/index.html.erb` trägt `<meta name="turbo-visit-control" content="reload">` —
  jeder dieser Wege ist ein Vollreload und tötet den Knoten samt getipptem Entwurf. Das
  Cookie (`AssistantPanelState`) stellt danach Geometrie und Offen-Zustand wieder her.
  Guard gegen die Rückkehr der TOTEN Attribut-Variante:
  `spec/architecture/turbo_visit_control_guard_spec.rb`.
## Spaltenwahl der Ticketliste (07.09.2026, `doc/spaltenwahl_plan.md`)

* `column_picker` sitzt am Wrapper der Ticketliste (`tickets/index.html.erb`) und erreicht von
  dort das Grid (Target `grid`, Klasse `column-picker-open`), das Panel
  (`Neo::ColumnPickerComponent`, außerhalb des Listen-Frames, überlebt jeden Reload) und den
  Auslöser in der Filterleiste (`[data-column-picker-trigger]`, seit 20a/S2; er saß bis dahin
  im Tabellenkopf). Ob das Panel schwebt, entscheidet `placePanel` und schreibt es als
  `data-floating` an das Panel selbst — nicht der Stylesheet aus Klassen am Grid.
  Drei Aufgaben: öffnen/schließen (Escape, Klick außen; gleitet ein über `column-picker-entering`
  am Grid, einen Frame beim Öffnen, den ganzen Weg beim Schließen; schwebend sitzt das Panel 10 px
  neben der Liste, `placePanel`), die **Passung** messen (Listenbreite minus Nr. und Titel, ohne Auslöserzelle
  gegen die Mindestbreiten in Rangfolge, `data-fit` am `<table>`, Grenzlinie im Panel an dieselbe
  Stelle; neu bei jedem Resize der Listenspalte und jedem Frame-Load) und jede Änderung **sofort
  speichern** (User 07.09.2026: kein Entwurf): PATCH `cols[]` an den `columns`-Endpunkt des Ordners
  oder der Grundansicht, dann `frame.reload()`. Nur „für alle Ansichten übernehmen" ist ein
  eigener Schritt (Formular, `fillApplyForm`). Nicht änderbare Ansicht: `editable=false`, keine
  Haken. Reine Teile ohne Imports in `lib/column_picker/fit.js` und `order.js` (node:test).
  ⚠️ `applyFit` liest die Mindestbreiten aus den Panel-Zeilen (`data-min`), ohne Panel aus den
  `th[data-col-min]`; beide kommen aus `ViewConfiguration::COLUMN_MIN_WIDTH_PX`.
* `table_config`, `view_config_modal` und `filter_bar_legacy` sind gelöscht (07.09.2026):
  sie bedienten die Legacy-Filterleiste und ihr Ein-Listen-Modal, und mit dem Flag
  `new_filter_bar?` ist beides weg. `smart_folder_display` ist ebenfalls gelöscht
  (der Spaltenabschnitt des Expertenformulars ist weg, D8).

- **`lane_split`** (Tickets UND Wissen seit 10.09.2026, Schlüssel je Kontext) — die Grenze zwischen Liste und Detailbahn, gezogen am Griff auf der
  Trennlinie. EIN Wert besitzt sie: `--list-split` am Grid, gelesen von der Spur UND vom
  Griff, damit der Griff nicht von der Kante wegläuft, die er verschiebt. Gespeichert als
  ANTEIL (localStorage, je Bereich), angewendet in Pixeln: eine gemerkte Pixelbreite vom
  großen Monitor lässt auf dem Notebook eine handygroße Liste übrig.
- **`list_row`** (bis 10.09.2026 `ticket_row`; `knowledge_row` ist darin aufgegangen,
  `doc/wissen_als_bahn_plan.md` S2) sitzt auf der Ticket-Tabellenzeile, der Board-Karte
  UND der Wissen-Zeile: ein Controller, drei Mounts. Values: `url` (die DETAIL-Adresse,
  die der Frame lädt), `id`, `param` (der eigene Auswahlparameter), `params` (ALLE der
  Seite, sie schließen sich aus), `frame`, `navigate` (Meeting-Treffer verlassen die
  Seite). Die Adresslogik ist rein in `lib/list_row/address.js` (node:test). Die eine
  Markierung heißt `.selected-row` (Server-Zeile und Client gleich). Die Adresse ist die Wahrheit (Index + `ticket_id`, gebaut
  aus `data-index-url` am Container, gefunden per `closest`), und jedes Element markiert
  sich auf `connect` selbst aus der Adresse; darum überlebt die Tönung jeden Karten- oder
  Board-Tausch ohne „nach X neu anwenden". `index_page` normalisiert den Deep-Link
  `/tickets/:id` beim Laden auf diese Adresse (D7). `kanban_board` öffnet nichts mehr
  (kein `openTicket`); er zieht, hält die Pfeile über einen `ResizeObserver` aktuell und
  scrollt die gewählte Karte per Rechtecken ins Bild (`revealSelected`, nie
  `scrollIntoView`). `kanban_ticket_modal` ist gelöscht. ⚠️ `turbo:frame-load` hört das
  Board in der Capture-Phase am `document`, aus dem Grund oben bei `ticket_selection`.
  ⚠️ Die Doppel-Sperre in `application.js` schlüsselt seitdem auf Methode + Ziel-Frame,
  nicht nur auf die Adresse: der Reload-GET des Boards nach „+ Ticket" wäre sonst im
  500-ms-Fenster verschluckt worden.
- **Bahn einer fremden Liste** (17.10.2026, „Alle Meetings“, PR 3): die Übersicht zeigt das
  Meeting eines Projekts in ihrer Bahn. `layout_toggle#syncFilterContext` gibt den Listenzustand
  nur Links und Formularen unter dem Index der Seite (`data-index-url`) UND unter dem Index, den
  der Kopf der Bahn nennt (`data-lane-index-url`, Regel in `lib/lane/filter_context.js`,
  node:test). Ohne den zweiten behielten Bearbeiten und Speichern den Filter vom Öffnen. Ein
  Löschen in der Bahn schickt `closeLane` (application.js): `layout_toggle#closeLane` schließt
  und nimmt `meeting_id` im SELBEN Eintrag aus der Adresse. `list_address` ist gelöscht, die
  Übersicht hat wie die Projektseite EINEN Adress-Schreiber (`layout_toggle#syncUrlFromFrame`).
  Dazu hängt `syncFilterContext` den Wert `laneContext` (bei der Übersicht
  `{"list_context":"organisation"}`) an jede Anfrage der fremden Bahn, auch an Links aus
  Broadcasts und Abschnitts-Aktualisierungen, die ohne Kontext gerendert wurden. Sonst lädt ein
  Klick auf „aktualisieren“ die Bahn im Projektmodus, und das nächste Speichern zeichnet die
  Liste der Übersicht nicht neu.
  Die Adresse nennt nur, was der Server geöffnet hat: eine `meeting_id`, die er nicht auflösen
  konnte, oder ein `new`, das er nicht gerendert hat, steht in `unresolvedSelection` (Name und
  Wert, `meeting_list_page_data`). `layout_toggle#dropUnresolvedSelection` nimmt sie beim
  Verbinden aus der Adresse, bevor `hasSelection()` und `index-page` sie lesen. Sonst öffnet
  ein gelöschtes oder fremdes Meeting eine leere Bahn.

## Mobile Anwendung (PR #807)

`mobile_shell` bedient den Projektwechsel (erst beim Öffnen als Lazy-Frame geladen),
Kopfwerkzeuge und Auswahlkopf. `neo_mobile_nav` enthält die Organisationsziele und
wechselt im Auswahlmodus zur Aktionsleiste. `mobile_ticket_list` ergänzt die zentrale
`ticket_selection` um langes Antippen und den nativen Editor-Dialog. Das Ergebnis
bleibt während des Bearbeitens im Dialog und danach in der Liste, einschließlich Undo.

Die Grenze ist `FULL_PAGE_BELOW_PX` aus `list_row/address` (1024), nicht
`MOBILE_BREAKPOINT` (768) der älteren Listen. Nur Ticket-Anfragen erhalten die
Viewport-Kennung. Kopf und Fuß sind sticky; das Dokument scrollt.
`viewport` ist Darstellungszustand und gehört in `ADDRESS_NOISE`, nicht zum Filter.
Projekt-Dialoge vor dem Turbo-Cache schließen. Das mobile Assistentenblatt
schließt erst bei `turbo:visit`; Klicks, abgebrochene Bestätigungen und
Turbo-Stream-Schreibaktionen lassen es offen. Browser-Regressionen laufen in `.github/workflows/guards.yml`.

Beim ganzen Frame-Tausch schützt `ticket_selection` die bisherige Seitenauswahl
während `event.detail.render` bis nach dessen DOM-Callbacks. Ein Timer schon
vor dem Render läuft zu früh ab, weil Turbo bis zur nächsten Zeichnung warten kann.
