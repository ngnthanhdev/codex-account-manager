# Contributing

Thanks for helping improve Codex Account Manager. This project touches local auth state, so contributions should be small, reviewable, and careful with user data.

## Good Contributions

- Bug fixes for account capture, switching, or token refresh flows.
- macOS compatibility fixes.
- UI improvements that keep the app simple and local-first.
- Documentation improvements.
- Tests or validation scripts where useful.

## Before You Start

1. Open an issue for larger changes so the approach can be discussed first.
2. For small bug fixes, you can open a pull request directly.
3. Never include real `auth.json`, tokens, cookies, profile folders, screenshots with secrets, or `~/Library/Application Support/CodexAccountSwitcher` data.

## Local Setup

```bash
git clone https://github.com/ngnthanhdev/codex-account-manager.git
cd codex-account-manager
chmod +x build-app.sh codex-account-switcher.sh
./build-app.sh
```

Run the app:

```bash
open "build/Codex Account Switcher.app"
```

Validate the shell script:

```bash
bash -n codex-account-switcher.sh
```

## Pull Request Flow

1. Fork the repo.
2. Create a branch from `main`.
3. Make a focused change.
4. Update `README.md` when behavior or setup changes.
5. Run:

```bash
bash -n codex-account-switcher.sh
./build-app.sh
```

6. Open a pull request into `main`.

## Pull Request Checklist

- The change is scoped and easy to review.
- The app still builds.
- No token, profile, cookie, or local auth data is included.
- Any user-facing behavior change is documented.
- Screenshots are included for UI changes when helpful.

## Review Policy

All changes should go through pull requests. The repository owner should review and approve changes before merging to `main`.

Recommended GitHub setting:

1. Go to **Settings > Branches**.
2. Add a branch protection rule for `main`.
3. Enable **Require a pull request before merging**.
4. Enable **Require approvals** and set it to at least `1`.
5. Enable **Require review from Code Owners**.
6. Enable **Do not allow bypassing the above settings** if you want the rule to apply to admins too.

## Security

If a bug could expose tokens or local auth data, avoid posting secrets publicly. Open an issue with a minimal description first, or contact the maintainer privately.
