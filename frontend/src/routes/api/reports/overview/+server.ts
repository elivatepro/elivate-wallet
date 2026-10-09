// The Reports page (Paper S05 desktop, S12 mobile): live totals for the
// workspace's scope, one currency and period (WAT).
import { Effect } from 'effect';
import { ExportsApi } from '#lib/server/apis-exports.js';
import { relayRead } from '#lib/server/money-endpoints.js';
import type { RequestHandler } from './$types';

const DATE = /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/;

export const GET: RequestHandler = (event) =>
	relayRead(
		event,
		{
			currency: /^(NGN|USD)$/,
			periodKind: /^(month|quarter|year|year_to_date|custom)$/,
			from: DATE,
			to: DATE
		},
		(membershipId, query) =>
			Effect.gen(function* () {
				return yield* (yield* ExportsApi).overview(membershipId, {
					currency: query.currency ?? '',
					periodKind: query.periodKind ?? '',
					from: query.from ?? '',
					to: query.to ?? ''
				});
			})
	);
