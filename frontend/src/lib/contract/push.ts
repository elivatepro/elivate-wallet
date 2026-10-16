// Push notifications (Blueprint 42): this device's switch. `identity` Edge
// routes /push/subscription (api.push_subscribe / push_subscription_state /
// push_unsubscribe), relayed by /api/push/subscription with the VAPID public
// key the browser subscribes with.

import { Schema } from 'effect';

/** A browser push endpoint, as the Edge route accepts it. */
export const PushEndpoint = Schema.String.check(Schema.isPattern(/^https:\/\/[!-~]{1,992}$/));

export const PushSubscribeCommand = Schema.Struct({
	endpoint: PushEndpoint,
	keys: Schema.Struct({
		p256dh: Schema.String.check(Schema.isPattern(/^B[A-Za-z0-9_-]{86}=?$/)),
		auth: Schema.String.check(Schema.isPattern(/^[A-Za-z0-9_-]{22}(==)?$/))
	}),
	hideAmounts: Schema.Boolean
});
export type PushSubscribeCommand = typeof PushSubscribeCommand.Type;

export const PushUnsubscribeCommand = Schema.Struct({ endpoint: PushEndpoint });

/** What the backend says about this device. */
export const PushDeviceState = Schema.Struct({ on: Schema.Boolean, hideAmounts: Schema.Boolean });
export type PushDeviceState = typeof PushDeviceState.Type;

/** The relay adds the key to subscribe with (null when push isn't set up). */
export const PushState = Schema.Struct({
	on: Schema.Boolean,
	hideAmounts: Schema.Boolean,
	publicKey: Schema.NullOr(Schema.String)
});
export type PushState = typeof PushState.Type;

export const PushRoutes = {
	subscribe: { method: 'PUT', path: '/push/subscription' },
	state: { method: 'GET', path: '/push/subscription' },
	unsubscribe: { method: 'DELETE', path: '/push/subscription' }
} as const;

export const PUSH_PATH = '/api/push/subscription';
