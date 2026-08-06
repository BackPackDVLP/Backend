# HubSpot integration — notes (one-way pipeline implemented, pending pilot verification)

Context: a travel agency client uses HubSpot as their CRM. Idea is to connect
the controlpanel with HubSpot to reduce manual re-entry of trip/member data.

## Feasibility
HubSpot exposes a REST API for contacts/deals and supports webhooks, so this
is doable without heavy infrastructure — a Cloud Function can receive a
HubSpot webhook and act on it.

## Proposed approach (one-way, HubSpot → controlpanel)
- Add a Cloud Function that listens for a HubSpot webhook, e.g. a deal
  moving to a "Booked" stage.
- On trigger, auto-create a group in Firestore by duplicating one of the
  bureau's own templates (existing `isTemplate: true` groups, "Skabeloner"
  in the control panel) rather than a bare/empty group — timeline, packing
  list, flight/emergency info come from the template, and members are
  pulled from the contacts associated with the deal (name, email, phone).
  See "Template-based group creation" below.
- This is the highest-value, lowest-risk piece: it removes manual group/member
  setup — and now manual trip-building — for bookings that already exist in
  HubSpot.

## Two-way sync (pushing controlpanel → HubSpot)
- Full two-way (e.g. pushing trip status back to HubSpot as deal notes/
  timeline events) is still significantly more work than one-way — deferred.
- A narrower, high-value slice is *not* deferred: a reverse bridge for
  member-submitted data (e.g. passport numbers) requested inside the app and
  pushed back to the matching HubSpot contact. See "Reverse bridge" below.

## Self-service, per-bureau setup (revised direction)

The earlier version of this doc assumed *we* (BackPack) would hand-configure
a fixed field mapping per client. That doesn't scale past one or two
agencies — every bureau's HubSpot instance has different custom properties,
pipeline names, and stage IDs. Revised direction: build a wizard **inside the
control panel** so a bureau's own owner can connect and configure this
themselves, no engineering time per client.

### New "Integrationer" section (Bureau Settings)

`BureauSettingsScreen` already had an "Integrationer" card with a "Forbind
CRM" tile pointing at `CrmIntegrationScreen` — a 5-step UI mockup someone
had already built to review the flow (no Firestore/Cloud Function/HubSpot
calls, all mock data) before this round of work wired it up for real.
`CrmIntegrationScreen` stays generically CRM-labeled on purpose (future-
proofs for non-HubSpot CRMs later); HubSpot-specific logic lives in the
Cloud Functions underneath. It's owner-only (same gate as
`inviteEmployee`/`updateEmployee` — `role == 'owner'`, checked both
client-side for UX and server-side in every callable below). Wizard steps:

1. **Connect** — a single "Forbind til HubSpot" button. This used to be a
   pasted Private App access token + client secret, but that broke the
   "no engineering time per bureau" goal: HubSpot now steers new Private
   App creation toward its CLI-driven Projects framework rather than a
   simple web form (verified against HubSpot's own docs — a real platform
   shift, not a relabeling), which would have put a CLI step on every
   single bureau. Replaced with a proper **OAuth flow** instead: the button
   calls `startHubspotOAuth`, opens the returned HubSpot authorize URL in a
   new tab, the bureau owner logs into their own HubSpot account and
   clicks "Allow," and `hubspotOAuthCallback` takes it from there — no
   token, client secret, or HubSpot developer tooling ever touches the
   bureau. This needs **one** shared HubSpot Public (OAuth) App, registered
   by BackPack a single time (still via the CLI, since that's now required
   for new public apps too) — never per bureau.
2. **Map fields** — once connected, a Cloud Function fetches the bureau's
   *actual* HubSpot properties (`GET /crm/v3/properties/deals` and
   `/contacts`) and pipeline stages (`GET /crm/v3/pipelines/deals`) and
   returns them to the client. The UI shows a dropdown next to each BackPack
   field (group name, departure date, return date, member name/email/phone,
   agencyCode if the bureau runs multiple brands) letting the owner pick
   which of *their own* HubSpot properties feeds it — including custom
   properties, which is the whole reason this can't be hardcoded.
3. **Pick the trigger & template** — a dropdown of the bureau's own deal
   pipeline stages (from step 2's fetch) to choose which stage transition
   creates a group (e.g. their "Booked"/"Betalt" stage, whatever they've
   actually named it), plus a second dropdown of the bureau's own templates
   (existing `isTemplate: true` groups) to duplicate when that trigger
   fires — so the created trip already has a timeline, packing list, and
   flight/emergency info instead of an empty shell. See "Template-based
   group creation" below for how the duplication works server-side.
4. **Save & activate** — `saveHubspotMapping` persists the mapping and
   flips the integration to active. Unlike the old Private-App design,
   there is no per-bureau webhook step at all: the shared Public App's
   webhook subscription is configured once, at the app level (in the
   Projects `webhooks.json`, subscribed to "Deal property change" for
   `dealstage`), and automatically covers every bureau that connects —
   HubSpot routes each event by `portalId`, which `hubspotWebhook` uses to
   look up the right agency.
5. **Status/troubleshooting panel** — shows recent webhook events received
   and whether each one successfully created a group, so a bureau can
   self-diagnose ("last event failed: no contact found for deal") without
   filing a support ticket.

### Template-based group creation

The control panel already supports this pattern manually: `_duplicateGroup`
in `group_selection_screen.dart` copies a group's `timelineEvents` (dates
shifted by the difference between old and new departure date),
`packinglistCategories`, `coupons`, flight info, `emergencyPhone`, and
departure/return airports into a new group doc, leaving `members`/`guides`
empty. `hubspotWebhook` needs a server-side equivalent of that same logic
(it can't call into client Flutter code), triggered by the incoming deal
instead of a manual "duplicate" button click:
- Load the bureau's chosen template group (`templateGroupId`).
- Compute the date shift from the template's `departureDate` to the new
  `departureDate` pulled from the deal via `fieldMappings`, and shift
  `timelineEvents` the same way `_duplicateGroup` does.
- Copy `packinglistCategories`, `coupons`, and flight/emergency/airport
  fields as-is from the template.
- Populate `members` from the deal's associated contacts (existing
  behavior), not from the template — templates have no real members.
- Timeline-event image copying between Storage paths applies here too, if
  templates use bureau-specific images.

Open question: one default template per agency is the simplest version.
Whether a bureau needs *multiple* templates picked by trip type (e.g. a
HubSpot deal property like "destination") rather than always the same one
is more wizard complexity (a template picker per pipeline/stage, or per
property value) and probably not needed for the pilot.

### Document import (implemented)

Any files attached to the triggering deal in HubSpot are copied into the
new group's documents automatically — a bureau attaches a booking
confirmation, itinerary, etc. to the deal as normal, and it just shows up
in the trip's documents in both apps, no manual re-upload.

Neither app has a documents *model* — both `backend/lib/screens/home/
homescreen.dart` and `backpack/lib/screens/documentscreen.dart/
documentscreen.dart` derive a trip's document list purely by listing
Firebase Storage at `{groupId}/documents/` (`listAll()`), no Firestore
metadata. So the whole feature is just: copy bytes into that same Storage
path, and both apps pick them up automatically.

HubSpot has no direct deal→file association — a file attached to a deal in
the HubSpot UI actually creates a **Note** (engagement) on the deal with
the file referenced in the note's `hs_attachment_ids` property
(semicolon-separated file IDs), confirmed against HubSpot's own community
docs. So `hubspotWebhook` (`importHubspotDealDocuments` in
`backpack/functions/src/index.ts`) does: fetch the deal with
`associations=contacts,notes` → batch-read the associated notes for
`hs_attachment_ids` → for each file id, `GET /files/v3/files/{id}/signed-url`
(works for both public and private files) → download the bytes → write to
`{groupId}/documents/{filename}` via the Admin SDK (bypasses Storage
rules, same as everything else this function writes). A small
extension→MIME map sets `contentType` on upload for common types (pdf,
doc(x), xls(x), images, txt); unknown extensions upload without one, same
as the existing manual-upload flows already do.

**Scope note**: requires the `files` OAuth scope, added to the shared
app's `requiredScopes`. HubSpot also documents a `crm.objects.notes.read`
scope for reading notes, but it isn't actually assignable — the HubSpot
CLI rejected it as unrecognized when uploading the project — so notes
access rides along under the existing `crm.objects.contacts.read`/
`crm.objects.deals.read` scopes instead (consistent with community reports
of the same scope being missing from HubSpot's own app-scope picker).
Since this changes the shared app's requested scopes, **every already-
connected bureau needs to disconnect and reconnect once** — HubSpot
requires re-consent when an app's scopes change, same caveat as the
reverse-bridge scope change noted below.

### Data model (implemented)

`agencyIntegrations/{agencyCode}` — non-secret status/config, staff-of-that-
agency readable:
- `hubspotPortalId`, `connectedAt`, `connectedBy` (uid), `status`
  (`'idle'|'connected'|'active'|'error'`).
- `fieldMappings`: `{ backpackField: string, hubspotObjectType: 'deal' |
  'contact', hubspotProperty: string }[]`.
- `triggerStageId`, `triggerPipelineId`.
- `templateGroupId`: the bureau's chosen template group (`isTemplate: true`)
  to duplicate when the trigger fires.
- `recentEvents`: capped log of the last 20 deliveries + outcome, for the
  status panel.

`agencyIntegrations/{agencyCode}/private/credentials` — `hubspotRefreshToken`
only. Split into its own function-only subdoc rather than a field on the
status doc above, so the status doc can be staff-readable (for the wizard's
own Status step) while the credentials stay unreadable to *any* client,
including the bureau owner. There's no per-bureau client secret anymore —
OAuth apps have one shared secret for the whole app (see below), not one
per install.

**Security**: `allow read, write: if false` on the credentials subdoc,
unconditionally, same pattern as `otpRequests` — the Cloud Functions below
are the only things that ever touch it, via the Admin SDK.

Two new Firebase secrets, shared across every bureau (unlike the old
per-bureau values): `HUBSPOT_CLIENT_ID` / `HUBSPOT_CLIENT_SECRET`, for
BackPack's one HubSpot Public App.

### New Cloud Functions (implemented — `backpack/functions/src/index.ts`)

- `startHubspotOAuth` (callable, owner-only) — generates a short-lived CSRF
  nonce (`oauthStates/{nonce}`), returns HubSpot's authorize URL
  (`client_id`, `redirect_uri` pointing at `hubspotOAuthCallback`, scopes,
  `state=nonce`) for the client to open.
- `hubspotOAuthCallback` (public `onRequest`) — HubSpot's OAuth redirect
  target. Validates + consumes the one-time state, exchanges the
  authorization code for a refresh token
  (`POST https://api.hubapi.com/oauth/v1/token`), looks up the portal id,
  stores the refresh token (function-only) and flips the agency's status
  to `connected`, then serves a plain "you can close this tab" page.
- `getValidHubspotAccessToken(agencyCode)` (internal helper, not exported)
  — mints a fresh short-lived access token from the stored refresh token on
  every call, used by every function below that needs to actually call
  HubSpot's API. Minted per call rather than cached, since call volume here
  is low.
- `getHubspotConnectionSummary` (callable, owner-only) — for an
  already-connected agency, returns contact/deal counts for the Connect
  step's "Forbundet — fundet X kontakter og Y aftaler" chip. Replaces the
  old `testHubspotConnection` — there's no token to test anymore, only a
  connection to summarize.
- `fetchHubspotSchema` (callable, owner-only) — proxies to HubSpot's
  properties/pipelines APIs using `getValidHubspotAccessToken`, for the
  mapping UI's dropdowns.
- `saveHubspotMapping` (callable, owner-only) — persists `fieldMappings` +
  `triggerPipelineId`/`triggerStageId` + `templateGroupId`, after validating
  the template really belongs to this agency and `isTemplate === true`.
  Unchanged by the OAuth pivot.
- `hubspotWebhook` (public `onRequest`) — receives the deal-property-change
  event(s). Verifies HubSpot's v3 signature (HMAC-SHA256 over
  method+uri+body+timestamp, constant-time compared, >5min-old timestamps
  rejected) using the **one shared** `HUBSPOT_CLIENT_SECRET` — checked
  *before* looking up which agency the event belongs to, which the old
  per-bureau-secret model couldn't do (had to find the agency first just
  to find its secret). Looks up the agency via `hubspotPortalId`, mints an
  access token via the helper, fetches the deal + associated contacts,
  duplicates `templateGroupId` (see "Template-based group creation" above),
  and writes `groups/hubspot_{dealId}` — a deterministic id so HubSpot's
  retry-on-non-2xx behavior can't create duplicate groups.

## Reverse bridge (controlpanel → HubSpot): member-submitted data

Concrete first use case for two-way sync, narrower than "full trip status
sync": a bureau requests something from a traveler that HubSpot doesn't have
yet (passport number is the running example), the traveler fills it in
inside the app, and it should land back on the matching HubSpot contact
automatically — no bureau employee re-typing it into HubSpot by hand.

### Flow
1. Bureau (or BackPack, on their behalf) marks a member field as
   "requested" — e.g. passport number — on a group/member, same "requested
   info" mechanism the app already uses to prompt travelers for missing
   data.
2. Traveler fills in the field in the app.
3. On write to that member field, a Cloud Function checks whether this
   agency has a reverse mapping for it. If so, it looks up the member's
   linked `hubspotContactId` and does a
   `PATCH /crm/v3/objects/contacts/{contactId}` with the mapped property.
4. Failure (no linked contact, HubSpot API error, missing scope) gets logged
   to the same `recentEvents` log the inbound webhook uses, so the status
   panel shows both directions.

### Prerequisite: linking a member to its HubSpot contact
The reverse bridge only works for members that trace back to a HubSpot
contact. Since members are created from the deal's associated contacts
during the inbound sync, `hubspotContactId` should be stamped onto the
member doc at creation time. Members added manually in-app (not sourced
from a HubSpot deal) have no HubSpot counterpart and reverse sync is a
no-op for them — worth surfacing that distinction in the UI so a bureau
doesn't expect a synced write for members it created by hand.

### Mapping UI
Extends the existing "Map fields" wizard step (step 2) rather than adding a
new one: each row already picks a HubSpot property for a BackPack field;
add a direction toggle (or a second list) for fields that make sense in
reverse — passport number, other traveler-supplied identity/travel-doc
fields. Not every field is reversible (e.g. departure date is HubSpot-
sourced, not traveler-supplied), so this isn't just "mirror the inbound
mapping."

### Data model additions
- Member doc: `hubspotContactId` (string, optional — absent for
  manually-added members).
- `agencyIntegrations/{agencyCode}`: `reverseFieldMappings`:
  `{ backpackField: string, hubspotProperty: string }[]`, separate from the
  inbound `fieldMappings` since the field sets and directions differ.

### New Cloud Function
- `pushMemberFieldToHubspot` (Firestore-triggered, on member doc write) —
  checks the written field against `reverseFieldMappings`, and if matched
  and `hubspotContactId` is present, calls HubSpot's contacts API using the
  agency's stored token. Reuses the same owner-gated stored token, no new
  secret handling needed.

### Scopes
Needs `crm.objects.contacts.write` added to the shared OAuth app's scope
list, in addition to the read scopes already listed in step 1 of the
wizard. Since scopes now live on BackPack's one shared app rather than a
per-bureau token, this is a single one-time change (redeploy the app with
the new scope) rather than something each already-connected bureau needs
to redo — though every bureau will need to reconnect/re-consent once,
since HubSpot requires re-authorization when an app's requested scopes
change.

## Open questions / prerequisites
- **Blocking, outside code**: BackPack needs a HubSpot Developer Account
  and the one shared Public (OAuth) App provisioned under it via
  `hs project create` (public-app template) — scopes, `redirect_uri`
  (→ `hubspotOAuthCallback`), and `webhooks/webhooks.json`
  (→ `hubspotWebhook`) all configured on that one app. The resulting
  Client ID/Secret get set as the `HUBSPOT_CLIENT_ID`/`HUBSPOT_CLIENT_SECRET`
  Firebase secrets. Nothing in the code depends on this existing yet, but
  it has to exist before any real end-to-end test can run.
- A demo/pilot bureau exists in HubSpot — once the app above exists, next
  step is the real end-to-end flow: click "Forbind til HubSpot," complete
  HubSpot's login/consent, confirm real fields/pipelines appear, pick a
  real template, activate, move a demo deal into the trigger stage, and
  confirm a real group is created — with no manual webhook step needed
  this time.
- That pilot bureau needs at least one template group (`isTemplate: true`)
  built in the control panel before the "pick the trigger & template" step
  is testable.
- HubSpot's date property format (Unix ms vs. ISO string, depending on
  property type) for the mapped `departureDate`/`returnDate` fields is
  handled defensively (`parseHubspotDate` tries numeric-ms first, falls
  back to `Date` parsing) but hasn't been empirically verified against a
  real HubSpot deal yet.
- Sync is no longer strictly one-way: full trip-status-to-HubSpot sync is
  still deferred, but the reverse bridge for member-submitted fields
  (passport number etc.) is now in scope — see "Reverse bridge" above.
- Passport numbers are sensitive personal data — confirm whether HubSpot's
  standard/custom contact properties are an acceptable place to store them
  for this client, and whether anything beyond the existing token-security
  handling (never client-readable) needs to apply specifically to this
  field.

## Status
The one-way pipeline (Connect → Map fields → Trigger+template → Activate →
Status, plus `hubspotWebhook` creating a real group from a template) is
implemented on an **OAuth** basis: `firestore.rules`,
`backpack/functions/src/index.ts` (`startHubspotOAuth`/
`hubspotOAuthCallback`/`getHubspotConnectionSummary`/`fetchHubspotSchema`/
`saveHubspotMapping`/`hubspotWebhook`), and `crm_integration_screen.dart`
all wired to each other rather than mock data. This replaced an earlier,
already-implemented version built around a pasted Private App access
token + client secret — abandoned once it turned out HubSpot now steers
new Private App creation toward CLI-driven tooling, which would have put
engineering work on every bureau instead of just BackPack once.

Blocked on one outside-code prerequisite before any real end-to-end test:
BackPack's own HubSpot Developer Account + shared Public App don't exist
yet (see "Open questions" above). The reverse bridge (passport-number
push, member → HubSpot) remains design-only, unchanged from before.
