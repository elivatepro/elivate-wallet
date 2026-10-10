// The signed-in person's own profile photo, streamed from private R2 storage.
import { error } from '@sveltejs/kit';
import { BackendError } from '#lib/contract/errors.js';
import { successBody } from '#lib/contract/envelope.js';
import { readOwnPhoto, storePhoto } from '#lib/server/photos.js';
import { invalidRequest } from '#lib/server/command.js';
import { respondError, toBackendError, unauthenticated } from '#lib/server/relay.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) error(401, 'Sign in to continue.');
	const photo = await readOwnPhoto(event, session);
	if (!photo) error(404, 'No photo.');
	return new Response(photo.body, {
		headers: {
			'content-type': photo.httpMetadata?.contentType ?? 'application/octet-stream',
			// The app asks for `?v=<photoUpdatedAt>` (profilePhotoSrc), so a new
			// photo is a new URL: the browser may keep this one privately.
			'cache-control': event.url.searchParams.has('v')
				? 'private, max-age=86400'
				: 'private, no-cache',
			'content-disposition': 'inline',
			'x-content-type-options': 'nosniff'
		}
	});
};

/**
 * Replace the own photo (Paper "App — Screens v4" Z04 "Change photo",
 * Blueprint 10). Multipart from the same origin (Kit's CSRF check covers
 * form posts); size, type by content and storage follow Blueprint 06 B4.
 */
export const POST: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	let file: FormDataEntryValue | null;
	try {
		file = (await event.request.formData()).get('photo');
	} catch {
		return respondError(invalidRequest('photo'));
	}
	if (!(file instanceof File)) return respondError(invalidRequest('photo'));
	const result = await storePhoto(event, session, file);
	if (result.ok) {
		return new Response(JSON.stringify(successBody({ saved: true }, crypto.randomUUID())), {
			headers: { 'cache-control': 'no-store', 'content-type': 'application/json; charset=utf-8' }
		});
	}
	if ('error' in result) {
		return respondError(
			new BackendError({
				status: 400,
				code: 'validation_error',
				message: result.error,
				retryable: false,
				details: { field: 'photo' },
				requestId: null
			})
		);
	}
	return respondError(toBackendError(result.failure));
};
