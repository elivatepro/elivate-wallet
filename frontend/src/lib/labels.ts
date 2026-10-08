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
	suspended: 'Network suspended',
	deactivated: 'Network deactivated'
};
