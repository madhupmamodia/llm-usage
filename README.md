# LLM Usage — Menu Bar + Desktop Widget

Menu bar app (works now) + Xcode widget scaffold (for later).

## Download

→ https://github.com/madhupmamodia/llm-usage/releases

Every push to `main` auto-cuts a new version (`v1.0.0` → `v1.0.1` → …) and attaches `LLMUsage.zip`. To bump minor/major manually:
```bash
git tag v1.1.0 && git push --tags
```

## Screenshots

![Main view — stats, budget bar, top models](docs/screenshots/main.png)

![Setup view — first launch, paste API key](docs/screenshots/setup.png)

## Run menu bar app

```bash
cd ~/workspace/llm-usage
swift build -c release
open ./LLMUsage.app
```

Look for ✨ `$XX.XX` in your menu bar. Click for today's spend, week-to-date, top models, refresh.

## Configure

API key + optional user_id are read from files in `$HOME`:

```bash
umask 077
printf '%s' "sk-..." > ~/.llm-usage-key
printf '%s' "<your-user-id>" > ~/.llm-usage-user   # optional, scopes to your own spend
chmod 600 ~/.llm-usage-key ~/.llm-usage-user
```

Find your `user_id` in the LLM Gateway UI → URL bar → value after `user_id=`.

### Auto-detect from `~/.zshrc`

If `~/.llm-usage-key` is missing, the app parses `~/.zshrc` for `LITELLM_API_KEY="..."` and pre-fills the setup screen (badged "detected from ~/.zshrc"). Edit, replace, or save as-is — your choice.

## Gateway URL

Default points at Multiplier's LLM Gateway: `https://llm-gateway.usemultiplier.cloud`.
To point at a different LiteLLM instance, edit `Sources/llm-usage/UsageStore.swift:28` and `Widget/LLMUsageWidget.swift:73`.

## Auto-start at login

`System Settings → General → Login Items → Open at Login → + → ~/workspace/llm-usage/LLMUsage.app`

## Desktop widget (later)

The `Widget/` directory is the Swift source + Info.plist + entitlements for a real `WidgetKit` widget. To build it:

1. Install full Xcode (`xcode-select --install` won't work — App Store → Xcode).
2. Open Xcode → File → New → Project → macOS → App (SwiftUI). Name it `LLMUsage`.
3. File → New → Target → Widget Extension → name `LLMUsageWidget`, uncheck "Include Configuration Intent".
4. In the new target, replace its generated `.swift` and `Info.plist` with the files in `Widget/`.
5. Signing & Capabilities → select your team. Add App Groups capability → `group.com.madhup.llm-usage` on both targets.
6. Build & run the app once (so the widget is registered), then right-click desktop → "Add Widget" → search `LLM Usage`.

The widget reads `~/.llm-usage-key` directly — same files as the menu bar app, no copy needed.

## Files

- `Package.swift` — SPM manifest for the menu bar app.
- `Sources/llm-usage/` — Swift sources (Models, UsageStore, App).
- `LLMUsage.app/` — built bundle. `open LLMUsage.app` to run.
- `Widget/` — Xcode widget extension sources for later.