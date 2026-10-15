export const THEMES = ['dark', 'light', 'system'] as const;
export type Theme = (typeof THEMES)[number];

/** Dark is the default (P-06). */
export const parseTheme = (value: string | null | undefined): Theme =>
	(THEMES as readonly string[]).includes(value ?? '') ? (value as Theme) : 'dark';

/**
 * Blueprint 41: the theme on screen. "System" follows the device, so the
 * More page's Dark mode switch shows what the person actually sees.
 */
export const effectiveTheme = (theme: Theme, deviceLight: boolean): 'dark' | 'light' =>
	theme === 'system' ? (deviceLight ? 'light' : 'dark') : theme;
