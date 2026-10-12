import { describe, expect, it } from 'vitest';
import type { Setup } from '#lib/contract/security.js';
import { nextStepFor, stepNumber, stepTotal } from './onboarding-steps.js';

const setup = (level: Setup['level'], next: Setup['next']): Setup => ({
	level,
	next,
	walletMembershipId: null
});

describe('wizard steps by role (Blueprint 22)', () => {
	it('numbers the light setup as three steps and the wallet setup as five', () => {
		expect(stepTotal('light')).toBe(3);
		expect(stepTotal('wallet')).toBe(5);
		expect(
			(['pin', 'profile', 'install', 'done'] as const).map((s) => stepNumber(s, 'light'))
		).toEqual([1, 2, 3, 3]);
		expect(
			(['pin', 'identity', 'details', 'profile', 'bank', 'install', 'done'] as const).map((s) =>
				stepNumber(s, 'wallet')
			)
		).toEqual([1, 2, 2, 3, 4, 5, 5]);
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

	it('asks to install the app once the gate is ready (Blueprint 35)', () => {
		expect(nextStepFor('ready', setup('wallet', null), true)).toBe('install');
		expect(nextStepFor('ready', setup('light', null), true)).toBe('install');
		expect(nextStepFor('profile_required', setup('wallet', 'bank'), true, true)).toBe('bank');
	});

	it('is done only when the gate is ready and the install step was handled', () => {
		expect(nextStepFor('ready', setup('wallet', null), true, true)).toBeNull();
		expect(nextStepFor('ready', undefined, true, true)).toBeNull();
	});

	it('fails closed when the gate holds but no step came back', () => {
		expect(nextStepFor('profile_required', undefined, true)).toBe('profile');
		expect(nextStepFor('profile_required', setup('light', null), true)).toBe('profile');
	});
});
