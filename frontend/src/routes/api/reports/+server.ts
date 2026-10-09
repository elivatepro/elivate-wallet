// Leadership report files (Blueprint 15, W-18; Paper S05/S06/S13d): the
// workspace's files (GET) and a new one (POST, export_scoped_reports).
import { Effect } from 'effect';
import { ReportCommand } from '#lib/contract/exports.js';
import { ExportsApi } from '#lib/server/apis-exports.js';
import { relayCommand } from '#lib/server/command.js';
import { kickRunner } from '#lib/server/exports/endpoints.js';
import { CURSOR, relayRead } from '#lib/server/money-endpoints.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	relayRead(event, { cursor: CURSOR }, (membershipId, query) =>
		Effect.gen(function* () {
			return yield* (yield* ExportsApi).reports(membershipId, query.cursor ?? null);
		})
	);

export const POST: RequestHandler = async (event) => {
	const response = await relayCommand(event, ReportCommand, (membershipId, body) =>
		Effect.gen(function* () {
			return yield* (yield* ExportsApi).createReport(membershipId, body);
		})
	);
	if (response.ok) kickRunner();
	return response;
};
