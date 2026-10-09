// CSV files (Blueprint 15): RFC 4180 (CRLF, quoted when needed), UTF-8 with a
// BOM so spreadsheet apps read ₦ correctly. Text cells that a spreadsheet would
// run as a formula are prefixed with an apostrophe; amounts are exact decimal
// strings with their own currency column and are never touched.

import type {
	MemberFigure,
	ReportSummary,
	StatementSummary,
	TxnRow
} from '#lib/contract/exports.js';
import { description, pocketCell } from './describe';

/** UTF-8 byte order mark: spreadsheet apps then read ₦ correctly. */
const BOM = String.fromCharCode(0xfeff);

export type Cell = { readonly text: string } | { readonly amount: string } | null;

const text = (value: string | null | undefined): Cell => ({ text: value ?? '' });
const amount = (value: string | null | undefined): Cell => (value ? { amount: value } : null);

/** A leading = + - @ tab or CR makes a spreadsheet evaluate the cell. */
export function guardText(value: string): string {
	return /^[=+\-@\t\r]/.test(value) ? `'${value}` : value;
}

function encode(cell: Cell): string {
	if (cell === null) return '';
	const raw = 'amount' in cell ? cell.amount : guardText(cell.text);
	return /[",\r\n]/.test(raw) ? `"${raw.replaceAll('"', '""')}"` : raw;
}

export function toCsv(header: readonly string[], rows: Iterable<readonly Cell[]>): string {
	const lines = [header.join(',')];
	for (const row of rows) {
		if (row.length !== header.length) throw new Error('csv row width does not match the header');
		lines.push(row.map(encode).join(','));
	}
	return `${BOM}${lines.join('\r\n')}\r\n`;
}

const TXN_HEADER = [
	'posted_at_utc',
	'date_wat',
	'time_wat',
	'reference',
	'type',
	'description',
	'office',
	'currency',
	'amount',
	'status',
	'reversed_by',
	'reverses',
	'pockets'
];

function txnCells(row: TxnRow, currency: string): Cell[] {
	return [
		text(row.postedAt),
		text(row.date),
		text(row.time),
		text(row.reference),
		text(row.type),
		text(description(row)),
		text(row.office),
		text(currency),
		amount(row.amount),
		text(row.status),
		text(row.reversedBy),
		text(row.reverses),
		text(pocketCell(row))
	];
}

/** Personal "CSV of transactions": posted movements only, with the running balance. */
export function statementCsv(summary: StatementSummary, rows: readonly TxnRow[]): string {
	return toCsv(
		[...TXN_HEADER.slice(0, 9), 'balance', ...TXN_HEADER.slice(9)],
		rows.map((row) => {
			const cells = txnCells(row, summary.currency);
			return [...cells.slice(0, 9), amount(row.balance), ...cells.slice(9)];
		})
	);
}

/** Leadership "Transactions · CSV": every posted movement in scope, with the member. */
export function transactionsCsv(summary: ReportSummary, rows: readonly TxnRow[]): string {
	return toCsv(
		[...TXN_HEADER.slice(0, 6), 'member', 'uid', ...TXN_HEADER.slice(6)],
		rows.map((row) => {
			const cells = txnCells(row, summary.currency);
			return [
				...cells.slice(0, 6),
				text(row.member?.name ?? null),
				text(row.member?.uid ?? null),
				...cells.slice(6)
			];
		})
	);
}

/** Leadership "Member balances · CSV": one row per person. */
export function memberBalancesCsv(summary: ReportSummary, rows: readonly MemberFigure[]): string {
	return toCsv(
		[
			'member',
			'uid',
			'offices',
			'currency',
			'opening',
			'income',
			'paid_out',
			'money_in',
			'money_out',
			'closing',
			'reserved',
			'available'
		],
		rows.map((row) => [
			text(row.member?.name ?? null),
			text(row.member?.uid ?? null),
			text(row.offices.join('; ')),
			text(summary.currency),
			amount(row.opening),
			amount(row.income),
			amount(row.paidOut),
			amount(row.in),
			amount(row.out),
			amount(row.closing),
			amount(row.reserved),
			amount(row.available)
		])
	);
}
