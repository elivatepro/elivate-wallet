// Small text helpers shared by the admin console pages (Blueprint 18).
// Client-safe: no I/O.

/** "Dayo Kalu" → "Dayo K."; one word stays as it is; null → fallback. */
export function shortName(name: string | null | undefined, fallback = '—'): string {
	const words = (name ?? '').trim().split(/\s+/).filter(Boolean);
	if (words.length === 0) return fallback;
	if (words.length === 1) return words[0]!;
	return `${words[0]} ${words.at(-1)!.charAt(0).toUpperCase()}.`;
}

/** "1 network", "3 networks". */
export const plural = (n: number, one: string, many = `${one}s`): string =>
	`${n} ${n === 1 ? one : many}`;

/** A person's label: their name, else their UID, else the fallback. */
export const personName = (
	person: { uid: string; name: string | null } | null | undefined,
	fallback = '—'
): string => person?.name ?? person?.uid ?? fallback;
