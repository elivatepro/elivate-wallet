// Members a leader may convert or adjust for (Paper v1 B07/E05 member picker).
import { EntryRoutes, EntryTargetPage } from '#lib/contract/entries.js';
import { CURSOR, ledgerRead, relayRead } from '#lib/server/money-endpoints.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	relayRead(
		event,
		{ kind: /^(conversion|adjustment)$/, q: /^.{1,100}$/s, cursor: CURSOR },
		ledgerRead(EntryRoutes.targets, EntryTargetPage)
	);
