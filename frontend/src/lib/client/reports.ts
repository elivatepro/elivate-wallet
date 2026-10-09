// Leadership reports in the browser (Blueprint 15): the Reports page's live
// figures, the workspace's files and the download with the PIN (Paper S14d).

import { Effect, Exit } from 'effect';
import {
	ExportFile,
	ExportPage,
	ReportOverview,
	type ReportCommand,
	type ReportKind
} from '#lib/contract/exports.js';
import type { Currency } from '#lib/contract/ledger.js';
import type { Period } from '#lib/statements.js';
import { getJson, newKey, sendCommand } from './api';
import { messageOf } from './exports.svelte';

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
