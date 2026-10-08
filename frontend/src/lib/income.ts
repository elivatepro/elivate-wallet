// Pure helpers for the Record income screen (W-08; Paper T02/T05): exact
// amount parsing, the split preview (a mirror of ledger.allocate), receipt
// checks and the copy for backend outcomes. No floats touch money here.

import type { ApiFailure } from '#lib/contract/errors.js';
import { isUnknownOutcome } from './recovery';
import type { Currency } from '#lib/contract/ledger.js';
import {
	RECEIPT_MAX_BYTES,
	RECEIPT_MAX_FILES,
	RECEIPT_MIME_TYPES,
	type ReceiptMime
} from '#lib/contract/income.js';

/** Pocket dots and bars, in display order (as on Pockets & split). */
export const POCKET_COLORS = [
	'var(--color-accent)',
	'var(--color-success)',
	'var(--color-info)',
	'var(--color-warning)',
	'var(--color-muted)',
	'#c9a3ff'
] as const;

export const pocketColor = (index: number) => POCKET_COLORS[index % POCKET_COLORS.length];

/**
 * What the person typed → the canonical decimal string with exactly `scale`
 * places ("180,000" → "180000.00"), or null when it is not a positive amount
 * with at most `scale` decimals. Accepts the currency symbol, spaces and
 * thousands commas.
 */
export function parseAmount(input: string, scale: number): string | null {
	const cleaned = input.replace(/[₦$,\s]/g, '');
	const pattern = new RegExp(`^(\\d{1,15})(?:\\.(\\d{0,${scale}}))?$`);
	const match = pattern.exec(cleaned);
	if (!match) return null;
	const whole = (match[1] ?? '0').replace(/^0+(?=\d)/, '');
	const fraction = (match[2] ?? '').padEnd(scale, '0');
	const canonical = scale > 0 ? `${whole}.${fraction}` : whole;
	return /[1-9]/.test(canonical) ? canonical : null;
}

/** "180000.00" → "180,000.00" (for the amount field after blur). */
export function groupAmount(canonical: string): string {
	const [whole = '0', fraction] = canonical.split('.');
	const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
	return fraction !== undefined ? `${grouped}.${fraction}` : grouped;
}

const toUnits = (canonical: string): bigint => BigInt(canonical.replace('.', ''));

const fromUnits = (units: bigint, scale: number): string => {
	if (scale === 0) return units.toString();
	const text = units.toString().padStart(scale + 1, '0');
	return `${text.slice(0, -scale)}.${text.slice(-scale)}`;
};

export interface SplitLineInput {
	readonly pocketId: string;
	readonly name: string;
	readonly basisPoints: number;
}

export interface PreviewLine extends SplitLineInput {
	readonly amount: string;
}

/**
 * Exact split of `amount` (canonical, `scale` places) across `lines` given in
 * display order, as ledger.allocate does it: each line gets
 * floor(units × bp / 10000) minor units; the leftover units go one each to the
 * lines with the largest remainder, ties by display order. The lines always
 * add up to the amount exactly. A preview only: the server's split is final.
 */
export function allocate(
	amount: string,
	scale: number,
	lines: ReadonlyArray<SplitLineInput>
): PreviewLine[] {
	const units = toUnits(amount);
	const parts = lines.map((line, index) => {
		const product = units * BigInt(line.basisPoints);
		return { line, index, base: product / 10000n, remainder: product % 10000n };
	});
	let leftover = units - parts.reduce((sum, p) => sum + p.base, 0n);
	const ranked = [...parts].sort((a, b) =>
		a.remainder === b.remainder ? a.index - b.index : a.remainder > b.remainder ? -1 : 1
	);
	const extra = new Set<number>();
	for (const p of ranked) {
		if (leftover <= 0n) break;
		extra.add(p.index);
		leftover -= 1n;
	}
	return parts.map((p) => ({
		...p.line,
		amount: fromUnits(p.base + (extra.has(p.index) ? 1n : 0n), scale)
	}));
}

/** "40.00" → "40", "12.50" → "12.5" (for "Main · 60%"). */
export const shortPercent = (basisPoints: number) =>
	(basisPoints / 100).toFixed(2).replace(/\.?0+$/, '');

/** Today in the person's own calendar, as YYYY-MM-DD. */
export function localToday(now: Date = new Date()): string {
	const y = now.getFullYear();
	const m = String(now.getMonth() + 1).padStart(2, '0');
	const d = String(now.getDate()).padStart(2, '0');
	return `${y}-${m}-${d}`;
}

/** "AN" for "Adaeze Nwosu"; the UID's digits when there is no name. */
export function initials(name: string | null | undefined, uid: string): string {
	const words = (name ?? '').trim().split(/\s+/).filter(Boolean);
	if (words.length === 0) return uid.slice(-2);
	const first = words[0]?.[0] ?? '';
	const last = words.length > 1 ? (words[words.length - 1]?.[0] ?? '') : '';
	return `${first}${last}`.toUpperCase();
}

/** "214 KB", "1.2 MB". */
export function formatSize(bytes: number): string {
	if (bytes < 1024) return `${bytes} B`;
	if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
	return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

/** Detects PDF, JPEG or PNG from the first bytes (as the Edge Function does). */
export function sniffReceipt(bytes: Uint8Array): ReceiptMime | null {
	const starts = (sig: number[]) => sig.every((b, i) => bytes[i] === b);
	if (starts([0x25, 0x50, 0x44, 0x46, 0x2d])) return 'application/pdf';
	if (starts([0xff, 0xd8, 0xff])) return 'image/jpeg';
	if (starts([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return 'image/png';
	return null;
}

/** A local check of a chosen file before it is accepted into the list. */
export function receiptProblem(
	file: { readonly size: number; readonly type: string },
	count: number
): string | null {
	if (count >= RECEIPT_MAX_FILES) return `Add up to ${RECEIPT_MAX_FILES} receipts.`;
	if (file.size === 0) return 'That file is empty.';
	if (file.size > RECEIPT_MAX_BYTES) return 'Receipts can be up to 10 MB.';
	if (file.type && !(RECEIPT_MIME_TYPES as readonly string[]).includes(file.type)) {
		return 'Use a PDF, JPEG or PNG.';
	}
	return null;
}

export interface IncomeDraft {
	readonly targetMembershipId: string | null;
	readonly currency: Currency;
	readonly scale: number;
	readonly amount: string;
	readonly source: string;
	readonly receivedOn: string;
	readonly notes: string;
	readonly providerReference: string;
	readonly feeAmount: string;
	readonly feeCurrency: Currency;
	readonly receipts: number;
	readonly today: string;
}

export type DraftErrors = Partial<
	Record<
		| 'target'
		| 'amount'
		| 'source'
		| 'receivedOn'
		| 'notes'
		| 'providerReference'
		| 'fee'
		| 'receipts',
		string
	>
>;

/** Local validation (the server validates again; W-00 "Invalid input"). */
export function validateDraft(draft: IncomeDraft): DraftErrors {
	const errors: DraftErrors = {};
	if (!draft.targetMembershipId) errors.target = 'Choose the member.';
	if (!parseAmount(draft.amount, draft.scale)) errors.amount = 'Enter the amount received.';
	const source = draft.source.trim();
	if (source.length < 1 || source.length > 100) errors.source = 'Say where it came from.';
	if (!/^\d{4}-\d{2}-\d{2}$/.test(draft.receivedOn) || draft.receivedOn > draft.today) {
		errors.receivedOn = 'Choose a date up to today.';
	}
	if (draft.notes.trim().length > 1000) errors.notes = 'Keep notes under 1,000 characters.';
	if (draft.providerReference.trim().length > 100) {
		errors.providerReference = 'Keep the reference under 100 characters.';
	}
	if (draft.feeAmount.trim() && !parseAmount(draft.feeAmount, draft.scale)) {
		errors.fee = 'Enter the fee, or leave it empty.';
	}
	if (draft.receipts < 1) errors.receipts = 'Add the receipt.';
	return errors;
}

/** True for answers that prove nothing posted (W-00): any backend refusal but a server error. */
export const isDefinitive = (failure: ApiFailure | undefined): boolean =>
	failure?._tag === 'BackendError' && !isUnknownOutcome(failure);

/** One short line for a refused income command. */
export function incomeMessage(failure: ApiFailure | undefined): string {
	if (failure?._tag !== 'BackendError') return 'We couldn’t reach Wallet. Try again.';
	switch (failure.code) {
		case 'target_not_eligible':
			return 'This member can’t receive income right now.';
		case 'self_target_forbidden':
			return 'You can’t record income into your own wallet.';
		case 'authorization_denied':
			return 'You can’t record income for this member.';
		case 'network_not_active':
			return 'Your network isn’t active, so income can’t be recorded.';
		case 'allocation_policy_missing':
			return 'Your network has no split yet. Ask the President Team to set it.';
		case 'currency_not_supported':
			return 'That currency isn’t supported.';
		case 'evidence_required':
			return 'Add the receipt.';
		case 'evidence_invalid':
			return 'A receipt couldn’t be used. Add it again.';
		case 'attempt_cancelled':
			return 'That attempt was cancelled. Nothing was posted.';
		case 'idempotency_conflict':
			return 'This attempt doesn’t match what was sent before. Reload to continue.';
		case 'rate_limited':
			return 'Too many tries. Wait a minute and try again.';
		case 'validation_error':
			return 'Check the highlighted details.';
		case 'workspace_invalid':
			return 'Workspace changed in another tab. Reload to continue.';
		default:
			return failure.message;
	}
}

/** The form field a validation_error points at, when it names one. */
export function fieldOfFailure(failure: ApiFailure | undefined): keyof DraftErrors | null {
	if (failure?._tag !== 'BackendError' || failure.code !== 'validation_error') return null;
	const field = String(failure.details.field ?? '');
	if (field === 'amount') return 'amount';
	if (field === 'source') return 'source';
	if (field === 'receivedOn') return 'receivedOn';
	if (field === 'notes') return 'notes';
	if (field === 'providerReference') return 'providerReference';
	if (field.startsWith('fee')) return 'fee';
	if (field === 'evidenceIds' || field === 'file' || field === 'size' || field === 'mimeType') {
		return 'receipts';
	}
	return null;
}
