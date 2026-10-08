// Unknown-outcome lookup (F-03, Blueprint 08 B4.1): what happened to the
// signed-in person's own attempt, by its idempotency key. Account-level (no
// workspace needed); the key is non-secret and never logged.
import { Effect } from 'effect';
import { IDEMPOTENCY_KEY_PATTERN } from '#lib/contract/common.js';
import { LedgerApi } from '#lib/server/apis-ledger.js';
import { invalidRequest, respond, respondError, unauthenticated } from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import type { RequestHandler } from './$types';

const COMMAND_PATTERN = /^[a-z][a-z_]{0,59}$/;

export const GET: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	const params = event.url.searchParams;
	for (const name of params.keys()) {
		if (name !== 'key' && name !== 'command') return respondError(invalidRequest(name));
	}
	const key = params.get('key') ?? '';
	const command = params.get('command');
	if (!IDEMPOTENCY_KEY_PATTERN.test(key)) return respondError(invalidRequest('key'));
	if (command !== null && !COMMAND_PATTERN.test(command)) {
		return respondError(invalidRequest('command'));
	}
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* LedgerApi).commandOutcome(key, command);
		})
	);
	return respond(exit);
};
