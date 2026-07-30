# HubSpot integration — notes (exploratory, not started)

Context: a travel agency client uses HubSpot as their CRM. Idea is to connect
the controlpanel with HubSpot to reduce manual re-entry of trip/member data.

## Feasibility
HubSpot exposes a REST API for contacts/deals and supports webhooks, so this
is doable without heavy infrastructure — a Cloud Function can receive a
HubSpot webhook and act on it.

## Proposed approach (one-way, HubSpot → controlpanel)
- Add a Cloud Function that listens for a HubSpot webhook, e.g. a deal
  moving to a "Booked" stage.
- On trigger, auto-create a group in Firestore, pulling members from the
  contacts associated with that deal (name, email, phone).
- This is the highest-value, lowest-risk piece: it removes manual group/member
  setup for bookings that already exist in HubSpot.

## Two-way sync (pushing controlpanel → HubSpot)
- E.g. pushing trip status back to HubSpot as deal notes/timeline events.
- Considered, but significantly more work than one-way — deferred.

## Self-service, per-bureau setup (revised direction)

The earlier version of this doc assumed *we* (BackPack) would hand-configure
a fixed field mapping per client. That doesn't scale past one or two
agencies — every bureau's HubSpot instance has different custom properties,
pipeline names, and stage IDs. Revised direction: build a wizard **inside the
control panel** so a bureau's own owner can connect and configure this
themselves, no engineering time per client.

### New "Integrationer" section (Bureau Settings)

A new card in `BureauSettingsScreen`, owner-only (same gate as
`inviteEmployee`/`updateEmployee` — `role == 'owner'` or `BACKPACK-ADMIN`).
Wizard steps:

1. **Connect** — explain what's needed with a numbered, in-app guide (not
   just this doc): how to create a HubSpot **Private App** under
   *Settings → Integrations → Private Apps*, which scopes to grant
   (`crm.objects.deals.read`, `crm.objects.contacts.read`, plus whatever
   webhook subscription scope HubSpot requires), and where to paste the
   generated token. A "Test forbindelse" button calls a new callable
   Cloud Function that pings HubSpot's API with the token and reports
   success/failure with a specific, actionable error (invalid token, missing
   scope, etc.) rather than a raw HTTP error.
2. **Map fields** — once connected, a Cloud Function fetches the bureau's
   *actual* HubSpot properties (`GET /crm/v3/properties/deals` and
   `/contacts`) and pipeline stages (`GET /crm/v3/pipelines/deals`) and
   returns them to the client. The UI shows a dropdown next to each BackPack
   field (group name, departure date, return date, member name/email/phone,
   agencyCode if the bureau runs multiple brands) letting the owner pick
   which of *their own* HubSpot properties feeds it — including custom
   properties, which is the whole reason this can't be hardcoded.
3. **Pick the trigger** — a dropdown of the bureau's own deal pipeline
   stages (from step 2's fetch) to choose which stage transition creates a
   group (e.g. their "Booked"/"Betalt" stage, whatever they've actually
   named it).
4. **Save & activate** — persists the mapping, registers/confirms the
   webhook subscription, and flips the integration to active.
5. **Status/troubleshooting panel** — shows recent webhook events received
   and whether each one successfully created a group, so a bureau can
   self-diagnose ("last event failed: no contact found for deal") without
   filing a support ticket.

### Data model

New Firestore doc per bureau, e.g. `agencyIntegrations/{agencyCode}`:
- `hubspotPortalId`, `hubspotAccessToken` (see security note below),
  `connectedAt`, `connectedBy` (uid), `status`.
- `fieldMappings`: `{ backpackField: string, hubspotObjectType: 'deal' |
  'contact', hubspotProperty: string }[]`.
- `triggerStageId`, `triggerPipelineId`.
- `recentEvents`: capped log of the last N webhook deliveries + outcome, for
  the status panel.

**Security**: the access token must never be client-readable. This doc
should be function-only (`allow read, write: if false` in
`firestore.rules`, same pattern as `admins`/`otpRequests`) — the wizard's
"test connection"/"fetch properties"/"save mapping" steps all go through
owner-gated callable Cloud Functions that read/write it server-side, never
returning the raw token back to the client.

### New Cloud Functions

- `testHubspotConnection` (callable, owner-only) — validates a submitted
  token + scopes before it's saved.
- `fetchHubspotSchema` (callable, owner-only) — proxies to HubSpot's
  properties/pipelines APIs using the *stored* token, for the mapping UI's
  dropdowns.
- `saveHubspotMapping` (callable, owner-only) — persists `fieldMappings`
  + `triggerStageId`.
- `hubspotWebhook` (public `onRequest`) — receives the deal-stage-change
  event, verifies HubSpot's request signature (HMAC using the app's client
  secret — required, otherwise anyone could POST a forged "deal booked"
  event to spawn bogus groups), looks up which agency it belongs to via
  `hubspotPortalId`, applies that agency's `fieldMappings` to the deal's
  associated contacts, and creates the `groups/{groupId}` doc + `members[]`.

## Open questions / prerequisites
- Need at least one bureau willing to be the pilot/test connection — the
  wizard's "fetch properties" and "test connection" steps are meaningless
  to build against without a real HubSpot account+token to point at.
- HubSpot's webhook signature verification scheme needs a concrete look
  once we're actually wiring `hubspotWebhook` up (which secret, which
  header, v2 vs v3 signature).
- Sync direction stays one-way (HubSpot → controlpanel) — two-way is still
  deferred, unchanged from before.

## Status
Exploratory design only — no code written, no HubSpot account/token
connected yet. This doc is now detailed enough to scope actual
implementation work once a pilot bureau is lined up.
