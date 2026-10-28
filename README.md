# Orbit

macOS menu bar app showing session and weekly usage for Claude, Codex, and Antigravity, with reset times.

## Build and run

    ./scripts/build-app.sh
    open build/Orbit.app

Disk image for installing (rebuilds the app, then writes `build/Orbit-<version>.dmg`; open it and drag Orbit onto Applications):

    ./scripts/build-dmg.sh

Use `./scripts/build-dmg.sh --open` to mount the image and open its drag-to-Applications window after building.

Every push to `main` builds the disk image in GitHub Actions and publishes it as a release (`v<version>.<run>`) listing the commits since the previous one. The latest is on the repository's Releases page.

## Updates

Orbit checks for a newer stable release on startup and every 24 hours while running, including after waking from sleep. **Check for updates** retries immediately. Checks use GitHub's public API without authentication. Network failures appear beside the update button without interrupting usage refreshes.

When available, **Update & restart** downloads the release disk image over HTTPS from the public GitHub release, verifies GitHub's SHA-256 asset digest, checks the bundled app identity, version and code signature, then stages it beside the installed app. Orbit quits, replaces the app and relaunches at the same path. The installer restores the previous app if replacement or the launch request fails. It requires a writable app and parent folder; move the app out of its disk image into Applications first. No administrator prompt is requested. A successful launch request does not detect subsequent crashes.

CI stamps the full `<version>.<run>` into the app so successive releases compare correctly. Older releases without matching bundle versions cannot be installed by the updater. Local builds keep the version from `Resources/Info.plist`; `ORBIT_RELEASE_VERSION` overrides it for release builds. Update metadata stays in memory. Temporary downloads and the previous app are removed after installation; a failed rollback preserves the backup in the adjacent `.Orbit-update-*` directory. No new dependencies are required.

The app is Apple silicon only, ad-hoc signed and not notarized. After installing a downloaded image, the first launch is blocked; allow it under System Settings > Privacy & Security > Open Anyway, or run `xattr -dr com.apple.quarantine /Applications/Orbit.app`.

Start at login (LaunchAgent that opens `build/Orbit.app`; `--remove` uninstalls):

    ./scripts/install-login-item.sh

Native AppKit menu bar app with a SwiftUI galaxy dashboard: moving, twinkling stars, a drifting spiral nebula, an opaque space-black backdrop, dark provider cards and flowing quota meters. Rockets fly along the bar when quota usage increases and when the popover opens. No Dock icon. It refreshes every 5 minutes and when you open the popover (at most once a minute). Claude requests reuse a five-minute in-memory cache; refreshes and popover opens respect its rate-limit cooldown. Animations pause when closed and respect macOS Reduce Motion. Escape or an outside click dismisses the popover; Command-R refreshes and Command-Q quits.

The dashboard grows to fit its cards, including connection errors, within the current display's usable area. The footer's Size menu offers Normal (100%), Larger (115%), and Largest (130%) and remembers the selection. On shorter displays, the cards remain scrollable without a visible scrollbar; the header and footer stay accessible.

Click a provider's name and external-link icon to open its dashboard in your default browser: Claude at `claude.ai`, Codex at `chatgpt.com/codex`, or Antigravity Remote Control at `antigravity.google.com`. Links remain available while connecting or when quota refresh fails.

Render a preview without accessing credentials or provider APIs:

    build/Orbit.app/Contents/MacOS/Orbit --snapshot /tmp/orbit-preview.png --demo

Omit `--demo` to render live usage. `--dump` still prints live quota data.
Add `--size normal`, `--size larger`, or `--size largest` to preview a specific dashboard size without changing the saved preference.

## App icon

The app bundle uses a colored spiral galaxy; the menu bar uses the same drawing as a white template that macOS adapts to the menu bar appearance. `Sources/Orbit/GalaxyIcon.swift` is the shared vector artwork. The build script generates all ten macOS icon representations (16–1024 pixels) and bundles `AppIcon.icns`; no external assets or dependencies are needed.

## Logos

Drop official logos into `Resources/logos/` as `claude`, `codex`, or `antigravity` with `.svg`, `.pdf`, or `.png`. Without them a letter badge is drawn.

## Connecting providers

If the initial account check finds a missing login, opening Orbit shows **Connect your providers**. The footer’s **Connect providers** button reopens it at any time. Install the provider CLI through the linked official instructions, then use **Copy command & open Terminal** and paste the command:

- Claude: `claude auth login`, using your Claude subscription.
- Codex: `codex login`, choosing **Sign in with ChatGPT**. API keys have no subscription quota windows.
- Antigravity: `agy`, completing interactive sign-in.

After sign-in, click **Check connections**. Authentication and token storage remain with the provider tools. Orbit does not ask for passwords, tokens or browser cookies. Expired Claude credentials require signing in again through Claude Code.

## Data sources

- **Claude**: OAuth token from the `Claude Code-credentials` Keychain item (or `~/.claude/.credentials.json`), then `GET https://api.anthropic.com/api/oauth/usage`. Undocumented endpoint; may change. The first run may prompt for Keychain access. Responses are cached for five minutes. HTTP 429 triggers exponential backoff from five minutes to one hour, honoring longer `Retry-After` seconds or HTTP dates; zero or invalid headers never allow immediate retries. Last good values and their fetch time remain visible during temporary failures. Server-side throttling can still occur, especially when other tools share the account.
- **Codex**: installed `codex app-server`, using the documented `account/read` and `account/rateLimits/read` methods. Reads current account quotas without scanning sessions or starting an inference turn. Codex owns Keychain/file authentication and token refresh. Orbit uses the `codex` quota bucket when available and maps windows by duration, including weekly-only responses. Requires a current Codex CLI; there is no stale session-log fallback.
- **Antigravity**: runs `agy -p /usage` (Antigravity CLI, looked up in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`) and shows the most used model group per window.

Provider executables are discovered in standard installation locations, mise's shims directory (`~/.local/share/mise/shims`, respecting `MISE_DATA_DIR` and `XDG_DATA_HOME`), and the inherited `PATH`. This works when Orbit is launched from Finder without shell initialization. Claude's credentials remain in the same Keychain/file locations regardless of its install manager. Provider errors do not expose credentials or raw account responses. Credential/account access audit events write status and provider names to stdout without tokens, emails, paths or quota values.

## Privacy

The app has no analytics or tracking. See [the draft privacy notice](Resources/Privacy.txt) for local data access, provider requests, retention and rights. The data controller is Kielblock Dev, represented by Pedro Kielblock; privacy contact: pedro@kielblock.dev. Lawful bases, the controller address and any required DPO designation need maintainer review before distribution.

## License

[MIT](LICENSE)
