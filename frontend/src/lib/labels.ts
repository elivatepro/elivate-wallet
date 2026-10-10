import type { Role, TenantStatus } from '#lib/contract/common.js';

export const ROLE_LABELS: Record<Role, string> = {
	member: 'Member',
	team_leader: 'Team Leader',
	director: 'Director',
	world_team_member: 'World Team',
	president_team_member: 'President Team'
};

/** Network status shown only when it is not simply active. */
export const TENANT_STATUS_LABELS: Record<TenantStatus, string | null> = {
	active: null,
	pending_payment: 'Awaiting payment',
	suspended: 'Paused',
	deactivated: 'Network deactivated'
};

/**
 * Before the person proves the address, the join page shows it masked (Paper
 * "Authentication v2" 08): first character, five dots, then the domain.
 */
export function maskEmail(email: string): string {
	const at = email.lastIndexOf('@');
	if (at < 1) return '•••••';
	return `${email[0]}•••••${email.slice(at)}`;
}

/**
 * A rank as shown everywhere (owner decision 2026-10-10): the level number
 * first, "4 Ruby Director". Display only: stored values keep their own form,
 * the profile's "Ruby Director 4" and the founder key "ruby_director_4".
 */
export function rankLabel(rank: string): string {
	const words = rank.includes('_')
		? rank
				.split('_')
				.filter(Boolean)
				.map((w) => w.charAt(0).toUpperCase() + w.slice(1))
				.join(' ')
		: rank.trim();
	const numbered = /^(.*\S)\s+(\d+)$/.exec(words);
	return numbered ? `${numbered[2]} ${numbered[1]}` : words;
}
