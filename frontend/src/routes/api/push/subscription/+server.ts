// This device's push switch (Blueprint 42): personal, bound to the signed-in
// session, so no workspace echo. GET reads it (and hands out the VAPID public
// key to subscribe with), PUT turns it on or updates Hide amounts, DELETE
// turns it off. The backend accepts only the browsers' push services.
import { Effect, Schema } from 'effect';
import { PushEndpoint, PushSubscribeCommand, PushUnsubscribeCommand } from '#lib/contract/push.js';
import { IdentityApi } from '#lib/server/apis-identity.js';
import { pushPublicKey } from '#lib/server/config.js';
import { invalidRequest, respond, respondError, unauthenticated } from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import type { RequestEvent, RequestHandler } from './$types';

async function body<S extends Schema.ConstraintDecoder<unknown>>(
	event: RequestEvent,
	schema: S
): Promise<S['Type'] | null> {
	if (!event.request.headers.get('content-type')?.startsWith('application/json')) return null;
	try {
		return Schema.decodeUnknownSync(schema, { onExcessProperty: 'error' })(
			await event.request.json()
		);
	} catch {
		return null;
	}
}

export const GET: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	const publicKey = pushPublicKey();
	const endpoint = event.url.searchParams.get('endpoint');
	if (endpoint === null) {
		return respond(
			await runApi(event, session, Effect.succeed({ on: false, hideAmounts: false, publicKey }))
		);
	}
	if (!Schema.is(PushEndpoint)(endpoint)) return respondError(invalidRequest('endpoint'));
	return respond(
		await runApi(
			event,
			session,
			Effect.gen(function* () {
				const state = yield* (yield* IdentityApi).pushState(endpoint);
				return { ...state, publicKey };
			})
		)
	);
};

export const PUT: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	const command = await body(event, PushSubscribeCommand);
	if (!command) return respondError(invalidRequest('body'));
	return respond(
		await runApi(
			event,
			session,
			Effect.gen(function* () {
				const state = yield* (yield* IdentityApi).pushSubscribe(command);
				return { ...state, publicKey: pushPublicKey() };
			})
		)
	);
};

export const DELETE: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	const command = await body(event, PushUnsubscribeCommand);
	if (!command) return respondError(invalidRequest('body'));
	return respond(
		await runApi(
			event,
			session,
			Effect.gen(function* () {
				const state = yield* (yield* IdentityApi).pushUnsubscribe(command.endpoint);
				return { ...state, publicKey: pushPublicKey() };
			})
		)
	);
};
