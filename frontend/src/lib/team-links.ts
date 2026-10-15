// Team links (Blueprint 38; Paper "Team links v11" TL01–TL06): the panel's
// choices and labels, and what to say when a command does not go through.

import type { ApiFailure } from '#lib/contract/errors.js';
import type { TeamLink, TeamLinkState } from '#lib/contract/invitations.js';
import { retryAfterText, shortDate, type Outcome } from '#lib/invitations.js';

/** Wheel values are strings; "none" is no end / no limit. */
export const DAYS_OPTIONS = [
	{ value: '1', label: '1 day' },
	{ value: '7', label: '7 days' },
	{ value: '30', label: '30 days' },
	{ value: 'none', label: 'No end' }
] as const;

export const USES_OPTIONS = [
	{ value: '10', label: '10 people' },
	{ value: '50', label: '50 people' },
	{ value: 'none', label: 'No limit' }
] as const;

/** Owner decision 3: 7 days and no limit unless the leader picks otherwise. */
export const DEFAULT_DAYS = '7';
export const DEFAULT_USES = 'none';

export const daysValue = (choice: string): 1 | 7 | 30 | null =>
	choice === '1' ? 1 : choice === '30' ? 30 : choice === 'none' ? null : 7;

export const usesValue = (choice: string): 10 | 50 | null =>
	choice === '10' ? 10 : choice === '50' ? 50 : null;

/** The link as shown, without the scheme ("app.elivatewallet.com/j/7K3M9QP2AB"). */
export const displayUrl = (url: string) => url.replace(/^https?:\/\//, '');

/** "12 of 50", or "12" with no limit. */
export const joinedLabel = (link: Pick<TeamLink, 'uses' | 'maxUses'>) =>
	link.maxUses === null ? String(link.uses) : `${link.uses} of ${link.maxUses}`;

/** "22 Oct", or "No end". */
export const stopsLabel = (expiresAt: string | null, timeZone?: string) =>
	expiresAt === null ? 'No end' : shortDate(expiresAt, timeZone);

/** Why the office's link stopped, shown above a fresh form. */
export const STOPPED_TEXT: Record<Exclude<TeamLinkState, 'live'>, string> = {
	expired: 'Your last link expired. Make a new one to keep inviting.',
	full: 'Your last link is full. Make a new one to keep inviting.',
	creator_left:
		'Your last link stopped because the person who made it can no longer invite here. Make a new one.',
	office_closed: 'This office is closed, so its link no longer works.',
	network_inactive: 'Links are paused while the network isn’t active.'
};

/** Join page heading line (TL03): "Tolu Bakare invited you to Unity Network." */
export const invitedLine = (preview: { invitedBy: string | null; networkName: string }) =>
	preview.invitedBy
		? `${preview.invitedBy} invited you to ${preview.networkName}.`
		: `You’re invited to ${preview.networkName}.`;

export type TeamLinkAction = 'create' | 'turn-off';

/** What to tell the leader when a team link command did not go through. */
export function describeTeamLinkFailure(
	action: TeamLinkAction,
	failure: ApiFailure | undefined
): Outcome {
	if (failure?._tag !== 'BackendError') {
		return { kind: 'message', text: 'We couldn’t confirm that. Try again.' };
	}
	const details = failure.details;
	switch (failure.code) {
		case 'step_up_required':
			return {
				kind: 'pin',
				text:
					action === 'create'
						? 'Enter your PIN to create the link.'
						: 'Enter your PIN to turn off the link.'
			};
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
			return { kind: 'message', text: retryAfterText(details.retryAfterSeconds) };
		case 'conflict':
			if (details.reason === 'office_closed') {
				return { kind: 'message', text: 'This office is closed, so it can’t have a link.' };
			}
			return { kind: 'message', text: failure.message };
		case 'authorization_denied':
			return { kind: 'message', text: 'You can’t make links for this office.' };
		case 'idempotency_conflict':
			return { kind: 'message', text: 'Something changed. Try again.' };
		case 'network_not_active':
			return { kind: 'message', text: 'Links are paused while the network isn’t active.' };
		default:
			return { kind: 'message', text: failure.message };
	}
}
