// Contract of the app server's own same-origin JSON endpoints (decision 36).
// The browser decodes these with Effect Schema exactly like the server decodes
// the Edge Functions.

import { Schema } from 'effect';
import { ActivityItem, WalletNetwork } from './ledger';
import { Capabilities, Workspace } from './org';
import { SecurityState } from './security';

/** GET /api/session: who is signed in, the gate, and the selected workspace. */
export const SessionView = Schema.Struct({
	state: SecurityState,
	workspace: Schema.NullOr(Workspace),
	capabilities: Schema.NullOr(Capabilities),
	/** Own name and photo flag (Blueprint 06); null when unavailable. Never cached on device. */
	profile: Schema.NullOr(
		Schema.Struct({ name: Schema.NullOr(Schema.String), hasPhoto: Schema.Boolean })
	)
});
export type SessionView = typeof SessionView.Type;

/**
 * GET /api/home: the selected network's slice of the person's own wallet
 * (W-07), its latest activity and the split percentages. `network` is null
 * when the person has no wallet here (e.g. President Team only).
 */
export const HomeView = Schema.Struct({
	network: Schema.NullOr(WalletNetwork),
	activity: Schema.Array(ActivityItem),
	split: Schema.NullOr(
		Schema.Array(Schema.Struct({ pocketId: Schema.String, percent: Schema.String }))
	)
});
export type HomeView = typeof HomeView.Type;

export const AppRoutes = {
	session: { method: 'GET', path: '/api/session' },
	home: { method: 'GET', path: '/api/home' }
} as const;
