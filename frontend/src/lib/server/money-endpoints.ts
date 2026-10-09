// Shared recipe for the Blueprint 11/12 read endpoints: signed in, a workspace
// cookie, only the listed query keys (each matching its pattern), then one
// backend read relayed as-is.

import type { RequestEvent } from '@sveltejs/kit';
import { Cause, Effect, Exit, Option, type Schema } from 'effect';
import { UUID_PATTERN } from '#lib/contract/common.js';
import { TransportError } from '#lib/contract/errors.js';
import { RECEIPT_MIME_TYPES } from '#lib/contract/income.js';
import { ReceiptLink } from '#lib/contract/withdrawals.js';
import { readWorkspace } from './cookies';
import type { EdgeFailure, EdgeRoute } from './edge';
import {
	invalidRequest,
	respond,
	respondError,
	toBackendError,
	unauthenticated,
	workspaceChanged
} from './relay';
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

/**
 * Streams one evidence file: the backend checks who may see it and signs a
 * 60-second link; this server follows it, so the browser never sees a storage
 * URL or token.
 */
export async function streamEvidence(
	event: RequestEvent,
	route: EdgeRoute,
	query: Readonly<Record<string, string>>
): Promise<Response> {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	const membershipId = readWorkspace(event.cookies);
	if (!membershipId) return respondError(workspaceChanged());
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			const api = yield* MoneyMovesApi;
			const link = yield* api.read(membershipId, route, query, ReceiptLink);
			const file = yield* api.fetchReceipt(link.url);
			return { link, file };
		})
	);
	if (Exit.isFailure(exit)) {
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		return respondError(
			toBackendError(failure ?? new TransportError({ reason: 'network', status: null }))
		);
	}
	const { link, file } = exit.value;
	const mime = (RECEIPT_MIME_TYPES as readonly string[]).includes(link.mimeType ?? '')
		? (link.mimeType as string)
		: 'application/octet-stream';
	const safeName = link.name.replace(/[^A-Za-z0-9._ -]/g, '_').slice(0, 120) || 'receipt';
	return new Response(file.bytes, {
		headers: {
			'content-type': mime,
			'content-disposition': `inline; filename="${safeName}"`,
			'cache-control': 'no-store',
			'x-content-type-options': 'nosniff',
			'content-security-policy':
				"default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; sandbox"
		}
	});
}
