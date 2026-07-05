# Client app prompt: Free/Default onboarding (account link + channel)

Copy this entire document into a task for the desktop/mobile client developer.

---

## Context

On **Free** and **Default** plans, VPN configs via the **Telegram bot** are issued only when the user is **compliant**:

- subscribed to the required Telegram channel (`requiredChannel`, usually `@DataGateVPNBot`), **or**
- **merged** account: Telegram + (Google **or** local/password) on the same `userId`.

The desktop/mobile client does **not** verify channel subscription itself. It shows onboarding when the backend reports non-compliance.

**NuGet (required):**

```xml
<PackageReference Include="DataGateMonitor.SharedModels" Version="1.0.38" />
```

Types: `FreeTierAccessStatusResponse`, `RequestTelegramAccountLinkCodeRequest`, `RequestTelegramAccountLinkCodeResponse`.

Do not use SharedModels versions below **1.0.38** for the link-code flow.

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

### 2. Request link code

```
POST /api/auth/telegram/request-account-link-code
Authorization: Bearer {token}
Content-Type: application/json

{
  "telegramId": 123456789
}
```

`telegramId` is the numeric Telegram user ID that will enter the code in the bot. It must match `msg.From.Id` in the bot. The Telegram account must be registered in the bot (`/register`).

**200:** `ApiResponse<RequestTelegramAccountLinkCodeResponse>`

```json
{
  "code": "ABCD2345",
  "expiresInSeconds": 900
}
```

**Errors:**

- **400** — already linked, no google/local identity, telegram not registered, blocked, etc.
- **404** — user not found

The code is bound to the given `telegramId`. Another Telegram account cannot use a stolen code.

### 3. User actions in onboarding UI

1. Subscribe to `requiredChannel`.
2. **Or** link accounts:
   - User opens the same Telegram bot (`/register` if needed).
   - Client collects the user's Telegram ID (instruction or bot command).
   - Call `POST request-account-link-code` with that `telegramId`.
   - Show `{code}` for ~15 minutes.
   - User enters in bot: `/link_account CODE` or sends the 8-character code in private chat.

3. Poll `GET free-tier-access/status` again → `isCompliant` should become `true` (via `isMergedAccount`).

---

## Do not implement in the client

- Do not call `POST /api/users/audit-free-tier-access/by-telegram/{id}` (bot App token only).
- Do not call `POST /api/users/merge-telegram-google/by-link-code` (bot only).
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
        var link = await api.RequestTelegramAccountLinkCodeAsync(
            token,
            new RequestTelegramAccountLinkCodeRequest { TelegramId = userTelegramId });
        ShowCode(link.Data.Code, link.Data.ExpiresInSeconds);
    }
}
```

---

## QA checklist

1. Free user, Google only, not linked → modal, `canRequestAccountLinkCode=true`
2. After merge → `isCompliant=true`, modal hidden
3. Code requested for telegramId A, entered from telegramId B → rejected
4. Pro user → `isApplicable=false`, no modal
5. During bot grace → status may show `isGracePeriod=true`, `isCompliant=true`
