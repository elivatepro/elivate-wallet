// Theme choice in the signed-in shell (W-01 Light/Dark/System). Same
// non-sensitive cookie the server-rendered pages read.

import { parseTheme, type Theme } from '#lib/theme.js';

export const THEME_LABELS: Record<Theme, string> = {
	light: 'Light',
	dark: 'Dark',
	system: 'System'
};

export class Appearance {
	theme: Theme = $state('dark');

	/** The prerendered shell ships with the default theme; follow the cookie. */
	start(): void {
		this.theme = parseTheme(document.cookie.match(/(?:^|; )ew_theme=([^;]+)/)?.[1]);
		document.documentElement.dataset.theme = this.theme;
	}

	set(value: string): void {
		this.theme = parseTheme(value);
		document.documentElement.dataset.theme = this.theme;
		const secure = location.protocol === 'https:' ? '; Secure' : '';
		document.cookie = `ew_theme=${this.theme}; Path=/; Max-Age=31536000; SameSite=Lax${secure}`;
	}
}
