// Logo upload (Blueprint 17; Paper F01 Logo tiles): multipart from the same
// origin with the workspace echo. Stores the image privately and returns its
// key, which the next settings save (with the PIN) makes live.
import { BackendError } from '#lib/contract/errors.js';
import { successBody } from '#lib/contract/envelope.js';
import { storeBrandAsset } from '#lib/server/brand.js';
import { invalidRequest } from '#lib/server/command.js';
import { readWorkspace } from '#lib/server/cookies.js';
import {
	respondError,
	toBackendError,
	unauthenticated,
	workspaceChanged,
	workspaceEchoMatches
} from '#lib/server/relay.js';
import type { RequestHandler } from './$types';

const KINDS = ['logo', 'icon', 'logo-light'] as const;

export const POST: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	if (!workspaceEchoMatches(event)) return respondError(workspaceChanged());
	const membershipId = readWorkspace(event.cookies)!;
	let form: FormData;
	try {
		form = await event.request.formData();
	} catch {
		return respondError(invalidRequest('file'));
	}
	const kind = form.get('kind');
	const file = form.get('file');
	if (typeof kind !== 'string' || !(KINDS as readonly string[]).includes(kind)) {
		return respondError(invalidRequest('kind'));
	}
	if (!(file instanceof File)) return respondError(invalidRequest('file'));
	const result = await storeBrandAsset(event, session, membershipId, file);
	if (result.ok) {
		return new Response(
			JSON.stringify(successBody({ kind, key: result.key }, crypto.randomUUID())),
			{
				headers: { 'cache-control': 'no-store', 'content-type': 'application/json; charset=utf-8' }
			}
		);
	}
	if ('error' in result) {
		return respondError(
			new BackendError({
				status: 400,
				code: 'validation_error',
				message: result.error,
				retryable: false,
				details: { field: 'file' },
				requestId: null
			})
		);
	}
	return respondError(toBackendError(result.failure));
};
