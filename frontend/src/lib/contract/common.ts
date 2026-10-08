// Shared wire schemas (plan §6.0). Derived from backend/supabase/functions/_shared
// and the api.* JSON builders on main. Responses may carry extra fields (the
// backend may add fields); requests must not (the Edge rejects unknown keys).

import { Schema } from 'effect';

export const UID_PATTERN = /^EW-[1-9][0-9]{4,}$/;
export const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const PIN_PATTERN = /^[0-9]{4}$/;
export const IDEMPOTENCY_KEY_PATTERN = /^[A-Za-z0-9_-]{16,100}$/;

/** Permanent person identifier, as returned (upper-case). */
export const Uid = Schema.String.check(Schema.isPattern(UID_PATTERN));

/** Lower-case UUID, as the backend serializes Postgres uuids. */
export const Uuid = Schema.String.check(Schema.isPattern(UUID_PATTERN));

/** Postgres timestamptz serialized to JSON; must parse as a date. */
export const IsoDateTime = Schema.String.check(
	Schema.makeFilter((s: string) => !Number.isNaN(Date.parse(s)) || 'expected an ISO date-time')
);

export const Role = Schema.Literals([
	'member',
	'team_leader',
	'director',
	'world_team_member',
	'president_team_member'
]);
export type Role = typeof Role.Type;

export const OfficeType = Schema.Literals(['world_team', 'director', 'team_leader']);
export type OfficeType = typeof OfficeType.Type;

export const TenantStatus = Schema.Literals([
	'pending_payment',
	'active',
	'suspended',
	'deactivated'
]);
export type TenantStatus = typeof TenantStatus.Type;

export const AccountStatus = Schema.Literals(['active', 'restricted', 'suspended', 'deactivated']);
export type AccountStatus = typeof AccountStatus.Type;

export const Person = Schema.NullOr(
	Schema.Struct({
		uid: Uid,
		name: Schema.NullOr(Schema.String)
	})
);
