// Root mascot poses exported 1×/2× WebP from Paper "App — Screens v3" (owner
// approved 2026-10-08; existing poses only). Files live in static/root/.

import { getContext, onDestroy, setContext } from 'svelte';

export type RootPose =
	| 'confirm-email'
	| 'link-expired'
	| 'pin-create'
	| 'pin-locked'
	| 'pin-forgot'
	| 'pin-reset-sent'
	| 'pin-new'
	| 'blocked'
	| 'workspaces'
	| 'no-workspace'
	| 'invitations'
	| 'offline-empty'
	| 'load-error'
	| 'notifications'
	| 'home-empty'
	| 'home'
	| 'split'
	| 'payout-accounts'
	| 'invitations-manage'
	| 'onboard-welcome'
	| 'onboard-pin'
	| 'onboard-verifying'
	| 'onboard-retry'
	| 'onboard-waiting'
	| 'onboard-confirm'
	| 'onboard-profile'
	| 'onboard-bank'
	| 'onboard-stop'
	| 'onboard-done'
	| 'income-abacus'
	| 'income-posted'
	| 'income-checking'
	| 'income-refused';

/** Rendered Root size on mobile gate screens (Paper: 120×160, 150×200, 180×240). */
export type RootSize = 'sm' | 'md' | 'lg';

/** Exported pixel size of each 1× file (2× is double). */
export const ROOT_HEIGHTS: Record<RootPose, number> = {
	'confirm-email': 520,
	'link-expired': 520,
	'pin-create': 520,
	'pin-locked': 520,
	'pin-forgot': 520,
	'pin-reset-sent': 520,
	'pin-new': 520,
	blocked: 520,
	workspaces: 520,
	'no-workspace': 520,
	invitations: 520,
	'offline-empty': 523,
	'load-error': 523,
	notifications: 520,
	'home-empty': 520,
	// Paper "App — Screens v3" H04/H06 balance card (Root on the coin stack).
	home: 525,
	// L01/L02 split editor, Y02 payout accounts, I01 invitations hero.
	split: 520,
	'payout-accounts': 523,
	'invitations-manage': 524,
	// Paper "Onboarding — Invited member" · Root — Onboarding poses.
	'onboard-welcome': 525,
	'onboard-pin': 525,
	'onboard-verifying': 525,
	'onboard-retry': 525,
	'onboard-waiting': 525,
	'onboard-confirm': 525,
	'onboard-profile': 525,
	'onboard-bank': 525,
	'onboard-stop': 525,
	'onboard-done': 525,
	// Paper "App — Screens v4" J01–J05 (existing poses reused: Abacus from E01,
	// Thumbs up from M08, Pocket watch from B16, Handing back from C03).
	'income-abacus': 520,
	'income-posted': 520,
	'income-checking': 520,
	'income-refused': 520
};

export const rootSrc = (pose: RootPose) => `/root/${pose}.webp`;
export const rootSrcset = (pose: RootPose) => `/root/${pose}.webp 390w, /root/${pose}@2x.webp 780w`;

/** Which Root the auth/gate layout shows; set by the page during its own render. */
export class RootStage {
	pose: RootPose | null = $state(null);
	size: RootSize = $state('lg');
	owner: symbol | null = null;
}

const KEY = Symbol('root-stage');

export function provideRootStage(): RootStage {
	return setContext(KEY, new RootStage());
}

/**
 * Called from a gate page's script. The layout renders the stage after the page
 * in the DOM (and moves it first with CSS order), so this also works in SSR.
 */
export function useRoot(
	pose: RootPose | (() => RootPose),
	size: RootSize | (() => RootSize) = 'lg'
): void {
	const stage = getContext<RootStage | undefined>(KEY);
	if (!stage) return;
	const currentPose = typeof pose === 'function' ? pose : () => pose;
	const currentSize = typeof size === 'function' ? size : () => size;
	const owner = Symbol('root-owner');
	stage.owner = owner;
	stage.pose = currentPose();
	stage.size = currentSize();
	// Pages whose state changes after a form post (e.g. G06 → G07) pass getters.
	if (typeof pose === 'function' || typeof size === 'function') {
		$effect.pre(() => {
			stage.pose = currentPose();
			stage.size = currentSize();
		});
	}
	// The next page may already have claimed the stage when this one unmounts.
	onDestroy(() => {
		if (stage.owner !== owner) return;
		stage.owner = null;
		stage.pose = null;
	});
}
