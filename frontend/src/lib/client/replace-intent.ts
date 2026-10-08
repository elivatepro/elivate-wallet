// Hand-off from the Replace dialog (Paper "App — Screens v4" Z05) to the
// add-account page in replace mode: the reason and the PIN typed in the
// dialog. Memory only (never storage, URL or cache), read once, then gone.

export interface ReplaceIntent {
	readonly payoutAccountId: string;
	readonly reason: string;
	readonly pin: string | undefined;
}

let intent: ReplaceIntent | null = null;

export function setReplaceIntent(next: ReplaceIntent): void {
	intent = next;
}

/** The intent for this account, once; null when absent or for another account. */
export function takeReplaceIntent(payoutAccountId: string): ReplaceIntent | null {
	const found = intent && intent.payoutAccountId === payoutAccountId ? intent : null;
	intent = null;
	return found;
}
