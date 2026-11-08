// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import {readFileSync} from 'node:fs'

const tasq = JSON.parse(
	readFileSync(new URL("../editors/vscode/syntaxes/tasq.tmLanguage.json", import.meta.url),'utf-8'),
);

// https://astro.build/config
export default defineConfig({
	site: 'https://masnyjimmy.github.io/',
	base: '/tasq/',
	integrations: [
		starlight({
			title: 'Tasq Docs',
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/masnyjimmy/tasq' }],
			sidebar: [
				{
					label: 'Getting started',
					items: [
						// Each item here is one entry in the navigation menu.
						{ label: 'Installation', slug: 'getting-started/installation' },
						{ label: 'Quick start', slug: 'getting-started/quick-start' },
					],
				},
			],
			expressiveCode: {
				shiki: {
					langs: [{...tasq, name: 'tasq'}],
				},
			},
		}),
	],
});
