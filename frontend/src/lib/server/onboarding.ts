// First-use wizard (W-02 order 2026-10-08; Paper "Onboarding — Invited member"):
// welcome → PIN → NIN → details → profile + rank → bank account → all set.
// Blueprint 22: setup differs by role, and the backend decides the step. The
// security state carries `setup` (identity.setup_state): the light setup
// (President Team, directors whose funds are not managed) is PIN → name,
// photo and rank; the wallet setup adds the NIN, the phone and the bank
// account. Every page asks `nextStep`, so the wizard resumes after sign-out,
// never repeats durable steps and can't be skipped by URL. The backend refuses
// every other call (`profile_required`) until it is done.

import { redirect, type Cookies, type RequestEvent } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { UUID_PATTERN } from '#lib/contract/common.js';
import type { Profile } from '#lib/contract/identity.js';
import { isSelectable } from '#lib/contract/org.js';
import type { SecurityState, SetupLevel } from '#lib/contract/security.js';
import { GATE_PATHS, safeAppNext } from '#lib/gate.js';
import { IdentityApi } from './apis-identity';
import type { VerifiedSession } from './auth';
import { localExportsDir } from './config';
import { readWorkspace } from './cookies';
import { failureOf, loadState, redirectForFailure } from './flow';
import { nextStepFor, type Step } from '#lib/onboarding-steps.js';
import { runApi } from './request';
import { listWorkspaces } from './workspace';

export const ONBOARDING_COOKIE = 'ew_onb';
/** Blueprint 22: the page the gate interrupted, opened once setup is done. */
export const ONBOARDING_NEXT_COOKIE = 'ew_onb_next';
export const ONBOARDING_PATH = '/onboarding';

export type { Step } from '#lib/onboarding-steps.js';
export { stepNumber, stepTotal } from '#lib/onboarding-steps.js';

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

/** Remembers a safe app page (or /setup) to return to after the wizard. */
export function rememberNext(cookies: Cookies, next: string | null, secure: boolean) {
	const safe = safeAppNext(next);
	if (!safe) return;
	cookies.set(ONBOARDING_NEXT_COOKIE, safe, {
		path: ONBOARDING_PATH,
		httpOnly: true,
		secure,
		sameSite: 'lax',
		maxAge: 60 * 60
	});
}

export function readNext(cookies: Cookies): string | null {
	return safeAppNext(cookies.get(ONBOARDING_NEXT_COOKIE));
}

export function clearOnboarding(cookies: Cookies) {
	cookies.delete(ONBOARDING_COOKIE, { path: '/' });
	cookies.delete(ONBOARDING_NEXT_COOKIE, { path: ONBOARDING_PATH });
}

export interface Wizard {
	readonly session: VerifiedSession;
	readonly state: SecurityState;
	/** Null before the PIN exists (profile reads need the PIN). */
	readonly profile: Profile | null;
	readonly membershipId: string | null;
	/** Which setup the person owes (Blueprint 22); the wallet setup if unknown. */
	readonly level: SetupLevel;
	/** The membership the bank step uses (the backend's choice). */
	readonly walletMembershipId: string | null;
}

let bindings: Promise<{ readonly PHOTOS?: PhotoBucket }> | null = null;

/**
 * Local e2e only (E2E_LOCAL_EXPORTS with a loopback Supabase, like exports):
 * photos on disk, so the wizard asks for a photo exactly as it does on the
 * deployed Worker, where the backend requires one (Blueprint 22).
 */
function localPhotos(dir: string): PhotoBucket {
	const path = async (key: string) => {
		const { join } = await import('node:path');
		if (!/^[a-z]+\/[0-9a-f-]{36}\/[0-9a-z.-]+$/i.test(key)) throw new Error('bad photo key');
		return join(dir, key.replaceAll('/', '_'));
	};
	return {
		async put(key, value, options) {
			const fs = await import('node:fs/promises');
			await fs.mkdir(dir, { recursive: true });
			await fs.writeFile(await path(key), new Uint8Array(value));
			await fs.writeFile(`${await path(key)}.type`, options?.httpMetadata?.contentType ?? '');
		},
		async get(key) {
			const fs = await import('node:fs/promises');
			try {
				const bytes = await fs.readFile(await path(key));
				const contentType = await fs.readFile(`${await path(key)}.type`, 'utf8').catch(() => '');
				return { body: new Response(bytes).body!, httpMetadata: { contentType } };
			} catch {
				return null;
			}
		},
		async delete(key) {
			const fs = await import('node:fs/promises');
			await fs.rm(await path(key), { force: true });
			await fs.rm(`${await path(key)}.type`, { force: true });
		}
	};
}

/**
 * The private R2 bucket (Blueprint 06 B4), or null when it isn't bound. Read
 * lazily from cloudflare:workers: the Worker runtime provides it; plain Node
 * (vite preview, tests) cannot load that module, which means "no storage"
 * unless the local e2e store is configured.
 */
export async function photoStorage(): Promise<PhotoBucket | null> {
	const local = localExportsDir();
	if (local) return localPhotos(`${local}/photos`);
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

/** Past the PIN: the setup (if any) is all that is left. */
const pastPin = (state: SecurityState) =>
	state.gate === 'ready' || state.gate === 'profile_required';

/** The onboarding cookie's membership, else the remembered or first selectable workspace. */
async function membershipFor(
	event: RequestEvent,
	session: VerifiedSession,
	state: SecurityState
): Promise<string | null> {
	const fromCookie = readOnboardingMembership(event.cookies);
	if (!pastPin(state)) return fromCookie;
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
	const profile = pastPin(state) ? await profileOf(event, session) : null;
	return {
		session,
		state,
		profile,
		membershipId: await membershipFor(event, session, state),
		level: state.setup?.level ?? 'wallet',
		walletMembershipId: state.setup?.walletMembershipId ?? null
	};
}

/** Where the person is; `null` once everything is done (see nextStepFor). */
export function nextStep(wizard: Wizard): Step | null {
	return nextStepFor(wizard.state.gate, wizard.state.setup, wizard.profile !== null);
}

/** Sends a page to the step the person belongs on, unless it is one of `allowed`. */
export async function expectStep(event: RequestEvent, ...allowed: Step[]) {
	const wizard = await loadWizard(event);
	const step = nextStep(wizard);
	if (step === null) {
		if (!allowed.includes('done')) redirect(303, stepPath('done'));
	} else if (!allowed.includes(step)) {
		redirect(303, stepPath(step));
	}
	return { wizard, step };
}
