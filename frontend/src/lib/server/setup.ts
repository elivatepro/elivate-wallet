// Founder setup helpers (Blueprint 16): the messages a founder sees when the
// backend refuses a start or a checkout. Unknown failures return null so the
// caller can redirect (gates, sign-in) as usual.

import type { EdgeFailure } from './edge';

const REASONS: Record<string, string> = {
	trial_used: 'You’ve already used your free trial. Pay yearly to open this network.',
	trial_plan: 'The free trial is on the smallest plan only.',
	pending_network_exists: 'Finish paying for your other new network first.',
	seats_exceed_plan: 'Your network has more people than that plan covers.'
};

export function describeFailure(failure: EdgeFailure): string | null {
	if (failure._tag === 'TransportError' && failure.status !== 401) {
		return 'We couldn’t confirm that. Try again.';
	}
	if (failure._tag !== 'BackendError') return null;
	if (failure.code === 'conflict') {
		return REASONS[String(failure.details.reason)] ?? 'That changed in the meantime. Try again.';
	}
	if (failure.code === 'validation_error') return 'Check the network name and try again.';
	if (failure.code === 'provider_unavailable') {
		return 'Paystack isn’t available right now. Try again in a moment.';
	}
	return null;
}
