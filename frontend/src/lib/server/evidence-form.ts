// Multipart evidence from the browser (payout receipts, Blueprint 11; entry
// evidence, Blueprint 12): signed in, the workspace echo matches, one file
// within the size limit, its MIME type taken from the bytes, its SHA-256
// computed here, and the decoded text fields (the attempt's idempotency key,
// the optional dialog PIN and any target fields).

import type { RequestEvent } from '@sveltejs/kit';
import { Schema } from 'effect';
import { PIN_PATTERN } from '#lib/contract/common.js';
import { RECEIPT_MAX_BYTES } from '#lib/contract/income.js';
import { IdempotencyKey } from '#lib/contract/invitations.js';
import { sniffReceipt } from '#lib/income.js';
import { readWorkspace } from './cookies';
import {
	invalidRequest,
	respondError,
	unauthenticated,
	workspaceChanged,
	workspaceEchoMatches
} from './relay';

export const EvidenceFields = Schema.Struct({
	idempotencyKey: IdempotencyKey,
	pin: Schema.optionalKey(Schema.String.check(Schema.isPattern(PIN_PATTERN)))
});

export interface EvidenceForm<F> {
	readonly session: NonNullable<Awaited<ReturnType<RequestEvent['locals']['session']>>>;
	readonly membershipId: string;
	readonly fields: F;
	readonly fileName: string;
	readonly mimeType: string;
	readonly bytes: Uint8Array<ArrayBuffer>;
	readonly sha256: string;
}

function cleanName(name: string): string {
	// eslint-disable-next-line no-control-regex
	const base = name.replace(/[\u0000-\u001f\u007f]/g, '').trim();
	return (base || 'receipt').slice(0, 200);
}

async function sha256Hex(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
	const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
	return Array.from(digest, (b) => b.toString(16).padStart(2, '0')).join('');
}

/** The parsed form, or the error response to send. */
export async function readEvidenceForm<S extends Schema.ConstraintDecoder<object>>(
	event: RequestEvent,
	schema: S,
	names: readonly string[]
): Promise<EvidenceForm<S['Type']> | Response> {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	if (!workspaceEchoMatches(event)) return respondError(workspaceChanged());
	const membershipId = readWorkspace(event.cookies)!;

	const declared = Number(event.request.headers.get('content-length') ?? '0');
	if (declared > RECEIPT_MAX_BYTES + 64 * 1024) return respondError(invalidRequest('size'));
	let form: FormData;
	try {
		form = await event.request.formData();
	} catch {
		return respondError(invalidRequest('body'));
	}
	const file = form.get('file');
	let fields: S['Type'];
	try {
		const raw: Record<string, unknown> = {};
		for (const name of names) {
			const value = form.get(name);
			if (typeof value === 'string' && value !== '') raw[name] = value;
		}
		fields = Schema.decodeUnknownSync(schema)(raw);
	} catch {
		return respondError(invalidRequest('body'));
	}
	if (!(file instanceof File)) return respondError(invalidRequest('file'));
	if (file.size < 1 || file.size > RECEIPT_MAX_BYTES) return respondError(invalidRequest('size'));
	const bytes = new Uint8Array(await file.arrayBuffer());
	const mimeType = sniffReceipt(bytes);
	if (!mimeType) return respondError(invalidRequest('mimeType'));
	return {
		session,
		membershipId,
		fields,
		fileName: cleanName(file.name),
		mimeType,
		bytes,
		sha256: await sha256Hex(bytes)
	};
}
