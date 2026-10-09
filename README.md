# ProxyBar

Menu bar quota monitor for the accounts in a local CLIProxyAPI.

- Lists accounts from the proxy's management API (`/v0/management/auth-files`).
- Fetches Claude and Codex quota through `/v0/management/api-call`, so the proxy injects and refreshes the credentials; ProxyBar never reads tokens.
- Shows request counts per account from the proxy (last ~3h) as secondary info.
- Refreshes every 5 minutes and when the panel opens; honors `Retry-After` from provider usage APIs.

## Setup

The proxy needs `remote-management.secret-key` set (localhost-only access is fine). The same key goes in the login Keychain:

```sh
security add-generic-password -U -s ProxyBar -a management-key -w '<key>'
```

Proxy URL defaults to `http://127.0.0.1:8317`; override with `defaults write dev.killian.proxybar proxyURL http://host:port`.

## Build

```sh
./build.sh   # builds, signs ad-hoc, installs to ~/Applications/ProxyBar.app
```

`PROXYBAR_SNAPSHOT=/tmp/panel.png ~/Applications/ProxyBar.app/Contents/MacOS/ProxyBar` renders the panel once and prints parsed quota, for debugging.

## Adding a provider

Implement `QuotaProvider` in `Providers.swift` (request URL/headers using `$TOKEN$`, and a parser) and add it to `QuotaProviders.all`.
