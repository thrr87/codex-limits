# Rozszerzenie Codex Limits o Claude Code, Grok/xAI i OpenCode

**Stan researchu:** 2026-08-18

**Zakres:** architektura bieżącego repozytorium, oficjalne kontrakty CLI/API oraz rekomendowany zakres produktu

**Metoda:** analiza lokalnego kodu i testów oraz źródeł pierwotnych Anthropic, xAI i OpenCode; konkurencja tylko jako punkt odniesienia

> Aktualizacja runtime 2026-08-22: ten dokument jest analizą wstępną. Późniejszy spike wykazał, że Grok Build stable 1.0.5 nie wystawia `x.ai/billing` przez zewnętrzne `grok agent stdio` (`-32601 Method not found`), mimo że handler istnieje w źródle pagera/TUI. OpenCode `serve --pure` zużył około 736 MiB RSS i wykonał około 66 MiB zapisów inicjalizacyjnych. Obie integracje są dlatego odroczone poza v1; obowiązują [wyniki walidacji](multi-integration-v1-validation-spikes-2026-08-22.md), nie pierwotne rekomendacje implementacyjne poniżej.

## Werdykt

Da się rozszerzyć produkt, ale nie przez dodanie jednego ogólnego `Vendor` z trzema nowymi wartościami. Obecny Codex pełni jednocześnie trzy niezależne role:

1. źródła autorytatywnego limitu konta;
2. źródła lokalnej aktywności coding agenta;
3. silnika funkcji `Analyze with Codex`.

Claude Code, Grok/xAI i OpenCode mają różne pokrycie tych ról. Najlepszy, najmniej ryzykowny plan to:

1. wydzielić tylko wspólną tożsamość integracji, odczyt okien allowance i partycjonowanie historii;
2. dodać **Claude Pro/Max (local beta)** jako ostatnio zaobserwowane okna 5 h i 7 dni z oficjalnego `statusLine`;
3. dodać **OpenCode Local Activity**, bez udawania limitu konta;
4. zrobić ograniczony spike **Grok Build billing przez `x.ai/billing` ACP**, a po potwierdzeniu kilku wersji CLI udostępnić go jako beta;
5. traktować xAI API billing, Claude Organization i późniejsze silniki analizy jako oddzielne integracje.

Najważniejsze rozróżnienie produktowe:

- **Claude Code** może dostarczyć użycie subskrypcji, ale tylko jako zdarzeniowy, ostatnio zaobserwowany stan aktywnego CLI.
- **Grok Build** ma odczyt billingowy przez oficjalny CLI, lecz na niewersjonowanym rozszerzeniu ACP.
- **OpenCode** jest przede wszystkim agentem i agregatorem wielu providerów, a nie jednym providerem kontowym. Najlepiej nadaje się do lokalnych sesji, tokenów i szacowanego kosztu.

Jeżeli celem jest wyłącznie „pokaż wszystkie paski limitów w menu bar”, nie budowałbym tego tutaj. [CodexBar](https://github.com/steipete/CodexBar) już obsługuje Claude, Grok i OpenCode/OpenCode Go, jest aplikacją macOS na licencji MIT i ma znacznie szerszy katalog providerów. Własna implementacja ma sens tylko wtedy, gdy zachowujemy wyróżnik Codex Limits: provenance danych, Coverage/Confidence, lokalne Task Trees, Usage Receipts i ostrożne prognozy.

## 1. Dlaczego obecny kod nie jest jeszcze wielovendorowy

### 1.1. Konto i allowance

[`CodexClient.swift`](../../Sources/CodexLimits/CodexClient.swift) uruchamia wyłącznie Homebrew Codex z dwóch stałych ścieżek i łączy się przez `codex app-server --stdio`. Jedno odświeżenie uzgadnia:

- `account/rateLimits/read`;
- `account/usage/read`;
- `account/read`;
- aktualizacje push stanu konta.

Kod wybiera okno dokładnie `10080` minut jako główny limit. [`UsageModels.swift`](../../Sources/CodexLimits/UsageModels.swift), [`UsagePerToken.swift`](../../Sources/CodexLimits/UsagePerToken.swift) i [`MEASUREMENT-CONTRACT.md`](../MEASUREMENT-CONTRACT.md) również traktują tygodniowy allowance Codex jako podstawową domenę produktu.

[`UsageMonitor.swift`](../../Sources/CodexLimits/UsageMonitor.swift) ma przydatny szew — wstrzykiwane `fetchUsage` — ale utrzymuje jeden snapshot konta, jedną partycję historii, jeden kolektor lokalny i jeden zestaw prognoz. Brakuje identyfikatora źródła w próbkach oraz historii.

### 1.2. Lokalna aktywność

[`LocalActivityCollector.swift`](../../Sources/CodexLimits/LocalActivityCollector.swift) i parsery obok niego zakładają:

- katalog `~/.codex/sessions`;
- Codex rollout JSONL;
- projekcje `thread/list` i `thread/read`;
- zamknięty zestaw source kinds związanych z Codex;
- semantykę Codex task, turn, agent, compaction i token counters.

Normalizowane fakty są częściowo użyteczne dla innych agentów, ale discovery i wire format są całkowicie Codex-specific. Nowe źródła powinny mieć własne małe adaptery, a nie warunki `if vendor == ...` w parserze rolloutów.

### 1.3. Assisted Insights

[`CodexAssistedInsights.swift`](../../Sources/CodexLimits/CodexAssistedInsights.swift) jest osobnym, dużym przepływem opartym o Codex App Server: discovery modeli, izolowany thread, read-only sandbox, schema wyniku, przerwanie turnu oraz pomiar allowance przed i po analizie.

To już ma protokół serwisowy, więc później można dodać inny runner. Nie jest to jednak konieczne do dodania limitów lub lokalnej aktywności i nie powinno blokować pierwszych integracji.

### 1.4. Skala realnej zmiany

Najbardziej związane obszary mają obecnie około:

- 4,5 tys. linii w głównym widoku menu;
- 2,3 tys. linii w Assisted Insights;
- 1,9 tys. linii w lokalnym collectorze;
- 1,3 tys. linii w `UsageMonitor`;
- 25,6 tys. linii testów Swift.

To oznacza, że „neutralizacja nazw” nie jest właściwym pierwszym krokiem. Potrzebna jest mała granica danych i migracja historii, przy zachowaniu działającej ścieżki Codex bez przepisywania jej.

## 2. Macierz możliwości

| Integracja | Limit subskrypcji / reset | Lokalna aktywność | Billing API | Runner analizy | Ocena pierwszego wdrożenia |
|---|---|---|---|---|---|
| Codex | Pełny, odczyt live z App Server | Pełne lokalne taski i tokeny | Fakty konta przez App Server | Obecny | istnieje |
| Claude Pro/Max | 5 h i 7 dni przez `statusLine`; last observed | OTel lub lokalne sesje, osobny etap | Nie dla indywidualnego planu | Tylko BYO API key/chmura bez zgody na OAuth planu | łatwe–średnie |
| Claude Organization | Nie jest allowance Pro/Max | Analytics organizacyjne | Usage & Cost / Analytics API | API key | średnie–trudne |
| Grok Build / SuperGrok | `x.ai/billing` przez oficjalny CLI; kontrakt niewersjonowany | Sesje na dysku i opt-in OTel | Nie publiczny consumer REST | Oficjalny headless/ACP | średnie, beta |
| xAI API | Rate limits przepustowości, nie weekly allowance | Tylko aktywność wykonana przez dany klient | Management API: usage, saldo, spend limits | Responses API | łatwe–średnie |
| OpenCode generic | Brak wspólnego limitu providerów | Bardzo dobre session totals przez lokalny server | Brak wspólnego billing ledger | `opencode run`/server, ale deleguje do providera | łatwe dla Local Activity |
| OpenCode Go | Wewnętrzny endpoint ma rolling/weekly/monthly, ale nie jest publicznym kontraktem | Jak OpenCode | Console | Jak OpenCode | odłożyć |

## 3. Claude Code

### Co jest oficjalnie dostępne

Claude Code uruchamia skonfigurowany przez użytkownika skrypt `statusLine` i przekazuje mu JSON przez stdin. Udokumentowany schemat zawiera:

- `rate_limits.five_hour.used_percentage` i `resets_at`;
- `rate_limits.seven_day.used_percentage` i `resets_at`;
- model, session ID, wersję CLI;
- kontekst, tokeny bieżącego wywołania i szacowany koszt sesji.

Pola `rate_limits` pojawiają się dla subskrybentów Claude.ai Pro/Max po pierwszej odpowiedzi API; każde okno może być osobno nieobecne. Skrypt jest wywoływany zdarzeniowo, więc dane są ostatnio zaobserwowanym stanem, a nie gwarantowanym odczytem live. Źródło: [Claude Code status line](https://code.claude.com/docs/en/statusline).

Claude ma też oficjalny opt-in OpenTelemetry z tokenami, kosztami, sesjami, aktywnym czasem, agentami i narzędziami. To lepsza powierzchnia dla bogatej lokalnej telemetrii niż parsowanie zmiennego transcriptu, ale wymaga konfiguracji exportera i lokalnego OTLP receivera. Źródło: [Claude Code monitoring](https://code.claude.com/docs/en/monitoring-usage).

Tryb headless `claude -p` ma JSON/stream-json, structured output, usage oraz koszt. Jest dobry dla jawnie uruchamianej funkcji analizy, lecz nie dla odświeżania limitu: dummy prompt zużywa allowance i uruchamia agenta. Źródło: [Claude Code headless mode](https://code.claude.com/docs/en/headless).

Administracyjne Usage & Cost oraz Claude Code Analytics są właściwe dla organizacji, nie dla osobistego Pro/Max. Źródła: [Usage & Cost Admin API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api), [Claude Code Analytics API](https://platform.claude.com/docs/en/manage-claude/claude-code-analytics-api).

### Minimalny wariant

**Claude Pro/Max (local beta):**

1. użytkownik sam instaluje i loguje oficjalne CLI;
2. opt-in konfiguruje mały relay `statusLine`;
3. relay zapisuje atomowo tylko allowlistę: czas obserwacji, wersję CLI oraz oba okna użycia/resetu;
4. aplikacja pokazuje `seven_day` jako główne okno, `five_hour` jako dodatkowe;
5. UI zawsze pokazuje „last observed” i wiek próbki;
6. brak lub przeterminowanie danych jest stanem `unavailable/stale`, nigdy `0% used`;
7. istniejący `statusLine` nie jest automatycznie nadpisywany;
8. historia pozostaje lokalna, dopóki nie ma wspieranego identyfikatora konta.

### Co jest łatwe, a co trudne

| Element | Ocena | Powód |
|---|---:|---|
| Parse dwóch okien | łatwe | Jawny i prosty schemat JSON. |
| Mapowanie used → remaining | łatwe | `remaining = 100 - used`, z walidacją 0–100. |
| Cache i oznaczenie świeżości | łatwe–średnie | Atomowy zapis, out-of-order events, kilka aktywnych sesji. |
| Bezpieczny setup/uninstall relay | średnie | Jeden slot `statusLine` może być już używany. |
| Pełna lokalna telemetria OTel | średnie–trudne | Receiver, protobuf/HTTP lub gRPC, retry, deduplikacja i privacy. |
| Odczyt live bez aktywnego Claude | niewykonalne pasywnie | Brak indywidualnego read-only usage endpointu. |
| Stabilna historia wielu kont | trudne | `statusLine` nie daje trwałej tożsamości konta. |
| `Analyze with Claude` przez plan Pro/Max | no-go bez zgody | Produkt zewnętrzny nie powinien kierować własnych żądań przez OAuth/allowance użytkownika; użyć BYO API key lub chmury. |

Przed użyciem Agent SDK w produkcie trzeba też uwzględnić [warunki i compliance Claude Code](https://code.claude.com/docs/en/legal-and-compliance); nie należy bundlować CLI tylko dlatego, że jego repozytorium jest publiczne.

## 4. Grok Build i xAI

### 4.1. Konsumencki allowance Grok Build

Oficjalny consumer FAQ opisuje wspólny procentowy pool planów SuperGrok, używany przez różne produkty, z procentem, breakdownem i resetem w Settings → Usage. To nie jest to samo co teamowe xAI API prepaid/postpaid. Źródło: [Grok FAQ](https://docs.x.ai/grok/faq).

Najważniejsze odkrycie: oficjalne, otwartoźródłowe Grok Build implementuje custom ACP request `x.ai/billing`. W obecnym kodzie:

- handler pobiera authenticated Grok Build billing bez ujawniania credentials klientowi;
- preferuje `creditUsagePercent` i `currentPeriod`;
- `currentPeriod.type` rozróżnia weekly/monthly, a `start`/`end` są RFC 3339;
- odpowiedź może zawierać prepaid balance, PAYG i subscription tier;
- pager Grok sam wywołuje tę metodę i mapuje wynik do własnego widoku `/usage`.

Źródła pierwotne, przypięte do badanego commita `d71f6e0`:

- [`x.ai/billing` i schema response](https://github.com/xai-org/grok-build/blob/d71f6e0c1f5acc5469e503e192fe14824e6f8c90/crates/codegen/xai-grok-shell/src/extensions/billing.rs);
- [wywołanie ACP przez pager](https://github.com/xai-org/grok-build/blob/d71f6e0c1f5acc5469e503e192fe14824e6f8c90/crates/codegen/xai-grok-pager/src/app/effects/mod.rs);
- [mapowanie current period i percentage](https://github.com/xai-org/grok-build/blob/d71f6e0c1f5acc5469e503e192fe14824e6f8c90/crates/codegen/xai-grok-pager/src/app/effects/helpers.rs);
- [etykiety weekly/monthly i summary](https://github.com/xai-org/grok-build/blob/d71f6e0c1f5acc5469e503e192fe14824e6f8c90/crates/codegen/xai-grok-pager/src/views/credit_bar.rs).

To jest dużo lepsze niż scraping grok.com: aplikacja uruchamia user-managed `grok agent stdio`, inicjalizuje ACP i prosi oficjalny CLI o billing. Nie czyta `~/.grok/auth.json`, cookies ani prywatnych tokenów.

Ryzyko: `x.ai/billing` jest oficjalnym kontraktem implementacyjnym, lecz nie publicznym, wersjonowanym REST API. Ogólna dokumentacja ACP mówi, że przestrzeń `x.ai/*` może się rozszerzać i jest SpaceXAI-specific; sama metoda billing nie ma osobnej publicznej specyfikacji. Integracja powinna więc mieć capability probe, tolerant decoder, fixtures per wspierana wersja CLI i czytelny fallback `Grok billing unavailable`.

### 4.2. Lokalna aktywność Grok Build

Grok Build przechowuje sesje w `~/.grok/sessions/<encoded-cwd>/<session-id>/`. Oficjalny guide opisuje m.in. `summary.json`, `updates.jsonl`, `signals.json` oraz subagents. `updates.jsonl` jest autorytatywnym strumieniem ACP, ale niesie także treść i narzędzia. Źródło: [Grok Build sessions](https://github.com/xai-org/grok-build/blob/d71f6e0c1f5acc5469e503e192fe14824e6f8c90/crates/codegen/xai-grok-pager/docs/user-guide/17-sessions.md).

Bezpieczne minimum może czytać tylko allowlistę z `summary.json` i niesensytywne agregaty z `signals.json`: session ID, parent, projekt, model, czasy, liczba tur/subagentów. Dokładne per-turn token receipts lepiej oprzeć później na oficjalnym opt-in OTel niż na raw chat history. Grok OTel udostępnia `grok_code.token.usage` i zdarzenia turn/API/tool, lecz schema jest oznaczona jako alpha. Źródło: [Grok Build Monitoring Usage](https://github.com/xai-org/grok-build/blob/d71f6e0c1f5acc5469e503e192fe14824e6f8c90/crates/codegen/xai-grok-pager/docs/user-guide/24-monitoring-usage.md).

### 4.3. xAI API to osobna integracja

Oficjalny xAI Responses API ma streaming, structured outputs, usage i `cost_in_usd_ticks`, więc `Analyze with Grok` w trybie BYO API key jest relatywnie proste. Źródła: [xAI inference API](https://docs.x.ai/developers/rest-api-reference/inference), [xAI cost tracking](https://docs.x.ai/developers/cost-tracking).

Management API może zwracać teamowe usage, saldo prepaid oraz spending limits, ale wymaga osobnego Management Key i nie reprezentuje planu SuperGrok. Źródło: [xAI Billing Management API](https://docs.x.ai/developers/rest-api-reference/management/billing).

### Co jest łatwe, a co trudne

| Element | Ocena | Powód |
|---|---:|---|
| `Analyze with Grok` przez BYO API key | łatwe–średnie | HTTP/JSON, schema outputs i dokładny koszt requestu. |
| xAI API team billing | średnie | Stabilne API, ale Management Key, Keychain, team selection i paginacja. |
| Grok local session metadata | łatwe–średnie | Jawny układ katalogów i summary; trzeba wersjonować parser. |
| Grok Build allowance przez ACP | średnie / beta | Dobry technicznie flow, ale metoda jest niewersjonowana. |
| Dokładne lokalne token receipts | średnie–trudne | OTel alpha albo parsing richer session stream z ryzykiem privacy. |
| Bezpośredni consumer REST | brak wspieranego kontraktu | Nie ma publicznego API; nie używać prywatnego proxy/cookies. |
| Ujednolicenie SuperGrok i xAI API | błędne domenowo | To inne auth, pool i billing ledger. |

## 5. OpenCode

### OpenCode nie jest jednym providerem

OpenCode jest coding agentem i orchestratoriem wielu providerów. Provider i model są wymiarami jego sesji. Szczególne oferty `opencode`/Zen i OpenCode Go są dostawcami rozliczenia, ale nie należy z nich wnioskować o wszystkich sesjach OpenCode. Źródło: [OpenCode providers](https://opencode.ai/docs/providers/).

Najlepsza oficjalna powierzchnia integracji to lokalny server:

- `opencode serve --hostname 127.0.0.1 --port 0`;
- OpenAPI pod `/doc`;
- health, projects, sessions, children i providers;
- opcjonalne SSE events;
- Basic Auth przez zmienne środowiskowe.

Źródło: [OpenCode server](https://opencode.ai/docs/server/).

Aktualny schemat sesji ma skumulowane:

- `cost`;
- tokeny input/output/reasoning/cache read/cache write;
- provider/model/variant;
- agent, parent session, projekt, directory i timestamps.

Źródło: [OpenCode `Session.Info` v1.18.18](https://github.com/anomalyco/opencode/blob/v1.18.18/packages/opencode/src/session/session.ts#L224-L245).

To pozwala zbudować wartościową integrację bez czytania transcriptu i credentials. `opencode stats` nie ma maszynowego JSON, bezpośredni SQLite jest wewnętrznym storage, a `auth.json` jest poza zakresem. Oficjalne komendy i ich ograniczenia opisuje [OpenCode CLI](https://opencode.ai/docs/cli/).

### Minimalny wariant

**OpenCode Local Activity:**

1. uruchomić własny child `opencode serve` tylko na loopback;
2. wygenerować losowe Basic Auth wyłącznie dla procesu potomnego;
3. sprawdzić health i wersję;
4. pobrać projekty oraz bounded listę sesji;
5. dekodować tylko metadata/session totals;
6. normalizować sesje i parent/child do lokalnych faktów;
7. przechowywać źródło, wersję i czas obserwacji;
8. na początku używać pollingu, nie SSE;
9. nie pobierać messages/parts, bo odpowiedź niesie Source Content.

Koszt należy nazywać **OpenCode local estimated cost**, nie rachunkiem. Nie obejmuje użycia tego samego providera poza OpenCode ani rabatów, abonamentów czy billing corrections.

### OpenCode Go

Kod OpenCode v1.18.18 ma endpoint `GET /zen/go/v1/usage` z rolling/weekly/monthly percentage i `resetsAt`, ale endpoint nie jest wymieniony jako wspierany publiczny kontrakt i wymaga API key. Publiczne docs kierują użytkownika do console. Źródła: [OpenCode Go](https://opencode.ai/docs/go/), [implementacja endpointu v1.18.18](https://github.com/anomalyco/opencode/blob/v1.18.18/packages/console/app/src/routes/zen/go/v1/usage.ts).

Nie wdrażałbym go, dopóki OpenCode nie udokumentuje endpointu albo lokalny server nie zacznie proxy'ować usage bez ujawniania credentials.

### Co jest łatwe, a co trudne

| Element | Ocena | Powód |
|---|---:|---|
| Binary + health probe | łatwe | Oficjalny child server i JSON HTTP. |
| Sessions, token totals, cost, parent/child | łatwe–średnie | Są w `Session.Info`; potrzebna iteracja po projektach i tolerant decoding. |
| Provider/model discovery | łatwe | `GET /provider`; to katalog, nie quota. |
| Live SSE | średnie | Reconnect, bootstrap, dedupe i wersje eventów; zbędne w v1. |
| Per-turn/model/tool receipts | średnie–trudne | Wymaga messages/parts, które niosą treść. |
| Generic quota Anthropic/xAI/OpenAI | niewykonalne | OpenCode nie ma wspólnego billing ledger providerów. |
| OpenCode Go quota | technicznie średnie, produktowo wysokie ryzyko | Wewnętrzny endpoint i secret. |
| Wspólny runway Codex + OpenCode | błędne domenowo | Miesza allowance konta z lokalnym kosztem wielu providerów. |

## 6. Rekomendowana architektura

### 6.1. Nie jeden `Vendor`, tylko trzy niezależne capability boundaries

W warstwie kompozycji utrzymywać trzy osobne zestawy implementacji, wszystkie identyfikowane przez mały `IntegrationID`:

```text
AccountAllowanceSource  -> okna used/remaining/reset i świeżość
LocalActivitySource     -> lokalne sesje/task trees/tokeny/koszt z provenance
AssistedAnalysisRunner  -> jawnie uruchamiane wywołanie modelu
```

Na początku mogą to być value types z closure'ami, nie fabryki ani duża hierarchia protokołów. Każde źródło implementuje tylko zdolność, którą naprawdę ma:

- Codex: wszystkie trzy;
- Claude beta: tylko allowance;
- Grok Build beta: allowance + ograniczona local activity;
- xAI API: billing/runner, nie SuperGrok allowance;
- OpenCode: local activity, opcjonalnie runner;
- Claude Organization: billing/analytics, nie Pro/Max allowance.

### 6.2. Neutralny kontrakt allowance

Silnik prognozy potrzebuje mniej pól niż cały `UsageSnapshot`:

```text
AllowanceReading
  sourceID
  observedAt
  freshness: live | observed | stale
  primaryWindowID?
  windows[]
    id
    usedPercent
    resetsAt
    durationMinutes?
  accountIdentity?
```

Codex-specific facts — banked resets, lifetime tokens, credits — pozostają osobnymi faktami Codex. Nie tworzyć pustych odpowiedników dla Claude, Grok lub OpenCode.

Prognoza i guidance działają tylko, gdy źródło ma prawdziwe okno procentowe, reset i wystarczająco świeże próbki. OpenCode Local Activity nie przechodzi przez ten silnik.

### 6.3. Historia i migracja

Każda próbka historii musi mieć co najmniej `sourceID`. Klucz partycji powinien być semantycznie:

```text
(sourceID, stableAccountIdentity || localInstallationPartition)
```

Migracja istniejących rekordów bez `sourceID` przypisuje je do Codex. Claude i Grok bez stabilnego account ID pozostają w partycji lokalnej i nie są automatycznie synchronizowane między urządzeniami. Zmiana loginu bez wspieranego identity tworzy comparison break zamiast łączyć historie.

### 6.4. UI

Najmniejszy sensowny UI to selektor integracji albo osobne karty, nie suma procentów. Każda karta pokazuje:

- nazwę i typ źródła;
- primary/other windows tylko jeśli istnieją;
- `live`, `last observed` albo `stale`;
- Coverage i brakujące capability;
- provider-specific facts w osobnej sekcji;
- Local Activity oddzielnie od Account Allowance.

Nigdy nie agregować `65% Claude + 20% Grok` w jeden procent. Procenty mają różne koszty, okna i jednostki.

## 7. Kolejność wdrożenia i orientacyjny koszt

Szacunki zakładają jednego inżyniera znającego Swift/macOS, brak backendu, zachowanie bieżącej jakości testów i brak zmian w istniejących kontraktach vendorów. To widełki wdrożeniowe, nie kalendarzowe zobowiązanie.

| Etap | Zakres | Szacunek | Ryzyko |
|---|---|---:|---:|
| 0. Capability spikes | Fixtures rzeczywistych odpowiedzi Claude/Grok/OpenCode, wersje minimalne, auth modes | 2–4 dni | niskie |
| 1. Provider boundary | `IntegrationID`, allowance reading, historia per source, migracja Codex, UI source selection, regresje | 6–10 dni | średnie |
| 2. Claude Pro/Max beta | Relay statusLine, cache/TTL, konflikt istniejącego status line, 5 h/7 dni, stale UX | 4–7 dni | średnie |
| 3. OpenCode Local Activity | Child server, Basic Auth, projects/sessions, totals, parent/child, dedupe, Coverage | 4–7 dni | niskie–średnie |
| 4. Grok billing beta | ACP lifecycle, `x.ai/billing`, tolerant schema, weekly/monthly, fixtures kilku wersji/auth modes | 4–8 dni | średnie–wysokie |
| 5. Grok local metadata | Discovery sesji, summary/signals allowlist, trees, history | 3–6 dni | średnie |
| 6. xAI API billing | Management Key w Keychain, teams, usage/balance/spend, paginacja | 5–9 dni | średnie |
| 7. Rich OTel activity | Lokalny receiver i normalizacja dla jednego CLI | 8–15 dni na pierwszy source | wysokie |
| 8. Inny analysis runner | BYO key, model discovery, schema, privacy/preflight, cost, cancellation | 5–10 dni per ekosystem | średnie–wysokie |

Realistyczny pierwszy release wieloźródłowy to etapy 0–3: **około 3–5 tygodni**, jeśli obejmuje pełną migrację, UI i testy. Dodanie Grok billing beta zwiększa zakres o około tydzień i stały koszt compatibility maintenance.

## 8. Co byłoby naprawdę łatwe

- wykrywanie zainstalowanych CLI i wersji;
- dekodowanie Claude 5 h/7 dni z `statusLine`;
- OpenCode health/projects/session totals przez HTTP;
- podstawowe metadata sesji Grok Build;
- xAI Responses API z structured output i per-request cost;
- provider/model jako provenance lokalnej sesji;
- source selector i osobne karty, jeśli najpierw dodamy `sourceID` do historii.

## 9. Co byłoby naprawdę trudne

- zachowanie poprawnej historii przy zmianie loginu, gdy CLI nie daje stabilnej identity;
- odświeżanie Claude Pro/Max na żądanie bez zużycia allowance;
- utrzymanie Grok `x.ai/billing` mimo braku wersjonowanego publicznego kontraktu;
- generic provider quota przez OpenCode — nie istnieje taki ledger;
- per-turn tokeny i tool timing bez wciągania promptów/responses do pamięci aplikacji;
- porównywalny koszt między subscription, prepaid, PAYG i ceną lokalnie estymowaną;
- wspólny runway wielu providerów bez fałszywej normalizacji;
- bundlowanie lub automatyczne użycie cudzych credentials zgodnie z warunkami, prywatnością i Keychain;
- pełny multi-provider `Analyze`, bo obecne preflight, sandbox i pomiar overhead są Codex-specific.

## 10. Czego nie robić

- Nie tworzyć jednego szerokiego `VendorProtocol` z kilkunastoma optional methods.
- Nie przepisywać `CodexClient`; owinąć stabilną, istniejącą ścieżkę adapterem.
- Nie przedstawiać braku capability jako zera.
- Nie czytać Claude/Grok/OpenCode credentials ani browser cookies.
- Nie wykonywać dummy prompts dla odświeżenia limitów.
- Nie parsować tekstowego `opencode stats` ani bezpośrednio SQLite.
- Nie pobierać OpenCode messages lub Grok chat history w pierwszej wersji.
- Nie nazywać local estimated cost rachunkiem.
- Nie mieszać SuperGrok z xAI API ani OpenCode generic z OpenCode Go.
- Nie robić OTel receivera przed potwierdzeniem, że podstawowe integracje są używane.

## Rekomendowana decyzja

**Go**, ale jako produkt wieloźródłowy, nie „czterech równych vendorów”.

Najlepsza kolejność wartości do ryzyka:

1. **Claude allowance beta** — największa nowa wartość przy publicznym schemacie danych.
2. **OpenCode Local Activity** — najczystsza integracja techniczna i naturalne rozszerzenie Usage Receipts.
3. **Grok Build billing beta** — funkcjonalnie atrakcyjne, ale wymaga jawnego compatibility budget.
4. **Grok local metadata** — przydatne bez naruszania treści.
5. **xAI/Claude organization billing i alternatywni analysis runners** — tylko po osobnej walidacji popytu.

Jeżeli użytkownicy chcą jedynie pasków limitów, rekomendacja brzmi: użyć lub współtworzyć CodexBar. Jeżeli chcą zrozumieć, **dlaczego** allowance znika, które task trees je zużyły i jak wiarygodna jest prognoza, powyższy zakres rozszerza Codex Limits bez utraty jego najważniejszego kontraktu.

## Raporty szczegółowe

- [Claude Code integration feasibility](./claude-code-integration-feasibility-2026-08-18.md)
- [xAI / Grok provider feasibility](./xai-grok-provider-feasibility-2026-08-18.md)
- [OpenCode integration](./opencode-integration-2026-08-18.md)
