import type { EdgeFailure } from '#lib/server/edge.js';

export type PinErrors = Partial<Record<'pin' | 'pinConfirm', string>>;

/** Field errors for `validation_error` on pin/pinConfirm; null for anything else. */
export function pinFieldErrors(failure: EdgeFailure): PinErrors | null {
	if (failure._tag !== 'BackendError' || failure.code !== 'validation_error') return null;
	const field = failure.details.field;
	if (field === 'pinConfirm') {
		return {
			pinConfirm:
				failure.details.reason === 'mismatch' ? 'The PINs don’t match.' : 'Enter the same 4 digits.'
		};
	}
	return { pin: 'Enter 4 digits.' };
}
