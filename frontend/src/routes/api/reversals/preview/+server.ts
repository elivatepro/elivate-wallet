// The transaction a President is about to reverse (W-15, Paper v1 E07/E08),
// found by its reference, with the lines the reversal would post.
import { EntryRoutes, ReversalPreview } from '#lib/contract/entries.js';
import { ledgerRead, relayRead } from '#lib/server/money-endpoints.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	relayRead(
		event,
		{ reference: /^[A-Za-z0-9-]{11,20}$/ },
		ledgerRead(EntryRoutes.reversalPreview, ReversalPreview)
	);
