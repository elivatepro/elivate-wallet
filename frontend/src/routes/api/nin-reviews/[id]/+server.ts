// Decide one NIN review: reason + PIN (step-up), never one's own (backend).
import { Effect, Schema } from 'effect';
import { ReviewDecisionCommand } from '#lib/contract/app.js';
import { UUID_PATTERN } from '#lib/contract/common.js';
import { BackendError } from '#lib/contract/errors.js';
import { IdentityApi } from '#lib/server/apis-identity.js';
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

export const POST: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	if (!workspaceEchoMatches(event)) return respondError(workspaceChanged());
	const membershipId = readWorkspace(event.cookies)!;
	const reviewId = event.params.id;
	if (!UUID_PATTERN.test(reviewId)) return respondError(invalid('reviewId'));
	let body: ReviewDecisionCommand;
	try {
		body = Schema.decodeUnknownSync(ReviewDecisionCommand)(await event.request.json());
	} catch {
		return respondError(invalid('body'));
	}
	const { pin, ...input } = body;
	return respond(
		await runApi(
			event,
			session,
			withPin(
				pin,
				Effect.gen(function* () {
					return yield* (yield* IdentityApi).decide(membershipId, reviewId, input);
				})
			)
		)
	);
};
