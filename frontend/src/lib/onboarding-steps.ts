// First-use wizard steps (W-02; Blueprint 22). Pure, so the step logic is
// unit-tested apart from the server module that loads the wizard.

import type { Gate, Setup, SetupLevel } from '#lib/contract/security.js';

export type Step = 'pin' | 'identity' | 'details' | 'profile' | 'bank' | 'done';

/** "Step n / 4" (wallet: PIN 1, identity 2, profile 3, bank 4) or "n / 2" (light: PIN 1, profile 2). */
export function stepNumber(step: Step, level: SetupLevel): number {
	if (level !== 'wallet') return step === 'pin' ? 1 : 2;
	return { pin: 1, identity: 2, details: 2, profile: 3, bank: 4, done: 4 }[step];
}

export const stepTotal = (level: SetupLevel): number => (level === 'wallet' ? 4 : 2);

/**
 * Where the person is; `null` once everything is done. The backend's setup
 * state decides (it also refuses every other call until then), so a missing
 * answer never counts as "done": at `profile_required` without a step the
 * profile step is asked for.
 */
export function nextStepFor(
	gate: Gate,
	setup: Setup | undefined,
	hasProfile: boolean
): Step | null {
	if (gate === 'pin_setup_required' || !hasProfile) return 'pin';
	if (gate === 'ready') return null;
	return setup?.next ?? 'profile';
}
