// `invitations` Edge Function contract, the routes the app uses so far: the
// in-app "Invitations for you" list, the emailed-link join flow (preview,
// verify-email, accept by token; W-02) and accepting by id (W-03 owner
// decision 8). Derived from backend/supabase/functions/invitations/handler.ts,
// _shared/invite_token.ts and the api.* invitation commands on main.

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

/** The link secret from `/join#t=…` (_shared/invite_token.ts tokenPattern). */
export const INVITATION_TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/;
export const InvitationToken = Schema.String.check(Schema.isPattern(INVITATION_TOKEN_PATTERN));

export const InvitationTokenRequest = Schema.Struct({ token: InvitationToken });

/** POST /preview: only the bound email (W-02 step 1). */
export const InvitationPreview = Schema.Struct({ email: Schema.String });
export type InvitationPreview = typeof InvitationPreview.Type;

/** POST /verify-email: never echoes the email. */
export const VerificationSent = Schema.Struct({ sent: Schema.Literal(true) });

/** Exactly one of token (emailed link) or invitationId (in-app list). */
export const AcceptInvitationRequest = Schema.Union([
	Schema.Struct({ invitationId: Uuid, idempotencyKey: IdempotencyKey }),
	Schema.Struct({ token: InvitationToken, idempotencyKey: IdempotencyKey })
]);
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
	accept: { method: 'POST', path: '/accept' },
	preview: { method: 'POST', path: '/preview' },
	verifyEmail: { method: 'POST', path: '/verify-email' }
} as const;
