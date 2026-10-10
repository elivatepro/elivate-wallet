// One logo of the selected network, streamed from private storage to its
// members only (W-20: never a public asset URL). `?v=<revision>` busts caches.
import { error } from '@sveltejs/kit';
import { readBrandAsset } from '#lib/server/brand.js';
import { readWorkspace } from '#lib/server/cookies.js';
import type { RequestHandler } from './$types';

const KINDS = ['logo', 'icon', 'logo-light'] as const;

export const GET: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) error(401, 'Sign in to continue.');
	const membershipId = readWorkspace(event.cookies);
	const kind = event.params.kind;
	if (!membershipId || !(KINDS as readonly string[]).includes(kind)) error(404, 'Not found.');
	const object = await readBrandAsset(event, session, membershipId, kind as (typeof KINDS)[number]);
	if (!object) error(404, 'No logo.');
	return new Response(object.body, {
		headers: {
			'content-type': object.httpMetadata?.contentType ?? 'application/octet-stream',
			'cache-control': 'private, max-age=300',
			'content-disposition': 'inline',
			'x-content-type-options': 'nosniff',
			'content-security-policy': "default-src 'none'; sandbox"
		}
	});
};
