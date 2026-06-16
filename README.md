# Codex Account Manager

Codex Account Manager is a local-first macOS app for managing multiple Codex Desktop accounts on the same Mac. It lets you save each signed-in Codex session as a local profile, switch between profiles quickly, inspect auth metadata, and recover from revoked refresh tokens without manually copying `auth.json`.

The project is designed for people who regularly move between personal, work, team, or client Codex accounts and want a safer workflow than hand-editing local auth files.

## Highlights

- Manage multiple Codex Desktop profiles on macOS.
- Switch accounts with one click.
- Save and restore `~/.codex/auth.json`.
- Save and restore Codex Desktop state from `~/Library/Application Support/Codex`.
- Inspect profile metadata such as auth mode, email/account id, and refresh time.
- Use Token Vault to reveal or copy tokens only when you explicitly choose to.
- Automatically save fresh tokens into the active profile after you sign in again.
- Run fully locally. No token or profile data is uploaded anywhere.

## Requirements

- macOS.
- OpenAI Codex Desktop App.
- Swift compiler, usually installed with Xcode Command Line Tools.

Check Swift:

```bash
swift --version
```

Install Xcode Command Line Tools if needed:

```bash
xcode-select --install
```

## Installation

Clone the repository:

```bash
git clone https://github.com/ngnthanhdev/codex-account-manager.git
cd codex-account-manager
```

Build the app:

```bash
chmod +x build-app.sh codex-account-switcher.sh
./build-app.sh
```

Open the app:

```bash
open "build/Codex Account Switcher.app"
```

After launch, the **Codex Account Manager** window should appear. If it does not, click the app in the Dock or choose **Window > Show Manager** from the macOS menu bar.

## Usage

### 1. Save Your First Account

1. Open Codex Desktop.
2. Sign in with your first account.
3. Open Codex Account Manager.
4. Enter a profile name, for example:

```text
personal
```

5. Click **Capture**.

The current Codex login state is now saved as the `personal` profile.

### 2. Add Another Account

1. In Codex Desktop, log out of the current account.
2. Sign in with another account.
3. Return to Codex Account Manager.
4. Enter another profile name, for example:

```text
work
```

5. Click **Capture**.

### 3. Switch Accounts

1. Select a saved profile from the left sidebar.
2. Click **Switch to Selected**.

When switching, the app will:

- Quit Codex Desktop.
- Save the current state into the active profile.
- Restore the selected profile.
- Open Codex Desktop again.

## Token Vault

Token Vault reads tokens from the selected profile's `auth.json`.

- Tokens are hidden by default.
- Enable **Reveal** to view the selected token inside the app.
- Click **Copy** to copy the selected token to the macOS clipboard.
- Tokens are not printed to terminal, written to logs, or sent over the network.

Common token fields:

- `access_token`
- `refresh_token`
- `id_token`

## Revoked Refresh Tokens

If Codex shows this error:

```text
Your access token could not be refreshed because your refresh token was revoked.
Please log out and sign in again.
```

the saved profile contains a refresh token that OpenAI has revoked. Codex Account Manager cannot refresh a revoked token. You need to sign in again so Codex can create a fresh token.

Recovery flow:

1. Switch to the broken profile.
2. In Codex Desktop, log out.
3. Sign in again with the same account.
4. Keep Codex Account Manager open for a few seconds. It will auto-save the fresh token into the active profile.
5. To save immediately, click **Save Token**.

If you also want to refresh the saved Codex Desktop app state after signing in again, click **Save Active**.

## CLI

The app uses the local `codex-account-switcher.sh` script under the hood. You can also run it directly:

```bash
./codex-account-switcher.sh capture personal
./codex-account-switcher.sh switch work
./codex-account-switcher.sh save-auth personal
./codex-account-switcher.sh list
./codex-account-switcher.sh active
```

## Contributing

Bug fixes and improvements are welcome through pull requests.

- Report bugs with GitHub Issues.
- Send fixes through Pull Requests into `main`.
- Never include tokens, `auth.json`, cookies, profile folders, or real login data.
- See [CONTRIBUTING.md](CONTRIBUTING.md) for the full contribution guide.

To require owner review before changes are merged, enable branch protection for `main` on GitHub:

1. Go to **Settings > Branches**.
2. Add a rule for `main`.
3. Enable **Require a pull request before merging**.
4. Enable **Require approvals**.
5. Enable **Require review from Code Owners**.

## Local Data

Profiles are stored at:

```text
~/Library/Application Support/CodexAccountSwitcher
```

Each profile uses this structure:

```text
profiles/<name>/auth/auth.json
profiles/<name>/app-support/Codex
profiles/<name>/profile.env
```

Do not commit or share this profile folder. It contains tokens, cookies, and Codex Desktop login state.

## Security

Codex Account Manager is local-first:

- It does not upload tokens.
- It does not send profile data to a custom server.
- It does not store tokens in Git.
- It does not log token values to files or terminal output.

Treat the profile folder as sensitive data, just like a password manager export or a browser session.

## Build Output

After a successful build:

```text
build/Codex Account Switcher.app
```

The `build/` directory is ignored by Git.

## License

MIT License. See [LICENSE](LICENSE).

## Support

If Codex Account Manager saves you time or makes switching between Codex accounts less painful, consider supporting the project. Donations help keep the tool maintained, tested on newer macOS releases, and improved with safer account-management workflows.

[![Support me on Ko-fi](https://storage.ko-fi.com/cdn/kofi2.png?v=3)](https://ko-fi.com/A6I721HY8E)

You can also support directly here: [ko-fi.com/A6I721HY8E](https://ko-fi.com/A6I721HY8E)
