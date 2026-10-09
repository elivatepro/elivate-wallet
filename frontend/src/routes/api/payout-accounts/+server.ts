// Payout accounts (W-17; Paper "App — Screens v3" Y02). GET: the person's own
// accounts in this workspace (masked; never cached on device, decision 36a).
// POST: explicit save of a resolved lookup (step-up). Confirmation is not
// primary selection; the backend sets the 24 h cooling-off (usableFrom).
import { Effect } from 'effect';
import { PayoutConfirmCommand, type PayoutAccountsView } from '#lib/contract/app.js';
import { PayoutApi } from '#lib/server/apis-identity.js';
import { relayCommand } from '#lib/server/command.js';
import { readWorkspace } from '#lib/server/cookies.js';
import { respond, respondError, unauthenticated, workspaceChanged } from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	const membershipId = readWorkspace(event.cookies);
	if (!membershipId) return respondError(workspaceChanged());
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			const items = yield* (yield* PayoutApi).accounts(membershipId);
			return { items } satisfies PayoutAccountsView;
		})
	);
	return respond(exit);
};

export const POST: RequestHandler = (event) =>
	relayCommand(event, PayoutConfirmCommand, (membershipId, { lookupId, reason, idempotencyKey }) =>
		Effect.gen(function* () {
			return yield* (yield* PayoutApi).confirm(membershipId, {
				lookupId,
				...(reason === undefined ? {} : { reason }),
				idempotencyKey
			});
		})
	);
