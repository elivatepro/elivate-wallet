// Platform Admin site (Blueprint 18): the session gate every admin page uses,
// the PIN step-up every admin command uses, and safe form messages. Pages are
// server-rendered (no offline cache of admin data); the Edge Function and the
// database make the real checks.

import { error, fail, redirect, type ActionFailure, type RequestEvent } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import type { AdminMe } from '#lib/contract/admin.js';
import type { SecurityState } from '#lib/contract/security.js';
import { SecurityApi } from './apis';
import { AdminApi } from './apis-admin';
import type { VerifiedSession } from './auth';
import type { EdgeFailure } from './edge';
import { failureOf } from './flow';
import { runApi, type ApiServices } from './request';

export const ADMIN_PATHS = {
	signIn: '/admin/sign-in',
	pin: '/admin/pin',
	setupPin: '/admin/setup-pin',
	pinLocked: '/admin/pin-locked',
	noAccess: '/admin/no-access',
	home: '/admin'
} as const;

const GATE_TO_PATH: Record<SecurityState['gate'], string> = {
	pin_setup_required: ADMIN_PATHS.setupPin,
	pin_required: ADMIN_PATHS.pin,
	pin_locked: ADMIN_PATHS.pinLocked,
	ready: ADMIN_PATHS.home
};

/** Admin page for a gate/auth failure code, or null. */
export function adminPathForCode(code: string): string | null {
	switch (code) {
		case 'authentication_required':
			return ADMIN_PATHS.signIn;
		case 'pin_setup_required':
			return ADMIN_PATHS.setupPin;
		case 'pin_required':
			return ADMIN_PATHS.pin;
		case 'pin_locked':
			return ADMIN_PATHS.pinLocked;
		case 'account_blocked':
		case 'authorization_denied':
			return ADMIN_PATHS.noAccess;
		default:
			return null;
	}
}

/** Gate/auth failures go to their admin page; anything else is a safe 503. */
export function adminRedirectFor(failure: EdgeFailure): never {
	if (failure._tag === 'BackendError') {
		const path = adminPathForCode(failure.code);
		if (path) redirect(303, path);
		if (failure.code === 'not_found') error(404, 'Not found');
	}
	if (failure._tag === 'TransportError' && failure.status === 401)
		redirect(303, ADMIN_PATHS.signIn);
	if (failure._tag === 'ContractViolation') {
		console.error(
			JSON.stringify({ route: failure.route, requestId: failure.requestId, contract: 'violation' })
		);
	}
	error(503, 'Admin is unavailable right now. Try again shortly.');
}

/** Runs an admin program; gate failures redirect, others become a 503/404. */
export async function adminCall<A>(
	event: RequestEvent,
	session: VerifiedSession,
	program: Effect.Effect<A, EdgeFailure, ApiServices>
): Promise<A> {
	const exit = await runApi(event, session, program);
	if (Exit.isSuccess(exit)) return exit.value;
	adminRedirectFor(failureOf(exit));
}

/** The security gate state of the signed-in account (no admin check). */
export async function adminGateState(
	event: RequestEvent
): Promise<{ session: VerifiedSession; state: SecurityState }> {
	const session = await event.locals.session();
	if (!session) redirect(303, ADMIN_PATHS.signIn);
	const state = await adminCall(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* SecurityApi).state;
		})
	);
	return { session, state };
}

/** Where a gate state belongs on the admin site. */
export const adminPathForGate = (gate: SecurityState['gate']): string => GATE_TO_PATH[gate];

/**
 * Every console page: signed in, PIN verified this session, and an active
 * platform admin. Anything else goes to its gate page.
 */
export async function requireAdmin(
	event: RequestEvent
): Promise<{ session: VerifiedSession; me: AdminMe }> {
	const { session, state } = await adminGateState(event);
	if (state.gate !== 'ready') redirect(303, GATE_TO_PATH[state.gate]);
	const me = await adminCall(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* AdminApi).me;
		})
	);
	if (!me.isAdmin) redirect(303, ADMIN_PATHS.noAccess);
	return { session, me };
}

/** A fresh idempotency key for one form (kept across resubmits of that form). */
export function newKey(): string {
	return `adm${crypto.randomUUID().replaceAll('-', '')}`;
}

const KEY_PATTERN = /^[A-Za-z0-9_-]{16,100}$/;

export interface CommandForm {
	readonly reason: string;
	readonly pin: string;
	readonly idempotencyKey: string;
	readonly form: FormData;
}

/** Reason (3–500), 4-digit PIN and idempotency key from a dialog form. */
export async function readCommandForm(
	event: RequestEvent
): Promise<CommandForm | ActionFailure<{ error: string; reason?: string }>> {
	const form = await event.request.formData();
	const reason = String(form.get('reason') ?? '').trim();
	const pin = String(form.get('pin') ?? '');
	const idempotencyKey = String(form.get('idempotencyKey') ?? '');
	if (!KEY_PATTERN.test(idempotencyKey))
		return fail(400, { error: 'Reload the page and try again.' });
	if (reason.length < 3 || reason.length > 500) {
		return fail(400, { error: 'Give a reason (3 to 500 characters).', reason });
	}
	if (!/^[0-9]{4}$/.test(pin)) return fail(400, { error: 'Enter your 4-digit PIN.', reason });
	return { reason, pin, idempotencyKey, form };
}

const CONFLICT_MESSAGES: Readonly<Record<string, string>> = {
	invalid_transition: 'That step is no longer possible. Reload to see the latest status.',
	last_platform_admin: 'The last platform admin cannot be removed.',
	not_dead_lettered: 'That email is no longer waiting. Reload the list.',
	not_pending: 'This network already has the development exception.',
	archive_unavailable: 'The backup file is no longer available.',
	operation_paused: 'That operation is stopped right now.',
	already_decided: 'Another admin already decided this application. Reload the list.',
	already_accepted: 'The founder already accepted this invitation.',
	not_approved: 'Only an approved application can get a new invitation.',
	resend_limit:
		'This invitation has been sent 6 times, the limit. Once the last link expires, the founder can apply again.'
};

/** A safe sentence for a command failure shown in its dialog. */
export function commandMessage(failure: EdgeFailure): string {
	if (failure._tag !== 'BackendError') return 'Something went wrong. Try again.';
	switch (failure.code) {
		case 'validation_error':
			return failure.details.field === 'reason'
				? 'Give a reason (3 to 500 characters).'
				: 'Check the details and try again.';
		case 'pin_incorrect': {
			const left = Number(failure.details.attemptsRemaining);
			const tries = Number.isInteger(left) ? ` ${left} ${left === 1 ? 'try' : 'tries'} left.` : '';
			return `That PIN is incorrect.${tries}`;
		}
		case 'step_up_required':
			return 'Enter your PIN again to confirm.';
		case 'self_target_forbidden':
			return "You can't do this to your own account.";
		case 'idempotency_conflict':
			return 'This form was already used for something else. Reload and try again.';
		case 'network_not_active':
			return 'This network is deactivated.';
		case 'not_found':
			return 'Not found. Reload the page.';
		case 'conflict': {
			const reason = String(failure.details.reason ?? '');
			return CONFLICT_MESSAGES[reason] ?? 'This can’t be done right now. Reload and try again.';
		}
		default:
			return 'Something went wrong. Try again.';
	}
}

/**
 * Confirms the PIN (opening the five-minute step-up window for this session,
 * A-05), then runs the command. Never retried: each PIN attempt counts.
 * Gate failures redirect; a locked PIN goes to its page.
 */
export async function withStepUp<A>(
	event: RequestEvent,
	session: VerifiedSession,
	pin: string,
	program: Effect.Effect<A, EdgeFailure, ApiServices>
): Promise<{ ok: true; value: A } | { ok: false; message: string; status: number }> {
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			yield* (yield* SecurityApi).verifyPin({ pin });
			return yield* program;
		})
	);
	if (Exit.isSuccess(exit)) return { ok: true, value: exit.value };
	const failure = failureOf(exit);
	if (failure._tag === 'BackendError') {
		if (failure.code === 'pin_locked') redirect(303, ADMIN_PATHS.pinLocked);
		const gate = adminPathForCode(failure.code);
		if (gate && failure.code !== 'authorization_denied') redirect(303, gate);
		if (failure.code === 'authorization_denied') redirect(303, ADMIN_PATHS.noAccess);
		return { ok: false, message: commandMessage(failure), status: failure.status };
	}
	return { ok: false, message: commandMessage(failure), status: 503 };
}
