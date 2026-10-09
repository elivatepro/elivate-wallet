// Download (owner decision Q7): the backend re-checks the person (and a fresh
// PIN proof for leadership reports) and audits it; this server streams the
// file from private storage. No storage URL ever reaches the browser.
import { streamExport } from '#lib/server/exports/endpoints.js';
import { validId } from '#lib/server/money-endpoints.js';
import { invalidRequest, respondError } from '#lib/server/relay.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	validId(event.params.id)
		? streamExport(event, event.params.id, 'file')
		: Promise.resolve(respondError(invalidRequest('id')));
