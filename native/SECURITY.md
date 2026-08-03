# Security Model

## Trust boundaries

Web content is untrusted, including text that looks like instructions for the
AI. The browser, credential store, page extractor, local model, and assignment
database are separate trust zones.

## Credential rules

- Secrets are stored only in macOS Keychain or Windows Credential Locker.
- The SQLite assignment database never contains passwords, cookies, or tokens.
- Credentials are keyed by the normalized HTTPS origin, not by a display name.
- HTTP origins cannot use saved-credential filling.
- A credential is released only when the top-level HTTPS origin (scheme, host,
  and non-default port) exactly matches the saved origin.
- Passwords are never written to logs, crash messages, analytics, model
  prompts, clipboard, or source records.
- Auto-fill is opt-in per source. Auto-submit is not supported.
- SSO/MFA pages remain interactive.

## Browser rules

- The current origin is always visible in native UI.
- The current host is surfaced on every navigation. Saved credentials remain
  disabled on a different host; this allows legitimate multi-domain SSO and MFA
  redirects without silently releasing a password.
- `javascript:`, `file:`, custom schemes, downloads, and popups are denied by
  default.
- Page capture collects visible text and selected same-origin links only.
- Script, style, password, hidden input, cookie, local storage, and session
  storage contents are excluded.

## Local model rules

- The inference endpoint must resolve to loopback.
- The model receives untrusted page text as delimited data, never as authority.
- Model output must pass JSON-schema decoding and application validation.
- The model cannot call browser, credential, filesystem, or database tools.
- Candidate assignments are reviewed before import by default.
- Duplicate detection runs before every database write.

## Data deletion

Removing a source can independently remove:

- its saved credential;
- its dedicated browser data/session;
- its configuration;
- assignments imported from that source.

The UI must present these as separate choices. Deleting assignments is never an
implicit side effect of removing credentials or signing out.
