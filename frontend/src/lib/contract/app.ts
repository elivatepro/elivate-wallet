// Contract of the app server's own same-origin JSON endpoints (decision 36).
// The browser decodes these with Effect Schema exactly like the server decodes
// the Edge Functions.

import { Schema } from 'effect';
import { Capabilities, Workspace } from './org';
import { SecurityState } from './security';

/** GET /api/session: who is signed in, the gate, and the selected workspace. */
export const SessionView = Schema.Struct({
	state: SecurityState,
	workspace: Schema.NullOr(Workspace),
	capabilities: Schema.NullOr(Capabilities)
});
export type SessionView = typeof SessionView.Type;

export const AppRoutes = {
	session: { method: 'GET', path: '/api/session' }
} as const;
