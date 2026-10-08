// `invitations` Edge Function contract, the routes the app uses so far: the
// in-app "Invitations for you" list and accepting one by id (W-03 owner
// decision 8). Derived from backend/supabase/functions/invitations/handler.ts
// and api.my_invitations / api.accept_invitation on main.

import { Schema } from 'effect';
import { IDEMPOTENCY_KEY_PATTERN, IsoDateTime, Role, Uuid } from './common';

export const MyInvitation = Schema.Struct({
	invitationId: Uuid,
	reference: Schema.String,
	tenantName: Schema.String,
	officeName: Schema.String,
	role: Role,
	expiresAt: IsoDateTime
});
export type MyInvitation = typeof MyInvitation.Type;

export const MyInvitations = Schema.Array(MyInvitation);

export const IdempotencyKey = Schema.String.check(Schema.isPattern(IDEMPOTENCY_KEY_PATTERN));

/** Only the id form; the emailed-link (token) form is not used by the app yet. */
export const AcceptInvitationRequest = Schema.Struct({
	invitationId: Uuid,
	idempotencyKey: IdempotencyKey
});
export type AcceptInvitationRequest = typeof AcceptInvitationRequest.Type;

export const AcceptedInvitation = Schema.Struct({
	invitationId: Uuid,
	membershipId: Uuid,
	tenantId: Uuid,
	officeId: Uuid,
	role: Role,
	isPrimary: Schema.Boolean
});
export type AcceptedInvitation = typeof AcceptedInvitation.Type;

export const InvitationRoutes = {
	mine: { method: 'GET', path: '/mine' },
	accept: { method: 'POST', path: '/accept' }
} as const;
