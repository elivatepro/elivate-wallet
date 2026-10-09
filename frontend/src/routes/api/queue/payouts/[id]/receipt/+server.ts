// View a payout receipt (approver, reviewer): the backend checks who may see
// it and signs a 60-second link; this server follows it and streams the
// bytes, so the browser never sees a storage URL or token.
import { Cause, Effect, Exit, Option } from 'effect';
import { TransportError } from '#lib/contract/errors.js';
import { RECEIPT_MIME_TYPES } from '#lib/contract/income.js';
import { ReceiptLink, WithdrawalRoutes } from '#lib/contract/withdrawals.js';
import { MoneyMovesApi } from '#lib/server/apis-withdrawals.js';
import { readWorkspace } from '#lib/server/cookies.js';
import { validId } from '#lib/server/money-endpoints.js';
import {
	invalidRequest,
	respondError,
	toBackendError,
	unauthenticated,
	workspaceChanged
} from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	const membershipId = readWorkspace(event.cookies);
	if (!membershipId) return respondError(workspaceChanged());
	const payoutId = event.params.id;
	if (!validId(payoutId)) return respondError(invalidRequest('id'));
	const params = [...event.url.searchParams.keys()];
	const revision = event.url.searchParams.get('revision');
	if (params.some((k) => k !== 'revision') || (revision !== '1' && revision !== '2')) {
		return respondError(invalidRequest('revision'));
	}
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			const api = yield* MoneyMovesApi;
			const link = yield* api.read(
				membershipId,
				WithdrawalRoutes.receipt(payoutId),
				{ revision },
				ReceiptLink
			);
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
};
