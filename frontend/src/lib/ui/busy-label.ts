// Blueprint 41: a command button that is working says so ("Save changes" →
// "Saving…") next to its spinner, the same way in every dialog. The first
// word is the verb; a particle after it stays ("Sign out others" →
// "Signing out…"). Labels that aren't commands read "Working…".

/** Verbs whose last consonant doubles (British spelling: "Cancelling"). */
const DOUBLED = new Set(['submit', 'cancel', 'stop', 'set', 'get', 'put', 'run', 'drop', 'plan']);
const PARTICLES = new Set(['out', 'in', 'up', 'off', 'on']);
const NOT_VERBS = new Set(['got', 'ok', 'okay', 'yes', 'no', 'done']);

function gerund(verb: string): string {
	const lower = verb.toLowerCase();
	if (DOUBLED.has(lower)) return `${verb}${verb.slice(-1)}ing`;
	if (lower.endsWith('ie')) return `${verb.slice(0, -2)}ying`;
	if (lower.endsWith('e') && !lower.endsWith('ee') && !lower.endsWith('ye'))
		return `${verb.slice(0, -1)}ing`;
	return `${verb}ing`;
}

export function busyLabel(label: string): string {
	const [verb, next] = label.trim().split(/\s+/);
	if (!verb || !/^[A-Za-z]+$/.test(verb) || NOT_VERBS.has(verb.toLowerCase())) return 'Working…';
	const particle = next && PARTICLES.has(next.toLowerCase()) ? ` ${next}` : '';
	return `${gerund(verb)}${particle}…`;
}
