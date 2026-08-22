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
   returns them to the client, plus the list of the bureau's own **custom
   object types** (`GET /crm/v3/schemas`) — a bureau can define objects
   beyond the built-in Deal/Contact (e.g. a "Booking" or "Room" object
   attached to a deal). The UI is a tabbed source picker: Deal, Contact,
   and one tab per custom object type the bureau turns on (fetched lazily
   via `fetchHubspotObjectProperties`, only for types actually enabled — a
   portal can have many a given bureau never uses). Each BackPack field
   (group name, departure date, return date on the Deal/custom-object side;
   member email/phone on the Contact side) gets a dropdown of *that
   source's* HubSpot properties — including custom properties, which is
   the whole reason this can't be hardcoded. A field can be filled from any
   one enabled source; group name/departure/return date don't have to come
   from the Deal itself if a bureau's booking data actually lives on a
   custom object instead.
3. **Pick the trigger & template rules** — a dropdown of the bureau's own
   deal pipeline stages (from step 2's fetch) to choose which stage
   transition creates a group (e.g. their "Booked"/"Betalt" stage, whatever
   they've actually named it). Template selection is a small rule engine
   rather than one fixed template: an ordered, reorderable list of "IF
   [any HubSpot property — Deal, Contact, or an enabled custom object]
   [equals / is not equal to / is one of / is not empty] [value] THEN use
   template [X]" rules, evaluated first-match-wins, plus a required
   "standardskabelon" (default template) row used when no rule matches (or
   none are configured — the original single-template behavior). This is
   what lets a bureau route different deals to different templates based
   on HubSpot data (e.g. a `referenceCode` property) without needing any
   engineering time, and supports as many templates as the bureau has
   rules for. Every template (default and every rule's target) still has
   to be one of the bureau's own `isTemplate: true` groups — see
   "Template-based group creation" below for how the duplication works
   server-side.
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

Resolved: a bureau can pick *multiple* templates, routed by an ordered
rule list evaluated against any Deal/Contact/custom-object property (see
"Pick the trigger & template rules" above) — not just a per-pipeline/stage
split, and not limited to one property. `hubspotWebhook` resolves the
condition value for each rule in order (from the already-fetched deal,
first associated contact, or first associated custom object record,
depending on the rule's source) and duplicates the first matching rule's
template, falling back to the default template when nothing matches.

### Document import (implemented, source configurable, optional)

Files are copied into the new group's documents automatically — a bureau
attaches a booking confirmation, itinerary, etc. in HubSpot as normal, and
it just shows up in the trip's documents in both apps, no manual
re-upload. Where those files come from — or whether this happens at all —
is now a per-bureau choice (`agencyIntegrations/{agencyCode}.
documentSource`, see "Data model" below), not hardcoded-on:

- **`mode: 'disabled'`**: document import is skipped entirely for this
  agency — some bureaus may not want HubSpot files copied into a trip's
  documents at all.
- **`mode: 'notes'` (default)**: unchanged original behavior. HubSpot has
  no direct deal→file association — a file attached to a deal in the
  HubSpot UI actually creates a **Note** (engagement) on the deal with the
  file referenced in the note's `hs_attachment_ids` property
  (semicolon-separated file IDs), confirmed against HubSpot's own
  community docs. `importHubspotDealDocuments` fetches the deal with
  `associations=contacts,notes` → batch-reads the associated notes for
  `hs_attachment_ids` → downloads each via `downloadHubspotFile`.
- **`mode: 'property'`**: pulls from one specific HubSpot property instead
  (e.g. a "file" fieldType property on the deal, a contact, or an enabled
  custom object) — useful for a bureau that uploads documents somewhere
  other than a Note. `importHubspotPropertyDocuments` resolves that
  property's value via the same deal/contact/custom-object resolver
  `templateRules` conditions already use, and
  `downloadHubspotFilesFromPropertyValue` treats each `;`-separated token
  as a File Manager id *unless* it already looks like a URL, downloaded
  directly instead — HubSpot's file-property value shape (bare id vs. URL)
  isn't empirically confirmed either way yet, so both are supported
  defensively, same spirit as `parseHubspotDate`'s dual-strategy parsing.

Both modes share `downloadHubspotFile` (signed-url → download → filename/
content-type) and `saveHubspotFileToDocuments` (write to
`{groupId}/documents/{filename}` via the Admin SDK, bypassing Storage
rules like everything else this function writes) — neither app has a
documents *model*; both `backend/lib/screens/home/homescreen.dart` and
`backpack/lib/screens/documentscreen.dart/documentscreen.dart` derive a
trip's document list purely by listing Firebase Storage at
`{groupId}/documents/` (`listAll()`), no Firestore metadata, so writing
bytes to that path is the whole feature regardless of source. A small
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

### Message sync — HubSpot Notes → BackPack messages (implemented, opt-in)

Ongoing sync, not a one-time pull: unlike group creation (a single event
per deal), a new HubSpot Note added to a deal *after* its group already
exists should still show up as a new BackPack message. That needs its own
webhook subscription — a Note-creation event, not the dealstage-change one
group creation uses — added to
`hubspot-bridge/src/app/webhooks/webhooks-hsmeta.json`:
```json
{ "subscriptionType": "object.creation", "objectType": "note", "active": true }
```
**Unverified, blocking**: whether `"note"` is a valid `objectType` for this
config schema is not confirmed. Notes are an engagement, not a standard
CRM object like deal/contact/company/ticket, and this app has already hit
one case where Notes don't behave like a normal object in this tooling
(`crm.objects.notes.read` rejected by the HubSpot CLI as an unrecognized
scope — see the document-import scope note above). This can only be
confirmed by running `hs project upload` against a real HubSpot Developer
Account, which doesn't exist yet — see "Open questions" below.

Both webhook subscriptions deliver to the same `hubspotWebhook` endpoint.
Since this app registers exactly two subscriptions, the events loop
discriminates a Note-creation event from a dealstage-change one purely by
the *absence* of `event.propertyName` (a property-change event always has
one; object-creation events don't) — documented inline as something to
revisit if a third subscription type is ever added.

Flow (`handleNoteCreated` in `backpack/functions/src/index.ts`):
- No-ops entirely unless the agency has `messageSyncEnabled: true` — **off
  by default**. A synced Note becomes traveler-visible content the moment
  this is on, including notes never written with a traveler audience in
  mind, so this is an explicit per-bureau opt-in (with an in-wizard warning
  to that effect) rather than defaulting on for everyone.
- Fetches the note (`hs_note_body`, `hs_attachment_ids`,
  `associations=deals`). No-ops if it isn't associated with any deal, or
  its body is empty after HTML-stripping (`stripHtmlToPlainText` — best-
  effort, same unverified-until-real-portal caveat as `parseHubspotDate`
  beyond "`hs_note_body` is documented as HTML").
- For each associated deal, resolves `groups/hubspot_{dealId}`; silently
  skips deals that don't yet have a group, or belong to a different
  agency's connection — this fires for *every* Note in the whole portal,
  most of which won't be relevant, so non-matches are never logged to
  `recentEvents`.
- Writes to a **deterministic** message doc id,
  `groups/{groupId}/messages/hubspot_note_{noteId}` (not `.add()`) — same
  retry-safety pattern as the deterministic `hubspot_{dealId}` group id,
  so HubSpot's retry-on-non-2xx can't create duplicate messages. Message
  shape matches `Message.fromSnapshot` in `message_model.dart`: `title:
  "Besked fra HubSpot"`, `content` (stripped note body), `authorName:
  "HubSpot"`, `bureauName`, `isAdmin: true`, `isRead: true` (mirrors how
  `createMessage` in `groupInformation_repository.dart` marks a bureau-
  authored message already-read). Increments `messagesTotal` on the group
  doc, matching that same repository method's side effect.
- Note attachments are imported too, via `downloadHubspotFile` +
  `saveHubspotFileAsMessageAttachment` — uploaded to
  `groups/{groupId}/messageAttachments/{timestamp}_{filename}` (matching
  `uploadMessageAttachment` in the repository, not the `documents/` path),
  with a `{name, url}` shape built from a **persistent** Firebase Storage
  download URL (a `firebaseStorageDownloadTokens` metadata token + the
  same URL shape the client SDK's `getDownloadURL()` produces) rather than
  a short-lived signed URL, since a message attachment needs to stay
  viewable indefinitely like a manually-added one.
- Logs one `recentEvents` entry per successful message import (reusing
  `appendIntegrationEvent`), so the Status step shows message-sync
  activity alongside group-creation activity.
- `sendGroupMessageNotification` (existing Firestore trigger on any
  `groups/{groupId}/messages/{messageId}` create) fires automatically for
  these writes too — a HubSpot-sourced message push-notifies every member
  with an `fcmToken` for free, no changes needed there.

### Data model (implemented)

`agencyIntegrations/{agencyCode}` — non-secret status/config, staff-of-that-
agency readable:
- `hubspotPortalId`, `connectedAt`, `connectedBy` (uid), `status`
  (`'idle'|'connected'|'active'|'error'`).
- `fieldMappings`: `{ backpackField: string, hubspotObjectType: string,
  hubspotProperty: string, hubspotFieldType?: string }[]`.
  `hubspotObjectType` is `'deal' | 'contact' | <customObjectTypeId>` — widened
  from a fixed union so a bureau can source a group-level field from one of
  their own custom objects instead of the deal.
- `customObjectTypeIds: string[]` — which of the bureau's custom object
  types are enabled as a mapping/rule source. Drives both what
  `hubspotWebhook` fetches per deal and which tabs the mapping UI shows.
- `triggerStageId`, `triggerPipelineId`.
- `templateRules: TemplateRule[]` — ordered, first-match-wins list of
  `{ id, label?, condition: { hubspotObjectType, hubspotProperty, operator:
  'equals'|'not_equals'|'in'|'is_not_empty', value?: string | string[] },
  templateGroupId }`, replacing the old flat `templateGroupId`.
- `defaultTemplateGroupId: string` — required fallback template used when
  no rule matches (or none are configured). The bureau's chosen template
  group (`isTemplate: true`) — same validation as before, now applied to
  this field and to every distinct template referenced by a rule.
- `documentSource: { mode: 'disabled' | 'notes' | 'property';
  hubspotObjectType?: string; hubspotProperty?: string }` — where
  `hubspotWebhook` pulls a new group's documents from. Absent or `mode:
  'notes'` preserves the original always-on Notes-attachments behavior;
  `'property'` points at one specific mapped property instead; `'disabled'`
  skips document import entirely (`documentsImported` stays `0`, same as
  a deal with no attachments — no separate error/event). See "Document
  import" above.
- `messageSyncEnabled: boolean` — off by default. Whether a HubSpot Note
  created on a deal becomes a BackPack message once that deal's group
  exists. See "Message sync" above.
- `recentEvents`: capped log of the last 20 deliveries + outcome, for the
  status panel. The outcome string now also notes which rule matched (or
  that the default template was used), and message-sync imports log their
  own entries alongside group-creation ones.

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
  mapping UI's dropdowns. Also calls `GET /crm/v3/schemas` and returns the
  bureau's custom object types (id + label) — HubSpot's schemas endpoint
  only ever lists a portal's *custom* objects, never the built-in ones, so
  no filtering is needed (unverified against a real portal yet, same
  caveat as `parseHubspotDate` below).
- `fetchHubspotObjectProperties` (callable, owner-only) — given one or more
  custom object type ids, returns their property lists, reusing the same
  filter/sort as `fetchHubspotSchema`'s deal/contact lists. Split into its
  own callable rather than fetching every custom object type's full
  property list up front, since a portal can have many a bureau never uses.
- `saveHubspotMapping` (callable, owner-only) — persists `fieldMappings` +
  `customObjectTypeIds` + `triggerPipelineId`/`triggerStageId` +
  `templateRules` + `defaultTemplateGroupId` + `documentSource` +
  `messageSyncEnabled`, after validating every distinct referenced
  template really belongs to this agency and `isTemplate === true`, and
  that `documentSource.mode === 'property'` always carries both an object
  type and a property.
- `downloadHubspotFile`/`downloadHubspotFilesFromPropertyValue`/
  `saveHubspotFileToDocuments`/`saveHubspotFileAsMessageAttachment`
  (internal helpers, not exported) — the shared file-download/upload
  primitives behind both document-import modes and Note-message
  attachment import; see "Document import" and "Message sync" above.
- `hubspotWebhook` (public `onRequest`) — receives both the dealstage
  property-change and Note-creation event(s) (see "Message sync" above for
  how those two are told apart). For a dealstage event: verifies HubSpot's
  v3 signature (HMAC-SHA256 over method+uri+body+timestamp, constant-time
  compared, >5min-old timestamps rejected) using the **one shared**
  `HUBSPOT_CLIENT_SECRET` — checked *before* looking up which agency the
  event belongs to, which the old per-bureau-secret model couldn't do (had
  to find the agency first just to find its secret) — this signature check
  happens once for the whole delivery, ahead of either event type. Looks
  up the agency via `hubspotPortalId`, mints an access token via the
  helper, fetches the deal + associated contacts + (for every enabled
  `customObjectTypeIds` entry actually referenced by a mapping or rule)
  the deal's first associated custom object record via `GET /crm/v4/
  objects/deals/{dealId}/associations/{objectTypeId}` — a deal with
  multiple associated instances of the same custom object type isn't
  disambiguated in v1, it just uses the first one found. Evaluates
  `templateRules` in order against the resolved deal/contact/custom-object
  property values, picks the first match's template (or the default), and
  duplicates it (see "Template-based group creation" above), writing
  `groups/hubspot_{dealId}` — a deterministic id so HubSpot's
  retry-on-non-2xx behavior can't create duplicate groups. For a
  Note-creation event: delegates to `handleNoteCreated` (see "Message
  sync" above).

## Conversations Inbox (two-way, implemented, opt-in)

Distinct from "Message sync" above, which reads a HubSpot deal's **Notes**
timeline. This connects BackPack messaging to HubSpot's actual
**Conversations Inbox** — the shared team-inbox product staff normally live
in — so a bureau employee can write to a specific traveler from HubSpot the
same way they'd answer any other inbox conversation, and a traveler's reply
inside the app shows back up in that same HubSpot thread. Two-way, not a
one-time pull, same ongoing-sync posture as Message sync.

**Biggest risk, above every other open question in this doc**: building a
channel that appears inside HubSpot's Conversations Inbox requires
HubSpot's **Custom Channels API**. Unlike every other piece of this
integration (CRM objects, deal webhooks, OAuth scopes), this has
historically required HubSpot to grant an app special access, not just
adding a scope — qualitatively different from "unverified but implemented
per docs anyway" the rest of this doc uses, because if access isn't
grantable at all, this whole feature needs a different design (e.g. drop
back to a Notes-adjacent approach, or accept no real Inbox presence).
**Confirm Custom Channels access is actually obtainable for BackPack's app
before investing further here** — not resolvable by reading code, only by
checking current HubSpot developer docs or asking in HubSpot's developer
Slack, same "needs a real Developer Account" gate the rest of this doc is
already blocked on, but this one could invalidate the design outright rather
than just leaving it untested.

### Where this surfaces in BackPack (explicit product trade-off)
HubSpot Conversations threads are always private and 1:1 with one contact.
BackPack's existing comment thread under a message
(`groups/{groupId}/messages/{messageId}/comments`, read via `getComments`
with **no author filter** in both the traveler app's `messages_screen.dart`
and the bureau's `group_messages_dialog.dart`) is visible to the **whole
trip group**. Rather than build a new private per-traveler channel, this
reuses the existing group message/comment feature as-is — a deliberate
product choice, not an oversight: a traveler's personal reply (synced to
their own HubSpot contact) becomes visible to every other member of that
trip, a privacy shape HubSpot's own Inbox doesn't have. The wizard's opt-in
copy for this toggle says so explicitly (`_buildConversationSyncCard` in
`crm_integration_screen.dart`), same spirit as the existing Message-sync
warning about unfiltered Notes.

### Inbound: staff writes in HubSpot Inbox → BackPack message
Mirrors `handleNoteCreated` exactly in shape — same deterministic message id
pattern (`hubspot_conv_{messageId}`), same `"Besked fra HubSpot"` /
`authorName: "HubSpot"` / `isAdmin: true` write, same `messagesTotal`
increment and `recentEvents` logging — sourced from a Conversations message
instead of a deal Note:
- New webhook subscription, `hubEvents: [{ eventType:
  "conversation.newMessage" }]` in `webhooks-hsmeta.json` — a different
  category than the two existing `crmObjects` subscriptions (dealstage
  change, Note creation), since Conversations events aren't CRM objects.
  **Unverified**: whether `"conversation.newMessage"` is the correct
  `eventType` string for this schema, and what field names a `hubEvents`
  delivery actually carries — `hubspotWebhook`'s discriminator checks
  `event.subscriptionType`/`event.eventType` starting with `"conversation."`
  first, before falling back to the original two-way Note/dealstage split,
  and `handleConversationMessageCreated` defensively checks several
  plausible field names (`threadId`/`conversationId`/`objectId`,
  `messageId`/`messageEventId`) for the same reason `parseHubspotDate` tries
  multiple parse strategies — none of this has been exercised against a
  real delivery.
- `handleConversationMessageCreated` (in `hubspotWebhook`'s event loop) —
  gated by `conversationSyncEnabled` (off by default, same posture as
  `messageSyncEnabled`). Fetches the message
  (`GET /conversations/v3/conversations/threads/{threadId}/messages/{messageId}`)
  and **only processes it if `direction === "OUTGOING"`** (business →
  visitor) — messages this same integration posts on a traveler's behalf
  land as `INCOMING` on the same thread, and processing those here would
  loop a traveler's own comment back into their group as a new "Besked fra
  HubSpot" message. Resolves the thread's associated contact
  (`GET /conversations/v3/conversations/threads/{threadId}`,
  `associatedContactId` — **unverified** field name/endpoint), looks up
  `hubspotContactLinks/{contactId}` to find the group, and writes the
  message the same way `handleNoteCreated` does.

### Outbound: traveler comment → pushed into the HubSpot conversation
`pushCommentToHubspotConversation` (new Firestore trigger on
`groups/{groupId}/messages/{messageId}/comments/{commentId}` create) — the
first real implementation of a Firestore-write → HubSpot push in this
integration; the still-unbuilt reverse bridge below (passport-number sync)
can follow this same shape later:
- Skips staff-authored comments (`isAdmin === true`) — only a traveler's own
  words get echoed back.
- Resolves the commenting traveler: `users/{authorId}` → email (already kept
  current by `syncUserDocFromGroups`) → matched against the group's
  `members` array by email → that member's `hubspotContactId`. No-ops for
  members with none (manually-added members, same limitation the reverse
  bridge below documents).
- Posts to `/conversations/v3/custom-channels/{channelId}/messages` using
  the agency's `hubspotChannelAccountId` and the member's
  `hubspotContactId`, reusing a stored `hubspotThreadId` on the member doc
  after the first message so replies land on the same thread rather than
  starting a new one each time. **Unverified**: exact endpoint/payload shape
  (recipient identification, thread-reuse semantics) — implemented per
  HubSpot's documented API surface, not yet exercised against a real portal.
- Logs failures (API error, no linked contact, missing channel account) to
  the same `recentEvents` log every other direction of this integration
  uses.

### Data model additions
- `agencyIntegrations/{agencyCode}`: `conversationSyncEnabled: boolean`
  (default false, persisted by `saveHubspotMapping`), `hubspotChannelAccountId:
  string` (set once per bureau right after OAuth connect, see below).
- Member entry (inside a group's `members` array): `hubspotThreadId?: string`
  — the HubSpot conversation thread for this specific traveler, alongside
  the existing `hubspotContactId`.
- New top-level `hubspotContactLinks/{contactId} = { agencyCode, groupId,
  memberEmail }` — reverse lookup from a HubSpot contact id to the
  group/agency it belongs to, since `handleConversationMessageCreated` only
  has a contactId/portalId to go on and members live nested under
  `groups/{groupId}`, not queryable top-level. Written alongside
  `hubspotContactId` itself when a group is created from a deal.
  Function-only (`allow read, write: if false` in `firestore.rules`), same
  pattern as `agencyIntegrations/*/private`.

### Channel + channel-account setup
Two levels, mirroring how the OAuth app itself is shared but each bureau
gets its own connection — but unlike the OAuth app's Client ID/Secret, the
channel id is **not** a Firebase secret. This is a multi-tenant platform, so
no bureau-specific or platform-wide HubSpot id should need manual, outside-
code provisioning — the same reasoning that already drove this integration
off pasted Private App tokens. A hardcoded secret also has a very concrete
downside in practice: Firebase's CLI loads the whole functions codebase to
build its deploy manifest, and refuses to deploy *anything* from that
codebase in non-interactive mode while any referenced secret has no value
set — so an unset placeholder secret for a still-unbuilt feature blocked
deploying unrelated bug fixes the first time this was tried.
- **One shared "channel"**, created lazily by `getOrCreateHubspotChannelId`
  the first time *any* bureau needs it (via the Custom Channels API),
  cached in `hubspotPlatformConfig/conversations` (function-only, see
  `firestore.rules`) and reused by every bureau after that — whichever
  bureau connects first "pays" the one-time creation call. **Unverified**:
  whether a channel created via one portal's access token actually
  registers at the *app* level (reusable by every other portal) rather than
  being scoped to that one portal — if it turns out to be portal-scoped,
  this caching assumption is wrong and each bureau needs its own channel,
  not a shared cached one.
- **One "channel account" per connected bureau**, created automatically by
  `ensureHubspotChannelAccount` right after token exchange in
  `hubspotOAuthCallback` (parallels the existing `hubspotPortalId` lookup
  there) — so a bureau owner never has to do anything channel-related
  themselves, same "no engineering/manual work per bureau" goal the whole
  OAuth redesign was built around. Best-effort: if this call fails (e.g.
  because Custom Channels access turns out not to be granted), the OAuth
  connect step still succeeds — only `conversationSyncEnabled` stays
  non-functional until it's fixed, nothing else in the integration is
  affected. **This is exactly the step most likely to actually require a
  manual per-portal action in HubSpot's own UI** (e.g. an admin assigning
  the channel to an inbox) even if the API call itself succeeds — confirm
  this isn't the case before assuming the automatic flow above is complete.

### Scopes
`conversations.read` / `conversations.write` added to the shared app's
`requiredScopes`. Since scopes live on BackPack's one shared app, this is a
single one-time change — but, same caveat as every previous scope addition
(`files`, etc.), every already-connected bureau needs to reconnect once,
since HubSpot requires re-authorization when an app's requested scopes
change.

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

## Custom objects and rule-based templates (implemented)

Two extensions on top of the one-way pipeline above, both UI + backend:

- **Custom objects as a mapping/rule source**: a bureau can turn on any of
  their own HubSpot custom object types (e.g. "Booking", "Room") as a
  source for group-level fields (group name, departure/return date) and
  for rule conditions, alongside Deal and Contact. Not usable for member
  fields (email/phone) — members are structurally built from the deal's
  associated contacts, not from custom objects, so that constraint carries
  over unchanged. v1 limitation: if a deal has multiple associated
  instances of the same custom object type, `hubspotWebhook` uses the
  first one found rather than disambiguating.
- **Rule-based template selection**: `templateGroupId` is no longer a
  single flat field. A bureau builds an ordered list of rules (any
  Deal/Contact/custom-object property, an operator, a value, and a target
  template) plus a required default/fallback template. This directly
  replaces the earlier "one default template per agency" open question
  below — resolved by a rule engine rather than, say, forcing template
  document ids to equal HubSpot property values (considered and rejected:
  fragile, single-property-only, no fallback).

Same caveat as the rest of this doc: none of this has been exercised
against a real HubSpot portal yet (see "Open questions / prerequisites"),
so the exact response shapes of `GET /crm/v3/schemas` and the v4
associations endpoint are implemented per HubSpot's documented API surface
but unverified empirically.

## Open questions / prerequisites
- **Blocking, new, above every other item below**: whether HubSpot's Custom
  Channels API is actually obtainable for BackPack's app — this gates the
  entire "Conversations Inbox (two-way)" feature, not just its E2E test.
  See that section for why this is a different kind of risk than the rest
  of this list.
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
- **Blocking, new**: whether `{ "subscriptionType": "object.creation",
  "objectType": "note" }` is a valid webhook subscription for this app's
  config schema is unconfirmed — Notes are an engagement, not a standard
  CRM object, and this project has already hit one case
  (`crm.objects.notes.read` scope rejected as unrecognized) where Notes
  don't behave like a normal object in HubSpot's tooling. Only `hs project
  upload` against a real Developer Account can confirm this — same
  prerequisite as the bullet above, but message sync specifically can't be
  considered done until this is verified, even once the rest of the
  pipeline is pilot-tested.

## Status
The one-way pipeline (Connect → Map fields → Trigger+template rules →
Activate → Status, plus `hubspotWebhook` creating a real group from a
rule-selected template, sourced from Deal/Contact/custom-object data,
importing documents from a configurable source, and — opt-in — syncing
HubSpot Notes into BackPack messages on an ongoing basis) is implemented
on an **OAuth** basis: `firestore.rules`, `backpack/functions/src/
index.ts` (`startHubspotOAuth`/`hubspotOAuthCallback`/
`getHubspotConnectionSummary`/`fetchHubspotSchema`/
`fetchHubspotObjectProperties`/`saveHubspotMapping`/`hubspotWebhook`, the
last of which now also branches into `handleNoteCreated` and
`handleConversationMessageCreated`, plus the new outbound
`pushCommentToHubspotConversation` trigger), the app's webhook config
(`hubspot-bridge/src/app/webhooks/webhooks-hsmeta.json`, now three
subscriptions), and `crm_integration_screen.dart` (redesigned with a tabbed
Deal/Contact/custom-object mapping picker, a reorderable rule-builder for
template selection, a document-source picker, a message-sync opt-in
toggle, and a Conversations-Inbox two-way opt-in toggle) all wired to each
other rather than mock data. This replaced an earlier, already-implemented
version built around a pasted Private App access token + client secret —
abandoned once it turned out HubSpot now steers new Private App creation
toward CLI-driven tooling, which would have put engineering work on every
bureau instead of just BackPack once.

Blocked on outside-code prerequisites before any real end-to-end test:
BackPack's own HubSpot Developer Account + shared Public App don't exist
yet (see "Open questions" above) — and message sync specifically has a
second, narrower unknown on top of that (whether the Note-creation webhook
subscription is even valid), not resolvable until the same account exists
and `hs project upload` can be run against it. Conversations Inbox two-way
sync carries a third, bigger unknown on top of both of those — whether
Custom Channels API access is obtainable at all — see "Conversations Inbox
(two-way)" above; until that's confirmed, treat this feature as designed
and scaffolded, not validated as buildable. The reverse bridge
(passport-number push, member → HubSpot) remains design-only, unchanged
from before.
