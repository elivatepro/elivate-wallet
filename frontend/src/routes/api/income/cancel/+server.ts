// Cancel an income attempt whose outcome is unknown (W-08 recovery, F-03). The
// backend serializes it against posting: the answer is the posted income if
// it went through, otherwise the cancelled attempt. Reason required; no PIN.
import { Effect, Schema } from 'effect';
import { CancelIncomeCommand } from '#lib/contract/income.js';
import { IncomeApi } from '#lib/server/apis-income.js';
import { invalidRequest } from '#lib/server/command.js';
import { readWorkspace } from '#lib/server/cookies.js';
import {
	respond,
	respondError,
	unauthenticated,
	workspaceChanged,
	workspaceEchoMatches
} from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	if (!workspaceEchoMatches(event)) return respondError(workspaceChanged());
	const membershipId = readWorkspace(event.cookies)!;
	let body: CancelIncomeCommand;
	try {
		body = Schema.decodeUnknownSync(CancelIncomeCommand)(await event.request.json());
	} catch {
		return respondError(invalidRequest('body'));
	}
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* IncomeApi).cancel(membershipId, body);
		})
	);
	return respond(exit);
};
