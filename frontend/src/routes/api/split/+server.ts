// Pockets & split for the selected network (W-07/U-01; Paper L01/L02).
// GET: live split + history; PUT: President's change with reason + PIN.
import { Effect, Schema } from 'effect';
import { SplitCommand, type SplitView } from '#lib/contract/app.js';
import { BackendError } from '#lib/contract/errors.js';
import { LedgerApi } from '#lib/server/apis-ledger.js';
import { OrgApi } from '#lib/server/apis.js';
import { readWorkspace } from '#lib/server/cookies.js';
import {
	respond,
	respondError,
	unauthenticated,
	workspaceChanged,
	workspaceEchoMatches
} from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import { withPin } from '#lib/server/step-up.js';
import type { RequestHandler } from './$types';

const invalid = (field: string) =>
	new BackendError({
		status: 400,
		code: 'validation_error',
		message: 'The request is invalid.',
		retryable: false,
		details: { field },
		requestId: null
	});

export const GET: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	const membershipId = readWorkspace(event.cookies);
	if (!membershipId) return respondError(workspaceChanged());
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			const ledger = yield* LedgerApi;
			const [allocation, versions, capabilities] = yield* Effect.all(
				[
					ledger.allocation(membershipId),
					ledger.versions(membershipId),
					(yield* OrgApi).capabilities(membershipId)
				],
				{ concurrency: 3 }
			);
			return {
				allocation,
				versions: versions.items,
				canEdit: capabilities.permissions.includes('manage_allocation')
			} satisfies SplitView;
		})
	);
	return respond(exit);
};

export const PUT: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	if (!workspaceEchoMatches(event)) return respondError(workspaceChanged());
	const membershipId = readWorkspace(event.cookies)!;
	let body: SplitCommand;
	try {
		body = Schema.decodeUnknownSync(SplitCommand)(await event.request.json());
	} catch {
		return respondError(invalid('body'));
	}
	const { pin, ...input } = body;
	const exit = await runApi(
		event,
		session,
		withPin(
			pin,
			Effect.gen(function* () {
				return yield* (yield* LedgerApi).setAllocation(membershipId, input);
			})
		)
	);
	return respond(exit);
};
