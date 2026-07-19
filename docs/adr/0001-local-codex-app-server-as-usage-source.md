# Local Codex app-server as the usage source

The app requires a locally installed, signed-in Codex CLI and reads data through `account/rateLimits/read` and `account/usage/read`. This interface avoids copying credentials or scraping a graphical interface. The protocol may change between Codex versions, so an incompatible response must produce a clear error instead of a misleading forecast.
