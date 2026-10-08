// The signed-in person's own profile photo, streamed from private R2 storage.
import { error } from '@sveltejs/kit';
import { readOwnPhoto } from '#lib/server/photos.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) error(401, 'Sign in to continue.');
	const photo = await readOwnPhoto(event, session);
	if (!photo) error(404, 'No photo.');
	return new Response(photo.body, {
		headers: {
			'content-type': photo.httpMetadata?.contentType ?? 'application/octet-stream',
			'cache-control': 'private, no-store',
			'content-disposition': 'inline',
			'x-content-type-options': 'nosniff'
		}
	});
};
