# Codex Limits a metoda multi-provider z CodexBar

Data badania: 2026-08-21  
Zakres: porównanie architektury, kontraktów, kolejności prób, transportu, obsługi poświadczeń, normalizacji, odświeżania i błędów. To nie jest analiza ani propozycja kopiowania kodu CodexBar.

> Aktualizacja runtime 2026-08-22: późniejszy spike potwierdził granicę zaufania rekomendowaną w tym dokumencie, ale odrzucił dwa pierwotne źródła v1. Grok Build stable 1.0.5 zwraca `-32601 Method not found` dla `x.ai/billing` przez zewnętrzne ACP, a OpenCode `serve --pure` nie mieści się w budżecie pamięci i zapisów. Codex Limits nie przejmuje fallbacków CodexBar opartych na credentials, cookies ani prywatnych backendach, więc Grok i OpenCode są odroczone. Zobacz [wyniki walidacji](multi-integration-v1-validation-spikes-2026-08-22.md).

## Werdykt

Tak — warto zastosować **podobną metodę na poziomie architektury**: stała lista integracji, uporządkowane źródła danych dla każdej integracji, wspólny mały wynik znormalizowany oraz stan odświeżania przechowywany osobno dla każdego dostawcy i konta.

Nie — nie warto odtwarzać całego systemu CodexBar ani jego konkretnych sposobów pozyskiwania danych. Szeroki zasięg CodexBar jest osiągany między innymi przez prywatne endpointy, odczyt obcych poświadczeń, cookies przeglądarki, emulowanie terminala i parsowanie ekranów CLI. To podnosi koszt utrzymania, ryzyko pomylenia konta i powierzchnię bezpieczeństwa. Codex Limits powinien zachować obecną zasadę: w pierwszej kolejności używać oficjalnego, należącego do dostawcy procesu lub API, a źródło i pewność danych pokazywać jawnie.

Najlepszy wariant dla Codex Limits to zatem **„CodexBar-like pipeline, Codex Limits trust boundary”**:

1. istniejący `codex app-server --stdio` pozostaje bez zmian jako adapter Codex;
2. dokładamy mały kontrakt integracji i opcjonalną listę prób źródeł;
3. fallback zachodzi wyłącznie po błędzie sklasyfikowanym jako dostępność źródła, nigdy po niejednoznaczności konta lub danych;
4. nie importujemy automatycznie cookies, tokenów ani kluczy z innych aplikacji;
5. nie budujemy teraz dynamicznego systemu pluginów ani rozbudowanego rejestru metadanych.

## Wersja CodexBar objęta badaniem

Repozytorium zostało sprawdzone na bieżącym `main`:

- commit [`f74117aeb7a9ee02a78c0f08ca354ff26b2292e0`](https://github.com/steipete/CodexBar/commit/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0), z 2026-08-20;
- najnowsze wydanie: [`v0.54.0`](https://github.com/steipete/CodexBar/releases/tag/v0.54.0), opublikowane 2026-08-20;
- tag wydania wskazuje commit `22a2168842a9ed4fdd15dd6761cd109c56bcd3b5`.

Analiza i wszystkie odsyłacze do kodu CodexBar są przypięte do powyższego commitu `main`, aby późniejsza zmiana repozytorium nie zmieniła znaczenia raportu.

## Jak działa obecnie Codex Limits

Obecna integracja jest wąska, ale ma dobrą granicę zaufania:

- [`CodexClient`](../../Sources/CodexLimits/CodexClient.swift) wyszukuje wyłącznie lokalny program Codex w znanych lokalizacjach, uruchamia `codex app-server --stdio` i komunikuje się z nim przez standardowe wejście/wyjście;
- jedna paczka RPC odczytuje limity, użycie i konto; klient ponawia odczyt, jeśli podczas pobierania przychodzą aktualizacje, i nie publikuje niespójnej migawki;
- równoległe żądania współdzielą jedno trwające pobranie, a zerwane połączenie jest jednokrotnie odbudowywane;
- [`UsageMonitor`](../../Sources/CodexLimits/UsageMonitor.swift) utrzymuje jedną migawkę konta, jeden stan źródła i jedną partycję historii; nie uruchamia dwóch odświeżeń naraz i po błędzie zachowuje poprzednie dane ze statusem awarii;
- [`UsageModels`](../../Sources/CodexLimits/UsageModels.swift) i [`UsageHistory`](../../Sources/CodexLimits/UsageHistory.swift) są dziś semantycznie związane z Codexem: główne okno to tygodniowe `10080` minut, a klucz partycji historii identyfikuje konto, lecz nie dostawcę;
- [`LocalActivityCollector`](../../Sources/CodexLimits/LocalActivityCollector.swift) czyta lokalną aktywność wyłącznie z `~/.codex/sessions`;
- ADR [`0001`](../adr/0001-local-codex-app-server-as-usage-source.md) świadomie odrzuca kopiowanie poświadczeń i scraping GUI, a [`MEASUREMENT-CONTRACT`](../MEASUREMENT-CONTRACT.md) rozróżnia fakty konta, fakty lokalne i wartości pochodne oraz preferuje brak wyniku nad słabym szacunkiem.

To oznacza, że rozszerzenie nie powinno polegać na dopisaniu kolejnych warunków do `CodexClient`. Najpierw trzeba wynieść **tożsamość integracji i stan per integracja** o jeden poziom wyżej, pozostawiając sam klient Codex jako istniejącą, sprawdzoną implementację.

## Metoda CodexBar

### 1. Dostawca jest opisem zachowania, nie tylko nazwą

CodexBar ma zamkniętą, generowaną listę natywnych dostawców w [`ProviderManifest`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBarCore/Providers/ProviderManifest.swift#L1-L77). Każdy wpis jest rozwijany do obszernego [`ProviderDescriptor`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBarCore/Providers/ProviderDescriptor.swift#L298-L421), który łączy między innymi metadane, prezentację, ustawienia, poświadczenia, plan pobierania i konfigurację CLI. Rejestr przechowuje deskryptory w kolejności i umożliwia lookup po identyfikatorze.

W aplikacji istnieje druga, celowo cieńsza warstwa [`ProviderImplementation`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBar/Providers/Shared/ProviderImplementation.swift#L4-L98) oraz jej [`ProviderImplementationRegistry`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBar/Providers/Shared/ProviderImplementationRegistry.swift#L4-L47). Oddziela to rdzeń pobierania od dostępności runtime, ustawień i akcji UI.

Jest to skuteczne dla aplikacji obsługującej kilkadziesiąt dostawców, ale za duże dla czterech integracji w Codex Limits. W naszym przypadku statyczna tablica małych definicji będzie czytelniejsza; dynamiczna rejestracja nie daje jeszcze realnej korzyści.

### 2. Dostawca ma uporządkowany plan prób

Najbardziej wartościowym wzorcem jest [`ProviderFetchPlan`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBarCore/Providers/ProviderFetchPlan.swift#L114-L197) i wykonujący go [`ProviderFetchPipeline`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBarCore/Providers/ProviderFetchPlan.swift#L245-L393):

- plan rozwiązuje strategie w określonej kolejności;
- każda strategia potrafi określić dostępność, wykonać pobranie i zdecydować, czy dany błąd dopuszcza fallback;
- pierwsza prawidłowa odpowiedź kończy łańcuch;
- wynik zawiera nie tylko migawkę, lecz również identyfikator strategii, rodzaj źródła i diagnostykę prób;
- błędy są klasyfikowane, anulowanie nie jest traktowane jak zwykła awaria, a ograniczone ponowienie uwzględnia sugerowane opóźnienie.

To jest istota „metody CodexBar”, którą warto przenieść jako **własny kontrakt zachowania**, bez przenoszenia nazw, typów ani implementacji.

### 3. Wszystkie źródła normalizują się do wspólnej migawki

Wspólny model [`UsageSnapshot` i `RateWindow`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBarCore/UsageFetcher.swift#L3-L168) pozwala interfejsowi wyświetlać wyniki niezależnie od transportu. Model niesie okna limitów, czasy resetu, koszty, tożsamość i poziom pewności.

Jednocześnie w dojrzałym CodexBar wspólna migawka zgromadziła pola właściwe konkretnym dostawcom. To ostrzeżenie przed nadmierną unifikacją. Codex Limits powinien normalizować tylko część rzeczywiście wspólną: identyfikator integracji i konta, okna limitów, czas pobrania, pochodzenie, pewność i ewentualny koszt. Lokalna aktywność i dane specyficzne dla dostawcy powinny pozostać osobnymi składnikami.

### 4. Stan i odświeżanie są izolowane per dostawca

CodexBar przechowuje migawki, błędy, etykiety źródła i diagnostykę prób osobno dla każdego dostawcy. [`ProviderRefreshCoordinator`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBar/ProviderRefreshCoordinator.swift#L1-L127) nadaje żądaniom generacje, anuluje zastępowane prace i zapobiega opublikowaniu starszego wyniku po nowszym. Przepływ publikacji sukcesu i błędu jest widoczny w [`UsageStore+Refresh`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBar/UsageStore%2BRefresh.swift#L335-L477) oraz [obsłudze wyników](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBar/UsageStore%2BRefresh.swift#L640-L859). Przy istniejących danych pierwsza przejściowa awaria może zostać wygaszona przez [`ConsecutiveFailureGate`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBar/UsageStoreSupport.swift#L90-L109).

Codex Limits ma już prostszy odpowiednik dla jednego źródła. Po dodaniu dostawców potrzebuje kluczowania stanu `(integracja, konto)` i ochrony przed spóźnioną publikacją, ale nie musi kopiować rozbudowanego store'u CodexBar.

### 5. Kosztowne źródła mają osobny cache

CodexBar rozróżnia ręczne i automatyczne odświeżenia. Na przykład wynik komendy Claude może być używany w tle przez 15 minut, podczas gdy ręczne odświeżenie wymusza nowy odczyt; przekroczenie czasu resetu unieważnia cache. Pokazuje to [`ClaudeCLIUsageSpawnThrottle`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBar/ClaudeCLIUsageSpawnThrottle.swift#L3-L112).

W Codex Limits warto zachować jedno globalne domyślne tempo tylko dla lekkich źródeł. Każda integracja powinna móc zadeklarować minimalny odstęp pobierania i warunek unieważnienia przy resecie. Ręczne odświeżenie nie powinno omijać ograniczenia dostawcy, jeśli grozi to rate limitami lub otwieraniem promptów systemowych.

## Porównanie kontraktów

| Obszar | Codex Limits obecnie | CodexBar | Zalecenie dla Codex Limits |
|---|---|---|---|
| Lista dostawców | Jeden zaszyty Codex | Manifest + rozbudowany rejestr deskryptorów | Statyczna lista 4 integracji; bez runtime pluginów |
| Transport | Jedno trwałe RPC do `codex app-server` | HTTP, CLI, PTY, OAuth, cookies, lokalne pliki/bazy | Transport zamknięty wewnątrz adaptera; domyślnie provider-owned CLI lub publiczne API |
| Kolejność źródeł | Jedno źródło | Uporządkowany plan strategii z warunkowym fallbackiem | Mała lista prób tylko tam, gdzie istnieją co najmniej dwa uzasadnione źródła |
| Wynik | Codexowa migawka, główne okno tygodniowe | Wspólna migawka + źródło, strategia, diagnostyka i pewność | Minimalna wspólna migawka; bez pól vendor-specific w rdzeniu |
| Tożsamość | Partycja po koncie | Stan i konta per dostawca | Klucz `(integrationID, stableAccountID)`; brak łączenia historii przy niepewnej tożsamości |
| Odświeżanie | Jedno trwające pobranie, zachowanie starej migawki po błędzie | Koordynator per klucz, generacje, anulowanie, cache per źródło | Rozszerzyć obecny mechanizm o klucz i generację; nie przepisywać całego store'u |
| Diagnostyka | Jeden stan źródła | Lista prób i końcowe źródło | Zapisywać krótkie, zredagowane przyczyny prób; UI pokazuje źródło i świeżość |
| Poświadczenia | Należą do procesu Codex; aplikacja ich nie kopiuje | Własny Keychain, obce tokeny, cookies i loginy CLI zależnie od źródła | Zachować obecny trust boundary; własny Keychain tylko dla klucza wpisanego przez użytkownika |
| Lokalne dane | Sesje Codex i pomiary pochodne | Również logi i lokalne bazy innych klientów | Trzymać lokalną aktywność oddzielnie od autorytatywnych limitów |

## Konkretne integracje

### Codex — łatwe

CodexBar w trybie automatycznym potrafi próbować PAT, OAuth i CLI, a web pozostawia jako źródło jawnie wybrane. Kolejność jest opisana w [`CodexProviderDescriptor`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBarCore/Providers/Codex/CodexProviderDescriptor.swift#L28-L155). Bieżąca domyślna ścieżka CLI nie parsuje PTY: uruchamia jednorazowo `codex app-server`, odczytuje `account/rateLimits/read` i `account/read`, po czym zamyka proces ([`UsageFetcher`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBarCore/UsageFetcher.swift#L1124-L1170)). Osobny [`CodexStatusProbe`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBarCore/Providers/Codex/CodexStatusProbe.swift#L60-L146) istnieje jako inna powierzchnia diagnostyczna, nie jako opis domyślnego odczytu usage.

Codex Limits ma już głębszą dla swojego celu ścieżkę: utrzymuje połączenie z `app-server` i scala `account/rateLimits/read`, `account/usage/read` oraz `account/read` z aktualizacjami przychodzącymi w trakcie pobierania. Podstawowa ścieżka CLI CodexBar jest odczytem one-shot i nie ma odpowiednika pełnego `account/usage/read`. Oprócz bogatszych danych Codex Limits unika przejmowania OAuth/PAT i parsowania terminala. Należy tę ścieżkę jedynie opakować jako integrację `codex`. Trudność jest niska, a ryzyko regresji niewielkie, jeśli sam `CodexClient` pozostanie niezmieniony.

### Claude Code — średnio łatwe jako opt-in, trudne jako bezobsługowe źródło

CodexBar rozróżnia aplikację i runtime CLI. Dla aplikacji tryb automatyczny próbuje OAuth, CLI, a następnie web; dla runtime CLI preferuje web przed CLI. Wybrane konto jest granicą autorytetu: uszkodzone poświadczenia wybranego konta nie powinny po cichu przejść na konto ambient. Reguły są w [`ClaudeSourcePlanner`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBarCore/Providers/Claude/ClaudeSourcePlanner.swift#L169-L234) i [`ClaudeProviderDescriptor`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBarCore/Providers/Claude/ClaudeProviderDescriptor.swift#L231-L288).

W praktyce źródła obejmują bezpośredni odczyt OAuth, prywatne endpointy webowe z cookies oraz fallback przez PTY i parsowanie `/usage` lub `/status`; opisuje je dokumentacja [`docs/claude.md`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/docs/claude.md#L20-L134) i [sekcja CLI/logów](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/docs/claude.md#L201-L248).

Dla Codex Limits v1 rekomenduję **wyłącznie jawnie włączaną integrację z oficjalnym `statusLine`**. Obecna dokumentacja Claude Code definiuje dokładnie `rate_limits.five_hour` i `rate_limits.seven_day`, pola `used_percentage` i `resets_at`; wywołania są event-driven, a opcjonalny `refreshInterval` dodaje odświeżanie czasowe ([oficjalny kontrakt `statusLine`](https://code.claude.com/docs/en/statusline)). Ograniczenie jest uczciwe i mierzalne: dane pojawiają się dla subskrybentów Claude.ai po pierwszej odpowiedzi API w aktywnej sesji, więc nie jest to niezależny od sesji polling konta.

PTY można rozważyć dopiero jako osobny przyszły eksperyment kompatybilności, nie jako równorzędny fallback v1. Nie rekomenduję na start czytania tokenów OAuth Claude, cookies przeglądarki, prywatnych endpointów ani parsowania `/usage`. Wtedy „podobna metoda” oznacza pochodzenie, normalizację i izolację stanu, a nie ten sam dostęp do poświadczeń.

### xAI / Grok — dobry kandydat do średniego spike'u ACP

CodexBar planuje kolejno CLI ACP, proxy OAuth, web cookies i gRPC OAuth; plan widać w [`GrokProviderDescriptor`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBarCore/Providers/Grok/GrokProviderDescriptor.swift#L111-L201). Pierwsza strategia rzeczywiście uruchamia `grok agent stdio` i wywołuje `x.ai/billing`. Dokumentacja odnotowuje wersyjną usterkę `Method not found` w starym Grok `0.1.210`, po której CodexBar przechodzi do tokenu z `~/.grok/auth.json`, proxy CLI, cookies lub prywatnego gRPC. Szczegóły są w [`docs/grok.md`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/docs/grok.md#L11-L103) oraz [opisie poświadczeń i lokalnych sygnałów](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/docs/grok.md#L104-L206).

Aktualny `main` oficjalnego Grok Build, commit [`19d42e35`](https://github.com/xai-org/grok-build/commit/19d42e35c07a9c9244f03f6df0c4c353f970d4f9), nadal zawiera handler i schemat rozszerzenia [`x.ai/billing`](https://github.com/xai-org/grok-build/blob/19d42e35c07a9c9244f03f6df0c4c353f970d4f9/crates/codegen/xai-grok-shell/src/extensions/billing.rs#L1-L120). Oznacza to, że **czysty probe ACP jest dziś najbliższym kandydatem do metody Codex Limits**, choć dostępność w zainstalowanych wydaniach CLI nadal trzeba wykrywać w runtime.

Rekomendacja: niezależny spike `grok agent stdio` → initialize → `x.ai/billing`, z capability/version probe, tolerancyjnym dekoderem pól opcjonalnych, timeoutem, zabiciem procesu i wynikiem „source unavailable” przy braku metody. Nie dodawać fallbacku do tokenu z `auth.json`, cookies ani prywatnego gRPC. Jeśli oficjalny ACP nie jest dostępny w wersji użytkownika, pokazujemy lokalną aktywność albo brak limitu — nie obchodzimy kontraktu dostawcy.

### OpenCode — łatwe dla lokalnej aktywności, prywatne limity są trudne

Ważne jest rozróżnienie dwóch funkcji CodexBar:

- dostawca **OpenCode** odczytuje limity workspace z serwisu `opencode.ai` przez cookies przeglądarki i prywatne wywołania serwerowe; implementację wyboru źródła pokazuje [`OpenCodeProviderDescriptor`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBarCore/Providers/OpenCode/OpenCodeProviderDescriptor.swift#L23-L143);
- **OpenCode Go** próbuje lokalnej bazy, API i web. Lokalny wynik może zostać wzbogacony bardziej autorytatywnym API/web i jest oznaczany jako szacowany, gdy zostaje sam. Kolejność i merge opisuje [`OpenCodeGoProviderDescriptor`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBarCore/Providers/OpenCodeGo/OpenCodeGoProviderDescriptor.swift#L121-L305).

CodexBar czyta lokalną SQLite OpenCode Go w trybie read-only i rekonstruuje koszty z tabel wiadomości/części; szczegóły schematu i zapytań są w [`OpenCodeGoLocalUsageReader`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBarCore/Providers/OpenCodeGo/OpenCodeGoLocalUsageReader.swift#L49-L214). Dokumentacja [`docs/opencode.md`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/docs/opencode.md#L10-L50) opisuje różnicę między prywatną ścieżką web a API/local dla Go.

Dla Codex Limits najłatwiejszy sensowny zakres to lokalna aktywność OpenCode przez oficjalny `opencode serve`, nie przez bazę CodexBar. W aktualnym wydaniu [`v1.18.20`](https://github.com/anomalyco/opencode/releases/tag/v1.18.20) serwer publikuje OpenAPI, health, projekty, sesje, wiadomości/providerów i SSE ([oficjalna dokumentacja serwera](https://opencode.ai/docs/server/), [endpointy sesji przypięte do wydania](https://github.com/anomalyco/opencode/blob/7248bc1964b13fa67e601733f89ee9dc6dfa0563/packages/opencode/src/server/routes/instance/httpapi/groups/session.ts#L78-L188)). `SessionInfo` zawiera koszt, tokeny, model/provider oraz relację rodzic–dziecko ([oficjalny schemat](https://github.com/anomalyco/opencode/blob/7248bc1964b13fa67e601733f89ee9dc6dfa0563/packages/schema/src/v1/session.ts#L537-L568)). To jest bardzo bliski odpowiednik zasady użytej dziś z `codex app-server`, chociaż dostarcza lokalnej aktywności, a nie gwarantowanego limitu konta.

Bezpośrednie związanie się z wewnętrznym schematem SQLite jest umiarkowanie kruche i niepotrzebne, gdy istnieje lokalny serwer/OpenAPI; eksport i `opencode stats` mogą być fallbackiem dla starszych wersji ([oficjalne CLI](https://opencode.ai/docs/cli/)). Autorytatywne limity zwykłego OpenCode przez prywatne funkcje webowe nie pasują do v1. Jeśli celem jest OpenCode Go i istnieje publiczny endpoint z kluczem, można go dodać później, zapisując **klucz podany przez użytkownika** w naszym Keychain; lokalne koszty nadal muszą mieć etykietę „szacunek”, nie „pozostały limit”.

## Poświadczenia, prywatność i transport

CodexBar rozwiązuje wiele realnych problemów Keychain i cookies: własny cache jest izolowany zakresami, zapis ma ochronę przed spóźnionym wynikiem, a odczyty w tle unikają interaktywnych promptów. Dokument [`keychain-prompts.md`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/docs/keychain-prompts.md#L11-L70) pokazuje jednak koszt takiej funkcji: dostęp do Safe Storage przeglądarki i obcych wpisów Keychain może wywoływać systemowe monity i wymaga osobnych reguł dla pracy w tle.

CodexBar dodatkowo centralizuje projekcję ustawień na poświadczenia i środowisko procesu. Wybrane konto najpierw usuwa ambient credentials, a dopiero potem wstrzykuje własne, co ogranicza cichy cross-account fallback: [`ProviderCredentialAdapter`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBarCore/Providers/ProviderCredentialAdapter.swift#L71-L218) i [`ProviderEnvironmentResolver`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBarCore/Providers/ProviderEnvironmentResolver.swift#L3-L29). Sam wzorzec izolacji konta jest cenny; framework przejmowania wielu rodzajów credentiali nie jest nam potrzebny.

Warstwa HTTP CodexBar ogranicza ponowienia do bezpiecznych przypadków i pilnuje przekierowań do tego samego hosta po HTTPS w [`ProviderHTTPClient`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBarCore/ProviderHTTPClient.swift#L38-L252). Logi redagują e-maile, nagłówki cookies i tokeny Bearer w [`LogRedactor`](https://github.com/steipete/CodexBar/blob/f74117aeb7a9ee02a78c0f08ca354ff26b2292e0/Sources/CodexBarCore/Logging/LogRedactor.swift#L12-L50). Te reguły bezpieczeństwa są warte odtworzenia niezależnie, jeśli Codex Limits doda własny HTTP.

Proponowana polityka Codex Limits:

1. automatyczne źródło nie może pokazać promptu logowania ani Keychain;
2. nie czytamy domyślnie cookies przeglądarki, cudzych wpisów Keychain ani plików tokenów;
3. jeśli publiczne API wymaga klucza, użytkownik wkleja go świadomie, a Codex Limits zapisuje go we własnym wpisie Keychain;
4. token, cookie i surowa odpowiedź nie trafiają do logów, historii ani crash reportów;
5. przekierowanie HTTP nie może przenieść nagłówka autoryzacji na inny origin;
6. błędna tożsamość konta zatrzymuje łańcuch zamiast uruchamiać fallback do „jakiegoś” konta ambient;
7. każda migawka przechowuje `source`, `fetchedAt`, `confidence` i stabilny klucz konta albo jest oznaczona jako niepartycjonowalna.

## Minimalna architektura docelowa

Nie potrzeba kopii `ProviderDescriptor`. Wystarczą trzy własne pojęcia:

- **Integration** — stały identyfikator, nazwa i funkcja pobrania;
- **Probe** — opcjonalne pojedyncze źródło wewnątrz integracji, z kontrolą dostępności, timeoutem i klasyfikacją błędu;
- **Allowance snapshot** — wspólne okna limitów oraz metadane źródła, pewności, czasu i konta.

Przepływ:

```text
odśwież(integracja, konto)
  → wybierz statyczną definicję integracji
  → uruchamiaj jej źródła w ustalonej kolejności
  → po prawidłowym wyniku normalizuj i opublikuj tylko dla tego klucza
  → po błędzie „źródło niedostępne” przejdź do kolejnego źródła
  → po błędzie auth / account mismatch / parse ambiguity zatrzymaj łańcuch
  → zachowaj ostatnią poprawną migawkę i pokaż jej świeżość oraz błąd
```

Stan monitora należy przechowywać jako kolekcję kluczowaną przez integrację i konto, zamiast rozbudowywać pojedyncze `accountSnapshot`. Historia musi dostać identyfikator integracji; w przeciwnym razie te same skróty kont lub partycja `unknown` mogłyby mieszać dane vendorów. Dotychczasowa tygodniowa semantyka Codex nie może zostać globalnym założeniem — okna muszą pochodzić z integracji.

Nie trzeba jednak wykonywać tej migracji przed pierwszym wydaniem. Najmniejszy bezpieczny wariant v1 pozostawia obecny `UsageMonitor`, historię i prognozy jako ścieżkę **Codex-only**, a nowe źródła publikuje do małego stanu kart przeglądowych kluczowanego przez integrację. Karta używa istniejącej semantyki okna (`remainingPercent`, reset, czas trwania) i dodaje tylko provenance, świeżość oraz pewność. Claude i Grok dostają historię lub forecast dopiero po potwierdzeniu stabilnej tożsamości konta i jakości wielu kolejnych próbek. Dzięki temu nie uniwersalizujemy z góry `UsageSnapshot` ani silnika analitycznego.

Lokalną aktywność należy modelować równolegle:

```text
account allowance  ← źródło autorytatywne dostawcy
local activity     ← pliki/sesje/CLI na tym Macu
derived analytics  ← wyłącznie jawne połączenie powyższych, z coverage
```

To zachowuje obecny kontrakt pomiarowy i zapobiega prezentowaniu kosztu wyliczonego z lokalnej bazy jako pozostałego limitu konta.

## Kolejność wdrożenia i trudność

| Etap | Zakres | Trudność | Ryzyko |
|---|---|---:|---:|
| 1 | `IntegrationID` i mały stan kart: okna, źródło, świeżość, pewność; obecny Codex bez zmian | Niska | Niskie |
| 2 | Odświeżanie per integracja z generation guard; bez historii i forecastu nowych źródeł | Niska–średnia | Niskie |
| 3 | Grok: techniczny spike oficjalnego ACP `x.ai/billing`, z capability probe | Średnia | Średnie |
| 4 | Claude: wyłącznie oficjalny opt-in `statusLine` w v1 | Niska–średnia | Niskie–średnie |
| 5 | OpenCode: lokalna aktywność przez oficjalny `opencode serve`/OpenAPI | Niska–średnia | Niskie |
| 6 | Historia/forecast per `(integracja, konto)` dopiero po potwierdzeniu jakości danych | Średnia–wysoka | Średnie |
| Później | OpenCode Go: publiczne API z własnym Keychain, jeśli potwierdzony popyt | Średnia | Średnie |
| Odrzucone w v1 | Cookies przeglądarki, prywatne endpointy, obce tokeny, Grok gRPC, prywatne funkcje OpenCode | Wysoka | Wysokie |

Praktyczny pierwszy milestone powinien kończyć się na etapach 1–2. Pierwszym **spike'em protokołu** powinien być Grok, bo najbardziej przypomina obecną metodę Codex; pierwszym **niskoryzykownym źródłem produktowym** może być Claude `statusLine`. OpenCode trafia do osobnej części Local Activity, a nie do kart limitu konta.

## Zasada „bez kopiowania kodu”

Implementacja powinna powstać jako niezależny projekt kontraktów na podstawie obserwowalnego zachowania i oficjalnej dokumentacji dostawców:

- używamy własnych nazw typów, własnego modelu błędów i własnych testów;
- CodexBar służy wyłącznie do identyfikacji wzorców, kolejności źródeł, znanych awarii i ryzyk;
- fixture'y parserów pozyskujemy z uruchomień własnych CLI lub oficjalnych przykładów, nie z testów ani kodu CodexBar;
- nie przenosimy parserów, endpointowych wrapperów, zapytań SQL, struktur deskryptorów ani mechanizmów Keychain;
- każdą prywatną powierzchnię najpierw zastępujemy publicznym API/CLI, a jeśli nie istnieje — ograniczamy zakres funkcji zamiast kopiować workaround.

## Konkluzja

CodexBar potwierdza, że multi-provider jest wykonalny i że dobrym rdzeniem jest **uporządkowany łańcuch źródeł normalizujących się do jednej migawki**. Nie potwierdza natomiast, że wszystkie jego źródła są odpowiednie dla Codex Limits. Obecna metoda Codex Limits jest bardziej konserwatywna, łatwiejsza do obrony prywatnościowo i powinna stać się wzorcem zaufania dla kolejnych integracji.

Najłatwiejsze: opakowanie Codex, wspólny stan per integracja, Claude przez jawny `statusLine` oraz lokalna aktywność OpenCode przez `opencode serve`.  
Umiarkowane: Grok jako beta przez oficjalne ACP z wykrywaniem capability.  
Najtrudniejsze i niewarte v1: prywatne limity OpenCode oraz wszelkie fallbacki wymagające przejmowania tokenów/cookies.
