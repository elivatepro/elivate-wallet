// The person picker's pure parts (Blueprint 27): what a query is, and what
// was picked. No I/O here.

import { UID_PATTERN } from '#lib/contract/common.js';

/** A person with an account, or (leader forms only) an email to invite. */
export type Picked =
	| { readonly kind: 'person'; readonly uid: string; readonly name: string | null }
	| { readonly kind: 'invite'; readonly email: string };

/** too short to search, a UID, something with an "@", or a name. */
export function pickerQuery(raw: string): 'short' | 'uid' | 'email' | 'name' {
	const q = raw.trim();
	if (q.length < 2) return 'short';
	if (UID_PATTERN.test(q.toUpperCase())) return 'uid';
	if (q.includes('@')) return 'email';
	return 'name';
}

/** The UID a form sends, when a person (not an invitation) was picked. */
export const pickedUid = (picked: Picked | null): string | null =>
	picked?.kind === 'person' ? picked.uid : null;
