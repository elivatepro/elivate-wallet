// Upload the payout transfer receipt (W-10 step 3, Paper v1 T03 "Upload the
// transfer receipt"; exactly one per payout record). Multipart from the
// browser with the attempt's idempotency key; this server takes the MIME type
// from the bytes, computes the SHA-256, then: step-up (optional PIN) → upload
// intent → bytes to the signed upload URL → finalize (the Edge Function
// re-reads and verifies the stored bytes). `[id]` is the withdrawal.
import { Effect, Schema } from 'effect';
import { PIN_PATTERN } from '#lib/contract/common.js';
import { RECEIPT_MAX_BYTES } from '#lib/contract/income.js';
import { IdempotencyKey } from '#lib/contract/invitations.js';
import { sniffReceipt } from '#lib/income.js';
import { MoneyMovesApi } from '#lib/server/apis-withdrawals.js';
import { readWorkspace } from '#lib/server/cookies.js';
import { validId } from '#lib/server/money-endpoints.js';
import {
	invalidRequest,
	respond,
	respondError,
	unauthenticated,
	workspaceChanged,
	workspaceEchoMatches
} from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import { withPin } from '#lib/server/step-up.js';
import type { RequestHandler } from './$types';

const Fields = Schema.Struct({
	idempotencyKey: IdempotencyKey,
	pin: Schema.optionalKey(Schema.String.check(Schema.isPattern(PIN_PATTERN)))
});

function cleanName(name: string): string {
	// eslint-disable-next-line no-control-regex
	const base = name.replace(/[\u0000-\u001f\u007f]/g, '').trim();
	return (base || 'receipt').slice(0, 200);
}

async function sha256Hex(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
	const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
	return Array.from(digest, (b) => b.toString(16).padStart(2, '0')).join('');
}

export const POST: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	if (!workspaceEchoMatches(event)) return respondError(workspaceChanged());
	const membershipId = readWorkspace(event.cookies)!;
	const withdrawalId = event.params.id;
	if (!validId(withdrawalId)) return respondError(invalidRequest('id'));

	const declared = Number(event.request.headers.get('content-length') ?? '0');
	if (declared > RECEIPT_MAX_BYTES + 64 * 1024) return respondError(invalidRequest('size'));
	let form: FormData;
	try {
		form = await event.request.formData();
	} catch {
		return respondError(invalidRequest('body'));
	}
	const file = form.get('file');
	let fields: typeof Fields.Type;
	try {
		const pin = form.get('pin');
		fields = Schema.decodeUnknownSync(Fields)({
			idempotencyKey: form.get('idempotencyKey'),
			...(typeof pin === 'string' && pin !== '' ? { pin } : {})
		});
	} catch {
		return respondError(invalidRequest('body'));
	}
	if (!(file instanceof File)) return respondError(invalidRequest('file'));
	if (file.size < 1 || file.size > RECEIPT_MAX_BYTES) return respondError(invalidRequest('size'));
	const bytes = new Uint8Array(await file.arrayBuffer());
	const mimeType = sniffReceipt(bytes);
	if (!mimeType) return respondError(invalidRequest('mimeType'));
	const sha256 = await sha256Hex(bytes);

	return respond(
		await runApi(
			event,
			session,
			withPin(
				fields.pin,
				Effect.gen(function* () {
					return yield* (yield* MoneyMovesApi).uploadPayoutReceipt(membershipId, {
						withdrawalId,
						idempotencyKey: fields.idempotencyKey,
						fileName: cleanName(file.name),
						mimeType,
						bytes,
						sha256
					});
				})
			)
		)
	);
};
