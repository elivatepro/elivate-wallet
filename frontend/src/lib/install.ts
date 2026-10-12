// Blueprint 35: which install screen a device gets (Paper "Install app v9").
// Pure, so it runs on the server (no flash of the wrong screen) and in tests.

/**
 * - `ios`: Safari has no install prompt, so IA02 shows the three taps.
 * - `android` / `desktop`: Chromium's install prompt (IA01 / IA03).
 * - `mac-safari`: File › Add to Dock (Safari 17+), no prompt.
 * - `in-app`: a browser inside another app, which can't install at all.
 */
export type InstallDevice = 'ios' | 'android' | 'desktop' | 'mac-safari' | 'in-app';

const IN_APP =
	/FBAN|FBAV|FB_IAB|Instagram|WhatsApp|Snapchat|TikTok|musical_ly|Line\/|LinkedInApp|Twitter/i;

/**
 * `touchPoints` tells an iPad (which reports itself as a Mac) from a Mac; the
 * server doesn't know it and passes 0, and the page corrects it on mount.
 */
export function installDeviceFor(userAgent: string, touchPoints = 0): InstallDevice {
	if (IN_APP.test(userAgent)) return 'in-app';
	const mac = /Macintosh/.test(userAgent);
	if (/iPhone|iPad|iPod/.test(userAgent) || (mac && touchPoints > 1)) return 'ios';
	if (/Android/.test(userAgent)) return 'android';
	if (mac && /Safari\//.test(userAgent) && !/Chrome\/|Chromium\/|Edg\/|Firefox\//.test(userAgent)) {
		return 'mac-safari';
	}
	return 'desktop';
}
