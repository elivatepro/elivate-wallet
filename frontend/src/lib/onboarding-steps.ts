// First-use wizard steps (W-02; Blueprint 22). Pure, so the step logic is
// unit-tested apart from the server module that loads the wizard.

import type { Gate, Setup, SetupLevel } from '#lib/contract/security.js';

export type Step =
	'pin' | 'identity' | 'details' | 'profile' | 'bank' | 'install' | 'notifications' | 'done';

/**
 * "Step n / 5" (wallet: PIN 1, identity 2, profile 3, bank 4, install 5) or
 * "n / 3" (light: PIN 1, profile 2, install 3). Blueprint 35: installing the
 * app is the last step for everyone; Blueprint 42's notifications screen is
 * part of it ("One last thing", same number).
 */
export function stepNumber(step: Step, level: SetupLevel): number {
	const last = step === 'install' || step === 'notifications' || step === 'done';
	if (level !== 'wallet') return step === 'pin' ? 1 : last ? 3 : 2;
	if (last) return 5;
	return { pin: 1, identity: 2, details: 2, profile: 3, bank: 4 }[step];
}

export const stepTotal = (level: SetupLevel): number => (level === 'wallet' ? 5 : 3);

/**
 * Where the person is; `null` once everything is done. The backend's setup
 * state decides (it also refuses every other call until then), so a missing
 * answer never counts as "done": at `profile_required` without a step the
 * profile step is asked for. Once the backend is satisfied, the install step
 * (Blueprint 35, browser only) comes next until it is installed or put off,
 * then the notifications offer (Blueprint 42, browser only; the page moves on
 * by itself where push can't work or was already answered).
 */
export function nextStepFor(
	gate: Gate,
	setup: Setup | undefined,
	hasProfile: boolean,
	installHandled = false,
	pushHandled = false
): Step | null {
	if (gate === 'pin_setup_required' || !hasProfile) return 'pin';
	if (gate === 'ready') {
		if (!installHandled) return 'install';
		return pushHandled ? null : 'notifications';
	}
	return setup?.next ?? 'profile';
}
