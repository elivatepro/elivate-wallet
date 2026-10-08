// SecurityApi and OrgApi (plan §5.2): one method per route the app uses. Each
// method validates its input with the contract schema before dispatch and
// decodes the response. Reads retry at most twice on transient failures; PIN
// commands never retry (each attempt counts, Blueprint 01 B4).

import { Context, Effect, Layer, Schedule, Schema } from 'effect';
import { BackendError, isRetryableRead } from '#lib/contract/errors.js';
import { Capabilities, OrgRoutes, Workspaces, type Workspace } from '#lib/contract/org.js';
import {
	Pin,
	PinResetRequested,
	PinSetRequest,
	PinVerifyRequest,
	SecurityRoutes,
	SecurityState
} from '#lib/contract/security.js';
import { EdgeTransport, type EdgeFailure } from './edge';

const readPolicy = {
	times: 2,
	while: isRetryableRead,
	schedule: Schedule.exponential('200 millis').pipe(Schedule.jittered)
};

/** Local validation failure, shaped exactly like the Edge's own `validation_error`. */
const localValidation = (field: string, reason?: string) =>
	new BackendError({
		status: 400,
		code: 'validation_error',
		message: 'The request is invalid.',
		retryable: false,
		details: reason ? { field, reason } : { field },
		requestId: null
	});

/** Same order and rules as _shared/validate.ts matchingPins()/pin(). */
export function validate<S extends typeof PinSetRequest | typeof PinVerifyRequest>(
	schema: S,
	input: { pin: string; pinConfirm?: string }
): Effect.Effect<S['Type'], BackendError> {
	if (!Schema.is(Pin)(input.pin)) return Effect.fail(localValidation('pin'));
	if (schema === PinVerifyRequest) return Effect.succeed({ pin: input.pin } as S['Type']);
	if (!Schema.is(Pin)(input.pinConfirm)) return Effect.fail(localValidation('pinConfirm'));
	if (input.pinConfirm !== input.pin) {
		return Effect.fail(localValidation('pinConfirm', 'mismatch'));
	}
	return Effect.succeed({ pin: input.pin, pinConfirm: input.pinConfirm } as S['Type']);
}

export interface SecurityApiShape {
	readonly state: Effect.Effect<SecurityState, EdgeFailure>;
	readonly setPin: (input: {
		pin: string;
		pinConfirm: string;
	}) => Effect.Effect<SecurityState, EdgeFailure>;
	readonly verifyPin: (input: { pin: string }) => Effect.Effect<SecurityState, EdgeFailure>;
	readonly requestPinReset: Effect.Effect<PinResetRequested, EdgeFailure>;
	readonly completePinReset: (input: {
		pin: string;
		pinConfirm: string;
	}) => Effect.Effect<SecurityState, EdgeFailure>;
}

export class SecurityApi extends Context.Service<SecurityApi, SecurityApiShape>()('SecurityApi') {}

export const SecurityApiLive = Layer.effect(
	SecurityApi,
	Effect.gen(function* () {
		const edge = yield* EdgeTransport;
		return {
			state: edge
				.call({ fn: 'security', route: SecurityRoutes.state }, SecurityState)
				.pipe(Effect.retry(readPolicy)),
			setPin: (input) =>
				validate(PinSetRequest, input).pipe(
					Effect.flatMap((body) =>
						edge.call({ fn: 'security', route: SecurityRoutes.pinSet, body }, SecurityState)
					)
				),
			verifyPin: (input) =>
				validate(PinVerifyRequest, input).pipe(
					Effect.flatMap((body) =>
						edge.call({ fn: 'security', route: SecurityRoutes.pinVerify, body }, SecurityState)
					)
				),
			requestPinReset: edge.call(
				{ fn: 'security', route: SecurityRoutes.pinResetRequest, body: {} },
				PinResetRequested
			),
			completePinReset: (input) =>
				validate(PinSetRequest, input).pipe(
					Effect.flatMap((body) =>
						edge.call(
							{ fn: 'security', route: SecurityRoutes.pinResetComplete, body },
							SecurityState
						)
					)
				)
		};
	})
);

export interface OrgApiShape {
	readonly workspaces: Effect.Effect<ReadonlyArray<Workspace>, EdgeFailure>;
	readonly capabilities: (membershipId: string) => Effect.Effect<Capabilities, EdgeFailure>;
}

export class OrgApi extends Context.Service<OrgApi, OrgApiShape>()('OrgApi') {}

export const OrgApiLive = Layer.effect(
	OrgApi,
	Effect.gen(function* () {
		const edge = yield* EdgeTransport;
		return {
			workspaces: edge
				.call({ fn: 'org', route: OrgRoutes.workspaces }, Workspaces)
				.pipe(Effect.retry(readPolicy)),
			capabilities: (membershipId) =>
				edge
					.call({ fn: 'org', route: OrgRoutes.capabilities, membershipId }, Capabilities)
					.pipe(Effect.retry(readPolicy))
		};
	})
);
