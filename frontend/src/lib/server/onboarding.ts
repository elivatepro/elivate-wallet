// First-use wizard (W-02 order 2026-10-08; Paper "Onboarding — Invited member"):
// welcome → PIN → NIN → details → profile + rank → bank account → all set.
// Every page asks `nextStep` where the person really is, so the wizard resumes
// after sign-out, never repeats durable steps and can't be skipped by URL.

import { redirect, type Cookies, type RequestEvent } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { UUID_PATTERN } from '#lib/contract/common.js';
import type { Profile } from '#lib/contract/identity.js';
import { isSelectable } from '#lib/contract/org.js';
import type { SecurityState } from '#lib/contract/security.js';
import { GATE_PATHS } from '#lib/gate.js';
import { IdentityApi, PayoutApi } from './apis-identity';
import type { VerifiedSession } from './auth';
import { readWorkspace } from './cookies';
import { failureOf, loadState, redirectForFailure } from './flow';
import { runApi } from './request';
import { listWorkspaces } from './workspace';

export const ONBOARDING_COOKIE = 'ew_onb';
export const ONBOARDING_PATH = '/onboarding';

export type Step = 'pin' | 'identity' | 'details' | 'profile' | 'bank' | 'done';

/** "Step n / 4" in the progress bar (Paper: PIN 1, identity 2, profile 3, bank 4). */
export const STEP_NUMBER: Record<Step, number> = {
	pin: 1,
	identity: 2,
	details: 2,
	profile: 3,
	bank: 4,
	done: 4
};

export const stepPath = (step: Step) => `${ONBOARDING_PATH}/${step}`;

/** The membership the wizard works in: set when an invitation is accepted. */
export function readOnboardingMembership(cookies: Cookies): string | null {
	const value = cookies.get(ONBOARDING_COOKIE);
	return value && UUID_PATTERN.test(value) ? value : null;
}

export function writeOnboardingMembership(cookies: Cookies, membershipId: string, secure: boolean) {
	cookies.set(ONBOARDING_COOKIE, membershipId, {
		path: '/',
		httpOnly: true,
		secure,
		sameSite: 'lax',
		maxAge: 60 * 60 * 24 * 30
	});
}

export function clearOnboarding(cookies: Cookies) {
	cookies.delete(ONBOARDING_COOKIE, { path: '/' });
}

export interface Wizard {
	readonly session: VerifiedSession;
	readonly state: SecurityState;
	/** Null before the PIN exists (profile reads need gate `ready`). */
	readonly profile: Profile | null;
	readonly membershipId: string | null;
	readonly photoRequired: boolean;
}

let bindings: Promise<{ readonly PHOTOS?: PhotoBucket }> | null = null;

/**
 * The private R2 bucket (Blueprint 06 B4), or null when it isn't bound. Read
 * lazily from cloudflare:workers: the Worker runtime provides it; plain Node
 * (vite preview, tests) cannot load that module, which means "no storage".
 * Photos are required exactly when storage exists.
 */
export async function photoStorage(): Promise<PhotoBucket | null> {
	bindings ??= import('cloudflare:workers').then(
		(m) => m.env,
		() => ({})
	);
	return (await bindings).PHOTOS ?? null;
}

async function profileOf(event: RequestEvent, session: VerifiedSession): Promise<Profile> {
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* IdentityApi).profile;
		})
	);
	if (Exit.isSuccess(exit)) return exit.value;
	redirectForFailure(failureOf(exit));
}

/** The onboarding cookie's membership, else the remembered or first selectable workspace. */
async function membershipFor(
	event: RequestEvent,
	session: VerifiedSession,
	state: SecurityState
): Promise<string | null> {
	const fromCookie = readOnboardingMembership(event.cookies);
	if (state.gate !== 'ready') return fromCookie;
	const workspaces = (await listWorkspaces(event, session)).filter(isSelectable);
	const preferred = [fromCookie, readWorkspace(event.cookies)];
	for (const id of preferred) {
		const hit = workspaces.find((w) => w.membershipId === id);
		if (hit) return hit.membershipId;
	}
	return workspaces.find((w) => w.isPrimary)?.membershipId ?? workspaces[0]?.membershipId ?? null;
}

export async function loadWizard(event: RequestEvent): Promise<Wizard> {
	const { session, state } = await loadState(event);
	if (state.gate === 'pin_required')
		redirect(303, `${GATE_PATHS.pin_required}?next=${ONBOARDING_PATH}`);
	if (state.gate === 'pin_locked') redirect(303, GATE_PATHS.pin_locked);
	const profile = state.gate === 'ready' ? await profileOf(event, session) : null;
	return {
		session,
		state,
		profile,
		membershipId: await membershipFor(event, session, state),
		photoRequired: (await photoStorage()) !== null
	};
}

/** Whether the person still owes a payout account (members with a wallet only). */
async function needsBank(event: RequestEvent, wizard: Wizard): Promise<boolean> {
	if (!wizard.membershipId) return false;
	const membershipId = wizard.membershipId;
	const exit = await runApi(
		event,
		wizard.session,
		Effect.gen(function* () {
			const payout = yield* PayoutApi;
			if (!(yield* payout.walletExists)) return false;
			const accounts = yield* payout.accounts(membershipId);
			return !accounts.some((a) => a.status === 'active');
		})
	);
	if (Exit.isSuccess(exit)) return exit.value;
	const failure = failureOf(exit);
	// No self-service payout permission or no wallet here (e.g. President Team only).
	if (
		failure._tag === 'BackendError' &&
		['authorization_denied', 'no_wallet', 'workspace_invalid'].includes(failure.code)
	) {
		return false;
	}
	redirectForFailure(failure);
}

export const profileComplete = (profile: Profile, photoRequired: boolean) =>
	(!photoRequired || profile.hasPhoto) && profile.rank !== null && profile.phone !== null;

/** Where the person is; `null` once everything is done. */
export async function nextStep(event: RequestEvent, wizard: Wizard): Promise<Step | null> {
	if (wizard.state.gate === 'pin_setup_required') return 'pin';
	const profile = wizard.profile;
	if (!profile) return 'pin';
	if (profile.identity.status !== 'verified') return 'identity';
	if (!profileComplete(profile, wizard.photoRequired)) return 'profile';
	if (await needsBank(event, wizard)) return 'bank';
	return null;
}

/** Sends a page to the step the person belongs on, unless it is one of `allowed`. */
export async function expectStep(event: RequestEvent, ...allowed: Step[]) {
	const wizard = await loadWizard(event);
	const step = await nextStep(event, wizard);
	if (step === null) {
		if (!allowed.includes('done')) redirect(303, stepPath('done'));
	} else if (!allowed.includes(step)) {
		redirect(303, stepPath(step));
	}
	return { wizard, step };
}

/**
 * Used by the workspace picker: true when a signed-in, PIN-ready person with
 * a workspace still has onboarding to do. Any failure to tell is "no" (the
 * wizard must never lock people out of their wallet).
 */
export async function onboardingIncomplete(event: RequestEvent, session: VerifiedSession) {
	try {
		const exit = await runApi(
			event,
			session,
			Effect.gen(function* () {
				return yield* (yield* IdentityApi).profile;
			})
		);
		if (Exit.isFailure(exit)) return false;
		const profile = exit.value;
		if (profile.identity.status !== 'verified') return true;
		return !profileComplete(profile, (await photoStorage()) !== null);
	} catch {
		return false;
	}
}
