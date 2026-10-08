// Profile & security pages (Blueprint 10): load the account view and route
// gate failures (signed out, PIN owed, locked, blocked) to their pages.

import { Cause, Effect, Exit, Option } from 'effect';
import { AccountRoutes, AccountView } from '#lib/contract/account.js';
import type { ApiFailure } from '#lib/contract/errors.js';
import { pathForGateCode } from '#lib/gate.js';
import { getJson } from './api';

export const failureOf = <A>(exit: Exit.Exit<A, ApiFailure>): ApiFailure | undefined =>
	Exit.isFailure(exit) ? Option.getOrUndefined(Cause.findErrorOption(exit.cause)) : undefined;

/** Leaves the page for a gate failure; true when it did. */
export function followGate(failure: ApiFailure | undefined, next: string): boolean {
	if (failure?._tag === 'TransportError' && failure.status === 401) {
		window.location.assign('/sign-in');
		return true;
	}
	if (failure?._tag !== 'BackendError') return false;
	const path = pathForGateCode(failure.code);
	if (!path) return false;
	window.location.assign(path === '/pin' ? `/pin?next=${encodeURIComponent(next)}` : path);
	return true;
}

export async function loadAccount(): Promise<Exit.Exit<AccountView, ApiFailure>> {
	return Effect.runPromiseExit(getJson(AccountRoutes.view.path, AccountView));
}
