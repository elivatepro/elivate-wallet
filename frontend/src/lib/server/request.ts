// Per-request composition (plan §5.1 runtime.ts): builds the Effect layers for
// one signed-in request and runs an API program, returning an Exit so callers
// can branch on typed failures without try/catch.

import type { RequestEvent } from '@sveltejs/kit';
import { Effect, Exit, Layer } from 'effect';
import {
	InvitationsApi,
	InvitationsApiLive,
	OrgApi,
	OrgApiLive,
	SecurityApi,
	SecurityApiLive
} from './apis';
import { IdentityApi, IdentityApiLive, PayoutApi, PayoutApiLive } from './apis-identity';
import type { VerifiedSession } from './auth';
import { EdgeTransportLive, type EdgeFailure } from './edge';
import { requireConfig } from './config';

export type ApiServices = SecurityApi | OrgApi | InvitationsApi | IdentityApi | PayoutApi;

/**
 * `session` null runs without a bearer token: only the public invitation
 * routes (preview, verify-email) accept that; everything else answers
 * `authentication_required`.
 */
export function runApi<A>(
	event: RequestEvent,
	session: VerifiedSession | null,
	program: Effect.Effect<A, EdgeFailure, ApiServices>
): Promise<Exit.Exit<A, EdgeFailure>> {
	const config = requireConfig();
	const edge = EdgeTransportLive({
		supabaseUrl: config.supabaseUrl,
		publishableKey: config.publishableKey,
		accessToken: session?.accessToken ?? null,
		fetch: event.fetch,
		signal: event.request.signal
	});
	const layer = Layer.mergeAll(
		SecurityApiLive,
		OrgApiLive,
		InvitationsApiLive,
		IdentityApiLive,
		PayoutApiLive
	).pipe(Layer.provide(edge));
	return Effect.runPromiseExit(program.pipe(Effect.provide(layer)));
}

export { Exit };
