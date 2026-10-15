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

// ── Team links (Blueprint 38): one open link per office ──

/** `/j/<code>`: 10 Crockford Base32 characters (_shared/invite_token.ts teamCodePattern). */
export const TEAM_CODE_PATTERN = /^[0-9A-HJKMNP-TV-Z]{10}$/;
export const TeamCode = Schema.String.check(Schema.isPattern(TEAM_CODE_PATTERN));

/** Upper-cases a code from a URL; null when it cannot be one. */
export const normalizeTeamCode = (value: string): string | null => {
	const code = value.trim().toUpperCase();
	return TEAM_CODE_PATTERN.test(code) ? code : null;
};

/** Offered limits (owner decision 3); null is "no end" / "no limit". */
export const TEAM_LINK_DAYS = [1, 7, 30] as const;
export const TEAM_LINK_USES = [10, 50] as const;
export const TeamLinkDays = Schema.NullOr(Schema.Literals(TEAM_LINK_DAYS));
export const TeamLinkUses = Schema.NullOr(Schema.Literals(TEAM_LINK_USES));

/** Why the office's link does not work right now, or `live`. */
export const TeamLinkState = Schema.Literals([
	'live',
	'expired',
	'full',
	'creator_left',
	'office_closed',
	'network_inactive'
]);
export type TeamLinkState = typeof TeamLinkState.Type;

export const TeamLink = Schema.Struct({
	teamLinkId: Uuid,
	reference: Schema.String,
	url: Schema.String,
	officeId: Uuid,
	expiresAt: Schema.NullOr(IsoDateTime),
	maxUses: Schema.NullOr(Schema.Int),
	uses: Schema.Int,
	createdAt: IsoDateTime,
	createdBy: Person,
	state: TeamLinkState
});
export type TeamLink = typeof TeamLink.Type;

/** GET /team-link?officeId=: the office's active link, if any. */
export const TeamLinkRead = Schema.Struct({ link: Schema.NullOr(TeamLink) });
export type TeamLinkRead = typeof TeamLinkRead.Type;

/** POST /team-link (PIN): replaces the office's active link. */
export const CreateTeamLinkRequest = Schema.Struct({
	officeId: Uuid,
	days: TeamLinkDays,
	maxUses: TeamLinkUses,
	idempotencyKey: IdempotencyKey
});
export type CreateTeamLinkRequest = typeof CreateTeamLinkRequest.Type;

export const CreatedTeamLink = Schema.Struct({
	...TeamLink.fields,
	replaced: Schema.Boolean
});
export type CreatedTeamLink = typeof CreatedTeamLink.Type;

/** POST /team-link/:id/turn-off (PIN). */
export const TurnOffTeamLinkRequest = Schema.Struct({ idempotencyKey: IdempotencyKey });

export const TurnedOffTeamLink = Schema.Struct({
	teamLinkId: Uuid,
	status: Schema.String,
	/** false when it had already ended. */
	changed: Schema.Boolean
});
export type TurnedOffTeamLink = typeof TurnedOffTeamLink.Type;

/** POST /team-link/preview (no session): the join page's heading (owner decision 8). */
export const TeamLinkPreview = Schema.Struct({
	networkName: Schema.String,
	officeName: Schema.String,
	invitedBy: Schema.NullOr(Schema.String)
});
export type TeamLinkPreview = typeof TeamLinkPreview.Type;

export const TeamCodeRequest = Schema.Struct({ code: TeamCode });

export const JoinTeamLinkRequest = Schema.Struct({
	code: TeamCode,
	idempotencyKey: IdempotencyKey
});

export const JoinedTeam = Schema.Struct({
	membershipId: Uuid,
	tenantId: Uuid,
	officeId: Uuid,
	role: Role,
	isPrimary: Schema.Boolean
});
export type JoinedTeam = typeof JoinedTeam.Type;

export const InvitationRoutes = {
	mine: { method: 'GET', path: '/mine' },
	accept: { method: 'POST', path: '/accept' },
	preview: { method: 'POST', path: '/preview' },
	verifyEmail: { method: 'POST', path: '/verify-email' },
	list: { method: 'GET', path: '/' },
	create: { method: 'POST', path: '/' },
	reissue: (invitationId: string) =>
		({ method: 'POST', path: `/${invitationId}/reissue` }) as const,
	revoke: (invitationId: string) => ({ method: 'POST', path: `/${invitationId}/revoke` }) as const,
	teamLink: { method: 'GET', path: '/team-link' },
	createTeamLink: { method: 'POST', path: '/team-link' },
	turnOffTeamLink: (teamLinkId: string) =>
		({ method: 'POST', path: `/team-link/${teamLinkId}/turn-off` }) as const,
	teamLinkPreview: { method: 'POST', path: '/team-link/preview' },
	joinTeamLink: { method: 'POST', path: '/team-link/join' }
} as const;
