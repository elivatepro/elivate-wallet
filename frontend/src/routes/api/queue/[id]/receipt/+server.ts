// Upload the payout transfer receipt (W-10 step 3, Paper v1 T03 "Upload the
// transfer receipt"; exactly one per payout record). Multipart from the
// browser with the attempt's idempotency key; this server takes the MIME type
// from the bytes, computes the SHA-256, then: step-up (optional PIN) → upload
// intent → bytes to the signed upload URL → finalize (the Edge Function
// re-reads and verifies the stored bytes). `[id]` is the withdrawal.
import { Effect } from 'effect';
import { MoneyMovesApi } from '#lib/server/apis-withdrawals.js';
import { EvidenceFields, readEvidenceForm } from '#lib/server/evidence-form.js';
import { validId } from '#lib/server/money-endpoints.js';
import { invalidRequest, respond, respondError } from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import { withPin } from '#lib/server/step-up.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = async (event) => {
	const withdrawalId = event.params.id;
	if (!validId(withdrawalId)) return respondError(invalidRequest('id'));
	const form = await readEvidenceForm(event, EvidenceFields, ['idempotencyKey', 'pin']);
	if (form instanceof Response) return form;
	return respond(
		await runApi(
			event,
			form.session,
			withPin(
				form.fields.pin,
				Effect.gen(function* () {
					return yield* (yield* MoneyMovesApi).uploadPayoutReceipt(form.membershipId, {
						withdrawalId,
						idempotencyKey: form.fields.idempotencyKey,
						fileName: form.fileName,
						mimeType: form.mimeType,
						bytes: form.bytes,
						sha256: form.sha256
					});
				})
			)
		)
	);
};
