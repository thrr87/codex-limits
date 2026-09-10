# Claude Code jako dodatkowy vendor — wykonalność integracji

**Data:** 2026-08-18\
**Data dostępu do źródeł:** 2026-08-18\
**Zakres:** aplikacja `codex-limits`, Claude Code CLI, Claude Agent SDK, Claude API oraz administracyjne API Anthropic\
**Źródła:** wyłącznie oficjalna dokumentacja Anthropic i oficjalne repozytoria Anthropic

> **Status implementacyjny:** ten dokument zachowuje szeroki research wykonalności, ale jego warianty historii, modelu i sesji nie są autoryzacją v1. Normatywny zakres wyznaczają [PRD multi-integracji](../prd/multi-integration-workspace.md) oraz [wyniki spike'ów](multi-integration-v1-validation-spikes-2026-08-22.md): v1 przechowuje tylko ostatni allowlisted snapshot limitów, nie zapisuje modelu ani identyfikatora sesji i modyfikuje wyłącznie user settings po potwierdzeniu.

## Werdykt

Warto dodać **ograniczoną, lokalną integrację Claude Pro/Max w wersji beta**, opartą na danych, które aktywny Claude Code przekazuje do skonfigurowanego przez użytkownika `statusLine`. Da się z nich uzyskać wykorzystanie i reset okien `five_hour` oraz `seven_day`, a następnie odwzorować siedem dni jako limit główny, a pięć godzin jako limit dodatkowy.

Nie należy obiecywać pełnej równoważności z obecną integracją Codex. Claude Code nie udostępnia odpowiednika `codex app-server`, z którego zewnętrzna aplikacja może pasywnie i na żądanie odczytać kompletny stan konta. W szczególności brak wspieranego, indywidualnego API do pobierania bieżącego wykorzystania subskrypcji, stabilnej tożsamości konta, dziennych bucketów tokenowych, kredytów i pełnej historii. Dane `statusLine` są **ostatnio zaobserwowanym stanem podczas aktywności Claude Code**, nie gwarantowanym odczytem „live”.

Nie należy okresowo uruchamiać `claude -p`, aby wymusić odświeżenie limitów. Takie wywołanie zużywa limit, tworzy lub modyfikuje sesję i uruchamia agenta. Ponadto Anthropic zabrania bez wcześniejszej zgody oferowania logowania Claude.ai lub kierowania żądań produktu zewnętrznego przez poświadczenia i limity planów Free/Pro/Max. Dla funkcji, w których aplikacja sama pyta model, właściwym kontraktem jest klucz API użytkownika albo obsługiwany dostawca chmurowy.

## Obecny kontrakt aplikacji

### Pobieranie danych konta Codex

Obecna implementacja nie ma abstrakcji vendora. `CodexClient` jest bezpośrednim aktorem uruchamiającym proces `codex app-server --stdio` i utrzymującym sesję JSONL po stdio. Wykrywanie CLI obejmuje tylko `/opt/homebrew/bin/codex` i `/usr/local/bin/codex` (`Sources/CodexLimits/CodexClient.swift`).

W pojedynczym odświeżeniu aplikacja wysyła równolegle:

- `account/rateLimits/read`,
- `account/usage/read`,
- `account/read` z `refreshToken: false`.

Z odpowiedzi buduje `CodexFetchResult` i `UsageSnapshot`. Kontrakt produktu zakłada m.in. główne okno o `windowDurationMins == 10080`, dodatkowe okna, dzienne buckety tokenowe, fakty o koncie, kredyty, kontrolę wydatków i bankowane resety. Adres e-mail pełni funkcję stabilnej tożsamości partycjonującej historię. Zob. także [`docs/MEASUREMENT-CONTRACT.md`](../MEASUREMENT-CONTRACT.md).

### Sesje, lokalna aktywność i funkcje wspomagane

Drugi tor danych jest również specyficzny dla Codex:

- `thread/list` i `thread/read` przez `ReadOnlyThreadProjectionSource`,
- przyrostowe czytanie `~/.codex/sessions` jako rollout JSONL,
- enum źródła ograniczony do `codex-rollout-jsonl` i `codex-app-server-thread-list`,
- ścisła zgodność z konkretną wersją schematu/CLI.

„Analyze with Codex” ma osobny, rozbudowany przepływ: `model/list`, izolowane `thread/start`, `turn/start` i `turn/interrupt` oraz porównanie limitów przed i po operacji. Dodanie Claude jako źródła limitów nie czyni automatycznie tej funkcji wielovendorową.

### Rzeczywiste punkty rozszerzeń

Najbardziej użyteczne istniejące szwy to:

- `UsageMonitor` przyjmuje wstrzykiwane `fetchUsage: () async throws -> CodexFetchResult`;
- `UsageSnapshot` jest w dużej mierze neutralnym modelem limitów i historii;
- lokalny collector przyjmuje opcjonalne źródło projekcji wątków.

To nie jest jednak gotowy interfejs providera. Typ wyniku, błędy, trwałe klucze, tożsamość konta, nazwy źródeł, UI i część logiki domenowej nadal są nazwane lub modelowane pod Codex. Najmniejsza sensowna zmiana architektoniczna powinna wydzielić tylko **źródło snapshotu konta i identyfikator vendora**, nie uniwersalną abstrakcję wszystkich funkcji agenta.

## Co oficjalnie udostępnia Claude Code

### CLI i formaty wyjścia

Claude Code obsługuje tryb nieinteraktywny przez `claude -p`. CLI oferuje:

- `--output-format text`, `json` lub `stream-json`,
- `--input-format text` lub `stream-json`,
- opcjonalne częściowe zdarzenia strumieniowe,
- `--json-schema` do walidacji wyniku strukturalnego,
- `--model` z aliasem lub pełnym identyfikatorem,
- `--max-budget-usd` i `--max-turns`,
- `--session-id`, `--resume`, `--continue` i `--fork-session`,
- wyłączenie trwałości sesji.

Wynik JSON/SDK zawiera identyfikator sesji i metadane. Końcowy komunikat `result` ma m.in. czas, liczbę tur, łączne `usage`, użycie per model oraz szacowany `total_cost_usd`. Strumień `stream-json` jest sekwencją rekordów JSON rozdzielonych znakami nowej linii.

Źródła: [CLI reference](https://code.claude.com/docs/en/cli-reference), [headless mode](https://code.claude.com/docs/en/headless), [Agent SDK — TypeScript types](https://code.claude.com/docs/en/agent-sdk/typescript), [streaming vs single mode](https://code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode).

**Znaczenie dla produktu:** jest to dobry kontrakt dla wywołań modelu inicjowanych przez aplikację, ale zły mechanizm pasywnego monitora subskrypcji. Każde zapytanie jest realną pracą agenta i może kosztować pieniądze lub limit.

### Sesje

Sesję można wznowić po jej ID albo sforkować. Lokalne sesje Claude Code są zapisywane jako JSONL w `~/.claude/projects/<project>/<session-id>.jsonl`; domyślne czyszczenie nieaktywnych sesji następuje po 30 dniach, o ile konfiguracja nie mówi inaczej. Lokalizację konfiguracji można zmienić przez `CLAUDE_CONFIG_DIR`, a sesję z `-p` można uruchomić bez trwałego zapisu.

Agent SDK ma lokalne operacje `list_sessions`, `get_session_info` oraz `get_session_messages`. Według oficjalnego cookbooka czytają pliki lokalne i nie uruchamiają subprocessu ani API. To obiecująca późniejsza ścieżka dla listy aktywności, lecz nie daje limitów konta, a zależność od SDK/runtime'u oraz prywatność treści wymagają osobnego projektu.

Źródła: [Claude Code sessions](https://code.claude.com/docs/en/sessions), [Agent SDK sessions](https://code.claude.com/docs/en/agent-sdk/sessions), [official session-browser cookbook](https://platform.claude.com/cookbook/claude-agent-sdk-05-building-a-session-browser).

### Modele

CLI przyjmuje aliasy (`default`, `sonnet`, `opus`, `haiku` i warianty providerów) albo pełne identyfikatory. Alias `default` zależy od konta i może zmieniać się wraz z aktualizacjami Claude Code. Dla wywołań API dostępne modele można pobrać z `GET /v1/models`.

Integracja nie powinna utrwalać znaczenia aliasu jako stałego modelu. W snapshotach/telemetrii należy zachować otrzymany pełny `model.id`, a alias traktować wyłącznie jako wybór użytkownika.

Źródła: [model configuration](https://code.claude.com/docs/en/model-config), [Models API](https://platform.claude.com/docs/en/api/models/list).

## Autoryzacja i rozdział subskrypcji od API

Claude Code może korzystać z:

- konta Claude.ai z planem subskrypcyjnym,
- konta Anthropic Console / klucza API,
- Amazon Bedrock,
- Google Vertex AI,
- Microsoft Foundry,
- bramy z tokenem bearer lub helperem klucza,
- długowiecznego setup tokenu.

Na macOS poświadczenia Claude.ai są przechowywane w Keychain. Aplikacja monitorująca nie powinna ich czytać ani kopiować. Użytkownik powinien instalować i logować oficjalne CLI samodzielnie.

CLI udostępnia też `claude auth status` do sprawdzenia bieżącego stanu uwierzytelnienia. Oficjalna dokumentacja nie ustanawia jednak trwałego schematu JSON tej komendy ani stabilnego identyfikatora konta. Można jej później użyć jako wersjonowanego, best-effort health checku, ale nie jako kontraktu tożsamości do łączenia historii.

Najważniejsze ograniczenie produktowe brzmi: bez wcześniejszej zgody Anthropic deweloper zewnętrzny nie może oferować w swoim produkcie logowania przez Claude.ai ani kierować zapytań przez poświadczenia i limity planów Free, Pro lub Max użytkownika. Dokumentacja Agent SDK nakazuje dla agentów w produktach zewnętrznych użyć uwierzytelniania kluczem API. To rozdziela dwa przypadki:

1. **Pasywna obserwacja lokalnego CLI użytkownika** — możliwa bez przejęcia poświadczeń, jeżeli aplikacja tylko odbiera dane, które oficjalny Claude Code przekazuje lokalnemu `statusLine`.
2. **Wywoływanie Claude przez aplikację** — wymaga osobnego klucza API/chmury albo formalnej zgody Anthropic; nie powinno korzystać z subskrypcyjnego OAuth Claude.ai.

Źródła: [Claude Code authentication](https://code.claude.com/docs/en/authentication), [Agent SDK quickstart](https://code.claude.com/docs/en/agent-sdk/quickstart), [legal and compliance](https://code.claude.com/docs/en/legal-and-compliance), [API authentication](https://platform.claude.com/docs/en/manage-claude/authentication), [API overview](https://platform.claude.com/docs/en/api/overview).

| Wariant | Rozliczenie / limit | Dane dostępne lokalnie | Właściwe zastosowanie |
|---|---|---|---|
| Claude.ai Pro/Max w oficjalnym CLI | pięcio- i siedmiodniowe allowance planu | `statusLine`, a w sesji SDK także `RateLimitEvent` | pasywna obserwacja stanu aktywnego CLI; bez wywołań agenta przez produkt zewnętrzny |
| Anthropic API key | usage-based billing oraz RPM/ITPM/OTPM | usage wyniku, estymowany koszt, nagłówki rate-limit | funkcje aplikacji rzeczywiście wywołujące Claude |
| Bedrock / Vertex / Foundry | zasady i rozliczenie danego providera | zależne od providera i konfiguracji | firmowe wywołania modelu, osobny adapter rozliczeń |
| Console organization | API billing + dane organizacyjne | Admin Usage & Cost / Claude Code Analytics | raportowanie zespołu/organizacji, nie indywidualny allowance Pro/Max |
| Claude Enterprise | kontrakt enterprise | Enterprise Analytics API | centralne raportowanie organizacji, inny produkt niż lokalny monitor subskrypcji |

## Jakie dane o użyciu i limitach są dostępne

### 1. `statusLine`: najlepsze źródło dla Pro/Max

Claude Code pozwala skonfigurować pojedynczy skrypt `statusLine`. CLI wielokrotnie wysyła do niego JSON na stdin. Schemat obejmuje m.in. wersję CLI, ID sesji, model, koszt sesji, kontekst oraz `rate_limits`.

Udokumentowane okna to:

- `rate_limits.five_hour.used_percentage` i `resets_at`,
- `rate_limits.seven_day.used_percentage` i `resets_at`.

`used_percentage` jest liczbą od 0 do 100, a `resets_at` czasem Unix w sekundach. Dokumentacja zaznacza, że `rate_limits` pojawia się tylko u subskrybentów Claude.ai Pro/Max, dopiero po pierwszej odpowiedzi API, a poszczególne okna mogą być nieobecne.

Konsekwencje:

- jest to stan zdarzeniowy, nie endpoint odpytywany na żądanie;
- gdy Claude Code nie działa, cache się nie odświeża;
- pierwszy rekord sesji może nie mieć limitów;
- pojedynczy wpis konfiguracyjny może kolidować z istniejącym status line użytkownika;
- JSON zawiera znacznie więcej informacji niż potrzebujemy, więc relay powinien zapisywać tylko minimalne pola i nigdy surowy payload.

Źródło: [Claude Code status line](https://code.claude.com/docs/en/statusline).

### 2. `RateLimitEvent` Agent SDK: bogatsze, lecz niepasywne

Python Agent SDK dokumentuje `RateLimitEvent` z `RateLimitInfo`:

- `status`: `allowed`, `allowed_warning` albo `rejected`,
- `rate_limit_type`: `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet` albo `overage`,
- `resets_at` jako Unix seconds,
- `utilization` od 0 do 1,
- status overage, reset i powód wyłączenia,
- `session_id`, UUID zdarzenia i surowe dane.

Jest to atrakcyjny, strukturalny kontrakt, ale zdarzenie należy do sesji prowadzonej przez SDK. Oficjalne API nie dokumentuje pasywnego „podłączenia” do cudzej, już działającej sesji Claude Code. Uruchomienie pustego/dummy promptu wyłącznie po to, aby dostać event, zużywa limit i wchodzi w opisane wyżej ograniczenie auth dla produktu zewnętrznego.

Źródło: [Agent SDK — Python types](https://code.claude.com/docs/en/agent-sdk/python).

### 3. Tokeny i koszt pojedynczego wywołania

Komunikaty asystenta zawierają zużycie danego kroku, a końcowy `ResultMessage` skumulowane zużycie całego zapytania i `total_cost_usd`. Usage rozróżnia input, output, cache read i cache creation oraz może być podzielone per model.

Anthropic zastrzega, że koszt SDK jest estymacją po stronie klienta: może różnić się od rachunku wskutek zmiany cen, nieznanych identyfikatorów modeli lub umów niestandardowych. Do rozliczeń organizacji należy używać Usage & Cost Admin API.

Źródła: [Agent SDK cost tracking](https://code.claude.com/docs/en/agent-sdk/cost-tracking), [TypeScript result types](https://code.claude.com/docs/en/agent-sdk/typescript), [Python result types](https://code.claude.com/docs/en/agent-sdk/python), [Claude Code costs](https://code.claude.com/docs/en/costs).

### 4. OpenTelemetry: dobre dla lokalnej aktywności, nie dla pozostałego limitu

Claude Code może opcjonalnie eksportować metryki i zdarzenia przez OTLP albo Prometheus. Oficjalny schemat obejmuje m.in.:

- `claude_code.cost.usage`,
- `claude_code.token.usage` z input/output/cache read/cache creation,
- sesje, linie kodu, commity, PR-y i aktywny czas,
- event `claude_code.api_request` z estymowanym kosztem, tokenami, modelem, czasem i ID requestów,
- atrybucję do agenta, skilla, pluginu, źródła zapytania i poziomu effort.

To lepszy długoterminowy kanał do lokalnych statystyk niż parsowanie niepublicznego kształtu transcriptów. Oficjalny schemat OTel nie udostępnia jednak pozostałego procentu ani resetu okna subskrypcji.

Źródło: [Claude Code monitoring usage](https://code.claude.com/docs/en/monitoring-usage).

### 5. Bezpośrednie Claude API: inne limity niż subskrypcja

Messages API jest bezstanowe — klient przesyła pełną historię. Odpowiedzi podają input/output/cache usage; streaming wykorzystuje SSE (`message_start`, content block events, `message_delta`, `message_stop`), a końcowe użycie jest aktualizowane w `message_delta`.

Limity API to token-bucket RPM, ITPM i OTPM, a nie pięcio- i siedmiodniowe allowance Claude Code. Nagłówki odpowiedzi obejmują m.in.:

- `retry-after`,
- `anthropic-ratelimit-requests-{limit,remaining,reset}`,
- `anthropic-ratelimit-tokens-{limit,remaining,reset}`,
- analogiczne nagłówki input/output tokenów.

Reset ma format RFC 3339, a `remaining` może być zaokrąglone i odzwierciedla najbardziej restrykcyjny aktywny limit. Tych wartości nie wolno przedstawiać jako procentu tygodniowej subskrypcji.

Źródła: [Messages API](https://platform.claude.com/docs/en/api/typescript/messages/create), [streaming](https://platform.claude.com/docs/en/build-with-claude/streaming), [working with Messages](https://platform.claude.com/docs/en/build-with-claude/working-with-messages), [API rate limits](https://platform.claude.com/docs/en/api/rate-limits).

### 6. API administracyjne: wiarygodne, ale organizacyjne

Anthropic udostępnia trzy istotne klasy raportów:

- Usage & Cost API dla organizacji Console, z bucketami minutowymi/godzinnymi/dziennymi i podziałem m.in. na model i workspace;
- Claude Code Analytics API, z dziennymi statystykami per użytkownik: sesje, linie kodu, commity, PR-y, narzędzia, tokeny i szacowany koszt per model;
- Enterprise Analytics API z produktowym usage/cost.

Wymagają Admin API key albo Analytics API key, nie są dostępne dla indywidualnego konta i mają inną świeżość (np. Claude Code Analytics może opóźniać się około godziny). Cost report zwraca kwotę jako dziesiętny string w centach; implementacja finansowa powinna używać typu dziesiętnego, nie `Double`.

To dobry późniejszy vendor „Claude Organization”, ale nie zastępuje widoku bieżącego allowance Pro/Max.

Źródła: [Usage & Cost Admin API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api), [Cost Report schema](https://platform.claude.com/docs/en/api/admin/cost_report), [Claude Code Analytics API](https://platform.claude.com/docs/en/manage-claude/claude-code-analytics-api), [Claude Code usage schema](https://platform.claude.com/docs/en/api/admin/usage_report), [Analytics APIs overview](https://platform.claude.com/docs/en/manage-claude/analytics-api), [Enterprise cost report](https://platform.claude.com/docs/en/api/admin/analytics/cost).

## Licencje i zależności

Repozytorium `anthropics/claude-code` jest publiczne, ale Claude Code CLI nie jest projektem open-source na licencji pozwalającej na swobodne bundlowanie. Jego `LICENSE.md` wskazuje „all rights reserved” i odsyła do Commercial Terms. To samo dotyczy natywnego binarium dołączanego przez TypeScript Agent SDK. Sam TypeScript SDK również wskazuje Commercial Terms.

Python Agent SDK wrapper ma licencję MIT, lecz nie relicencjonuje natywnego Claude Code ani jego warunków użycia. Oficjalny TypeScript SDK do bezpośredniego Claude API jest MIT.

Wniosek praktyczny:

- w MVP wykrywamy osobno zainstalowane oficjalne CLI; nie kopiujemy i nie redystrybuujemy binarium;
- przed ewentualnym bundlowaniem Agent SDK/binarium trzeba zaakceptować aktualne Commercial Terms i przejść przegląd prawny;
- nie nazywamy repozytorium Claude Code „open source” tylko dlatego, że kod/artefakty są widoczne na GitHubie.

Źródła: [Claude Code license](https://github.com/anthropics/claude-code/blob/main/LICENSE.md), [Claude Code repository](https://github.com/anthropics/claude-code), [TypeScript Agent SDK license](https://github.com/anthropics/claude-agent-sdk-typescript/blob/main/LICENSE.md), [TypeScript Agent SDK repository](https://github.com/anthropics/claude-agent-sdk-typescript), [Python Agent SDK license](https://github.com/anthropics/claude-agent-sdk-python/blob/main/LICENSE), [Anthropic TypeScript API SDK package](https://github.com/anthropics/anthropic-sdk-typescript/blob/main/package.json).

## Ocena trudności

| Obszar | Trudność | Uzasadnienie |
|---|---:|---|
| Wykrycie oficjalnego CLI i wersji | łatwe | Natywny installer i Homebrew mają udokumentowane ścieżki; potrzebna jest też `~/.local/bin/claude`, a nie tylko obecne ścieżki Codex. |
| Mapowanie `seven_day` i `five_hour` na `UsageSnapshot` | łatwe | Procent i reset mają jawny schemat; trzeba zachować semantykę „used”, źródło i czas obserwacji. |
| Wyświetlenie ostatnio zaobserwowanych limitów | łatwe–średnie | UI i snapshot są blisko potrzeb, ale produkt nie może sugerować odczytu live. |
| Relay `statusLine` z bezpiecznym setup/uninstall | średnie | Jeden slot konfiguracyjny, możliwy istniejący skrypt, wiele procesów, out-of-order events, atomowy cache i minimalizacja danych. |
| Historia i prognoza tylko z próbek aplikacji | średnie | Da się użyć istniejącego silnika, ale wymaga partycjonowania vendora, fresh/stale semantics i zakazu fabrykowania dziennych bucketów. |
| Lokalna aktywność z OTel | średnie | Schemat jest wspierany, lecz aplikacja musi utrzymać receiver, konfigurację, retry i deduplikację; nadal brak allowance. |
| Lista lokalnych sesji przez Agent SDK | średnie | Read-only API jest wspierane, ale trzeba dodać runtime/SDK lub osobny helper, politykę prywatności i wersjonowanie. |
| Organizacyjne usage/cost | średnie–trudne | API są formalne, ale dochodzą klucze Admin/Analytics, Keychain, sieć, paginacja, opóźnienie i inny model produktu. |
| Pełna równoważność indywidualnego konta z Codex | trudne / niewykonalne obecnie | Brak pasywnego API dla usage, stable identity, dziennych bucketów, kredytów i bankowanych resetów. |
| „Live refresh” Pro/Max bez aktywności Claude | niewykonalne bez skutków ubocznych | Wymagałoby wykonania zapytania agenta, które zużywa limit i narusza oczekiwany pasywny charakter. |
| „Analyze with Claude” przez subskrypcję użytkownika | trudne prawnie i technicznie | Third-party product nie może bez zgody kierować żądań przez OAuth/limity Free/Pro/Max; osobny tryb API-key jest możliwy. |
| Task Tree w pełnej parytecie | trudne | Brak odpowiednika `thread/list`/`thread/read`, osobne subagenty, retencja i zmienność transcriptów; wymaga osobnego kontraktu UX i danych. |
| Poprawna historia dla wielu kont | trudne | `statusLine` nie dokumentuje stabilnej tożsamości konta. Bez niej nie wolno łączyć próbek różnych loginów. |

## Rekomendowany minimalny wariant

### Produkt

Nazwa funkcji: **Claude Pro/Max (local beta)**. Widok powinien mówić „ostatnio zaobserwowane podczas aktywności Claude Code” i pokazywać czas ostatniego eventu.

Zakres MVP:

1. Użytkownik sam instaluje i loguje oficjalne Claude Code.
2. Po świadomym opt-in aplikacja konfiguruje mały lokalny relay `statusLine` wyłącznie w user settings albo podaje instrukcję ręcznej konfiguracji. Nie skanuje ustawień project, local-project ani managed; wyższe zakresy pozostają nietknięte i mogą przesłonić wpis użytkownika.
3. Jeżeli user settings zawiera już `statusLine`, MVP nie nadpisuje go automatycznie. Pokazuje konflikt i instrukcję manualną. Łańcuchowanie dowolnego polecenia użytkownika można zaprojektować później.
4. Relay waliduje wejście, odrzuca niepotrzebne pola i atomowo zapisuje wyłącznie:
   - wersję schematu relay,
   - `observedAt`,
   - wersję CLI,
   - `five_hour.used_percentage` i `resets_at`,
   - `seven_day.used_percentage` i `resets_at`.
5. Aplikacja czyta cache lokalnie. `seven_day` staje się limitem głównym, `five_hour` dodatkowym; `remaining = 100 - used_percentage`.
6. Brak danych jest normalnym stanem. Settings wyjaśnia, że snapshot pojawia się po pierwszej odpowiedzi na kwalifikującym się koncie Pro/Max. Dane po ustalonym TTL są jawnie oznaczone jako nieaktualne, nie zerowane.
7. v1 zachowuje wyłącznie ostatni poprawny snapshot. Nie tworzy historii, sztucznych dziennych token buckets, kosztów, faktów lifetime ani kredytów.
8. Snapshot Claude jest lokalny dla instalacji. Synchronizacja między urządzeniami i automatyczne łączenie pozostają wyłączone, dopóki nie powstanie wspierany identyfikator konta i osobna decyzja retencyjna.
9. Local Task Tree i „Analyze with Codex” pozostają Codex-only, z jawną etykietą.

### Minimalna zmiana architektury

Nie budować od razu „uniwersalnego agent runtime”. Wystarczy mały kontrakt źródła account snapshot, np. semantycznie:

```swift
enum VendorID { case codex, claudeCode }

struct VendorFetchResult {
    let vendor: VendorID
    let snapshot: UsageSnapshot
    let freshness: SourceFreshness
    let accountIdentity: VendorAccountIdentity?
    let capabilities: VendorCapabilities
}
```

Capabilities powinny jawnie określać brak: account daily tokens, lifetime facts, credits, local activity, sync identity i assisted analysis. Dzięki temu UI nie wywnioskuje funkcji z pustych tablic i nie nazwie braku danych zerem.

Codex zachowuje obecny client i pełny zestaw możliwości. Claude dostaje osobny, mały adapter cache relay. Dopiero realna druga implementacja pokaże, które nazwy i typy warto uczynić neutralnymi.

## Etapy po MVP

1. **Provider boundary:** vendor w snapshotach, historii i UI; bez zmiany transportu Codex.
2. **Claude Pro/Max beta:** read-only cache z `statusLine`, current allowance i reset, jawna świeżość.
3. **Lokalna aktywność:** opcjonalny OTel receiver; ewentualnie Agent SDK read-only sessions po osobnej ocenie dependency/privacy.
4. **Claude Organization:** Claude Code Analytics oraz Usage & Cost Admin API, jako oddzielny typ konta.
5. **Assisted analysis:** tylko w trybie BYO API key / Bedrock / Vertex / Foundry, nigdy automatycznie przez subskrypcję Claude.ai bez zgody Anthropic.

## Warunki go/no-go

**Go:** opt-in beta pokazująca ostatnio zaobserwowane okna Pro/Max, bez odczytu credentiali, bez wywoływania modelu i bez obietnicy live/parytetu.

**No-go:** marketing funkcji jako pełnego odpowiednika Codex; polling przez dummy prompts; przejmowanie OAuth Claude.ai; nadpisywanie istniejącego status line; mieszanie RPM/TPM API z allowance Pro/Max; synchronizowanie historii bez stabilnej tożsamości konta.

Przed dystrybucją funkcji, która sama uruchamiałaby Claude Agent SDK z subskrypcyjną sesją użytkownika, potrzebna jest jednoznaczna zgoda Anthropic i przegląd aktualnych Commercial Terms.

## Źródła pierwotne — indeks

Wszystkie źródła odwiedzono 2026-08-18.

### Claude Code i Agent SDK

- [CLI reference](https://code.claude.com/docs/en/cli-reference)
- [Headless mode](https://code.claude.com/docs/en/headless)
- [Authentication](https://code.claude.com/docs/en/authentication)
- [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance)
- [Status line](https://code.claude.com/docs/en/statusline)
- [Settings scopes and precedence](https://code.claude.com/docs/en/settings)
- [Costs](https://code.claude.com/docs/en/costs)
- [Errors and usage limits](https://code.claude.com/docs/en/errors)
- [Sessions](https://code.claude.com/docs/en/sessions)
- [Hooks](https://code.claude.com/docs/en/hooks)
- [Monitoring usage / OpenTelemetry](https://code.claude.com/docs/en/monitoring-usage)
- [Data usage](https://code.claude.com/docs/en/data-usage)
- [How Claude Code works](https://code.claude.com/docs/en/how-claude-code-works)
- [Setup](https://code.claude.com/docs/en/setup)
- [Model configuration](https://code.claude.com/docs/en/model-config)
- [Agent SDK quickstart](https://code.claude.com/docs/en/agent-sdk/quickstart)
- [Agent SDK TypeScript](https://code.claude.com/docs/en/agent-sdk/typescript)
- [Agent SDK Python](https://code.claude.com/docs/en/agent-sdk/python)
- [Agent SDK cost tracking](https://code.claude.com/docs/en/agent-sdk/cost-tracking)
- [Agent SDK sessions](https://code.claude.com/docs/en/agent-sdk/sessions)
- [Agent loop](https://code.claude.com/docs/en/agent-sdk/agent-loop)
- [Streaming vs single mode](https://code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode)
- [Official session-browser cookbook](https://platform.claude.com/cookbook/claude-agent-sdk-05-building-a-session-browser)

### Claude API i administracja

- [API authentication](https://platform.claude.com/docs/en/manage-claude/authentication)
- [API overview](https://platform.claude.com/docs/en/api/overview)
- [Messages API](https://platform.claude.com/docs/en/api/typescript/messages/create)
- [Streaming Messages](https://platform.claude.com/docs/en/build-with-claude/streaming)
- [Working with Messages](https://platform.claude.com/docs/en/build-with-claude/working-with-messages)
- [Models API](https://platform.claude.com/docs/en/api/models/list)
- [API rate limits](https://platform.claude.com/docs/en/api/rate-limits)
- [Usage & Cost Admin API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api)
- [Cost Report schema](https://platform.claude.com/docs/en/api/admin/cost_report)
- [Claude Code Analytics API](https://platform.claude.com/docs/en/manage-claude/claude-code-analytics-api)
- [Claude Code usage report schema](https://platform.claude.com/docs/en/api/admin/usage_report)
- [Analytics APIs overview](https://platform.claude.com/docs/en/manage-claude/analytics-api)
- [Enterprise cost report](https://platform.claude.com/docs/en/api/admin/analytics/cost)

### Oficjalne repozytoria i licencje

- [Claude Code](https://github.com/anthropics/claude-code)
- [Claude Code license](https://github.com/anthropics/claude-code/blob/main/LICENSE.md)
- [TypeScript Agent SDK](https://github.com/anthropics/claude-agent-sdk-typescript)
- [TypeScript Agent SDK license](https://github.com/anthropics/claude-agent-sdk-typescript/blob/main/LICENSE.md)
- [Python Agent SDK license](https://github.com/anthropics/claude-agent-sdk-python/blob/main/LICENSE)
- [Anthropic TypeScript API SDK package metadata](https://github.com/anthropics/anthropic-sdk-typescript/blob/main/package.json)
