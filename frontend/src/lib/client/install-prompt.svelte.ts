// Blueprint 35: Chromium's install prompt, kept from the moment the app loads
// (the event fires once, often before the install step is open).

interface BeforeInstallPromptEvent extends Event {
	prompt(): Promise<void>;
	readonly userChoice: Promise<{ outcome: 'accepted' | 'dismissed' }>;
}

class InstallPrompt {
	event: BeforeInstallPromptEvent | null = $state(null);
	installed = $state(false);
}

export const installPrompt = new InstallPrompt();

let listening = false;

/** Called once by the root layout, in the browser. */
export function listenForInstallPrompt(): void {
	if (listening) return;
	listening = true;
	addEventListener('beforeinstallprompt', (event) => {
		// Keep it for our own button instead of the browser's mini-infobar.
		event.preventDefault();
		installPrompt.event = event as BeforeInstallPromptEvent;
	});
	addEventListener('appinstalled', () => {
		installPrompt.installed = true;
		installPrompt.event = null;
	});
}

/** Shows the browser's install dialog; true if the person installed. */
export async function promptInstall(): Promise<boolean> {
	const event = installPrompt.event;
	if (!event) return false;
	installPrompt.event = null; // a prompt can be shown only once
	await event.prompt();
	const { outcome } = await event.userChoice;
	return outcome === 'accepted';
}

/** Already opened from the home screen, dock or Start menu. */
export function runningInstalled(): boolean {
	return (
		matchMedia('(display-mode: standalone)').matches ||
		(navigator as Navigator & { standalone?: boolean }).standalone === true
	);
}
