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
