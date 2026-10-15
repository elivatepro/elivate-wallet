import { describe, expect, it } from 'vitest';
import { BackendError, type ErrorCode } from '#lib/contract/errors.js';
import { normalizeTeamCode } from '#lib/contract/invitations.js';
import {
	daysValue,
	describeTeamLinkFailure,
	displayUrl,
	invitedLine,
	joinedLabel,
	stopsLabel,
	usesValue
} from './team-links';

const failure = (code: ErrorCode, details: Record<string, unknown> = {}) =>
	new BackendError({
		status: 400,
		code,
		message: 'Backend says no.',
		retryable: false,
		details,
		requestId: null
	});

describe('team link choices', () => {
	it('maps wheel values to what the backend accepts', () => {
		expect([daysValue('1'), daysValue('7'), daysValue('30'), daysValue('none')]).toEqual([
			1,
			7,
			30,
			null
		]);
		expect([usesValue('10'), usesValue('50'), usesValue('none')]).toEqual([10, 50, null]);
	});
});

describe('team link labels', () => {
	it('shows the link without its scheme', () => {
		expect(displayUrl('https://app.elivatewallet.com/j/7K3M9QP2AB')).toBe(
			'app.elivatewallet.com/j/7K3M9QP2AB'
		);
	});
	it('counts joins against the limit, or alone', () => {
		expect(joinedLabel({ uses: 12, maxUses: 50 })).toBe('12 of 50');
		expect(joinedLabel({ uses: 3, maxUses: null })).toBe('3');
	});
	it('says when it stops', () => {
		expect(stopsLabel(null)).toBe('No end');
		expect(stopsLabel('2026-10-22T10:00:00Z', 'Africa/Lagos')).toBe('22 Oct');
	});
	it('names the inviter when known', () => {
		expect(invitedLine({ invitedBy: 'Tolu Bakare', networkName: 'Unity Network' })).toBe(
			'Tolu Bakare invited you to Unity Network.'
		);
		expect(invitedLine({ invitedBy: null, networkName: 'Unity Network' })).toBe(
			'You’re invited to Unity Network.'
		);
	});
	it('reads codes case-insensitively', () => {
		expect(normalizeTeamCode('7k3m9qp2ab')).toBe('7K3M9QP2AB');
		expect(normalizeTeamCode('7K3M9QP2AU')).toBeNull();
	});
});

describe('describeTeamLinkFailure', () => {
	it('asks for the PIN', () => {
		expect(describeTeamLinkFailure('create', failure('step_up_required'))).toEqual({
			kind: 'pin',
			text: 'Enter your PIN to create the link.'
		});
		expect(
			describeTeamLinkFailure('turn-off', failure('pin_incorrect', { attemptsRemaining: 1 }))
		).toEqual({
			kind: 'pin',
			text: 'That PIN is incorrect. 1 try left.'
		});
	});
	it('locks on a locked PIN and explains refusals', () => {
		expect(describeTeamLinkFailure('create', failure('pin_locked'))).toEqual({ kind: 'locked' });
		expect(describeTeamLinkFailure('create', failure('authorization_denied')).kind).toBe('message');
		expect(describeTeamLinkFailure('create', undefined)).toEqual({
			kind: 'message',
			text: 'We couldn’t confirm that. Try again.'
		});
	});
});
