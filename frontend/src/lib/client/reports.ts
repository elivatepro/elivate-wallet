// Leadership reports in the browser (Blueprint 15): the Reports page's live
// figures, the workspace's files and the download with the PIN (Paper S14d).

import { Cause, Effect, Exit, Option } from 'effect';
import {
	ExportFile,
	ExportPage,
	ReportOverview,
	type ReportCommand,
	type ReportKind
} from '#lib/contract/exports.js';
import type { Currency } from '#lib/contract/ledger.js';
import { periodPresets, type Period } from '#lib/statements.js';
import { getJson, newKey, sendCommand } from './api';
import { messageOf } from './exports.svelte';
import type { PageLoaded } from './page-cache.svelte';

export const overviewPath = (currency: Currency, period: Period) =>
	`/api/reports/overview?${new URLSearchParams({
		currency,
		periodKind: period.kind,
		from: period.from,
		to: period.to
	})}`;

export const loadOverview = (currency: Currency, period: Period, signal?: AbortSignal) =>
	Effect.runPromiseExit(getJson(overviewPath(currency, period), ReportOverview, signal));

export const loadReports = () => Effect.runPromiseExit(getJson('/api/reports', ExportPage));

// Blueprint 23: the Reports pages open from the device cache (kind 'reports').
// The files list carries no download links (downloads go through the app
// server by export id and need the PIN), so it is kept whole.

/** The cache part of one currency and period (lower case, `[a-z0-9-]`). */
export const overviewPart = (currency: Currency, period: Period): string =>
	`overview-${currency}-${period.kind}-${period.from}-${period.to}`
		.toLowerCase()
		.replaceAll('_', '-');

/** Only the preset periods are kept; a custom range is shown, never kept. */
export const isPresetPeriod = (period: Period, today: string): boolean =>
	periodPresets(today).some(
		(p) => p.kind === period.kind && p.from === period.from && p.to === period.to
	);

/** The backend status of a failed read (403 and 404 clear the saved copy). */
const statusOf = <A, E>(exit: Exit.Exit<A, E>): number | null => {
	if (!Exit.isFailure(exit)) return null;
	const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause)) as
		{ readonly _tag?: string; readonly status?: number | null } | undefined;
	return failure?._tag === 'BackendError' || failure?._tag === 'TransportError'
		? (failure.status ?? null)
		: null;
};

/** The overview as a cached page reads it. */
export async function readOverview(
	currency: Currency,
	period: Period
): Promise<PageLoaded<ReportOverview>> {
	const exit = await loadOverview(currency, period);
	return Exit.isSuccess(exit)
		? { ok: true, value: exit.value }
		: {
				ok: false,
				text: messageOf(exit, 'We couldn’t load the report figures.'),
				status: statusOf(exit)
			};
}

/** The workspace's recent report files as a cached page reads them. */
export async function readReports(): Promise<PageLoaded<ExportPage>> {
	const exit = await loadReports();
	return Exit.isSuccess(exit)
		? { ok: true, value: exit.value }
		: {
				ok: false,
				text: messageOf(exit, 'We couldn’t load your reports.'),
				status: statusOf(exit)
			};
}

export interface ReportChoice {
	readonly kind: ReportKind;
	readonly currency: Currency;
	readonly period: Period;
	readonly member: { readonly walletId: string; readonly name: string } | null;
}

/** Starts a report file; the caller keeps the key until it succeeds (F-03). */
export async function createReport(
	choice: ReportChoice,
	workspaceId: string,
	key: string = newKey()
) {
	const body: ReportCommand = {
		kind: choice.kind,
		memberWalletId: choice.member?.walletId ?? null,
		currency: choice.currency,
		periodKind: choice.period.kind,
		from: choice.period.from,
		to: choice.period.to,
		idempotencyKey: key
	};
	const exit = await Effect.runPromiseExit(
		sendCommand('/api/reports', 'POST', body, workspaceId, ExportFile)
	);
	return Exit.isSuccess(exit)
		? ({ ok: true, file: exit.value } as const)
		: ({
				ok: false,
				message: messageOf(exit, 'We couldn’t start the report. Try again.')
			} as const);
}
