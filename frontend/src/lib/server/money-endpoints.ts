// Shared recipe for the Blueprint 11 read endpoints: signed in, a workspace
// cookie, only the listed query keys (each matching its pattern), then one
// backend read relayed as-is.

import type { RequestEvent } from '@sveltejs/kit';
import { Effect, type Schema } from 'effect';
import { UUID_PATTERN } from '#lib/contract/common.js';
import { readWorkspace } from './cookies';
import type { EdgeFailure, EdgeRoute } from './edge';
import { invalidRequest, respond, respondError, unauthenticated, workspaceChanged } from './relay';
import { runApi, type ApiServices } from './request';
import { MoneyMovesApi } from './apis-withdrawals';

export const CURSOR = /^.{1,500}$/s;

export async function relayRead<A>(
	event: RequestEvent,
	allowed: Readonly<Record<string, RegExp>>,
	program: (
		membershipId: string,
		query: Record<string, string>
	) => Effect.Effect<A, EdgeFailure, ApiServices>
): Promise<Response> {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	const membershipId = readWorkspace(event.cookies);
	if (!membershipId) return respondError(workspaceChanged());
	const query: Record<string, string> = {};
	for (const [key, value] of event.url.searchParams) {
		const pattern = allowed[key];
		if (!pattern || !pattern.test(value)) return respondError(invalidRequest(key));
		query[key] = value;
	}
	return respond(await runApi(event, session, program(membershipId, query)));
}

/** One ledger read through MoneyMovesApi. */
export const ledgerRead =
	<S extends Schema.ConstraintDecoder<unknown>>(route: EdgeRoute, schema: S) =>
	(membershipId: string, query: Record<string, string>) =>
		Effect.gen(function* () {
			return yield* (yield* MoneyMovesApi).read(membershipId, route, query, schema);
		});

/** Path ids must be lower-case UUIDs before they reach a backend path. */
export const validId = (id: string | undefined): id is string => !!id && UUID_PATTERN.test(id);
