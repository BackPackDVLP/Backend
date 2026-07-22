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

## Open questions / prerequisites
- Need a HubSpot private app access token from the client's HubSpot account.
- Need field mapping decisions: which HubSpot deal/contact properties map to
  group name, departure date, member email/phone, etc.
- Sync direction should start one-way (HubSpot → controlpanel) rather than
  two-way, to avoid conflict-resolution complexity.

## Status
Exploratory discussion only — no code written, no HubSpot account/token
connected yet.
