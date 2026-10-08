// Pure helpers for the leaders' Invitations page (Paper I01/I02): row labels,
// which actions a row offers, what to say when a command is refused, and
// whether an idempotency key survives a failure (W-00). No I/O here.

import type { OfficeType, Role } from '#lib/contract/common.js';
import type { ApiFailure } from '#lib/contract/errors.js';
import type { Invitation, InvitationStatus } from '#lib/contract/invitations.js';

const HOUR = 3_600_000;
const DAY = 24 * HOUR;

export const STATUS_LABELS: Record<InvitationStatus, string> = {
	pending: 'Pending',
	accepted: 'Accepted',
	expired: 'Expired',
	revoked: 'Revoked'
};

export const STATUS_FILTERS = [
	{ value: 'all', label: 'All' },
	{ value: 'pending', label: 'Pending' },
	{ value: 'accepted', label: 'Accepted' },
	{ value: 'expired', label: 'Expired' },
	{ value: 'revoked', label: 'Revoked' }
] as const;
export type StatusFilter = (typeof STATUS_FILTERS)[number]['value'];

/** "2026-10-03T…" → "3 Oct" (the person's local calendar unless a zone is given). */
export function shortDate(iso: string, timeZone?: string): string {
	return new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', timeZone }).format(
		new Date(iso)
	);
}

/** Time left on a pending link, and whether it is close enough to flag. */
export function expiryLabel(expiresAt: string, now: number): { text: string; soon: boolean } {
	const left = Date.parse(expiresAt) - now;
	if (left <= 0) return { text: 'Expired', soon: true };
	if (left < HOUR) return { text: 'Expires in under an hour', soon: true };
	if (left < DAY) {
		const hours = Math.floor(left / HOUR);
		return { text: `Expires in ${hours} ${hours === 1 ? 'hour' : 'hours'}`, soon: true };
	}
	if (left < 2 * DAY) return { text: 'Expires tomorrow', soon: true };
	return { text: `Expires in ${Math.round(left / DAY)} days`, soon: false };
}

export type ActivityTone = 'plain' | 'warning' | 'muted';

/** The "Last activity" column: expiry or a failed email for pending, else when it ended. */
export function activityLabel(
	invitation: Invitation,
	now: number,
	timeZone?: string
): { text: string; tone: ActivityTone } {
	switch (invitation.status) {
		case 'pending': {
			if (invitation.delivery === 'failed') return { text: 'Email didn’t send', tone: 'warning' };
			const expiry = expiryLabel(invitation.expiresAt, now);
			return { text: expiry.text, tone: expiry.soon ? 'warning' : 'plain' };
		}
		case 'accepted':
			return invitation.acceptedAt
				? { text: `Joined ${shortDate(invitation.acceptedAt, timeZone)}`, tone: 'plain' }
				: { text: 'Joined', tone: 'plain' };
		case 'revoked':
			return invitation.revokedAt
				? { text: `Revoked ${shortDate(invitation.revokedAt, timeZone)}`, tone: 'muted' }
				: { text: 'Revoked', tone: 'muted' };
		case 'expired':
			return { text: `Expired ${shortDate(invitation.expiresAt, timeZone)}`, tone: 'muted' };
	}
}

/** "Sent 3 Oct", or "Resent · 3 Oct" once a fresh link went out. */
export const sentLabel = (invitation: Invitation, timeZone?: string) =>
	`${invitation.issueCount > 1 ? 'Resent' : 'Sent'} ${shortDate(invitation.createdAt, timeZone)}`;

/** org.invitation_max_issues(): the first link plus 5 reissues. */
export const MAX_ISSUES = 6;

/** Only pending invitations can be resent (until the link limit) or revoked. */
export function rowActions(invitation: Invitation, maxIssues = MAX_ISSUES) {
	const pending = invitation.status === 'pending';
	return { resend: pending && invitation.issueCount < maxIssues, revoke: pending };
}

/** Leader role of an office type (org.leader_role). */
export const LEADER_ROLE: Record<OfficeType, Role> = {
	world_team: 'world_team_member',
	director: 'director',
	team_leader: 'team_leader'
};

/**
 * Roles to offer when inviting into an office: always Member; the office's
 * leader role only for a leader inviting below their own office (the backend
 * still decides: role_not_invitable / role_office_mismatch).
 */
export function inviteRoles(
	workspace: { role: Role; officeId: string | null },
	office: { officeId: string; type: OfficeType }
): Role[] {
	if (workspace.role === 'member' || office.officeId === workspace.officeId) return ['member'];
	return ['member', LEADER_ROLE[office.type]];
}

/** "Try again in 42 seconds" / "in 2 minutes" / "in 1 hour". */
export function retryAfterText(seconds: unknown): string {
	const s = Number(seconds);
	if (!Number.isFinite(s) || s <= 0) return 'Try again in a moment.';
	if (s < 60) {
		const n = Math.ceil(s);
		return `Try again in ${n} ${n === 1 ? 'second' : 'seconds'}.`;
	}
	if (s < 3600) {
		const n = Math.ceil(s / 60);
		return `Try again in ${n} ${n === 1 ? 'minute' : 'minutes'}.`;
	}
	const n = Math.ceil(s / 3600);
	return `Try again in ${n} ${n === 1 ? 'hour' : 'hours'}.`;
}

/**
 * Whether the same idempotency key must be reused on the next try: the
 * outcome is unknown (no envelope, or the app server could not reach the
 * backend). A definite refusal gets a new key (W-00).
 */
export const keepsKey = (failure: ApiFailure | undefined) =>
	!failure || failure._tag !== 'BackendError' || failure.code === 'internal_error';

export type CommandAction = 'resend' | 'revoke' | 'create';

export type Outcome =
	| { readonly kind: 'pin'; readonly text: string }
	| { readonly kind: 'locked' }
	| { readonly kind: 'message'; readonly text: string };

/** What to tell the leader when a command did not go through. */
export function describeFailure(action: CommandAction, failure: ApiFailure | undefined): Outcome {
	if (failure?._tag !== 'BackendError') {
		return { kind: 'message', text: 'We couldn’t confirm that. Try again.' };
	}
	const details = failure.details;
	switch (failure.code) {
		case 'step_up_required':
			return { kind: 'pin', text: 'Enter your PIN to confirm.' };
		case 'pin_incorrect': {
			const left = Number(details.attemptsRemaining);
			return {
				kind: 'pin',
				text: Number.isInteger(left)
					? `That PIN is incorrect. ${left} ${left === 1 ? 'try' : 'tries'} left.`
					: 'That PIN is incorrect.'
			};
		}
		case 'pin_locked':
			return { kind: 'locked' };
		case 'rate_limited':
			return {
				kind: 'message',
				text:
					action === 'resend'
						? `A link just went out. ${retryAfterText(details.retryAfterSeconds)}`
						: `You’ve sent a lot of invitations. ${retryAfterText(details.retryAfterSeconds)}`
			};
		case 'conflict':
			if (details.reason === 'reissue_limit') {
				return {
					kind: 'message',
					text: 'This invitation can’t be resent again. Revoke it and invite again.'
				};
			}
			if (details.reason === 'accepted') {
				return { kind: 'message', text: 'Already accepted. They’re a member now.' };
			}
			return { kind: 'message', text: 'This invitation is no longer pending.' };
		case 'invitation_exists':
			return { kind: 'message', text: 'There’s already a pending invitation for that email here.' };
		case 'membership_exists':
			return { kind: 'message', text: 'That person is already a member here.' };
		case 'self_target_forbidden':
			return { kind: 'message', text: 'You can’t invite yourself.' };
		case 'role_not_invitable':
		case 'role_office_mismatch':
			return { kind: 'message', text: 'You can’t invite that role into this office.' };
		case 'idempotency_conflict':
			return { kind: 'message', text: 'Something changed. Try again.' };
		case 'validation_error':
			if (details.field === 'reason') {
				return { kind: 'message', text: 'Give a reason (3–500 characters).' };
			}
			if (details.field === 'email') return { kind: 'message', text: 'Check the email address.' };
			return { kind: 'message', text: failure.message };
		case 'network_not_active':
			return { kind: 'message', text: 'Invitations are paused while the network isn’t active.' };
		default:
			return { kind: 'message', text: failure.message };
	}
}
