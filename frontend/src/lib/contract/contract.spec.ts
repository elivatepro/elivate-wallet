import { describe, expect, it } from 'vitest';
import { Effect, Exit, Schema } from 'effect';
import { SessionView } from './app.js';
import { decodeResponse } from './envelope.js';
import { categorize, ERROR_CODES, isRetryableRead, type ApiFailure } from './errors.js';
import * as fx from './fixtures.js';
import { Capabilities, isSelectable, Workspace, Workspaces } from './org.js';
import { SecurityState } from './security.js';

const run = <A>(effect: Effect.Effect<A, ApiFailure>) => Effect.runSync(Effect.exit(effect));
const failureOf = <A>(exit: Exit.Exit<A, ApiFailure>): ApiFailure => {
	if (Exit.isSuccess(exit)) throw new Error('expected failure');
	return Effect.runSync(Effect.flip(Effect.failCause(exit.cause))) as ApiFailure;
};

describe('error codes', () => {
	it('mirrors the 24 backend codes in _shared/http.ts', () => {
		expect(ERROR_CODES).toHaveLength(24);
		expect(new Set(ERROR_CODES).size).toBe(24);
	});
});

describe('decodeResponse', () => {
	it('returns decoded data for a success envelope', () => {
		const exit = run(decodeResponse('GET /security/state', 200, fx.success(fx.securityStateReady), SecurityState));
		expect(Exit.isSuccess(exit) && exit.value.gate).toBe('ready');
	});

	it('maps a failure envelope to a typed BackendError with details and requestId', () => {
		const exit = run(
			decodeResponse('POST /security/pin/verify', 403, fx.failure('pin_incorrect', { attemptsRemaining: 3 }), SecurityState)
		);
		const error = failureOf(exit);
		expect(error._tag).toBe('BackendError');
		if (error._tag !== 'BackendError') return;
		expect(error.code).toBe('pin_incorrect');
		expect(error.status).toBe(403);
		expect(error.details).toEqual({ attemptsRemaining: 3 });
		expect(error.requestId).toBe(fx.failure('x').requestId);
		expect(categorize(error)).toBe('validation');
	});

	it('treats an unknown error code as a contract violation, never inventing a code', () => {
		const error = failureOf(run(decodeResponse('GET /org/workspaces', 409, fx.failure('brand_new_code'), Workspaces)));
		expect(error._tag).toBe('ContractViolation');
		expect(categorize(error)).toBe('defect');
	});

	it('treats a non-envelope body (gateway 401, HTML 502) as a TransportError', () => {
		const gateway = failureOf(run(decodeResponse('GET /security/state', 401, { msg: 'Invalid JWT' }, SecurityState)));
		expect(gateway).toMatchObject({ _tag: 'TransportError', reason: 'non_envelope', status: 401 });
		expect(categorize(gateway)).toBe('authentication');
		const html = failureOf(run(decodeResponse('GET /security/state', 502, undefined, SecurityState)));
		expect(html).toMatchObject({ _tag: 'TransportError', status: 502 });
		expect(isRetryableRead(html)).toBe(true);
	});

	it('rejects success data that does not match the route schema', () => {
		const bad = { ...fx.securityStateReady, gate: 'step_up' };
		const error = failureOf(run(decodeResponse('GET /security/state', 200, fx.success(bad), SecurityState)));
		expect(error._tag).toBe('ContractViolation');
	});
});

describe('security schemas', () => {
	const decode = Schema.decodeUnknownSync(SecurityState);
	it('accepts the four gate values and a null step-up window', () => {
		expect(decode(fx.securityStateSetup).stepUpExpiresAt).toBeNull();
		expect(decode(fx.securityStateReady).uid).toBe('EW-10042');
	});
	it('rejects malformed UIDs, out-of-range attempts and bad timestamps', () => {
		expect(() => decode({ ...fx.securityStateReady, uid: 'EW-0001' })).toThrow();
		expect(() => decode({ ...fx.securityStateReady, attemptsRemaining: 6 })).toThrow();
		expect(() => decode({ ...fx.securityStateReady, stepUpExpiresAt: 'soon' })).toThrow();
	});
});

describe('org schemas', () => {
	it('decodes workspaces and keeps unknown permission keys as strings', () => {
		expect(Schema.decodeUnknownSync(Workspaces)([fx.workspace])).toHaveLength(1);
		expect(Schema.decodeUnknownSync(Capabilities)(fx.capabilities).permissions).toContain(
			'some_future_permission'
		);
	});
	it('ignores extra response fields the backend may add', () => {
		const decoded = Schema.decodeUnknownSync(Workspace)({ ...fx.workspace, addedLater: 1 });
		expect(decoded.tenantName).toBe('Sunrise Network');
	});
	it('rejects an ended membership in the workspace list', () => {
		expect(() => Schema.decodeUnknownSync(Workspace)({ ...fx.workspace, status: 'ended' })).toThrow();
	});
	it('lets active memberships open even when the network awaits payment or is suspended', () => {
		const w = Schema.decodeUnknownSync(Workspace)(fx.workspace);
		expect(isSelectable(w)).toBe(true);
		expect(isSelectable({ ...w, tenantStatus: 'suspended' })).toBe(true);
		expect(isSelectable({ ...w, status: 'suspended' })).toBe(false);
	});
});

describe('app endpoint schema', () => {
	it('decodes the /api/session view', () => {
		const view = Schema.decodeUnknownSync(SessionView)({
			state: fx.securityStateReady,
			workspace: fx.workspace,
			capabilities: fx.capabilities
		});
		expect(view.workspace?.membershipId).toBe(fx.workspace.membershipId);
	});
});
