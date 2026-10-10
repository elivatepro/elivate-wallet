// Download a backup (owner decision 2026-10-09: the PIN first, through
// /api/exports/unlock). The backend re-checks authority and expiry and audits
// it; this server streams the archive from private storage.
import { streamBackup } from '#lib/server/backups/endpoints.js';
import { validId } from '#lib/server/money-endpoints.js';
import { invalidRequest, respondError } from '#lib/server/relay.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	validId(event.params.id)
		? streamBackup(event, event.params.id)
		: Promise.resolve(respondError(invalidRequest('id')));
