// PDF documents (Paper "Statements & reports v1"): S01/S02/S07 member
// statement and S03/S04 office report, as print HTML for the headless browser.
// A4 at 96 dpi (794 × 1123), 56 px sides. Page numbers and the running header
// of later pages come from @page margin boxes; tables repeat their header row.
// Root stays out of generated files (00-product). Every value is escaped.

import type {
	MemberFigure,
	PendingItem,
	ReportSummary,
	StatementSummary,
	TxnRow
} from '#lib/contract/exports.js';
import type { Currency } from '#lib/contract/ledger.js';
import { ROLE_LABELS } from '#lib/labels.js';
import { formatMoney, isZero } from '#lib/money.js';
import { CURRENCY_NAMES, periodRange, shortDate, watDateTime } from '#lib/statements.js';
import { badges, description, detail } from './describe';
import { FONT_FACES } from './fonts';

export const SUPPORT_EMAIL = 'support@elivatewallet.com';

export function escapeHtml(value: string): string {
	return value
		.replaceAll('&', '&amp;')
		.replaceAll('<', '&lt;')
		.replaceAll('>', '&gt;')
		.replaceAll('"', '&quot;')
		.replaceAll("'", '&#39;');
}
const e = escapeHtml;

/**
 * A CSS string literal for @page content. It sits inside <style>, so anything
 * but plain letters, digits and a few punctuation marks becomes a CSS hex
 * escape: a name can never close the string or the style element.
 */
export const cssString = (value: string) =>
	`"${Array.from(value)
		.map((ch) =>
			/^[A-Za-z0-9 .,·–_@()-]$/.test(ch) ? ch : `\\${(ch.codePointAt(0) ?? 32).toString(16)} `
		)
		.join('')}"`;

const BASE_CSS = `${FONT_FACES}
*{box-sizing:border-box;margin:0;padding:0}
html{-webkit-print-color-adjust:exact;print-color-adjust:exact}
body{font-family:Lexend,system-ui,sans-serif;color:#212628;background:#fff;font-size:13px;line-height:18px;-webkit-font-smoothing:antialiased;overflow-wrap:anywhere}
.mono{font-family:'IBM Plex Mono',ui-monospace,monospace}
.muted{color:#5E686B}.faint{color:#8A9396}.pos{color:#167D55}.neg{color:#B4433C}.warn{color:#8A5C00}
.stack{display:flex;flex-direction:column;gap:28px}
.head{display:flex;justify-content:space-between;align-items:flex-start;padding-bottom:20px;border-bottom:2px solid #212628}
.brand{display:flex;align-items:center;gap:10px;font-size:16px;line-height:20px;font-weight:600}
.tile{width:28px;height:28px;border-radius:6px;background:#212628;color:#fff;display:flex;align-items:center;justify-content:center;font-size:16px;font-weight:600}
.title{font-size:28px;line-height:34px;font-weight:600;letter-spacing:-0.02em;margin-top:14px}
.sub{font-size:14px;line-height:20px;color:#5E686B;margin-top:2px}
.meta{display:flex;flex-direction:column;align-items:flex-end;gap:4px;padding-top:4px;font-size:12px;line-height:16px;color:#5E686B;text-align:right}
.meta .mono{color:#212628}
.facts{display:flex;gap:40px}
.label{font-size:11px;line-height:16px;letter-spacing:0.06em;color:#5E686B;text-transform:uppercase}
.fact-value{font-size:15px;line-height:20px;margin-top:2px}
.fact-value.mono{font-size:14px}
.cards{display:flex;border:1px solid #D8DDDE;border-radius:12px;overflow:hidden}
.card{flex:1 1 0;display:flex;flex-direction:column;gap:6px;padding:16px 18px;border-right:1px solid #E6E9EA}
.card:last-child{border-right:0}.card.close{background:#FFF0EA}
.card-label{font-size:12px;line-height:16px;color:#5E686B}.card.close .card-label{color:#B74725}
.card-value{font-size:18px;line-height:24px;font-weight:600}
.card-note{font-size:11px;line-height:14px;color:#8A9396}
.section{display:flex;flex-direction:column;gap:10px}
.section-head{display:flex;justify-content:space-between;align-items:baseline}
.h{font-size:13px;line-height:18px;font-weight:600}
.note{font-size:11px;line-height:16px;color:#8A9396}
table{width:100%;border-collapse:collapse}
thead{display:table-header-group}
tr{break-inside:avoid;page-break-inside:avoid}
th{font-weight:400;font-size:11px;line-height:16px;letter-spacing:0.06em;color:#5E686B;text-align:left;padding:8px 0;border-top:1px solid #D8DDDE;border-bottom:1px solid #D8DDDE;text-transform:uppercase}
td{padding:9px 0;border-bottom:1px solid #E6E9EA;vertical-align:top}
tbody tr:last-child td{border-bottom-color:#D8DDDE}
.r{text-align:right}.strong{font-weight:500}
.txn td{padding:10px 0}
.txn .date{width:78px;font-size:12px;color:#5E686B}
.txn .amt{width:130px;font-weight:500}.txn .bal{width:130px}
.desc{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.detail{font-family:'IBM Plex Mono',ui-monospace,monospace;font-size:11px;line-height:16px;color:#5E686B;margin-top:2px}
.pill{border:1px solid #D8DDDE;border-radius:999px;padding:1px 7px;font-size:10px;line-height:14px;color:#5E686B}
.pill.warn{background:#FFF7E8;border-color:#E7C98F;color:#8A5C00}
.closing td{border-top:2px solid #212628;border-bottom:0;padding:12px 0}
.closing .what{font-size:14px;font-weight:600}.closing .total{font-size:16px;line-height:20px;font-weight:600}
.empty{padding:28px 0;text-align:center;border-top:1px solid #D8DDDE;border-bottom:1px solid #E6E9EA}
.empty strong{display:block;font-size:15px;line-height:20px;font-weight:500}
.empty span{display:block;font-size:12px;color:#5E686B;margin-top:4px}
.boxes{display:flex;border:1px solid #D8DDDE;border-radius:12px;overflow:hidden;break-inside:avoid}
.box{flex:1 1 0;display:flex;flex-direction:column;gap:4px;padding:14px 18px;border-right:1px solid #E6E9EA}
.box:last-child{border-right:0}.box .card-label{color:#5E686B}
.box-value{font-size:16px;line-height:22px;font-weight:600}.boxes.counts .box-value{font-size:18px;line-height:24px}
.lines td{padding:9px 0}
.lines .total td{border-top:0;border-bottom:2px solid #212628;padding:12px 0}
.lines .total .what{font-size:14px;line-height:20px;font-weight:600}.lines .total .total-value{font-size:16px;line-height:20px;font-weight:600}
.cols{display:flex;gap:28px;break-inside:avoid}.cols>.section{flex:1 1 0}
.bar{display:flex;height:10px;border-radius:999px;overflow:hidden;background:#EEF0F1}
.count{width:36px;color:#5E686B}.money{width:130px}
.page-break{break-before:page;padding-top:18px}
.members .uid{font-family:'IBM Plex Mono',ui-monospace,monospace;font-size:12px;color:#8A9396}
.members td{padding:11px 0}`;

/**
 * A4 with Paper's margins. Page numbers come from the renderer's footer
 * template (Chrome's own header/footer), which Cloudflare's browser and local
 * Chromium both draw; CSS @page margin boxes are not supported everywhere.
 */
function pageCss(): string {
	return '@page{size:A4;margin:48px 56px 64px 56px}';
}

function document(title: string, css: string, body: string): string {
	return `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${e(title)}</title><style>${BASE_CSS}${css}</style></head><body>${body}</body></html>`;
}

const money = (amount: string, currency: Currency, signed = false) =>
	formatMoney(amount, currency, signed);
const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;
const toneOf = (amount: string) => (isZero(amount) ? '' : amount.startsWith('-') ? '' : 'pos');

/** "Cedar Network · Powered by Elivate Wallet · support@…" (slice 10 adds team contact). */
const footerFor = (network: string, tail = SUPPORT_EMAIL) =>
	`${network} · Powered by Elivate Wallet · ${tail}`;

function brand(network: { name: string; initial: string }): string {
	return `<div class="brand"><div class="tile">${e(network.initial)}</div><div>${e(network.name)}</div></div>`;
}

// ── Statement ────────────────────────────────────────────────────────────────

const OUT_WORDS: Record<string, [string, string]> = {
	withdrawal: ['withdrawal', 'withdrawals'],
	reversal: ['reversal', 'reversals'],
	pocket_transfer: ['pocket move', 'pocket moves'],
	conversion: ['conversion', 'conversions'],
	adjustment: ['adjustment', 'adjustments'],
	income: ['income', 'incomes'],
	returned_funds: ['return', 'returns']
};

function outNote(types: Readonly<Record<string, number>>): string {
	const parts = Object.entries(types)
		.filter(([, n]) => n > 0)
		.map(([type, n]) => {
			const [one, many] = OUT_WORDS[type] ?? [
				type.replaceAll('_', ' '),
				`${type.replaceAll('_', ' ')}s`
			];
			return `${n} ${n === 1 ? one : many}`;
		});
	return parts.length ? parts.join(' · ') : 'No debits';
}

const PENDING_LABEL: Record<PendingItem['kind'], string> = {
	withdrawal: 'Withdrawal request',
	pocket_transfer: 'Pocket move request',
	conversion: 'Conversion being checked'
};
const PENDING_PILL: Record<PendingItem['status'], string> = {
	approved: 'Approved · not paid',
	requested: 'Waiting for approval',
	needs_review: 'Being checked'
};

function txnRow(row: TxnRow, currency: Currency, withBalance: boolean): string {
	const amountClass = row.amount.startsWith('-')
		? row.type === 'reversal'
			? 'neg'
			: ''
		: isZero(row.amount)
			? ''
			: 'pos';
	return `<tr class="txn"><td class="date">${e(shortDate(row.date))}</td><td><div class="desc"><span>${e(description(row))}</span>${badges(
		row
	)
		.map((b) => `<span class="pill">${e(b)}</span>`)
		.join(
			''
		)}</div><div class="detail">${e(detail(row, currency))}</div></td><td class="r amt ${amountClass}">${e(
		money(row.amount, currency, true)
	)}</td>${withBalance ? `<td class="r bal">${row.balance ? e(money(row.balance, currency)) : ''}</td>` : ''}</tr>`;
}

export function statementHtml(summary: StatementSummary, rows: readonly TxnRow[]): string {
	const c = summary.currency;
	const p = summary.period;
	const person = summary.person;
	const name = person?.name ?? person?.uid ?? '';
	const offices = [...new Set(summary.memberships.map((m) => m.office))].join(', ') || '—';
	const roles = [...new Set(summary.memberships.map((m) => ROLE_LABELS[m.role]))].join(', ') || '—';
	const range = periodRange(p);
	const endNote = p.cutShort ? `as of ${watDateTime(p.asOf)}` : `${shortDate(p.to)}, 23:59 WAT`;
	const empty = rows.length === 0;
	const other = c === 'NGN' ? 'USD' : 'NGN';
	const hasMoves = rows.some((r) => r.type === 'pocket_transfer');

	const head = `<div class="head"><div>${brand(summary.network)}<div class="title">Account statement</div><div class="sub">${e(
		`${range} · ${CURRENCY_NAMES[c]} (${c})`
	)}</div></div><div class="meta"><div class="mono">${e(summary.reference)}</div><div>Generated ${e(
		watDateTime(summary.generatedAt)
	)}</div></div></div>`;

	const facts = `<div class="facts">${[
		['Member', name, ''],
		['Wallet ID', person?.uid ?? '', 'mono'],
		[summary.memberships.length > 1 ? 'Offices' : 'Office', offices, ''],
		['Role', roles, '']
	]
		.map(
			([label, value, cls]) =>
				`<div><div class="label">${e(label ?? '')}</div><div class="fact-value ${cls}"${label === 'Member' ? ' style="font-weight:500"' : ''}>${e(value ?? '')}</div></div>`
		)
		.join('')}</div>`;

	const cards = `<div class="cards"><div class="card"><div class="card-label">Opening balance</div><div class="card-value">${e(
		money(summary.opening, c)
	)}</div><div class="card-note">${e(shortDate(p.from))}, 00:00 WAT</div></div><div class="card"><div class="card-label">Money in</div><div class="card-value ${toneOf(
		summary.moneyIn
	)}">${e(money(summary.moneyIn, c, true))}</div><div class="card-note">${e(
		summary.inCount ? plural(summary.inCount, 'posted credit') : 'No credits'
	)}</div></div><div class="card"><div class="card-label">Money out</div><div class="card-value">${e(
		money(summary.moneyOut, c)
	)}</div><div class="card-note">${e(outNote(summary.outTypes))}</div></div><div class="card close"><div class="card-label">Closing balance</div><div class="card-value">${e(
		money(summary.closing, c)
	)}</div><div class="card-note">${e(endNote)}</div></div></div>`;

	const pockets =
		empty || summary.pockets.length === 0
			? ''
			: `<div class="section"><div class="h">By pocket</div><table><thead><tr><th style="width:180px">Pocket</th><th class="r">Opening</th><th class="r">In</th><th class="r">Out</th><th class="r">Closing</th></tr></thead><tbody>${summary.pockets
					.map(
						(pk) =>
							`<tr><td>${e(pk.pocket)}</td><td class="r">${e(money(pk.opening, c))}</td><td class="r">${e(
								money(pk.in, c)
							)}</td><td class="r">${e(money(pk.out.replace(/^-/, ''), c))}</td><td class="r strong">${e(money(pk.closing, c))}</td></tr>`
					)
					.join(
						''
					)}</tbody></table>${hasMoves ? '<div class="note">Pocket columns include moves between pockets; they don’t change the total.</div>' : ''}</div>`;

	const transactions = empty
		? `<div class="section"><div class="h">Transactions</div><div class="empty"><strong>No transactions in this period</strong><span>${e(
				`Your ${c} balance did not change in ${p.kind === 'month' ? range.replace(/^[0-9]+ – [0-9]+ /, '').replace(/ [0-9]{4}$/, '') : 'this period'}.`
			)}</span></div></div>`
		: `<div class="section"><div class="section-head"><div class="h">Transactions</div><div class="note">Posted records only · times in WAT</div></div><table><thead><tr><th style="width:78px">Date</th><th>Description</th><th class="r" style="width:130px">Amount</th><th class="r" style="width:130px">Balance</th></tr></thead><tbody><tr class="txn"><td class="date">${e(
				shortDate(p.from)
			)}</td><td>Opening balance</td><td class="amt"></td><td class="r bal">${e(money(summary.opening, c))}</td></tr>${rows
				.map((row) => txnRow(row, c, true))
				.join('')}<tr class="closing"><td class="date muted" style="font-size:12px">${e(
				shortDate(p.cutShort ? p.asOf.slice(0, 10) : p.to)
			)}</td><td class="what">Closing balance</td><td></td><td class="r total">${e(money(summary.closing, c))}</td></tr></tbody></table></div>`;

	const pending = summary.pending.length
		? `<div class="section"><div class="h">${e(`Not yet posted on ${shortDate(p.cutShort ? p.asOf.slice(0, 10) : p.to)}`)}</div><table><tbody>${summary.pending
				.map(
					(item) =>
						`<tr class="txn"><td class="date">${e(shortDate(item.date))}</td><td><div class="desc"><span>${e(
							PENDING_LABEL[item.kind]
						)}</span><span class="pill warn">${e(PENDING_PILL[item.status])}</span></div><div class="detail">${e(
							[item.reference, `from ${item.pocket}`].filter(Boolean).join(' · ')
						)}</div></td><td class="r warn strong" style="width:260px">${e(money(item.amount, c))} reserved</td></tr>`
				)
				.join('')}</tbody></table></div>`
		: '';

	const boxes =
		empty && isZero(summary.reserved)
			? ''
			: `<div class="boxes"><div class="box"><div class="card-label">Closing balance</div><div class="box-value">${e(
					money(summary.closing, c)
				)}</div></div><div class="box"><div class="card-label">Reserved</div><div class="box-value ${isZero(summary.reserved) ? '' : 'warn'}">${e(
					isZero(summary.reserved) ? money(summary.reserved, c) : `−${money(summary.reserved, c)}`
				)}</div></div><div class="box"><div class="card-label">Available to withdraw</div><div class="box-value">${e(
					money(summary.available, c)
				)}</div></div></div>`;

	const footnote = `<div class="note muted" style="line-height:17px;color:#5E686B">Balances use posted records only. Reversals appear as their own entry and link to the original. ${e(
		other
	)} activity is on a separate statement.${p.cutShort ? ` This period had not ended: figures are as of ${e(watDateTime(p.asOf))}.` : ''}</div>`;

	const css = pageCss();
	return document(
		`${summary.reference} · Account statement`,
		css,
		`<main class="stack" data-footer-left="${e(footerFor(summary.network.name))}" data-footer-right="${e(summary.reference)}">${head}${facts}${cards}${pockets}${transactions}${pending}${boxes}${empty ? '' : footnote}</main>`
	);
}

// ── Office report ───────────────────────────────────────────────────────────

const HELD_LABEL: Record<string, [string, string]> = {
	income: ['Income posted', 'entry'],
	reversal: ['Reversals', 'entry'],
	withdrawal: ['Paid out', 'withdrawal'],
	returned_funds: ['Returned funds', 'return'],
	conversion_in: ['Conversions in', 'entry'],
	conversion_out: ['Conversions out', 'entry'],
	adjustment: ['Adjustments', 'entry'],
	pocket_transfer: ['Pocket moves', 'move']
};

const STAGE_LABEL: Record<string, string> = {
	requested: 'Requested',
	approved: 'Approved',
	completed: 'Completed',
	rejected: 'Not approved',
	cancelled: 'Cancelled'
};

const BAR_COLORS = ['#212628', '#FF7F4F', '#D8DDDE', '#8A9396', '#F2B85E', '#5E686B'];

/** Display-only widths from exact strings (a visual, never a money figure). */
function shares(amounts: readonly string[]): number[] {
	const values = amounts.map((a) => Math.max(0, Number(a)));
	const total = values.reduce((s, v) => s + v, 0);
	return total > 0 ? values.map((v) => (v / total) * 100) : values.map(() => 0);
}

export function reportTitle(summary: ReportSummary): string {
	if (summary.scope.member) return 'Member report';
	return summary.scope.kind === 'network' ? 'Network report' : 'Office report';
}

export function reportHtml(summary: ReportSummary, members: readonly MemberFigure[]): string {
	const c = summary.currency;
	const p = summary.period;
	const title = reportTitle(summary);
	const range = periodRange(p);
	const scopeName = summary.scope.member
		? `${summary.scope.member?.name ?? summary.scope.member?.uid ?? ''} · ${summary.scope.name}`
		: summary.scope.name;
	const who = summary.preparedFor;
	const end = p.cutShort ? `as of ${watDateTime(p.asOf)}` : shortDate(p.to);

	const head = `<div class="head"><div>${brand(summary.network)}<div class="title">${e(title)}</div><div class="sub">${e(
		`${scopeName} · ${range} · ${c}`
	)}</div></div><div class="meta"><div class="mono">${e(summary.reference)}</div><div>${e(
		`Prepared for ${who.name ?? who.uid}${who.role ? ` · ${ROLE_LABELS[who.role]}` : ''}`
	)}</div><div>Generated ${e(watDateTime(summary.generatedAt))}</div></div></div>`;

	const heldRows = summary.held
		.map((line) => {
			const [label, unit] = HELD_LABEL[line.kind] ?? [line.kind, 'entry'];
			const tone = line.kind === 'reversal' ? 'neg' : line.amount.startsWith('-') ? '' : 'pos';
			return `<tr><td>${e(`${label} · ${plural(line.count, unit, unit === 'entry' ? 'entries' : `${unit}s`)}`)}</td><td class="r ${tone}">${e(
				money(line.amount, c, true)
			)}</td></tr>`;
		})
		.join('');
	const held = `<div class="section"><div class="h">Money held for members</div><table class="lines"><thead style="display:none"><tr><th></th><th></th></tr></thead><tbody style="border-top:1px solid #D8DDDE"><tr><td>${e(
		`Opening balance · ${shortDate(p.from)}`
	)}</td><td class="r">${e(money(summary.opening, c))}</td></tr>${heldRows}<tr class="total"><td class="what">${e(
		`Closing balance · ${end}`
	)}</td><td class="r total-value">${e(money(summary.closing, c))}</td></tr><tr><td class="muted">${e(
		summary.reservedCount
			? `Reserved for ${plural(summary.reservedCount, 'open request')}`
			: 'Reserved'
	)}</td><td class="r warn">${e(isZero(summary.reserved) ? money(summary.reserved, c) : `−${money(summary.reserved, c)}`)}</td></tr><tr><td class="muted" style="border-bottom:0">Available to members</td><td class="r strong" style="border-bottom:0">${e(
		money(summary.available, c)
	)}</td></tr></tbody></table></div>`;

	const widths = shares(summary.netIncomeByPocket.map((x) => x.amount));
	const pockets = `<div class="section"><div class="h">Net income by pocket</div><table class="lines"><tbody style="border-top:1px solid #D8DDDE">${
		summary.netIncomeByPocket.length
			? summary.netIncomeByPocket
					.map(
						(x) =>
							`<tr><td style="padding:8px 0">${e(x.pocket)}</td><td class="r" style="padding:8px 0">${e(money(x.amount, c))}</td></tr>`
					)
					.join('')
			: '<tr><td class="muted" style="padding:8px 0">No income in this period</td><td></td></tr>'
	}<tr><td class="strong" style="padding:8px 0;border-bottom:0">Net income</td><td class="r strong" style="padding:8px 0;border-bottom:0">${e(
		money(summary.netIncome, c)
	)}</td></tr></tbody></table><div class="bar">${widths
		.map(
			(w, i) =>
				`<div style="width:${w.toFixed(2)}%;background:${BAR_COLORS[i % BAR_COLORS.length]}"></div>`
		)
		.join('')}</div></div>`;

	const withdrawals = `<div class="section"><div class="h">Withdrawals</div><table class="lines"><tbody style="border-top:1px solid #D8DDDE">${summary.withdrawals
		.map((w) => {
			const quiet = w.stage === 'rejected' || w.stage === 'cancelled';
			const strong = w.stage === 'completed' ? ' strong' : '';
			return `<tr><td style="padding:8px 0" class="${quiet ? 'muted' : ''}${strong}">${e(STAGE_LABEL[w.stage] ?? w.stage)}</td><td class="r count" style="padding:8px 0">${w.count}</td><td class="r money${quiet ? ' muted' : ''}${strong}" style="padding:8px 0">${e(
				money(w.amount, c)
			)}</td></tr>`;
		})
		.join(
			''
		)}</tbody></table><div class="note">Requested amounts, by the date each step happened.</div></div>`;

	const counts = `<div class="boxes counts"><div class="box"><div class="card-label">Active memberships</div><div class="box-value">${summary.counts.activeMemberships}</div></div><div class="box"><div class="card-label">Distinct people</div><div class="box-value">${summary.counts.people}</div></div><div class="box"><div class="card-label">${e(
		p.kind === 'month' ? 'Joined this month' : 'Joined in this period'
	)}</div><div class="box-value">${summary.counts.joined}</div></div></div>`;

	const excluded = summary.excludedPeople
		? `<div class="note" style="color:#5E686B">${e(
				`${plural(summary.excludedPeople, 'person', 'people')} in this scope ${summary.excludedPeople === 1 ? 'is' : 'are'} outside your permission and not included. Your own wallet is never part of your reports.`
			)}</div>`
		: '<div class="note" style="color:#5E686B">Your own wallet is never part of your reports. Each currency is reported separately.</div>';

	const memberTable = members.length
		? `<div class="section page-break members"><div class="section-head"><div class="h">By member</div><div class="note">${e(
				`${plural(members.length, 'member')} · by income`
			)}</div></div><table><thead><tr><th>Member</th><th style="width:110px">Wallet ID</th><th class="r" style="width:110px">Income</th><th class="r" style="width:110px">Paid out</th><th class="r" style="width:128px">Closing</th></tr></thead><tbody>${members
				.map(
					(m) =>
						`<tr><td>${e(m.member?.name ?? m.member?.uid ?? '')}</td><td class="uid">${e(m.member?.uid ?? '')}</td><td class="r">${e(
							money(m.income, c)
						)}</td><td class="r">${e(money(m.paidOut, c))}</td><td class="r strong">${e(money(m.closing, c))}</td></tr>`
				)
				.join('')}</tbody></table></div>`
		: '';

	const css = pageCss();
	return document(
		`${summary.reference} · ${title}`,
		css,
		`<main class="stack" data-footer-left="${e(footerFor(summary.network.name, 'Confidential to office leadership'))}" data-footer-right="${e(summary.reference)}">${head}${held}<div class="cols">${pockets}${withdrawals}</div>${counts}${excluded}${memberTable}</main>`
	);
}
