import { describe, expect, it } from 'vitest';
import type { Setup } from '#lib/contract/security.js';
import { nextStepFor, stepNumber, stepTotal } from './onboarding-steps.js';

const setup = (level: Setup['level'], next: Setup['next']): Setup => ({
	level,
	next,
	walletMembershipId: null
});

describe('wizard steps by role (Blueprint 22)', () => {
	it('numbers the light setup as two steps and the wallet setup as four', () => {
		expect(stepTotal('light')).toBe(2);
		expect(stepTotal('wallet')).toBe(4);
		expect([stepNumber('pin', 'light'), stepNumber('profile', 'light')]).toEqual([1, 2]);
		expect(
			(['pin', 'identity', 'details', 'profile', 'bank'] as const).map((s) =>
				stepNumber(s, 'wallet')
			)
		).toEqual([1, 2, 2, 3, 4]);
	});

	it('starts with the PIN', () => {
		expect(nextStepFor('pin_setup_required', setup('light', 'profile'), false)).toBe('pin');
		expect(nextStepFor('profile_required', setup('wallet', 'identity'), false)).toBe('pin');
	});

	it('follows the step the backend asks for', () => {
		expect(nextStepFor('profile_required', setup('light', 'profile'), true)).toBe('profile');
		expect(nextStepFor('profile_required', setup('wallet', 'identity'), true)).toBe('identity');
		expect(nextStepFor('profile_required', setup('wallet', 'bank'), true)).toBe('bank');
	});

	it('is done only when the gate is ready', () => {
		expect(nextStepFor('ready', setup('wallet', null), true)).toBeNull();
		expect(nextStepFor('ready', undefined, true)).toBeNull();
	});

	it('fails closed when the gate holds but no step came back', () => {
		expect(nextStepFor('profile_required', undefined, true)).toBe('profile');
		expect(nextStepFor('profile_required', setup('light', null), true)).toBe('profile');
	});
});
