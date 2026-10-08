// `invitations` Edge Function contract, the routes the app uses so far: the
// in-app "Invitations for you" list, the emailed-link join flow (preview,
// verify-email, accept by token; W-02), accepting by id (W-03 owner
// decision 8) and the leaders' list with create, resend (reissue) and revoke
// (Blueprint 03 B4; Paper I01/I02). Derived from
// backend/supabase/functions/invitations/handler.ts, _shared/invite_token.ts
// and the api.* invitation commands on main.

import { Schema } from 'effect';
import { IDEMPOTENCY_KEY_PATTERN, IsoDateTime, Person, Role, Uuid } from './common';

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

// ── Leaders' list and commands (api.list_invitations / create / reissue / revoke) ──

export const INVITATION_STATUSES = ['pending', 'accepted', 'expired', 'revoked'] as const;
export const InvitationStatus = Schema.Literals(INVITATION_STATUSES);
export type InvitationStatus = typeof InvitationStatus.Type;

/** Email delivery of the current link; only for pending invitations, null when unknown. */
export const InvitationDelivery = Schema.NullOr(Schema.Literals(['waiting', 'sent', 'failed']));

/** One row of GET / (api.list_invitations). The link token is never part of it. */
export const Invitation = Schema.Struct({
	invitationId: Uuid,
	reference: Schema.String,
	email: Schema.String,
	officeId: Uuid,
	officeName: Schema.String,
	role: Role,
	status: InvitationStatus,
	expiresAt: IsoDateTime,
	invitedBy: Person,
	issueCount: Schema.Int,
	delivery: InvitationDelivery,
	createdAt: IsoDateTime,
	acceptedAt: Schema.NullOr(IsoDateTime),
	revokedAt: Schema.NullOr(IsoDateTime)
});
export type Invitation = typeof Invitation.Type;

export const InvitationPage = Schema.Struct({
	items: Schema.Array(Invitation),
	nextCursor: Schema.NullOr(Schema.String)
});
export type InvitationPage = typeof InvitationPage.Type;

/** Same rule as the handler's email(): trimmed, ≤ 254, one @, a dot in the domain. */
export const INVITE_EMAIL_PATTERN = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
export const InviteEmail = Schema.String.check(
	Schema.isMaxLength(254),
	Schema.isPattern(INVITE_EMAIL_PATTERN)
);

/** Reason for a protected change (identity.require_reason: 3–500 after trimming). */
export const Reason = Schema.String.check(Schema.isMinLength(3), Schema.isMaxLength(500));

/** POST / : leader roles need a reason (and step-up); a member invitation may carry one. */
export const CreateInvitationRequest = Schema.Struct({
	officeId: Uuid,
	role: Role,
	email: InviteEmail,
	reason: Schema.optionalKey(Reason),
	idempotencyKey: IdempotencyKey
});
export type CreateInvitationRequest = typeof CreateInvitationRequest.Type;

export const CreatedInvitation = Schema.Struct({
	invitationId: Uuid,
	reference: Schema.String,
	status: InvitationStatus,
	expiresAt: IsoDateTime
});

/** POST /:id/reissue: a fresh link; the old one stops working, 7 days restart. */
export const ReissueInvitationRequest = Schema.Struct({ idempotencyKey: IdempotencyKey });

export const ReissuedInvitation = Schema.Struct({
	invitationId: Uuid,
	reference: Schema.String,
	status: InvitationStatus,
	expiresAt: IsoDateTime,
	issueCount: Schema.Int
});
export type ReissuedInvitation = typeof ReissuedInvitation.Type;

/** POST /:id/revoke: reason 3–500 characters. */
export const RevokeInvitationRequest = Schema.Struct({
	reason: Reason,
	idempotencyKey: IdempotencyKey
});

export const RevokedInvitation = Schema.Struct({
	invitationId: Uuid,
	status: Schema.Literal('revoked'),
	/** false when it was already revoked (an idempotent no-op). */
	changed: Schema.Boolean
});
export type RevokedInvitation = typeof RevokedInvitation.Type;

export const InvitationRoutes = {
	mine: { method: 'GET', path: '/mine' },
	accept: { method: 'POST', path: '/accept' },
	preview: { method: 'POST', path: '/preview' },
	verifyEmail: { method: 'POST', path: '/verify-email' },
	list: { method: 'GET', path: '/' },
	create: { method: 'POST', path: '/' },
	reissue: (invitationId: string) =>
		({ method: 'POST', path: `/${invitationId}/reissue` }) as const,
	revoke: (invitationId: string) => ({ method: 'POST', path: `/${invitationId}/revoke` }) as const
} as const;
