// First page of a personal PDF statement as an image (Paper S09 preview).
import { streamExport } from '#lib/server/exports/endpoints.js';
import { validId } from '#lib/server/money-endpoints.js';
import { invalidRequest, respondError } from '#lib/server/relay.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	validId(event.params.id)
		? streamExport(event, event.params.id, 'preview')
		: Promise.resolve(respondError(invalidRequest('id')));
