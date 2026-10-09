// ExportsApi (Blueprint 15): statements, reports and their files through the
// `ledger` Edge Function. Reads retry; commands never do (the caller keeps
// its idempotency key). The download target (storage key) is asked for with
// the app-server secret and never leaves this server.

import { Context, Effect, Layer, Schedule } from 'effect';
import { isRetryableRead } from '#lib/contract/errors.js';
import {
	DownloadTarget,
	ExportFile,
	ExportPage,
	ExportRoutes,
	ReportMembers,
	ReportOverview,
	StatementOptions,
	type ReportCommand,
	type StatementCommand
} from '#lib/contract/exports.js';
import { EdgeTransport, type EdgeFailure } from './edge';

const readPolicy = {
	times: 2,
	while: isRetryableRead,
	schedule: Schedule.exponential('200 millis').pipe(Schedule.jittered)
};

export interface PeriodQuery {
	readonly currency: string;
	readonly periodKind: string;
	readonly from: string;
	readonly to: string;
}

export interface ExportsApiShape {
	readonly options: Effect.Effect<StatementOptions, EdgeFailure>;
	readonly statements: (cursor: string | null) => Effect.Effect<ExportPage, EdgeFailure>;
	readonly createStatement: (body: StatementCommand) => Effect.Effect<ExportFile, EdgeFailure>;
	readonly overview: (
		membershipId: string,
		query: PeriodQuery
	) => Effect.Effect<ReportOverview, EdgeFailure>;
	readonly reports: (
		membershipId: string,
		cursor: string | null
	) => Effect.Effect<ExportPage, EdgeFailure>;
	readonly members: (membershipId: string, q: string) => Effect.Effect<ReportMembers, EdgeFailure>;
	readonly createReport: (
		membershipId: string,
		body: ReportCommand
	) => Effect.Effect<ExportFile, EdgeFailure>;
	readonly file: (id: string) => Effect.Effect<ExportFile, EdgeFailure>;
	readonly retry: (id: string) => Effect.Effect<ExportFile, EdgeFailure>;
	readonly authorizeDownload: (
		id: string,
		part: 'file' | 'preview',
		appServerSecret: string
	) => Effect.Effect<DownloadTarget, EdgeFailure>;
}

export class ExportsApi extends Context.Service<ExportsApi, ExportsApiShape>()('ExportsApi') {}

export const ExportsApiLive = Layer.effect(
	ExportsApi,
	Effect.gen(function* () {
		const edge = yield* EdgeTransport;
		const fn = 'ledger' as const;
		const cursorQuery = (cursor: string | null): Record<string, string> =>
			cursor ? { cursor } : {};
		return {
			options: edge
				.call({ fn, route: ExportRoutes.options }, StatementOptions)
				.pipe(Effect.retry(readPolicy)),
			statements: (cursor) =>
				edge
					.call({ fn, route: ExportRoutes.statements, query: cursorQuery(cursor) }, ExportPage)
					.pipe(Effect.retry(readPolicy)),
			createStatement: (body) =>
				edge.call({ fn, route: ExportRoutes.createStatement, body }, ExportFile),
			overview: (membershipId, query) =>
				edge
					.call(
						{ fn, route: ExportRoutes.overview, membershipId, query: { ...query } },
						ReportOverview
					)
					.pipe(Effect.retry(readPolicy)),
			reports: (membershipId, cursor) =>
				edge
					.call(
						{ fn, route: ExportRoutes.reports, membershipId, query: cursorQuery(cursor) },
						ExportPage
					)
					.pipe(Effect.retry(readPolicy)),
			members: (membershipId, q) =>
				edge
					.call({ fn, route: ExportRoutes.members, membershipId, query: { q } }, ReportMembers)
					.pipe(Effect.retry(readPolicy)),
			createReport: (membershipId, body) =>
				edge.call({ fn, route: ExportRoutes.createReport, membershipId, body }, ExportFile),
			file: (id) =>
				edge.call({ fn, route: ExportRoutes.file(id) }, ExportFile).pipe(Effect.retry(readPolicy)),
			retry: (id) => edge.call({ fn, route: ExportRoutes.retry(id), body: {} }, ExportFile),
			authorizeDownload: (id, part, appServerSecret) =>
				edge.call(
					{ fn, route: ExportRoutes.download(id), body: { part }, appServerSecret },
					DownloadTarget
				)
		};
	})
);
