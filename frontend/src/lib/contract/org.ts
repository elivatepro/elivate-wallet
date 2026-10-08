// `org` Edge Function contract for M1 (plan §6.2): workspaces and capabilities.
// Derived from backend/supabase/functions/org/handler.ts and api.my_workspaces /
// api.my_capabilities on main. Later milestones add the remaining routes here.

import { Schema } from 'effect';
import { OfficeType, Role, TenantStatus, Uuid } from './common';

export const Workspace = Schema.Struct({
	membershipId: Uuid,
	tenantId: Uuid,
	tenantName: Schema.String,
	tenantShortName: Schema.String,
	tenantStatus: TenantStatus,
	officeId: Schema.NullOr(Uuid),
	officeName: Schema.NullOr(Schema.String),
	officeType: Schema.NullOr(OfficeType),
	role: Role,
	// my_workspaces returns non-ended memberships only.
	status: Schema.Literals(['active', 'suspended']),
	isPrimary: Schema.Boolean
});
export type Workspace = typeof Workspace.Type;

export const Workspaces = Schema.Array(Workspace);

export const Capabilities = Schema.Struct({
	membershipId: Uuid,
	tenantStatus: TenantStatus,
	// Unknown permission keys are kept but ignored by the UI (plan §6.3, W-25).
	permissions: Schema.Array(Schema.String)
});
export type Capabilities = typeof Capabilities.Type;

export const OrgRoutes = {
	workspaces: { method: 'GET', path: '/workspaces' },
	capabilities: { method: 'GET', path: '/capabilities' }
} as const;

/**
 * A workspace can be opened when the membership is active, whatever the network
 * status (authz.require_workspace checks only the membership and its office;
 * decision 21 keeps own money visible in suspended networks). The office status
 * is not in this list, so the server re-validates with GET /capabilities.
 */
export const isSelectable = (w: Workspace): boolean => w.status === 'active';
