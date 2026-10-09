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
	// Paper "App — Screens v2" O/R (org management, Blueprint 07).
	| 'offices'
	| 'office'
	| 'office-new'
	| 'office-rename'
	| 'office-leader'
	| 'roles'
	| 'cross-access'
	| 'reviewers'
	| 'member'
	| 'member-suspend'
	| 'member-move'
	| 'member-end'
	// Paper "App — Screens v4" N01–N04 (owner approved 2026-10-08).
	| 'office-close'
	| 'office-closed'
	| 'member-role'
	| 'office-place'
	| 'account-security'
	| 'account-devices'
	| 'account-pin-change'
	| 'dialog-replace'
	| 'dialog-remove'
	| 'dialog-sign-out'
	| 'dialog-profile'
	// Paper "App — Screens v1" B16/B16d (pocket watch) and T04 (clipboard).
	| 'checking'
	| 'team'
	// Paper "App — Screens v4" Q02 (magnet), Q04 (podium skyline), Q05 (framed ID).
	| 'no-matches'
	| 'member-wallets'
	| 'member-wallet'
	| 'income-abacus'
	| 'income-posted'
	| 'income-checking'
	| 'income-refused'
	// Paper "App — Screens v2" W01 (wall calendar), W05 (traffic light); v1 M06
	// (paper plane), C01/C05/C07 (stamp, post box, two receipts), C09 (gavel),
	// B05 (carry coin).
	| 'withdrawals'
	| 'withdraw'
	| 'queue'
	| 'queue-checking'
	| 'queue-correction'
	| 'evidence-review'
	| 'pocket-move'
	| 'transfers'
	// Paper "App — Screens v4" U01 (magnifier), U04 (party popper), MV02–MV05
	// (balance scale, two coins, U-turn sign); "App — Screens v2" W07
	// (boomerang), W09 (mailbox).
	| 'payout-reveal'
	| 'payout-done'
	| 'adjust'
	| 'convert'
	| 'reverse'
	| 'returned-funds'
	| 'returned-checking';

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
	// Paper "App — Screens v2" O01/O07/O04/O10/O12, R01/R03/R05/R07/R09/R11/R13.
	offices: 507,
	office: 525,
	'office-new': 512,
	'office-rename': 512,
	'office-leader': 512,
	roles: 446,
	'cross-access': 513,
	reviewers: 446,
	member: 446,
	'member-suspend': 502,
	'member-move': 442,
	'member-end': 502,
	'office-close': 512,
	'office-closed': 521,
	'member-role': 442,
	'office-place': 512,
	// Paper "App — Screens v1" B09/B10 (Profile & security, padlock) and
	// "App — Screens v2" S03/S04 (juggling devices), S05/S06 (shh, secret).
	'account-security': 525,
	'account-devices': 525,
	'account-pin-change': 525,
	// Paper "App — Screens v4" Z04–Z07 dialogs (reused poses, flagged on the layers):
	// relay baton (B01), coin back in slot (W03), sleep mask (X05), name badge (R05).
	'dialog-replace': 525,
	'dialog-remove': 525,
	'dialog-sign-out': 525,
	'dialog-profile': 525,
	checking: 525,
	team: 525,
	'no-matches': 525,
	'member-wallets': 525,
	'member-wallet': 525,
	// Paper "App — Screens v4" J01–J05 (existing poses reused: Abacus from E01,
	// Thumbs up from M08, Pocket watch from B16, Handing back from C03).
	'income-abacus': 520,
	'income-posted': 520,
	'income-checking': 520,
	'income-refused': 520,
	withdrawals: 518,
	withdraw: 523,
	queue: 524,
	'queue-checking': 524,
	'queue-correction': 524,
	'evidence-review': 524,
	'pocket-move': 525,
	transfers: 524,
	'payout-reveal': 522,
	'payout-done': 523,
	adjust: 524,
	convert: 527,
	reverse: 527,
	'returned-funds': 520,
	'returned-checking': 499
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
