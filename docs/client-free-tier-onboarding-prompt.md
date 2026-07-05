# Client app prompt: Free/Default onboarding (account link + channel)

Copy this entire document into a task for the desktop/mobile client developer.

---

## Context

On **Free** and **Default** plans, VPN configs via the **Telegram bot** are issued only when the user is **compliant**:

- subscribed to the required Telegram channel (`requiredChannel`, usually `@DataGateVPNBot`), **or**
- **merged** account: Telegram + (Google **or** local/password) on the same `userId`.

The desktop/mobile client does **not** verify channel subscription itself. It shows onboarding when the backend reports non-compliance.

**Do not ask the user for a numeric Telegram ID.** The bot knows the sender from `msg.From.Id`.

**NuGet (required):**

```xml
<PackageReference Include="DataGateMonitor.SharedModels" Version="1.0.41" />
```

Types: `FreeTierAccessStatusResponse`, `RequestTelegramAccountLinkCodeRequest`, `RequestTelegramAccountLinkCodeResponse`, `CompleteTelegramAccountLinkFromAppRequest`, `CompleteTelegramAccountLinkResponse`.

Do not use SharedModels versions below **1.0.41** for the link-code flow.

---

## API

**Base URL:** same as login (`https://…/api/…`).

**Auth:** Bearer JWT (Google or login/password).

### 1. Status check (read-only, polling)

```
GET /api/auth/free-tier-access/status
Authorization: Bearer {token}
```

Response: `ApiResponse<FreeTierAccessStatusResponse>`

| Field | Meaning |
|-------|---------|
| `isApplicable` | user has active Free or Default plan |
| `isCompliant` | no onboarding required |
| `isMergedAccount` | telegram + google/local on same userId |
| `isChannelSubscribed` | channel subscription (backend checks via bot API) |
| `isGracePeriod` | grace active (read-only; does **not** start grace) |
| `isLinkedToTelegram` | telegram identity link exists |
| `canRequestAccountLinkCode` | may request link code |
| `activePlanName` | `"Free"` / `"Default"` |
| `requiredChannel` | e.g. `"@DataGateVPNBot"` |

**UI logic:**

```
if (!status.isApplicable || status.isCompliant) → show nothing
else → show onboarding modal
```

Call after login and when opening VPN section. Do **not** call the bot audit endpoint from the client.

### 2. Link accounts — recommended mobile flow (app → bot)

```
POST /api/auth/telegram/request-account-link-code
Authorization: Bearer {token}
Content-Type: application/json

{}
```

Omit `telegramId`. The user completes linking in the Telegram bot; the bot supplies the sender id.

**200:** `ApiResponse<RequestTelegramAccountLinkCodeResponse>`

```json
{
  "code": "ABCD2345",
  "expiresInSeconds": 900
}
```

**Errors:**

- **400** — already linked, no google/local identity, blocked, etc.
- **404** — user not found

**User steps:**

1. Open the same Telegram bot (`/register` if needed).
2. App shows `{code}` for ~15 minutes.
3. User sends `/link_account CODE` or the 8-character code alone in private chat with the bot.

### 3. Link accounts — alternative (bot → app)

The bot issues a code; the user enters it in the app:

```
POST /api/auth/telegram/complete-account-link
Authorization: Bearer {token}
Content-Type: application/json

{
  "code": "ABCD2345"
}
```

**200:** `ApiResponse<CompleteTelegramAccountLinkResponse>`

The bot calls `POST /api/auth/telegram/request-account-link-code-for-bot` (App token, not the client).

### 4. Legacy (optional)

You may pass a bound `telegramId` if you already know it (e.g. desktop). **Not for mobile.**

```json
{ "telegramId": 123456789 }
```

The Telegram account must be registered in the bot (`/register`).

### 5. User actions in onboarding UI

1. Subscribe to `requiredChannel`.
2. **Or** link accounts using flow **§2** (recommended) or **§3**.
3. Poll `GET free-tier-access/status` again → `isCompliant` should become `true` (via `isMergedAccount`).

---

## Do not implement in the client

- Do **not** show a field for numeric Telegram ID on mobile.
- Do not call `POST /api/users/audit-free-tier-access/by-telegram/{id}` (bot App token only).
- Do not call `POST /api/users/merge-telegram-google/by-link-code` (bot only).
- Do not call `POST /api/auth/telegram/request-account-link-code-for-bot` (bot only).
- Do not rely on grace for UX: grace starts on VPN attempt in the **bot**, not on status polling.
- Do not log link codes in analytics/crash reports.

---

## Enforcement

Compliance is enforced when issuing VPN in the **Telegram bot** (download/create OVPN/VLESS). Desktop OpenVPN API may not gate yet — client should still show onboarding from the status endpoint.

---

## Example (C#)

```csharp
var status = await api.GetFreeTierAccessStatusAsync(token);
if (status.Data is { IsApplicable: true, IsCompliant: false })
{
    if (status.Data.CanRequestAccountLinkCode)
    {
        // Recommended on mobile: empty body — no TelegramId
        var link = await api.RequestTelegramAccountLinkCodeAsync(
            token,
            new RequestTelegramAccountLinkCodeRequest());
        ShowCode(link.Data.Code, link.Data.ExpiresInSeconds);
        // User enters code in Telegram bot: /link_account CODE
    }
}
```

---

## QA checklist

1. Free user, Google only, not linked → modal, `canRequestAccountLinkCode=true`
2. After merge → `isCompliant=true`, modal hidden
3. App requests code with `{}`, user enters code in bot → merge succeeds
4. Bot-issued code entered in app via `complete-account-link` → merge succeeds
5. Pro user → `isApplicable=false`, no modal
6. During bot grace → status may show `isGracePeriod=true`, `isCompliant=true`
