// Theme choice in the signed-in shell (W-01 Light/Dark/System). Same
// non-sensitive cookie the server-rendered pages read.

import { effectiveTheme, parseTheme, type Theme } from '#lib/theme.js';

export const THEME_LABELS: Record<Theme, string> = {
	light: 'Light',
	dark: 'Dark',
	system: 'System'
};

export class Appearance {
	theme: Theme = $state('dark');
	/** Blueprint 41: the device asks for light (what "System" shows). */
	deviceLight = $state(false);
	/** Blueprint 41: the theme on screen, with "System" resolved. */
	readonly shown = $derived(effectiveTheme(this.theme, this.deviceLight));

	/** The prerendered shell ships with the default theme; follow the cookie. */
	start(): () => void {
		this.theme = parseTheme(document.cookie.match(/(?:^|; )ew_theme=([^;]+)/)?.[1]);
		document.documentElement.dataset.theme = this.theme;
		const media = window.matchMedia('(prefers-color-scheme: light)');
		this.deviceLight = media.matches;
		const onChange = () => (this.deviceLight = media.matches);
		media.addEventListener('change', onChange);
		return () => media.removeEventListener('change', onChange);
	}

	set(value: string): void {
		this.theme = parseTheme(value);
		document.documentElement.dataset.theme = this.theme;
		const secure = location.protocol === 'https:' ? '; Secure' : '';
		document.cookie = `ew_theme=${this.theme}; Path=/; Max-Age=31536000; SameSite=Lax${secure}`;
	}
}
