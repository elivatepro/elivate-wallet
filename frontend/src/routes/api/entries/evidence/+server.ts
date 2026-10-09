// Evidence for a conversion, adjustment or returned funds (Blueprint 12):
// multipart with the kind, the member's membership and the attempt's
// idempotency key; the same verified upload flow as payout receipts.
import { Effect, Schema } from 'effect';
import { Uuid } from '#lib/contract/common.js';
import { EntryKind } from '#lib/contract/entries.js';
import { MoneyMovesApi } from '#lib/server/apis-withdrawals.js';
import { EvidenceFields, readEvidenceForm } from '#lib/server/evidence-form.js';
import { respond } from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import { withPin } from '#lib/server/step-up.js';
import type { RequestHandler } from './$types';

const Fields = Schema.Struct({
	...EvidenceFields.fields,
	kind: EntryKind,
	targetMembershipId: Uuid
});

export const POST: RequestHandler = async (event) => {
	const form = await readEvidenceForm(event, Fields, [
		'idempotencyKey',
		'pin',
		'kind',
		'targetMembershipId'
	]);
	if (form instanceof Response) return form;
	return respond(
		await runApi(
			event,
			form.session,
			withPin(
				form.fields.pin,
				Effect.gen(function* () {
					return yield* (yield* MoneyMovesApi).uploadEntryEvidence(form.membershipId, {
						kind: form.fields.kind,
						targetMembershipId: form.fields.targetMembershipId,
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
