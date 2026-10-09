// Sign-in history (Blueprint 14). Right after Auth creates a session, the app
// server records the IP Cloudflare saw (CF-Connecting-IP), the approximate
// city and country from the Worker request's `cf` object and the device label.
// Best effort: a failure here never blocks signing in. The IP is sent to the
// backend only; it is never logged, shown or emailed. The security function
// accepts these records only with APP_SERVER_SECRET, which only this server
// holds, so a user token alone cannot write (or dodge) its own history.

import type { RequestEvent } from '@sveltejs/kit';
import { Effect } from 'effect';
import type { SignInMethod } from '#lib/contract/security.js';
import { describeDevice } from '#lib/devices.js';
import { SecurityApi } from './apis';
import { clientContext, type CfLocation } from './client-context';
import { appServerSecret, geoTestHeaders } from './config';
import { runApi } from './request';

/** Records the session just created for this request. Never throws. */
export async function recordSignIn(event: RequestEvent, method: SignInMethod): Promise<void> {
	try {
		const secret = appServerSecret();
		const session = await event.locals.session();
		if (!session || !secret) return;
		const userAgent = event.request.headers.get('user-agent');
		const cf = (event.request as Request & { readonly cf?: CfLocation }).cf;
		const where = clientContext(event.request.headers, cf, geoTestHeaders());
		await runApi(
			event,
			session,
			Effect.gen(function* () {
				return yield* (yield* SecurityApi).recordSignIn(
					{
						method,
						...where,
						device: describeDevice(userAgent).label,
						userAgent: userAgent ? userAgent.slice(0, 300) : null
					},
					secret
				);
			})
		);
	} catch {
		// Sign-in continues; the history simply has no row for this session.
	}
}
