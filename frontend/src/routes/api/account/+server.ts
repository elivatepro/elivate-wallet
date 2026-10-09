// Profile & security read (Blueprint 10; Paper B09/B10, S03/S04): own profile
// (the photo key never leaves the server), the sign-in email from the verified
// session, and the signed-in devices. Read live; never cached on device.
import { Effect } from 'effect';
import type { AccountView } from '#lib/contract/account.js';
import { IdentityApi } from '#lib/server/apis-identity.js';
import { SecurityApi } from '#lib/server/apis.js';
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
			const [profile, sessions] = yield* Effect.all(
				[(yield* IdentityApi).profile, (yield* SecurityApi).sessions],
				{ concurrency: 2 }
			);
			return { profile, email: session.email, sessions } satisfies AccountView;
		})
	);
	return respond(exit);
};
