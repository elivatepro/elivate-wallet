// The Paystack bank list for the add-account flow (W-17).
import { Effect } from 'effect';
import type { BanksView } from '#lib/contract/app.js';
import { PayoutApi } from '#lib/server/apis-identity.js';
import { respond, respondError, unauthenticated } from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			const banks = yield* (yield* PayoutApi).banks;
			return { banks } satisfies BanksView;
		})
	);
	return respond(exit);
};
