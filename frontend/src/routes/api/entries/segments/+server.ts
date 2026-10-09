// One member's pockets per currency with what is available, and the split.
import { UUID_PATTERN } from '#lib/contract/common.js';
import { EntryRoutes, EntrySegments } from '#lib/contract/entries.js';
import { ledgerRead, relayRead } from '#lib/server/money-endpoints.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	relayRead(
		event,
		{ kind: /^(conversion|adjustment)$/, membershipId: UUID_PATTERN },
		ledgerRead(EntryRoutes.segments, EntrySegments)
	);
